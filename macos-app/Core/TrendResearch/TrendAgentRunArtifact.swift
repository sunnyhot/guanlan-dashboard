import CryptoKit
import Foundation

struct TrendAgentToolCallAudit: Codable, Hashable, Sendable {
    let sequence: Int
    let name: String
    let redactedArguments: String
    let succeeded: Bool
    let evidenceIDs: [String]
    let errorCode: String?

    init(sequence: Int, call: AgentToolCall, result: TrendResearchToolResult) {
        self.sequence = sequence
        name = call.function.name
        redactedArguments = TrendAgentAuditRedactor.redactedArguments(
            toolName: call.function.name,
            argumentsJSON: call.function.arguments
        )
        succeeded = !result.isError
        let envelope = Self.envelope(from: result.contentJSON)
        evidenceIDs = envelope.evidenceIDs
        errorCode = envelope.errorCode
    }

    private static func envelope(
        from json: String
    ) -> (evidenceIDs: [String], errorCode: String?) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], "invalid_tool_result")
        }
        let evidenceIDs = object["evidence_ids"] as? [String]
            ?? (object["data"] as? [String: Any])?["evidence_ids"] as? [String]
            ?? []
        let errorCode = (object["error"] as? [String: Any])?["code"] as? String
        return (evidenceIDs, errorCode)
    }
}

struct TrendClaimEvidenceAuditLink: Codable, Hashable, Sendable {
    let claimPath: String
    let supportingEvidenceIDs: [String]
    let counterEvidenceIDs: [String]
    let contextEvidenceIDs: [String]
    let exemptionReason: String?
}

struct TrendConfidenceNormalizationAudit: Codable, Hashable, Sendable {
    let claimPath: String
    let score: Int
    let finalLabel: String
}

struct TrendValidatorAuditResult: Codable, Hashable, Sendable {
    let accepted: Bool
    let messages: [String]
}

struct TrendAgentRunArtifact: Codable, Hashable, Sendable, Identifiable {
    static let promptVersion = "trend-research-prompt-v4-official-first"
    static let policyVersion = "trend-claim-evidence-v2"

    let runID: UUID
    let agentKind: String
    let startedAt: String
    let completedAt: String
    let trigger: String
    let modelFingerprint: String
    let promptVersion: String
    let reportSchemaVersion: Int
    let policyVersion: String
    let snapshotHash: String
    let sourceStatuses: [TrendSourceStatus]
    let redactedToolCalls: [TrendAgentToolCallAudit]
    let canonicalEvidenceLedger: [TrendEvidence]
    let claimEvidenceLinks: [TrendClaimEvidenceAuditLink]
    let validatorResults: [TrendValidatorAuditResult]
    let confidenceNormalizationResults: [TrendConfidenceNormalizationAudit]
    let verifierResults: [String]
    let reportDisposition: TrendReportDisposition

    var id: UUID { runID }

    func replacingTrigger(_ value: String) -> TrendAgentRunArtifact {
        TrendAgentRunArtifact(
            runID: runID,
            agentKind: agentKind,
            startedAt: startedAt,
            completedAt: completedAt,
            trigger: value,
            modelFingerprint: modelFingerprint,
            promptVersion: promptVersion,
            reportSchemaVersion: reportSchemaVersion,
            policyVersion: policyVersion,
            snapshotHash: snapshotHash,
            sourceStatuses: sourceStatuses,
            redactedToolCalls: redactedToolCalls,
            canonicalEvidenceLedger: canonicalEvidenceLedger,
            claimEvidenceLinks: claimEvidenceLinks,
            validatorResults: validatorResults,
            confidenceNormalizationResults: confidenceNormalizationResults,
            verifierResults: verifierResults,
            reportDisposition: reportDisposition
        )
    }

