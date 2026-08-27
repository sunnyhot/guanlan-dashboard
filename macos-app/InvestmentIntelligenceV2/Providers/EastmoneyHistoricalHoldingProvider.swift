import Foundation

// MARK: - EastmoneyHistoricalHoldingProvider（M2 live PIT 链）
//
// FundLookThroughClient 的产品接口只返回当前可用的最新披露。M2 需要验证一条
// 已经发生的 Q2 披露，因此这里直接消费天天基金公开的历史归档表格和公告 API，
// 仍然只产 ProviderRecord，不修改 Core client，也不写 Canonical。

enum EastmoneyHoldingArchiveKind: String, Sendable, Hashable {
    case stocks = "jjcc"
    case bonds = "zqcc"

    var providerScheme: String {
        switch self {
        case .stocks: return "stock_symbol"
        case .bonds: return "bond_symbol"
        }
    }
}

struct EastmoneyFundAnnouncement: Sendable, Hashable {
    let title: String
    let publishedAt: Date
    let identifier: String
}

enum EastmoneyHistoricalHoldingError: Error, Equatable, Sendable {
    case invalidAnnouncementResponse
    case announcementNotFound(reportDate: Date)
    case holdingArchiveNotFound(reportDate: Date, kind: EastmoneyHoldingArchiveKind)
    case invalidHoldingArchive(reportDate: Date, kind: EastmoneyHoldingArchiveKind)
}

struct EastmoneyFundAnnouncementParser: Sendable {
    private struct Envelope: Decodable {
        let data: [Record]?
        let errorCode: Int?

        enum CodingKeys: String, CodingKey {
            case data = "Data"
            case errorCode = "ErrCode"
        }
    }

    private struct Record: Decodable {
        let title: String
        let publishedAt: String
        let identifier: String

        enum CodingKeys: String, CodingKey {
            case title = "TITLE"
            case publishedAt = "PUBLISHDATEDesc"
            case identifier = "ID"
        }
    }

    func parse(_ body: String) throws -> [EastmoneyFundAnnouncement] {
        guard let data = body.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.errorCode == nil || envelope.errorCode == 0,
              let records = envelope.data else {
            throw EastmoneyHistoricalHoldingError.invalidAnnouncementResponse
        }

        return records.compactMap { record in
            guard let publishedAt = Self.parseShanghaiDay(record.publishedAt) else { return nil }
            return EastmoneyFundAnnouncement(
                title: record.title,
                publishedAt: publishedAt,
                identifier: record.identifier
            )
        }
    }

    private static func parseShanghaiDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var shanghaiCalendar = Calendar(identifier: .gregorian)
        shanghaiCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
            .map { formatter.calendar.startOfDay(for: $0) }
    }
}

