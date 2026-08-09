import Foundation

struct InvestmentPlansStore {
    func load(from fileURL: URL) throws -> [PersonalInvestmentPlan] {
        try JSONFilePersistence.load(
            [PersonalInvestmentPlan].self,
            from: fileURL,
            defaultValue: []
        )
    }

    func save(_ plans: [PersonalInvestmentPlan], to fileURL: URL) throws {
        try JSONFilePersistence.save(plans, to: fileURL)
    }

    func delete(at fileURL: URL) throws {
        try JSONFilePersistence.delete(at: fileURL)
    }
}
