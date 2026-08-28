import Foundation

/// 从趋势研究报告的行动候选抽取市场决策信号。
///
/// 抽取纪律（对拍 DSA decision_signal_extractor）：
/// - confidence 高→0.8 / 中→0.6 / 低→0.4（TrendConfidence.score 归一）；
/// - 价格条件用受控正则从触发/作废条件文本解析，解析失败仍建信号但不可自动结算；
/// - 只有能解析出 6 位 A股代码的信号走市价结算，其余计样本等 NAV 结算扩展。
enum MarketSignalExtractor {
    // MARK: - 主入口

    static func extract(
        from report: TrendAnalysisReport,
        now: Date = Date()
    ) -> [MarketDecisionSignal] {
        let createdAt = timestamp(now)
        return report.actions.compactMap { candidate in
            buildSignal(from: candidate, createdAt: createdAt, now: now)
        }
    }

    static func buildSignal(
        from candidate: TrendActionCandidate,
        createdAt: String,
        now: Date
    ) -> MarketDecisionSignal? {
        // 暂停计划无市场标的也无方向收益，不建信号；其余（含观望类）都建——到期未触发也计入样本
        guard candidate.kind != .pausePlan else { return nil }
        let mapping = mapKind(candidate.kind)

        let subjectText = [candidate.targetName, candidate.title, candidate.detail]
            .compactMap { $0 }
            .joined(separator: " ")
        let subjectCode = firstAShareCode(in: subjectText)
        let subjectName = candidate.targetName ?? candidate.title

        // 价格条件：触发条件（方向价）+ 作废条件（反向价）
        var conditions = parsePrices(from: candidate.triggerConditions, direction: mapping.direction)
        let invalidation = parsePrices(from: candidate.invalidatingConditions, direction: opposite(of: mapping.direction))
        if conditions.stopLoss == nil, let invalidStop = invalidation.targetPrice {
            conditions.stopLoss = invalidStop
            conditions.parseNotes.append("作废条件中的突破价映射为止损")
        }
        if conditions.targetPrice == nil, let invalidTarget = invalidation.stopLoss {
            conditions.targetPrice = invalidTarget
            conditions.parseNotes.append("作废条件中的跌破价映射为目标")
        }

        let rawConfidence = confidenceValue(candidate.confidence)
        let reviewDays = mapping.direction == .hold ? 7 : 3
        let dueAt = timestamp(now.addingTimeInterval(Double(reviewDays * 86_400)))

        return MarketDecisionSignal(
            dedupKey: "trend|\(candidate.id)|\(subjectCode ?? subjectName)",
            sourceKind: .trendReport,
            sourceActionID: candidate.id,
            subjectCode: subjectCode,
            subjectName: subjectName,
            marketSettleable: subjectCode != nil && conditions.isSettleable,
            direction: mapping.direction,
            action: mapping.action,
            score: mapping.scoreAnchor,
            rawConfidence: rawConfidence,
            priceConditions: conditions,
            watchConditions: candidate.triggerConditions.filter { !$0.isEmpty },
            invalidatingConditions: candidate.invalidatingConditions.filter { !$0.isEmpty },
            reason: candidate.detail.isEmpty ? candidate.title : candidate.detail,
            evidenceIDs: Self.unique(
                candidate.claimEvidence.supportingEvidenceIDs
                    + candidate.claimEvidence.counterEvidenceIDs
                    + candidate.claimEvidence.contextEvidenceIDs
            ),
            dataQualitySummary: "来源：趋势研究行动候选；价格条件\(!conditions.isSettleable ? "未" : "")解析成功；\(!conditions.parseNotes.isEmpty ? conditions.parseNotes.joined(separator: "；") : "无解析备注")",
            createdAt: createdAt,
            reviewDueAt: dueAt,
            events: [
                SignalEvent(at: createdAt, type: .created, reason: "从趋势报告行动候选「\(candidate.title)」抽取")
            ]
        )
    }

    // MARK: - kind 映射

    struct KindMapping {
        let direction: CanonicalDecisionType
        let action: CanonicalAction
        let scoreAnchor: Int
    }

