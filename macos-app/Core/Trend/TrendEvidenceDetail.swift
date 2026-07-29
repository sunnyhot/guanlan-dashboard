import Foundation

enum TrendEvidenceRole: String, CaseIterable, Hashable {
    case supporting
    case counter
    case context
    case referenced
}

struct TrendEvidenceDetailItem: Identifiable, Hashable {
    let role: TrendEvidenceRole
    let evidence: TrendEvidence

    var id: String {
        "\(role.rawValue):\(evidence.id)"
    }
}

struct TrendEvidenceDetailModel: Hashable {
    let items: [TrendEvidenceDetailItem]
    let missingEvidenceIDs: [String]
    let exemptionReason: String?

    init(
        claimEvidence: TrendClaimEvidence,
        referencedEvidenceIDs: [String],
        evidenceLedger: [TrendEvidence]
    ) {
        let evidenceByID = Dictionary(
            evidenceLedger.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen = Set<String>()
        var resolvedItems: [TrendEvidenceDetailItem] = []
        var missingIDs: [String] = []

        func append(_ ids: [String], role: TrendEvidenceRole) {
            for rawID in ids {
                let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                if let evidence = evidenceByID[id] {
                    resolvedItems.append(
                        TrendEvidenceDetailItem(role: role, evidence: evidence)
                    )
                } else {
                    missingIDs.append(id)
                }
            }
        }

        append(claimEvidence.supportingEvidenceIDs, role: .supporting)
        append(claimEvidence.counterEvidenceIDs, role: .counter)
        append(claimEvidence.contextEvidenceIDs, role: .context)
        append(referencedEvidenceIDs, role: .referenced)

        items = resolvedItems
        missingEvidenceIDs = missingIDs
        exemptionReason = claimEvidence.exemptionReason
    }

    func items(for role: TrendEvidenceRole) -> [TrendEvidenceDetailItem] {
        items.filter { $0.role == role }
    }
}
