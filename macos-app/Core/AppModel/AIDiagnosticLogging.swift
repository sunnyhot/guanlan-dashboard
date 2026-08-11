import Foundation

extension AppModel {
    func makeAIAgentDiagnosticRecorder(
        runID: UUID,
        agentKind: String,
        scope: String,
        trigger: String,
        provider: TrendAIProviderSettings,
        privacyMode: TrendPrivacyMode,
        startedAt: String
    ) throws -> AIAgentDiagnosticRecorder? {
        guard let aiAnalysisDiagnosticLogsDirectoryURL else { return nil }
        return try AIAgentDiagnosticRecorder(
            directoryURL: aiAnalysisDiagnosticLogsDirectoryURL,
            metadata: AIAgentDiagnosticRunMetadata(
                runID: runID,
                agentKind: agentKind,
                scope: scope,
                trigger: trigger,
                providerName: provider.providerName,
                baseURL: provider.baseURL,
                model: provider.model,
                privacyMode: privacyMode.rawValue,
                startedAt: startedAt
            )
        )
    }

    func openAIAnalysisDiagnosticLogsDirectory() {
        guard let directoryURL = aiAnalysisDiagnosticLogsDirectoryURL else {
            lastTrendError = "AI 诊断日志目录尚未初始化。"
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            FilePresenter.reveal(directoryURL)
        } catch {
            lastTrendError = "无法打开 AI 诊断日志目录：\(error.localizedDescription)"
        }
    }
}
