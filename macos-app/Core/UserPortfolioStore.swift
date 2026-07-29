import Foundation

enum UserPortfolioParseError: LocalizedError {
    case emptyInput
    case invalidLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没有解析到任何持仓。请至少提供一行“基金代码 份额”。"
        case .invalidLine(let line, let sample):
            return "第 \(line) 行格式无法识别：\(sample)"
        }
    }
}

struct UserPortfolioStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load(from fileURL: URL) throws -> [UserPortfolioHolding] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([UserPortfolioHolding].self, from: data)
    }

    func save(_ holdings: [UserPortfolioHolding], to fileURL: URL) throws {
        let data = try encoder.encode(holdings)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func parseDraft(_ text: String) throws -> [UserPortfolioHolding] {
        var items: [UserPortfolioHolding] = []

        for (index, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let item = parseLine(line) else {
                throw UserPortfolioParseError.invalidLine(index + 1, line)
            }
            items.append(item)
        }

        guard !items.isEmpty else {
            throw UserPortfolioParseError.emptyInput
        }
        return items
    }

    func draft(from holdings: [UserPortfolioHolding]) -> String {
        holdings.map(\.draftLine).joined(separator: "\n")
    }

    func merging(_ imported: [UserPortfolioHolding], into existing: [UserPortfolioHolding]) -> [UserPortfolioHolding] {
        var merged = existing
        var indexByKey: [String: Int] = [:]
        for (index, holding) in merged.enumerated() {
            indexByKey[mergeKey(for: holding)] = index
        }

        for importedHolding in imported {
            let key = mergeKey(for: importedHolding)
            if let existingIndex = indexByKey[key] {
                let current = merged[existingIndex]
                merged[existingIndex] = UserPortfolioHolding(
                    id: current.id,
                    fundCode: importedHolding.normalizedFundCode,
                    assetType: importedHolding.assetType,
                    units: importedHolding.units,
                    costPrice: importedHolding.costPrice,
                    displayName: importedHolding.normalizedName ?? current.normalizedName,
                    stockMarket: importedHolding.stockMarket ?? current.stockMarket,
                    fundMarket: importedHolding.fundMarket ?? current.fundMarket,
                    isArchived: false,
                    archivedAt: nil
                )
            } else {
                indexByKey[key] = merged.count
                merged.append(importedHolding)
            }
        }
        return merged
    }

    func previewKey(for holding: UserPortfolioHolding) -> String {
        mergeKey(for: holding)
    }

    private func parseLine(_ line: String) -> UserPortfolioHolding? {
        let normalized = line
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: "|", with: " ")
        let commaParts = normalized
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if commaParts.count >= 2 {
            return parseTokens(commaParts)
        }

        let parts = normalized
            .split(whereSeparator: { $0 == "\t" || $0 == " " })
            .map(String.init)
        return parseTokens(parts)
    }

    private func parseTokens(_ tokens: [String]) -> UserPortfolioHolding? {
        let cleaned = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard cleaned.count >= 2 else { return nil }

        var tokens = cleaned
        var assetType: PersonalAssetType = .fund
        var marketHint: StockMarket?
        var fundMarketHint: FundMarket?
        if let explicitType = parseAssetType(tokens[0]) {
            assetType = explicitType
            marketHint = parseStockMarketHint(tokens[0])
            fundMarketHint = parseFundMarketHint(tokens[0])
            tokens.removeFirst()
        } else if tokens.count >= 2, let explicitType = parseAssetType(tokens[1]) {
            assetType = explicitType
            marketHint = parseStockMarketHint(tokens[1])
            fundMarketHint = parseFundMarketHint(tokens[1])
            tokens.remove(at: 1)
        } else if let parsedCode = parseAssetCode(tokens[0]), parsedCode.assetType == .stock {
            assetType = .stock
            marketHint = parsedCode.stockMarket
            fundMarketHint = parsedCode.fundMarket
        } else if tokens.count >= 2, let parsedCode = parseAssetCode(tokens[1]), parsedCode.assetType == .stock {
            assetType = .stock
            marketHint = parsedCode.stockMarket
            fundMarketHint = parsedCode.fundMarket
        }

        guard tokens.count >= 2 else { return nil }

        if let parsedCode = parseAssetCode(tokens[0]) {
            let resolvedMarket = parsedCode.stockMarket ?? marketHint
            let resolvedFundMarket = parsedCode.fundMarket ?? fundMarketHint
            return buildHolding(
                code: parsedCode.code,
                assetType: parsedCode.assetType ?? assetType,
                stockMarket: resolvedMarket,
                fundMarket: resolvedFundMarket,
                unitsText: tokens[safe: 1],
                costText: tokens[safe: 2],
                nameParts: Array(tokens.dropFirst(3))
            )
        }

        if tokens.count >= 3, let parsedCode = parseAssetCode(tokens[1]) {
            let resolvedMarket = parsedCode.stockMarket ?? marketHint
            let resolvedFundMarket = parsedCode.fundMarket ?? fundMarketHint
            return buildHolding(
                code: parsedCode.code,
                assetType: parsedCode.assetType ?? assetType,
                stockMarket: resolvedMarket,
                fundMarket: resolvedFundMarket,
                unitsText: tokens[safe: 2],
                costText: tokens[safe: 3],
                nameParts: [tokens[0]] + Array(tokens.dropFirst(4))
            )
        }

        return nil
    }

    private func buildHolding(
        code: String,
        assetType: PersonalAssetType,
        stockMarket: StockMarket?,
        fundMarket: FundMarket?,
        unitsText: String?,
        costText: String?,
        nameParts: [String]
    ) -> UserPortfolioHolding? {
        guard let unitsText, let units = decimalValue(unitsText), units > 0 else {
            return nil
        }
        let parsedCost = costText.flatMap(decimalValue)
        let derivedNameParts: [String]
        if parsedCost == nil, let costText, !costText.isEmpty {
            derivedNameParts = [costText] + nameParts
        } else {
            derivedNameParts = nameParts
        }
        let name = derivedNameParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return UserPortfolioHolding(
            fundCode: code,
            assetType: assetType,
            units: units,
            costPrice: parsedCost,
            displayName: name.isEmpty ? nil : name,
            stockMarket: stockMarket,
            fundMarket: fundMarket ?? (assetType == .fund ? UserPortfolioHolding.detectFundMarket(from: code) : nil)
        )
    }

    private func decimalValue(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func parseAssetType(_ value: String) -> PersonalAssetType? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "股票", "stock", "a股", "沪深", "港股", "hk", "美股", "us":
            return .stock
        case "基金", "fund", "场内基金", "场内", "etf", "lof", "场外基金", "场外":
            return .fund
        default:
            return nil
        }
    }

    private func parseStockMarketHint(_ value: String) -> StockMarket? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "港股", "hk":
            return .hk
        case "美股", "us":
            return .us
        case "a股", "沪深", "a":
            return .aShare
        default:
            return nil
        }
    }

    private func parseFundMarketHint(_ value: String) -> FundMarket? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "场内基金", "场内", "etf", "lof", "exchange", "exchange-traded":
            return .onExchange
        case "场外基金", "场外", "otc", "off-exchange", "fund":
            return .offExchange
        default:
            return nil
        }
    }

    private func parseAssetCode(_ value: String) -> (code: String, assetType: PersonalAssetType?, stockMarket: StockMarket?, fundMarket: FundMarket?)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        if upper.hasPrefix("ETF:") || upper.hasPrefix("LOF:") || upper.hasPrefix("EX:") {
            let code = String(upper.split(separator: ":", maxSplits: 1).last ?? "")
            guard !code.isEmpty else { return nil }
            return (code, .fund, nil, .onExchange)
        }

        if upper.hasPrefix("FUND:") || upper.hasPrefix("OTC:") {
            let code = String(upper.split(separator: ":", maxSplits: 1).last ?? "")
            guard !code.isEmpty else { return nil }
            return (code, .fund, nil, .offExchange)
        }

        let normalizedFundCode = UserPortfolioHolding.normalizedFundCode(from: trimmed)
        if UserPortfolioHolding.detectFundMarket(from: normalizedFundCode) == .onExchange {
            return (normalizedFundCode, .fund, nil, .onExchange)
        }

        if upper.count == 8,
           (upper.hasPrefix("SH") || upper.hasPrefix("SZ") || upper.hasPrefix("BJ")),
           isDigits(String(upper.dropFirst(2))) {
            return (String(upper.dropFirst(2)), .stock, .aShare, nil)
        }

        if upper.count == 9,
           (upper.hasSuffix(".SH") || upper.hasSuffix(".SZ") || upper.hasSuffix(".BJ")),
           isDigits(String(upper.prefix(6))) {
            return (String(upper.prefix(6)), .stock, .aShare, nil)
        }

        if upper.hasPrefix("HK:") {
            let code = normalizedHongKongStockCode(String(upper.dropFirst(3)))
            guard !code.isEmpty else { return nil }
            return (code, .stock, .hk, nil)
        }
        if upper.hasPrefix("HK"), upper.count > 2 {
            let code = normalizedHongKongStockCode(String(upper.dropFirst(2)))
            guard !code.isEmpty, isDigits(code) else { return nil }
            return (code, .stock, .hk, nil)
        }
        if upper.hasPrefix("US:") {
            let code = String(upper.dropFirst(3))
            guard !code.isEmpty else { return nil }
            return (code, .stock, .us, nil)
        }

        if upper.count == 5, isDigits(trimmed) {
            return (trimmed, .stock, .hk, nil)
        }

        if upper.allSatisfy({ $0.isLetter }), upper.count >= 1, upper.count <= 5 {
            return (upper, .stock, .us, nil)
        }

        guard trimmed.count >= 5 && trimmed.count <= 6, isDigits(trimmed) else { return nil }
        return (trimmed, nil, nil, UserPortfolioHolding.detectFundMarket(from: trimmed))
    }

    private func isDigits(_ value: String) -> Bool {
        CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: value))
    }

    private func normalizedHongKongStockCode(_ value: String) -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, isDigits(code), code.count < 5 else {
            return code
        }
        return String(repeating: "0", count: 5 - code.count) + code
    }

    private func mergeKey(for holding: UserPortfolioHolding) -> String {
        let code = holding.normalizedFundCode.lowercased()
        let marketSegment: String
        if holding.assetType == .stock {
            marketSegment = ":mkt:\(holding.detectedMarket?.rawValue ?? "a")"
        } else {
            marketSegment = ":fundmkt:\(holding.detectedFundMarket?.rawValue ?? FundMarket.offExchange.rawValue)"
        }
        if !code.isEmpty {
            return "\(holding.assetType.rawValue)\(marketSegment):code:\(code)"
        }
        return "\(holding.assetType.rawValue)\(marketSegment):name:\((holding.normalizedName ?? "").lowercased())"
    }
}

