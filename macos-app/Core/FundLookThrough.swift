import Foundation

enum FundUnderlyingAssetKind: String, Codable, Hashable, Sendable {
    case stock
    case bond

    var displayName: String {
        switch self {
        case .stock:
            return "股票"
        case .bond:
            return "债券"
        }
    }
}

struct FundUnderlyingHolding: Codable, Hashable, Sendable {
    let code: String
    let name: String
    let kind: FundUnderlyingAssetKind
    /// 占基金净值比例，使用 0...100 百分数口径。
    let weightPct: Double
    let disclosureDate: String
}

struct FundIndustryExposure: Codable, Hashable, Sendable {
    let name: String
    /// 占基金净值比例，使用 0...100 百分数口径。
    let weightPct: Double
    let disclosureDate: String
}

struct FundAssetAllocation: Codable, Hashable, Sendable {
    let stockPct: Double?
    let bondPct: Double?
    let cashPct: Double?
    let otherPct: Double?
    let disclosureDate: String
}

struct FundLookThroughDisclosure: Codable, Hashable, Sendable {
    let fundCode: String
    let fundName: String
    /// 各披露来源中最新的截止日期；细项仍保留各自 disclosureDate。
    let asOf: String
    let holdings: [FundUnderlyingHolding]
    let industries: [FundIndustryExposure]
    let assetAllocation: FundAssetAllocation?
    let sourceLabel: String
    let sourceURL: String
    let warnings: [String]

    var disclosedSecurityWeightPct: Double {
        min(100, holdings.reduce(0) { $0 + max(0, $1.weightPct) })
    }
}

struct FundLookThroughBatchResult: Sendable {
    let disclosures: [String: FundLookThroughDisclosure]
    let warnings: [String]
}

protocol FundLookThroughClientProtocol: Sendable {
    func fetchDisclosures(fundCodes: [String]) async -> FundLookThroughBatchResult
}

struct PortfolioLookThroughContributor: Codable, Hashable, Sendable {
    let fundCode: String?
    let fundName: String
    let fundPortfolioWeightPct: Double
    let underlyingWeightPct: Double
    let portfolioWeightPct: Double
    let disclosureDate: String?
    let isDirectHolding: Bool
}

struct PortfolioLookThroughPosition: Codable, Hashable, Sendable, Identifiable {
    let code: String
    let name: String
    let kind: FundUnderlyingAssetKind
    /// 穿透后占当前组合有效暴露的比例，使用 0...100 百分数口径。
    let portfolioWeightPct: Double
    let contributors: [PortfolioLookThroughContributor]

    var id: String { "\(kind.rawValue):\(code)" }
}

struct PortfolioLookThroughIndustry: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let portfolioWeightPct: Double

    var id: String { name }
}

struct PortfolioLookThroughAssetClass: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let portfolioWeightPct: Double

    var id: String { name }
}

struct PortfolioFundLookThroughSummary: Codable, Hashable, Sendable {
    let fundCode: String
    let fundName: String
    let portfolioWeightPct: Double
    let asOf: String?
    let disclosedSecurityWeightPct: Double
    let topHoldingCount: Int
    let industryCount: Int
    let warnings: [String]
}

struct PortfolioLookThroughSnapshot: Codable, Hashable, Sendable {
    let expectedFundCount: Int
    let coveredFundCount: Int
    /// 有披露数据基金占全部基金有效暴露的比例。
    let fundDataCoveragePct: Double
    /// 已披露底层证券占整个组合有效暴露的比例。
    let disclosedSecurityCoveragePct: Double
    /// 基金中未被股票/债券披露明细覆盖的组合比例。
    let unknownPortfolioWeightPct: Double
    let topPositions: [PortfolioLookThroughPosition]
    let industries: [PortfolioLookThroughIndustry]
    let assetClasses: [PortfolioLookThroughAssetClass]
    let funds: [PortfolioFundLookThroughSummary]
    let disclosures: [String: FundLookThroughDisclosure]
    let warnings: [String]
}