struct EastmoneyHoldingArchiveParser: Sendable {
    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func parse(
        _ body: String,
        reportDate: Date,
        kind: EastmoneyHoldingArchiveKind
    ) throws -> [FundHoldingPayload.Position] {
        let reportDateText = Self.dateFormatter.string(from: reportDate)
        let escapedDate = NSRegularExpression.escapedPattern(for: reportDateText)
        let markerPattern = "截止至：\\s*<font[^>]*>\\s*\(escapedDate)\\s*</font>"
        guard let marker = Self.firstMatch(in: body, pattern: markerPattern),
              let tableStart = body[marker.upperBound...].range(of: "<table"),
              let tableEnd = body[tableStart.upperBound...].range(of: "</table>") else {
            return []
        }

        let table = String(body[tableStart.lowerBound..<tableEnd.upperBound])
        let rows = Self.allMatches(in: table, pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#)
        var positions: [FundHoldingPayload.Position] = []

        for row in rows {
            let cells = Self.allMatches(in: row, pattern: #"<td[^>]*>([\s\S]*?)</td>"#)
                .map { Self.decodeHTML(Self.stripHTML($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 5,
                  Int(cells[0]) != nil,
                  !cells[1].isEmpty,
                  !cells[2].isEmpty,
                  let weightText = cells.reversed().first(where: { $0.contains("%") }),
                  let weightPercent = Decimal(string: weightText
                    .replacingOccurrences(of: "%", with: "")
                    .replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)),
                  weightPercent > 0,
                  weightPercent <= 100 else {
                continue
            }

            positions.append(FundHoldingPayload.Position(
                providerID: .eastmoney,
                providerCode: ProviderCode(
                    scheme: kind.providerScheme,
                    value: cells[1]
                ),
                weight: Ratio(value: weightPercent / 100),
                shares: nil,
                marketValue: nil,
                isDisclosed: true
            ))
        }

        guard !positions.isEmpty else {
            throw EastmoneyHistoricalHoldingError.invalidHoldingArchive(reportDate: reportDate, kind: kind)
        }
        return positions
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = shanghaiCalendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func firstMatch(
        in text: String,
        pattern: String
    ) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return Range(match.range, in: text)
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}

/// 读取指定历史报告的真实天天基金持仓，并把公告日期从公告 API 取出。
struct EastmoneyHistoricalHoldingProviderAdapter: ProviderAdapter {
    let providerID: DataProviderID = .eastmoney
    let reliabilityClass: ProviderReliabilityClass = .communityAggregated

    private let fetcher: any ResponseFetcher
    private let reportDate: Date
    private let ingestedAt: @Sendable () -> Date
    private let announcementParser = EastmoneyFundAnnouncementParser()
    private let holdingParser = EastmoneyHoldingArchiveParser()

    init(
        fetcher: any ResponseFetcher,
        reportDate: Date,
        ingestedAt: @escaping @Sendable () -> Date = { .now }
    ) {
        self.fetcher = fetcher
        self.reportDate = reportDate
        self.ingestedAt = ingestedAt
    }

    func fetch(code: ProviderCode, from: Date, to: Date) async throws -> [ProviderRecord] {
        try await fetchWithDiagnostics(code: code, from: from, to: to).records
    }

    func fetchWithDiagnostics(
        code: ProviderCode,
        from: Date,
        to: Date
    ) async throws -> ProviderFetchResult {
        // fund_code（兼容既有调用方）与 fund_product_code（持仓快照的 canonical
        // 维度——ObservationFactory 要求 FundProduct 目标）都接受，输出保持
        // 输入 scheme，由调用方按 identity 登记形态选择。
        guard code.scheme == "fund_code" || code.scheme == "fund_product_code" else {
            return ProviderFetchResult(records: [], diagnostics: ProviderFetchDiagnostics())
        }

        async let stockBody = fetcher.fetch(
            .eastmoneyHoldingArchive(
                fundCode: code.value,
                kind: .stocks,
                reportDate: Self.dateFormatter.string(from: reportDate)
            )
        )
        async let bondBody = fetcher.fetch(
            .eastmoneyHoldingArchive(
                fundCode: code.value,
                kind: .bonds,
                reportDate: Self.dateFormatter.string(from: reportDate)
            )
        )
        async let announcementBody = fetcher.fetch(
            .eastmoneyFundAnnouncements(fundCode: code.value, reportType: 3)
        )

        let announcements = try announcementParser.parse(try await announcementBody)
        let year = Self.calendar.component(.year, from: reportDate)
        let quarter = (Self.calendar.component(.month, from: reportDate) - 1) / 3 + 1
        guard let announcement = announcements.first(where: {
            $0.title.contains("\(year)年第\(quarter)季度报告")
                || $0.title.contains("\(year)年\(Self.chineseQuarter(quarter))季度报告")
        }) else {
            throw EastmoneyHistoricalHoldingError.announcementNotFound(reportDate: reportDate)
        }

        let stocks = try holdingParser.parse(
            try await stockBody,
            reportDate: reportDate,
            kind: .stocks
        )
        let bonds: [FundHoldingPayload.Position]
        do {
            bonds = try holdingParser.parse(
                try await bondBody,
                reportDate: reportDate,
                kind: .bonds
            )
        } catch EastmoneyHistoricalHoldingError.invalidHoldingArchive {
            // A fund may have no bond table for the target period. This is a legitimate
            // empty asset class; the stock table remains the authoritative disclosure.
            bonds = []
        }

        let positions = stocks + bonds
        let payload = FundHoldingPayload(
            reportPeriod: Self.reportPeriod(for: reportDate),
            positions: positions,
            disclosedWeightTotal: Ratio(value: min(
                Decimal(1),
                positions.reduce(Decimal.zero) { $0 + $1.weight.value }
            ))
        )
        let rawPayload = try JSONEncoder().encode(payload)
        let record = ProviderRecord(
            providerID: providerID,
            providerCode: code,
            effectiveAt: reportDate,
            publishedAt: announcement.publishedAt,
            ingestedAt: ingestedAt(),
            kind: .fundHoldingSnapshot,
            rawPayload: rawPayload,
            reliabilityClass: reliabilityClass,
            jurisdiction: .chinaMainland
        )
        let filtered = (from...to).contains(reportDate) ? [record] : []
        return ProviderFetchResult(
            records: filtered,
            diagnostics: ProviderFetchDiagnostics()
        )
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func chineseQuarter(_ quarter: Int) -> String {
        ["一", "二", "三", "四"].indices.contains(quarter - 1)
            ? ["一", "二", "三", "四"][quarter - 1]
            : String(quarter)
    }

    private static func reportPeriod(for date: Date) -> FundHoldingSnapshot.ReportPeriod {
        switch calendar.component(.month, from: date) {
        case 1...3: return .q1
        case 4...6: return .q2
        case 7...9: return .q3
        default: return .q4
        }
    }
}