    static func mapKind(_ kind: TrendActionKind) -> KindMapping {
        switch kind {
        case .considerIncrease:
            return KindMapping(direction: .buy, action: .add, scoreAnchor: 65)
        case .considerReduce:
            return KindMapping(direction: .sell, action: .reduce, scoreAnchor: 30)
        case .pausePlan, .rebalanceReview:
            return KindMapping(direction: .hold, action: .hold, scoreAnchor: 50)
        case .watch, .waitForConfirmation, .observeInBatches:
            return KindMapping(direction: .hold, action: .watch, scoreAnchor: 50)
        }
    }

    // MARK: - 价格解析

    /// 受控正则：从条件文本解析价格。
    /// 看多：回踩/回落 → 入场；跌破 → 止损；涨至/突破/站上 → 目标。
    /// 看空：跌破 → 目标；突破/涨至 → 止损。
    static func parsePrices(from conditions: [String], direction: CanonicalDecisionType) -> SignalPriceConditions {
        var result = SignalPriceConditions()
        let upPattern = #"(涨至|升至|突破|站上|到达|触及|收复)\s*([0-9]+(?:\.[0-9]{1,4})?)\s*(元|块|点)?"#
        let downPattern = #"(回踩|回调至|回落至|跌至|回撤至)\s*([0-9]+(?:\.[0-9]{1,4})?)\s*(元|块|点)?\s*(附近|左右)?"#
        let breakPattern = #"(跌破|下破|失守)\s*([0-9]+(?:\.[0-9]{1,4})?)\s*(元|块|点)?"#
        let stopPattern = #"止损\s*(位)?\s*[:：]?\s*([0-9]+(?:\.[0-9]{1,4})?)"#

        for text in conditions {
            if let value = firstMatch(text: text, pattern: stopPattern, group: 2) {
                if result.stopLoss == nil || value < (result.stopLoss ?? .infinity) {
                    result.stopLoss = value
                    result.parseNotes.append("「止损 \(trim(value))」")
                }
                continue
            }
            if let value = firstMatch(text: text, pattern: breakPattern, group: 2) {
                if direction == .buy {
                    if result.stopLoss == nil { result.stopLoss = value; result.parseNotes.append("「跌破 \(trim(value))」→止损") }
                } else {
                    if result.targetPrice == nil { result.targetPrice = value; result.parseNotes.append("「跌破 \(trim(value))」→目标") }
                }
                continue
            }
            if let value = firstMatch(text: text, pattern: downPattern, group: 2) {
                if direction == .buy {
                    if result.entryLow == nil {
                        result.entryLow = value * 0.99
                        result.entryHigh = value * 1.01
                        result.parseNotes.append("「回踩 \(trim(value))」→入场带 ±1%")
                    }
                }
                continue
            }
            if let value = firstMatch(text: text, pattern: upPattern, group: 2) {
                if direction == .buy {
                    if result.targetPrice == nil { result.targetPrice = value; result.parseNotes.append("「涨至 \(trim(value))」→目标") }
                } else {
                    if result.stopLoss == nil { result.stopLoss = value; result.parseNotes.append("「突破 \(trim(value))」→止损") }
                }
                continue
            }
        }
        return result
    }

    static func firstMatch(text: String, pattern: String, group: Int) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > group,
              let groupRange = Range(match.range(at: group), in: text)
        else { return nil }
        return Double(text[groupRange])
    }

    // MARK: - 工具

    static func firstAShareCode(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([0-9]{6})\b"#) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let groupRange = Range(match.range(at: 1), in: text)
        else { return nil }
        let code = String(text[groupRange])
        return MarketBoardRule.board(forCode: code) != nil ? code : nil
    }

    static func confidenceValue(_ confidence: TrendConfidence) -> Double {
        min(max(Double(confidence.normalizedScore) / 100.0, 0.4), 0.9)
    }

    static func opposite(of direction: CanonicalDecisionType) -> CanonicalDecisionType {
        switch direction {
        case .buy: return .sell
        case .sell: return .buy
        case .hold: return .hold
        }
    }

    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// 保序去重。
    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketPhase.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
