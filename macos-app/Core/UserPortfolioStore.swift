import Foundation

struct UserPortfolioStore {
    func load(from fileURL: URL) throws -> [UserPortfolioHolding] {
        try JSONFilePersistence.load(
            [UserPortfolioHolding].self,
            from: fileURL,
            defaultValue: []
        )
    }

    func save(_ holdings: [UserPortfolioHolding], to fileURL: URL) throws {
        try JSONFilePersistence.save(holdings, to: fileURL)
    }

    func delete(at fileURL: URL) throws {
        try JSONFilePersistence.delete(at: fileURL)
    }
}
