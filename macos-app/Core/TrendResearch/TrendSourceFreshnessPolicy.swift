import Foundation

enum TrendQuoteType: String, Codable, Hashable, Sendable {
    case indexQuote
    case lastTrade
    case intradayEstimate
    case officialNAV
    case previousClose
    case unknown
}

enum TrendFreshnessStatus: String, Codable, Hashable, Sendable {
    case fresh
    case previousSessionClose
    case stale
    case unknown

    var isFreshForExecution: Bool {
        self == .fresh
    }
}

enum TrendMarketSession: String, Codable, Hashable, Sendable {
    case preOpen
    case trading
    case breakTime
    case closed
    case unknown
}

struct TrendQuoteAssessment: Codable, Hashable, Sendable {
    let quoteType: TrendQuoteType
    let freshnessStatus: TrendFreshnessStatus
    let asOf: String?
    let receivedAt: String
    let ageSeconds: Double?
    let marketSession: TrendMarketSession

    var isFreshForExecution: Bool {
        freshnessStatus.isFreshForExecution
            && (marketSession == .preOpen || marketSession == .trading)
    }
}

enum TrendSourceFreshnessPolicy {
    static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func assess(
        quoteType: TrendQuoteType,
        asOf: String?,
        receivedAt: String,
        maxIntradayAgeMinutes: Double = 20
    ) -> TrendQuoteAssessment {
        let receivedDate = parse(receivedAt)
        let quoteDate = asOf.flatMap(parse)
        let session = receivedDate.map(marketSession) ?? .unknown
        let ageSeconds: Double?
        if let receivedDate, let quoteDate {
            ageSeconds = receivedDate.timeIntervalSince(quoteDate)
        } else {
            ageSeconds = nil
        }

        let status: TrendFreshnessStatus
        switch quoteType {
        case .indexQuote, .lastTrade, .intradayEstimate:
            guard let ageSeconds, ageSeconds >= -120 else {
                status = .unknown
                break
            }
            if session == .preOpen || session == .trading || session == .breakTime {
                status = ageSeconds <= maxIntradayAgeMinutes * 60 ? .fresh : .stale
            } else if let receivedDate, let quoteDate,
                      isRecentTradingDay(quoteDate, relativeTo: receivedDate) {
                status = quoteType == .intradayEstimate ? .stale : .previousSessionClose
            } else {
                status = .stale
            }

        case .officialNAV:
            guard let receivedDate, let quoteDate else {
                status = .unknown
                break
            }
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: quoteDate),
                to: calendar.startOfDay(for: receivedDate)
            ).day ?? Int.max
            status = (0...4).contains(days) ? .fresh : .stale

        case .previousClose:
            guard let receivedDate, let quoteDate else {
                status = .unknown
                break
            }
            status = isRecentTradingDay(quoteDate, relativeTo: receivedDate)
                ? .previousSessionClose
                : .stale

        case .unknown:
            status = .unknown
        }

        return TrendQuoteAssessment(
            quoteType: quoteType,
            freshnessStatus: status,
            asOf: asOf,
            receivedAt: receivedAt,
            ageSeconds: ageSeconds,
            marketSession: session
        )
    }

    static func marketSession(at date: Date) -> TrendMarketSession {
        let weekday = calendar.component(.weekday, from: date)
        guard weekday != 1, weekday != 7 else { return .closed }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return .unknown }
        let minuteOfDay = hour * 60 + minute
        switch minuteOfDay {
        case (9 * 60 + 15)..<(9 * 60 + 30):
            return .preOpen
        case (9 * 60 + 30)...(11 * 60 + 30),
             (13 * 60)...(15 * 60):
            return .trading
        case (11 * 60 + 31)..<(13 * 60):
            return .breakTime
        default:
            return .closed
        }
    }

    static func parse(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = chinaTimeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    private static func isRecentTradingDay(_ quoteDate: Date, relativeTo referenceDate: Date) -> Bool {
        let quoteDay = calendar.startOfDay(for: quoteDate)
        let referenceDay = calendar.startOfDay(for: referenceDate)
        guard quoteDay <= referenceDay else { return false }
        let days = calendar.dateComponents([.day], from: quoteDay, to: referenceDay).day ?? Int.max
        return days <= 4
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = chinaTimeZone
        return value
    }
}