    static func make(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        report: TrendAnalysisReport,
        completedAt: String,
        toolCalls: [TrendAgentToolCallAudit],
        canonicalEvidence: [TrendEvidence]
    ) -> TrendAgentRunArtifact {
        TrendAgentRunArtifact(
            runID: snapshot.runID,
            agentKind: "trend-research",
            startedAt: snapshot.createdAt,
            completedAt: completedAt,
            trigger: "unknown",
            modelFingerprint: settings.fingerprint,
            promptVersion: promptVersion,
            reportSchemaVersion: report.schemaVersion,
            policyVersion: policyVersion,
            snapshotHash: snapshotHash(snapshot),
            sourceStatuses: report.sourceStatuses,
            redactedToolCalls: toolCalls,
            canonicalEvidenceLedger: canonicalEvidence.map(redactedEvidence),
            claimEvidenceLinks: claimLinks(report),
            validatorResults: [
                TrendValidatorAuditResult(accepted: true, messages: [])
            ],
            confidenceNormalizationResults: confidenceResults(report),
            verifierResults: [],
            reportDisposition: report.disposition
        )
    }

    static func makeNextHour(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        report: NextHourGuidanceReport,
        trigger: String
    ) -> TrendAgentRunArtifact {
        let links = report.actions.map {
            TrendClaimEvidenceAuditLink(
                claimPath: "nextHour.action.\($0.id.uuidString)",
                supportingEvidenceIDs: $0.evidenceIDs,
                counterEvidenceIDs: [],
                contextEvidenceIDs: [],
                exemptionReason: $0.action == .hold
                    ? "交易证据门槛未满足或当前建议为持有。"
                    : nil
            )
        }
        let confidence = report.actions.map {
            TrendConfidenceNormalizationAudit(
                claimPath: "nextHour.action.\($0.id.uuidString)",
                score: $0.confidence,
                finalLabel: TrendConfidence.label(for: $0.confidence)
            )
        }
        return TrendAgentRunArtifact(
            runID: report.runID,
            agentKind: "next-hour-guidance",
            startedAt: snapshot.createdAt,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            trigger: trigger,
            modelFingerprint: settings.fingerprint,
            promptVersion: "next-hour-guidance-v2",
            reportSchemaVersion: 1,
            policyVersion: policyVersion,
            snapshotHash: snapshotHash(snapshot),
            sourceStatuses: report.sourceStatuses,
            redactedToolCalls: report.auditToolCalls,
            canonicalEvidenceLedger: report.auditEvidence.map(redactedEvidence),
            claimEvidenceLinks: links,
            validatorResults: [
                TrendValidatorAuditResult(accepted: true, messages: [])
            ],
            confidenceNormalizationResults: confidence,
            verifierResults: [],
            reportDisposition: report.disposition
        )
    }

    /// DecisionCase 研究 Agent 的审计产物(Slice 3)。
    static func makeDecisionCase(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        report: DecisionCaseResearchReport,
        trigger: String
    ) -> TrendAgentRunArtifact {
        TrendAgentRunArtifact(
            runID: UUID(),
            agentKind: "decision-case-research",
            startedAt: snapshot.createdAt,
            completedAt: ISO8601DateFormatter().string(from: Date()),
            trigger: trigger,
            modelFingerprint: settings.fingerprint,
            promptVersion: "decision-case-research-v1",
            reportSchemaVersion: DecisionCaseResearchReport.currentSchemaVersion,
            policyVersion: policyVersion,
            snapshotHash: snapshotHash(snapshot),
            sourceStatuses: [],
            redactedToolCalls: [],
            canonicalEvidenceLedger: report.evidence.map(redactedEvidence),
            claimEvidenceLinks: [],
            validatorResults: [
                TrendValidatorAuditResult(accepted: true, messages: [])
            ],
            confidenceNormalizationResults: [],
            verifierResults: [],
            reportDisposition: .analysisOnly
        )
    }

