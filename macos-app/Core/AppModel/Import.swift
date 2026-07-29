import Foundation

extension AppModel {
    func normalizedText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func fetchPlatformIfPossible() async throws -> PlatformPayload? {
        let prodCode = form.prodCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prodCode.isEmpty else {
            return nil
        }
        return try await platformClient.fetchPlatformPayload(prodCode: prodCode)
    }
}
