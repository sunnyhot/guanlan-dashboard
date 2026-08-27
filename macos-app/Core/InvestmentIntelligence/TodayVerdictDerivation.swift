import Foundation

/// W2.3:「今天一句话」hero 结论的纯派生。
///
/// 优先级:盘中 posture + 中期 horizon 并置 → 双短句;只有单一来源时退化为
/// 单短句;四链路均无内容时返回 nil(不显示 hero)。
///
/// **冲突语义**(合并进计划的验收要求):盘中与中期方向相反时不得平均成
/// 无方向的中性句——要么用固定的对照措辞(「短线防御 · 中线逢低布局」),
/// 要么不显示;绝不输出浆糊。全部输出 ≤ 20 字。
enum TodayVerdictDerivation {
    struct Input: Equatable {
        var intradayPosture: NextHourGuidancePosture?
        var topRadarSignalName: String?
        var topRadarRecommendation: InvestmentDirectionRecommendation?
        var mediumDirection: TrendDirection?

        init(
            intradayPosture: NextHourGuidancePosture? = nil,
            topRadarSignalName: String? = nil,
            topRadarRecommendation: InvestmentDirectionRecommendation? = nil,
            mediumDirection: TrendDirection? = nil
        ) {
            self.intradayPosture = intradayPosture
            self.topRadarSignalName = topRadarSignalName
            self.topRadarRecommendation = topRadarRecommendation
            self.mediumDirection = mediumDirection
        }
    }

    static func derive(_ input: Input) -> String? {
        // ① 盘中 + 中期并置(两个方向都有时最有信息量)。
        if let posture = input.intradayPosture, let medium = input.mediumDirection {
            if let mediumWord = mediumWord(for: medium) {
                return dualPhrase(posture: posture, mediumWord: mediumWord)
            }
            // 中期 uncertain 时只有盘中可用。
            return "短线\(postureWord(for: posture))"
        }

        // ② 只有盘中。
        if let posture = input.intradayPosture {
            return "短线\(postureWord(for: posture))"
        }

        // ③ 市场雷达最强信号。
        if let name = input.topRadarSignalName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           let recommendation = input.topRadarRecommendation {
            let shortName = String(name.prefix(8))
            return "\(shortName):\(recommendation.displayName)"
        }

        // ④ 只有中期 horizon。
        if let medium = input.mediumDirection, let mediumWord = mediumWord(for: medium) {
            return "中线\(mediumWord)"
        }
        return nil
    }

    private static func postureWord(for posture: NextHourGuidancePosture) -> String {
        switch posture {
        case .defensive: return "防守"
        case .balanced: return "均衡"
        case .selective: return "择机"
        case .opportunistic: return "进攻"
        }
    }

    private static func mediumWord(for direction: TrendDirection) -> String? {
        switch direction {
        case .bullish, .neutralPositive: return "看多"
        case .bearish, .neutralNegative: return "看淡"
        case .neutral: return "中性"
        case .uncertain: return nil
        }
    }

    /// 双短句:同向并置;反向用固定对照措辞,绝不平均成中性浆糊。
    private static func dualPhrase(posture: NextHourGuidancePosture, mediumWord: String) -> String {
        let shortWord = postureWord(for: posture)
        let postureLean: Int // -1 防御侧,0 中性,1 进攻侧
        switch posture {
        case .defensive: postureLean = -1
        case .balanced: postureLean = 0
        case .selective: postureLean = 0
        case .opportunistic: postureLean = 1
        }
        let mediumLean: Int
        switch mediumWord {
        case "看多": mediumLean = 1
        case "看淡": mediumLean = -1
        default: mediumLean = 0
        }
        if postureLean < 0, mediumLean > 0 {
            return "短线防御 · 中线逢低布局"
        }
        if postureLean > 0, mediumLean < 0 {
            return "短线进攻 · 中线注意回撤"
        }
        return "短线\(shortWord) · 中线\(mediumWord)"
    }
}
