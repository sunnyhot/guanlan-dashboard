import Foundation

struct MarketCloseReviewRecoveredRun: Hashable {
    let report: TrendAnalysisReport
    let portfolioAssets: [TrendContextAsset]
}

/// 从旧版本的本地完整诊断日志恢复最近一次收盘复盘。
///
/// 旧版本只有会被增量模块覆盖的共享报告，但诊断 JSONL 的 `run_completed`
/// 仍保存了已校验的完整报告，`get_portfolio_assets` 也保留了运行当时
/// 的冻结持仓。恢复过程只读本地文件，不调用模型或任何接口。
struct MarketCloseReviewArchiveRecovery {
    func latestRun(
        in directoryURL: URL,
        generatedAt: String
    ) -> MarketCloseReviewRecoveredRun? {
        let day = String(generatedAt.prefix(10))
        guard !day.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let candidates = files
            .filter {
                $0.pathExtension == "jsonl"
                    && $0.lastPathComponent.hasPrefix("\(day)-closeReview-")
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        var reportOnlyFallback: MarketCloseReviewRecoveredRun?
        for fileURL in candidates {
            if let run = recoveredRun(from: fileURL),
               String(run.report.generatedAt.prefix(10)) == day {
                if !run.portfolioAssets.isEmpty {
                    return run
                }
                if reportOnlyFallback == nil {
                    reportOnlyFallback = run
                }
            }
        }
        return reportOnlyFallback
    }

    func latestReport(
        in directoryURL: URL,
        generatedAt: String
    ) -> TrendAnalysisReport? {
        latestRun(in: directoryURL, generatedAt: generatedAt)?.report
    }

    private func recoveredRun(from fileURL: URL) -> MarketCloseReviewRecoveredRun? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var report: TrendAnalysisReport?
        var assetsByID: [String: TrendContextAsset] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(AIAgentDiagnosticTraceEntry.self, from: data),
                  let payload = entry.payload,
                  let payloadData = try? encoder.encode(payload) else {
                continue
            }

            if entry.event == "run_completed",
               let completed = try? decoder.decode(TrendAnalysisReport.self, from: payloadData) {
                report = completed
                continue
            }

            if entry.event == "tool_result",
               entry.toolName == "get_portfolio_assets",
               let trace = try? decoder.decode(PortfolioAssetsToolTrace.self, from: payloadData) {
                for asset in trace.result.data.assets {
                    assetsByID[asset.id] = asset
                }
            }
        }

        guard let report else { return nil }
        return MarketCloseReviewRecoveredRun(
            report: report,
            portfolioAssets: assetsByID.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        )
    }

    private struct PortfolioAssetsToolTrace: Decodable {
        let result: ResultEnvelope
    }

    private struct ResultEnvelope: Decodable {
        let data: Page
    }

    private struct Page: Decodable {
        let assets: [TrendContextAsset]
    }
}