    static func makeFailure(
        snapshot: TrendResearchSnapshot,
        settings: TrendAIProviderSettings,
        officialSourceConfigured: Bool = false,
        alphaVantageConfigured: Bool = false,
        completedAt: String,
        toolCalls: [TrendAgentToolCallAudit],
        canonicalEvidence: [TrendEvidence],
        message: String
    ) -> TrendAgentRunArtifact {
        var bySource = Dictionary(
            snapshot.sourceStatuses.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let officialEvidence = canonicalEvidence.filter {
            $0.metadata.sourceKind.isOfficialPrimary || $0.id.hasPrefix("official:sec:")
        }
        if snapshot.eligibleSECResearchTickers.isEmpty {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: .notRequested,
                receivedAt: completedAt,
                detail: "当前快照没有可映射到 SEC 的美国股票代码。"
            )
        } else {
            bySource[.officialSource] = TrendSourceStatus(
                source: .officialSource,
                status: officialSourceConfigured
                    ? (officialEvidence.isEmpty ? .failed : .success)
                    : .notConfigured,
                asOf: officialEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: officialEvidence.map(\.retrievedAt).max() ?? completedAt,
                errorCode: officialSourceConfigured && officialEvidence.isEmpty
                    ? "no_usable_official_evidence"
                    : nil,
                itemCount: officialEvidence.count
            )
        }
        let alphaEvidence = canonicalEvidence.filter {
            $0.metadata.sourceKind == .licensedMarketData
                || $0.id.hasPrefix("vendor:alphavantage:")
        }
        if snapshot.eligibleAlphaVantageSymbols.isEmpty {
            bySource[.alphaVantage] = TrendSourceStatus(
                source: .alphaVantage,
                status: .notRequested,
                receivedAt: completedAt
            )
        } else {
            bySource[.alphaVantage] = TrendSourceStatus(
                source: .alphaVantage,
                status: alphaVantageConfigured
                    ? (alphaEvidence.isEmpty ? .failed : .success)
                    : .notConfigured,
                asOf: alphaEvidence.compactMap { $0.publishedAt ?? $0.retrievedAt }.max(),
                receivedAt: alphaEvidence.map(\.retrievedAt).max() ?? completedAt,
                errorCode: alphaVantageConfigured && alphaEvidence.isEmpty
                    ? "no_usable_alpha_vantage_evidence"
                    : nil,
                itemCount: alphaEvidence.count
            )
        }
        bySource[.webSearch] = TrendSourceStatus(
            source: .webSearch,
            status: .notConfigured,
            receivedAt: completedAt,
            detail: "联网搜索已下线（Tavily 已移除）。"
        )
        for source in TrendDataSource.allCases where bySource[source] == nil {
            bySource[source] = TrendSourceStatus(
                source: source,
                status: .notRequested,
                receivedAt: completedAt
            )
        }
        return TrendAgentRunArtifact(
            runID: snapshot.runID,
            agentKind: "trend-research",
            startedAt: snapshot.createdAt,
            completedAt: completedAt,
            trigger: "unknown",
            modelFingerprint: settings.fingerprint,
            promptVersion: promptVersion,
            reportSchemaVersion: TrendAnalysisReport.currentSchemaVersion,
            policyVersion: policyVersion,
            snapshotHash: snapshotHash(snapshot),
            sourceStatuses: TrendDataSource.allCases.compactMap { bySource[$0] },
            redactedToolCalls: toolCalls,
            canonicalEvidenceLedger: canonicalEvidence.map(redactedEvidence),
            claimEvidenceLinks: [],
            validatorResults: [
                TrendValidatorAuditResult(accepted: false, messages: [message])
            ],
            confidenceNormalizationResults: [],
            verifierResults: [],
            reportDisposition: .insufficientEvidence
        )
    }

    private static func snapshotHash(_ snapshot: TrendResearchSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return "encoding-failed" }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func redactedEvidence(_ evidence: TrendEvidence) -> TrendEvidence {
        TrendEvidence(
            id: evidence.id,
            sourceName: evidence.sourceName,
            title: evidence.title,
            url: evidence.url,
            publishedAt: evidence.publishedAt,
            retrievedAt: evidence.retrievedAt,
            summary: TrendAgentAuditRedactor.redactedSensitiveText(evidence.summary),
            metadata: evidence.metadata
        )
    }