enum PortfolioLookThroughCalculator {
    static func make(
        rows: [PersonalAssetAggregateRow],
        disclosures: [String: FundLookThroughDisclosure],
        generatedAt: String
    ) -> PortfolioLookThroughSnapshot? {
        let exposedRows = rows.filter { $0.effectiveHoldingAmount > 0.001 }
        let totalExposure = exposedRows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        guard totalExposure > 0 else { return nil }

        let fundRows = exposedRows.filter { $0.assetType == .fund && $0.fundCode?.isEmpty == false }
        guard !fundRows.isEmpty else { return nil }

        let fundExposure = fundRows.reduce(0) { $0 + $1.effectiveHoldingAmount }
        var coveredFundExposure = 0.0
        var disclosedSecurityCoverage = 0.0
        var positionAccumulators: [String: PositionAccumulator] = [:]
        var industryWeights: [String: Double] = [:]
        var assetClassWeights: [String: Double] = [:]
        var fundSummaries: [PortfolioFundLookThroughSummary] = []
        var warnings: [String] = []

        for row in fundRows {
            guard let code = row.fundCode else { continue }
            let portfolioWeight = row.effectiveHoldingAmount / totalExposure * 100
            guard let disclosure = disclosures[code] else {
                fundSummaries.append(
                    PortfolioFundLookThroughSummary(
                        fundCode: code,
                        fundName: row.fundName,
                        portfolioWeightPct: rounded(portfolioWeight),
                        asOf: nil,
                        disclosedSecurityWeightPct: 0,
                        topHoldingCount: 0,
                        industryCount: 0,
                        warnings: ["暂无可用的底层持仓披露。"]
                    )
                )
                continue
            }

            coveredFundExposure += row.effectiveHoldingAmount
            let disclosedWeight = disclosure.disclosedSecurityWeightPct
            disclosedSecurityCoverage += portfolioWeight * disclosedWeight / 100

            for holding in disclosure.holdings {
                let contribution = portfolioWeight * holding.weightPct / 100
                guard contribution > 0 else { continue }
                let key = "\(holding.kind.rawValue):\(holding.code)"
                var accumulator = positionAccumulators[key]
                    ?? PositionAccumulator(code: holding.code, name: holding.name, kind: holding.kind)
                accumulator.portfolioWeightPct += contribution
                accumulator.contributors.append(
                    PortfolioLookThroughContributor(
                        fundCode: code,
                        fundName: row.fundName,
                        fundPortfolioWeightPct: rounded(portfolioWeight),
                        underlyingWeightPct: rounded(holding.weightPct),
                        portfolioWeightPct: rounded(contribution),
                        disclosureDate: holding.disclosureDate,
                        isDirectHolding: false
                    )
                )
                positionAccumulators[key] = accumulator
            }

            for industry in disclosure.industries {
                industryWeights[industry.name, default: 0] += portfolioWeight * industry.weightPct / 100
            }

            if let allocation = disclosure.assetAllocation {
                addAllocation(allocation.stockPct, name: "股票", portfolioWeight: portfolioWeight, into: &assetClassWeights)
                addAllocation(allocation.bondPct, name: "债券", portfolioWeight: portfolioWeight, into: &assetClassWeights)
                addAllocation(allocation.cashPct, name: "现金", portfolioWeight: portfolioWeight, into: &assetClassWeights)
                addAllocation(allocation.otherPct, name: "其他", portfolioWeight: portfolioWeight, into: &assetClassWeights)
            }

            fundSummaries.append(
                PortfolioFundLookThroughSummary(
                    fundCode: code,
                    fundName: row.fundName,
                    portfolioWeightPct: rounded(portfolioWeight),
                    asOf: disclosure.asOf,
                    disclosedSecurityWeightPct: rounded(disclosedWeight),
                    topHoldingCount: disclosure.holdings.count,
                    industryCount: disclosure.industries.count,
                    warnings: disclosure.warnings
                )
            )
        }

        // 直接股票也放入穿透后的证券暴露，便于识别“直接持有 + 基金间接持有”的重叠。
        for row in exposedRows where row.assetType == .stock {
            guard let code = row.fundCode, !code.isEmpty else { continue }
            let portfolioWeight = row.effectiveHoldingAmount / totalExposure * 100
            let key = "\(FundUnderlyingAssetKind.stock.rawValue):\(code)"
            var accumulator = positionAccumulators[key]
                ?? PositionAccumulator(code: code, name: row.fundName, kind: .stock)
            accumulator.portfolioWeightPct += portfolioWeight
            accumulator.contributors.append(
                PortfolioLookThroughContributor(
                    fundCode: nil,
                    fundName: row.fundName,
                    fundPortfolioWeightPct: rounded(portfolioWeight),
                    underlyingWeightPct: 100,
                    portfolioWeightPct: rounded(portfolioWeight),
                    disclosureDate: nil,
                    isDirectHolding: true
                )
            )
            positionAccumulators[key] = accumulator
            assetClassWeights["股票", default: 0] += portfolioWeight
        }

        let staleFunds = fundSummaries.filter {
            guard let asOf = $0.asOf else { return false }
            return isStale(disclosureDate: asOf, generatedAt: generatedAt)
        }
        if !staleFunds.isEmpty {
            warnings.append(
                "\(staleFunds.count) 只基金的最新披露距分析日超过 150 天，穿透结果可能明显滞后。"
            )
        }
        let missingCount = fundRows.count - disclosures.keys.filter { code in
            fundRows.contains { $0.fundCode == code }
        }.count
        if missingCount > 0 {
            warnings.append("\(missingCount) 只基金未取得底层披露，未覆盖部分保留为未知仓位。")
        }
        warnings.append("基金底层证券来自公开定期报告，并非实时完整持仓；主动基金可能在报告日后调仓。")

        let positions = positionAccumulators.values
            .map { accumulator in
                PortfolioLookThroughPosition(
                    code: accumulator.code,
                    name: accumulator.name,
                    kind: accumulator.kind,
                    portfolioWeightPct: rounded(accumulator.portfolioWeightPct),
                    contributors: accumulator.contributors.sorted {
                        $0.portfolioWeightPct > $1.portfolioWeightPct
                    }
                )
            }
            .sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }

        let industries = industryWeights
            .map { PortfolioLookThroughIndustry(name: $0.key, portfolioWeightPct: rounded($0.value)) }
            .sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }
        let assetClasses = assetClassWeights
            .map { PortfolioLookThroughAssetClass(name: $0.key, portfolioWeightPct: rounded($0.value)) }
            .sorted { $0.portfolioWeightPct > $1.portfolioWeightPct }

        let fundDataCoverage = fundExposure > 0 ? coveredFundExposure / fundExposure * 100 : 0
        let unknownWeight = max(0, fundExposure / totalExposure * 100 - disclosedSecurityCoverage)

        return PortfolioLookThroughSnapshot(
            expectedFundCount: fundRows.count,
            coveredFundCount: fundRows.filter { row in
                row.fundCode.map { disclosures[$0] != nil } ?? false
            }.count,
            fundDataCoveragePct: rounded(fundDataCoverage),
            disclosedSecurityCoveragePct: rounded(disclosedSecurityCoverage),
            unknownPortfolioWeightPct: rounded(unknownWeight),
            topPositions: positions,
            industries: industries,
            assetClasses: assetClasses,
            funds: fundSummaries.sorted { $0.portfolioWeightPct > $1.portfolioWeightPct },
            disclosures: disclosures,
            warnings: warnings
        )
    }

    private struct PositionAccumulator {
        let code: String
        var name: String
        let kind: FundUnderlyingAssetKind
        var portfolioWeightPct = 0.0
        var contributors: [PortfolioLookThroughContributor] = []
    }

    private static func addAllocation(
        _ allocationPct: Double?,
        name: String,
        portfolioWeight: Double,
        into values: inout [String: Double]
    ) {
        guard let allocationPct, allocationPct > 0 else { return }
        values[name, default: 0] += portfolioWeight * allocationPct / 100
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func isStale(disclosureDate: String, generatedAt: String) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        guard let disclosure = dayFormatter.date(from: String(disclosureDate.prefix(10))),
              let generated = dayFormatter.date(from: String(generatedAt.prefix(10))),
              let days = calendar.dateComponents([.day], from: disclosure, to: generated).day else {
            return false
        }
        return days > 150
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

actor FundLookThroughClient: FundLookThroughClientProtocol {
    /// 内存缓存条目，也作为磁盘缓存的单条载荷形态。
    struct CachedDisclosure: Codable, Sendable {
        let loadedAt: Date
        let disclosure: FundLookThroughDisclosure
    }

    private let session: URLSession
    private let now: @Sendable () -> Date
    private let cacheTTL: TimeInterval
    private let fallbackTTL: TimeInterval
    private let storageFileURL: URL?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var cache: [String: CachedDisclosure] = [:]
    private var diskCacheLoaded = false
    private static let concurrencyLimit = 4
    private static let maximumHoldingsPerKind = 10
    private static let requestMaxAttempts = 3
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    init(
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        cacheTTL: TimeInterval = 24 * 60 * 60,
        fallbackTTL: TimeInterval = 120 * 24 * 60 * 60,
        storageFileURL: URL? = nil
    ) {
        self.session = session
        self.now = now
        self.cacheTTL = cacheTTL
        self.fallbackTTL = fallbackTTL
        self.storageFileURL = storageFileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func fetchDisclosures(fundCodes: [String]) async -> FundLookThroughBatchResult {
        let codes = Array(
            Set(
                fundCodes
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        var disclosures: [String: FundLookThroughDisclosure] = [:]
        var warnings: [String] = []

        for start in stride(from: 0, to: codes.count, by: Self.concurrencyLimit) {
            let end = min(start + Self.concurrencyLimit, codes.count)
            let chunk = Array(codes[start..<end])
            await withTaskGroup(of: (String, Result<FundLookThroughDisclosure, Error>).self) { group in
                for code in chunk {
                    group.addTask {
                        do {
                            return (code, .success(try await self.fetchDisclosure(fundCode: code)))
                        } catch {
                            return (code, .failure(error))
                        }
                    }
                }
                for await (code, result) in group {
                    switch result {
                    case .success(let disclosure):
                        disclosures[code] = disclosure
                    case .failure(let error):
                        warnings.append("\(code)：\(error.localizedDescription)")
                    }
                }
            }
        }

        return FundLookThroughBatchResult(
            disclosures: disclosures,
            warnings: warnings.sorted()
        )
    }

    private func fetchDisclosure(fundCode: String) async throws -> FundLookThroughDisclosure {
        await ensureDiskCacheLoaded()
        if let cached = freshMemoryCacheEntry(for: fundCode) {
            return cached.disclosure
        }

        async let stockOutcome = retryingRequest(
            url: archivesURL(type: "jjcc", fundCode: fundCode),
            referer: "https://fundf10.eastmoney.com/ccmx_\(fundCode).html"
        )
        async let bondOutcome = retryingRequest(
            url: archivesURL(type: "zqcc", fundCode: fundCode),
            referer: "https://fundf10.eastmoney.com/ccmx1_\(fundCode).html"
        )
        async let industryOutcome = retryingRequest(
            url: industryURL(fundCode: fundCode),
            referer: "https://fundf10.eastmoney.com/hytz_\(fundCode).html"
        )
        async let allocationOutcome = retryingRequest(
            url: assetAllocationURL(fundCode: fundCode),
            referer: "https://fundf10.eastmoney.com/zcpz_\(fundCode).html"
        )

        let (stockResult, bondResult, industryResult, allocationResult) = await (
            stockOutcome,
            bondOutcome,
            industryOutcome,
            allocationOutcome
        )

        let stock = stockResult.value.map {
            Self.parseArchiveHoldings($0, kind: .stock, limit: Self.maximumHoldingsPerKind)
        }
        let bond = bondResult.value.map {
            Self.parseArchiveHoldings($0, kind: .bond, limit: Self.maximumHoldingsPerKind)
        }
        let industry = industryResult.value.flatMap(Self.parseIndustries)
        let allocation = allocationResult.value.flatMap(Self.parseAssetAllocation)

        let holdings = (stock?.holdings ?? []) + (bond?.holdings ?? [])
        let industries = industry?.exposures ?? []
        let failedSources = failedSourceLabels(
            stock: stockResult.error,
            bond: bondResult.error,
            industry: industryResult.error,
            allocation: allocationResult.error
        )

        // 四个来源全部成功才视为"完整披露"，可缓存、可计入覆盖率。
        if failedSources.isEmpty {
            let dates = holdings.map(\.disclosureDate)
                + industries.map(\.disclosureDate)
                + [allocation?.disclosureDate].compactMap { $0 }
            let fundName = stock?.fundName
                ?? bond?.fundName
                ?? industry?.fundName
                ?? fundCode
            let disclosure = FundLookThroughDisclosure(
                fundCode: fundCode,
                fundName: fundName,
                asOf: dates.max() ?? "",
                holdings: holdings,
                industries: industries,
                assetAllocation: allocation,
                sourceLabel: "天天基金 · 基金定期报告",
                sourceURL: "https://fundf10.eastmoney.com/ccmx_\(fundCode).html",
                warnings: []
            )
            persist(fundCode: fundCode, disclosure: disclosure)
            return disclosure
        }

        // 任一来源失败：不得用残缺数据冒充完整披露。优先回退到磁盘上已有的完整披露。
        // 兜底用更长的 TTL——基金持仓变化慢，季报周期内的历史完整披露作为兜底比残缺数据安全。
        if let fallback = fallbackCacheEntry(for: fundCode) {
            let date = fallback.disclosure.asOf.isEmpty
                ? shortDateString(fallback.loadedAt)
                : String(fallback.disclosure.asOf.prefix(10))
            let merged = FundLookThroughDisclosure(
                fundCode: fallback.disclosure.fundCode,
                fundName: fallback.disclosure.fundName,
                asOf: fallback.disclosure.asOf,
                holdings: fallback.disclosure.holdings,
                industries: fallback.disclosure.industries,
                assetAllocation: fallback.disclosure.assetAllocation,
                sourceLabel: fallback.disclosure.sourceLabel,
                sourceURL: fallback.disclosure.sourceURL,
                warnings: fallback.disclosure.warnings + [
                    "\(failedSources.joined(separator: "、"))接口暂不可用，已使用 \(date) 的缓存完整披露。"
                ]
            )
            return merged
        }

        // 既无完整抓取、也无缓存兜底：判为无可用披露，排除出覆盖率。绝不缓存残缺结果。
        throw FundLookThroughClientError.incompleteDisclosure(
            fundCode,
            failed: failedSources
        )
    }

    private func freshMemoryCacheEntry(for fundCode: String) -> CachedDisclosure? {
        guard let entry = cache[fundCode],
              now().timeIntervalSince(entry.loadedAt) < cacheTTL else {
            return nil
        }
        return entry
    }

    private func fallbackCacheEntry(for fundCode: String) -> CachedDisclosure? {
        guard let entry = cache[fundCode],
              now().timeIntervalSince(entry.loadedAt) < fallbackTTL else {
            return nil
        }
        return entry
    }

    private func persist(fundCode: String, disclosure: FundLookThroughDisclosure) {
        let entry = CachedDisclosure(loadedAt: now(), disclosure: disclosure)
        cache[fundCode] = entry
        guard storageFileURL != nil else { return }
        // 已通过 ensureDiskCacheLoaded 把磁盘内容并入 cache，直接基于内存快照写盘，
        // 避免重复读盘与潜在竞态（actor 内部串行化保证一致性）。
        writeDiskCache(cache)
    }

    private func ensureDiskCacheLoaded() async {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        for (code, entry) in loadDiskCache() {
            cache[code] = entry
        }
    }

    private func failedSourceLabels(
        stock: Error?,
        bond: Error?,
        industry: Error?,
        allocation: Error?
    ) -> [String] {
        var labels: [String] = []
        if stock != nil { labels.append("股票持仓") }
        if bond != nil { labels.append("债券持仓") }
        if industry != nil { labels.append("行业配置") }
        if allocation != nil { labels.append("资产配置") }
        return labels
    }

    private func shortDateString(_ date: Date) -> String {
        Self.shortDateFormatter.string(from: date)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func loadDiskCache() -> [String: CachedDisclosure] {
        guard let storageFileURL,
              FileManager.default.fileExists(atPath: storageFileURL.path),
              let data = try? Data(contentsOf: storageFileURL),
              let decoded = try? decoder.decode([String: CachedDisclosure].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeDiskCache(_ snapshot: [String: CachedDisclosure]) {
        guard let storageFileURL,
              let data = try? encoder.encode(snapshot) else {
            return
        }
        try? data.write(to: storageFileURL, options: .atomic)
    }

    /// 对单个披露接口做有限次指数退避重试，缓解偶发抖动；返回成功正文或最终错误。
    private func retryingRequest(url: URL, referer: String) async -> RequestOutcome {
        var lastError: Error?
        for attempt in 0..<Self.requestMaxAttempts {
            do {
                let text = try await requestText(url: url, referer: referer)
                return RequestOutcome(value: text)
            } catch {
                lastError = error
                if attempt < Self.requestMaxAttempts - 1 {
                    let backoff = pow(3.0, Double(attempt)) * 0.1
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }
        return RequestOutcome(error: lastError ?? FundLookThroughClientError.invalidResponse(url.absoluteString))
    }

    private struct RequestOutcome {
        let value: String?
        let error: Error?
        init(value: String) { self.value = value; self.error = nil }
        init(error: Error) { self.value = nil; self.error = error }
    }

    private func requestText(url: URL, referer: String) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw FundLookThroughClientError.invalidResponse(url.absoluteString)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw FundLookThroughClientError.invalidEncoding(url.absoluteString)
        }
        return text
    }

    private func archivesURL(type: String, fundCode: String) -> URL {
        var components = URLComponents(string: "https://fundf10.eastmoney.com/FundArchivesDatas.aspx")!
        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "code", value: fundCode),
            URLQueryItem(name: "topline", value: "10"),
            URLQueryItem(name: "year", value: ""),
            URLQueryItem(name: "month", value: ""),
            URLQueryItem(name: "rt", value: String(now().timeIntervalSince1970))
        ]
        return components.url!
    }

    private func industryURL(fundCode: String) -> URL {
        var components = URLComponents(string: "https://api.fund.eastmoney.com/f10/HYPZ/")!
        components.queryItems = [
            URLQueryItem(name: "fundCode", value: fundCode),
            URLQueryItem(name: "year", value: "")
        ]
        return components.url!
    }

    private func assetAllocationURL(fundCode: String) -> URL {
        URL(string: "https://fundf10.eastmoney.com/zcpz_\(fundCode).html")!
    }

    struct ParsedArchive: Hashable {
        let fundName: String?
        let holdings: [FundUnderlyingHolding]
    }

    static func parseArchiveHoldings(
        _ text: String,
        kind: FundUnderlyingAssetKind,
        limit: Int = maximumHoldingsPerKind
    ) -> ParsedArchive {
        guard let tableEnd = text.range(of: "</table>") else {
            return ParsedArchive(fundName: nil, holdings: [])
        }
        let latestTable = String(text[..<tableEnd.upperBound])
        let disclosureDate = firstMatch(
            in: latestTable,
            pattern: #"截止至：<font[^>]*>(\d{4}-\d{2}-\d{2})</font>"#
        ) ?? ""
        let fundName = firstMatch(
            in: latestTable,
            pattern: #"<a[^>]*(?:title='([^']+)'|href='http://fund\.eastmoney\.com/\d+\.html'[^>]*)>([^<]+)</a>"#,
            preferredGroups: [1, 2]
        ).map(decodeHTML)

        let rowTexts = allMatches(in: latestTable, pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#)
        var holdings: [FundUnderlyingHolding] = []
        for rowText in rowTexts {
            let cells = allMatches(in: rowText, pattern: #"<td[^>]*>([\s\S]*?)</td>"#)
                .map { decodeHTML(stripHTML($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 5,
                  Int(cells[0]) != nil,
                  !cells[1].isEmpty,
                  !cells[2].isEmpty,
                  let weightText = cells.dropFirst(3).reversed().first(where: { $0.contains("%") }),
                  let weight = Double(
                    weightText
                        .replacingOccurrences(of: "%", with: "")
                        .replacingOccurrences(of: ",", with: "")
                  ),
                  weight > 0 else {
                continue
            }
            holdings.append(
                FundUnderlyingHolding(
                    code: cells[1],
                    name: cells[2],
                    kind: kind,
                    weightPct: weight,
                    disclosureDate: disclosureDate
                )
            )
            if holdings.count >= max(1, limit) { break }
        }
        return ParsedArchive(fundName: fundName, holdings: holdings)
    }

    struct ParsedIndustry: Hashable {
        let fundName: String?
        let exposures: [FundIndustryExposure]
    }

    static func parseIndustries(_ text: String) -> ParsedIndustry? {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(IndustryEnvelope.self, from: data),
              envelope.errorCode == 0,
              let payload = envelope.payload,
              let latest = payload.quarters.max(by: { $0.date < $1.date }) else {
            return nil
        }
        let exposures = latest.items.compactMap { item -> FundIndustryExposure? in
            guard let weight = Double(item.weightPct), weight > 0 else { return nil }
            return FundIndustryExposure(
                name: item.name,
                weightPct: weight,
                disclosureDate: item.date
            )
        }
        return ParsedIndustry(fundName: payload.shortName, exposures: exposures)
    }

    static func parseAssetAllocation(_ text: String) -> FundAssetAllocation? {
        guard let json = firstMatch(
            in: text,
            pattern: #"var\s+Data_assetAllocation\s*=\s*(\{[\s\S]*?\});"#
        ), let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AssetAllocationPayload.self, from: data),
           let index = payload.categories.indices.last else {
            return parseAssetAllocationTable(text)
        }

        func latestValue(containing keyword: String) -> Double? {
            guard let series = payload.series.first(where: { $0.name.contains(keyword) }),
                  series.data.indices.contains(index) else {
                return nil
            }
            return series.data[index]
        }

        let stock = latestValue(containing: "股票")
        let bond = latestValue(containing: "债券")
        let cash = latestValue(containing: "现金")
        let known = [stock, bond, cash].compactMap { $0 }.reduce(0, +)
        let other = known > 0 ? max(0, 100 - known) : nil
        return FundAssetAllocation(
            stockPct: stock,
            bondPct: bond,
            cashPct: cash,
            otherPct: other,
            disclosureDate: payload.categories[index]
        )
    }

    private static func parseAssetAllocationTable(_ text: String) -> FundAssetAllocation? {
        guard let tableAnchor = text.range(of: "资产配置明细"),
              let tableEnd = text[tableAnchor.upperBound...].range(of: "</table>") else {
            return nil
        }
        let table = String(text[tableAnchor.lowerBound..<tableEnd.upperBound])
        let rows = allMatches(in: table, pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#)
        for row in rows {
            let cells = allMatches(in: row, pattern: #"<td[^>]*>([\s\S]*?)</td>"#)
                .map { decodeHTML(stripHTML($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard cells.count >= 4,
                  cells[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
                continue
            }
            func percentage(_ index: Int) -> Double? {
                guard cells.indices.contains(index) else { return nil }
                return Double(
                    cells[index]
                        .replacingOccurrences(of: "%", with: "")
                        .replacingOccurrences(of: ",", with: "")
                )
            }
            let stock = percentage(1)
            let bond = percentage(2)
            let cash = percentage(3)
            let known = [stock, bond, cash].compactMap { $0 }.reduce(0, +)
            return FundAssetAllocation(
                stockPct: stock,
                bondPct: bond,
                cashPct: cash,
                otherPct: known > 0 ? max(0, 100 - known) : nil,
                disclosureDate: cells[0]
            )
        }
        return nil
    }

    private struct IndustryEnvelope: Decodable {
        let payload: IndustryPayload?
        let errorCode: Int

        enum CodingKeys: String, CodingKey {
            case payload = "Data"
            case errorCode = "ErrCode"
        }
    }

    private struct IndustryPayload: Decodable {
        let shortName: String
        let quarters: [IndustryQuarter]

        enum CodingKeys: String, CodingKey {
            case shortName = "ShortName"
            case quarters = "QuarterInfos"
        }
    }

    private struct IndustryQuarter: Decodable {
        let date: String
        let items: [IndustryItem]

        enum CodingKeys: String, CodingKey {
            case date = "JZRQ"
            case items = "HYPZInfo"
        }
    }

    private struct IndustryItem: Decodable {
        let name: String
        let date: String
        let weightPct: String

        enum CodingKeys: String, CodingKey {
            case name = "HYMC"
            case date = "FSRQ"
            case weightPct = "ZJZBL"
        }
    }

    private struct AssetAllocationPayload: Decodable {
        let series: [AssetAllocationSeries]
        let categories: [String]
    }

    private struct AssetAllocationSeries: Decodable {
        let name: String
        let data: [Double?]
    }

    private static func firstMatch(
        in text: String,
        pattern: String,
        preferredGroups: [Int] = [1]
    ) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        for group in preferredGroups where group < match.numberOfRanges {
            let groupRange = match.range(at: group)
            guard groupRange.location != NSNotFound,
                  let swiftRange = Range(groupRange, in: text) else {
                continue
            }
            let value = String(text[swiftRange])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func allMatches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let swiftRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[swiftRange])
        }
    }

    private static func stripHTML(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
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

enum FundLookThroughClientError: Error, LocalizedError {
    case invalidResponse(String)
    case invalidEncoding(String)
    case noDisclosure(String)
    case incompleteDisclosure(String, failed: [String])

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let url):
            return "基金披露接口响应异常：\(url)"
        case .invalidEncoding(let url):
            return "基金披露接口编码异常：\(url)"
        case .noDisclosure(let code):
            return "基金 \(code) 暂无可解析的持仓、行业或资产配置披露。"
        case .incompleteDisclosure(let code, let failed):
            let joined = failed.isEmpty ? "部分接口" : failed.joined(separator: "、")
            return "基金 \(code) 的 \(joined) 接口暂不可用，且无可用缓存兜底，已排除以免残缺数据冒充完整披露。"
        }
    }
}