    private static func claimLinks(
        _ report: TrendAnalysisReport
    ) -> [TrendClaimEvidenceAuditLink] {
        var links: [TrendClaimEvidenceAuditLink] = []
        func append(_ path: String, _ evidence: TrendClaimEvidence) {
            links.append(
                TrendClaimEvidenceAuditLink(
                    claimPath: path,
                    supportingEvidenceIDs: evidence.supportingEvidenceIDs,
                    counterEvidenceIDs: evidence.counterEvidenceIDs,
                    contextEvidenceIDs: evidence.contextEvidenceIDs,
                    exemptionReason: evidence.exemptionReason
                )
            )
        }
        append("portfolio", report.portfolio.claimEvidence)
        report.horizons.forEach { append("horizon.\($0.horizon.rawValue)", $0.claimEvidence) }
        report.marketOutlook.forEach { append("market.\($0.id)", $0.claimEvidence) }
        report.sectors.forEach { append("sector.\($0.id)", $0.claimEvidence) }
        report.opportunities.forEach { append("opportunity.\($0.id)", $0.claimEvidence) }
        (report.keyAssets + report.assetTrends).forEach { asset in
            append("asset.\(asset.id)", asset.claimEvidence)
            asset.horizons.forEach {
                append("asset.\(asset.id).horizon.\($0.horizon.rawValue)", $0.claimEvidence)
            }
        }
        report.actions.forEach { append("action.\($0.id)", $0.claimEvidence) }
        return links
    }

    private static func confidenceResults(
        _ report: TrendAnalysisReport
    ) -> [TrendConfidenceNormalizationAudit] {
        var results: [TrendConfidenceNormalizationAudit] = []
        func append(_ path: String, _ confidence: TrendConfidence) {
            results.append(
                TrendConfidenceNormalizationAudit(
                    claimPath: path,
                    score: confidence.score,
                    finalLabel: confidence.label
                )
            )
        }
        report.horizons.forEach { append("horizon.\($0.horizon.rawValue)", $0.confidence) }
        report.marketOutlook.forEach { append("market.\($0.id)", $0.confidence) }
        report.sectors.forEach { append("sector.\($0.id)", $0.confidence) }
        report.opportunities.forEach { append("opportunity.\($0.id)", $0.confidence) }
        (report.keyAssets + report.assetTrends).forEach { asset in
            asset.horizons.forEach {
                append("asset.\(asset.id).horizon.\($0.horizon.rawValue)", $0.confidence)
            }
        }
        report.actions.forEach { append("action.\($0.id)", $0.confidence) }
        return results
    }
}

struct TrendAgentRunArtifactStore {
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let maximumArtifactCount: Int

    init(maximumArtifactCount: Int = 20) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.maximumArtifactCount = max(1, maximumArtifactCount)
    }

    func save(_ artifact: TrendAgentRunArtifact, in directoryURL: URL) throws {
        let fileURL = directoryURL.appendingPathComponent(
            "\(artifact.completedAt.prefix(10))-\(artifact.runID.uuidString).json",
            isDirectory: false
        )
        try JSONFilePersistence.save(artifact, to: fileURL, encoder: encoder)
        try trimArtifacts(in: directoryURL)
    }

    func load(from fileURL: URL) throws -> TrendAgentRunArtifact {
        guard let artifact = try JSONFilePersistence.load(
            TrendAgentRunArtifact.self,
            from: fileURL,
            decoder: decoder
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return artifact
    }

    private func trimArtifacts(in directoryURL: URL) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for staleURL in files.dropFirst(maximumArtifactCount) {
            try FileManager.default.removeItem(at: staleURL)
        }
    }
}

enum TrendAgentAuditRedactor {
    static func redactedArguments(
        toolName: String,
        argumentsJSON: String
    ) -> String {
        if toolName == TrendResearchAgent.submitToolName
            || TrendReportModuleToolName.all.contains(toolName) {
            return #"{"report_module":"[omitted]"}"#
        }
        guard let data = argumentsJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "[invalid-json]"
        }
        for key in ["api_key", "apiKey", "token", "cookie", "authorization"] {
            if object[key] != nil { object[key] = "[redacted]" }
        }
        if let query = object["query"] as? String {
            object["query"] = redactedSensitiveText(query)
        }
        guard let output = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ) else {
            return "[serialization-failed]"
        }
        return String(data: output, encoding: .utf8) ?? "[serialization-failed]"
    }

    static func redactedSensitiveText(_ value: String) -> String {
        var result = value
        let patterns = [
            #"\b(sk-[A-Za-z0-9_-]{8,})\b"#,
            #"(?i)\b(bearer\s+[A-Za-z0-9._-]{8,})\b"#,
            #"(¥|￥|人民币)\s*\d+(?:[,.]\d+)*(?:\.\d+)?"#,
            #"\d+(?:[,.]\d+)*(?:\.\d+)?\s*(元|万元|万|亿元)"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[redacted]"
            )
        }
        return result
    }
}
