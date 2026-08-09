import Foundation

/// alfa 投顾组合列表的持久化（纯函数式 load/save，状态由 AppModel 持有）。
/// 仿 `InvestmentPlansStore` / `ManagerWatchStore` 的范式。
struct AlfaPortfolioStore {
    func load(from fileURL: URL) -> [AlfaPortfolioCatalogItem] {
        do {
            return try JSONFilePersistence.load(
                [AlfaPortfolioCatalogItem].self,
                from: fileURL,
                defaultValue: Self.defaultPortfolios
            )
        } catch {
            return Self.defaultPortfolios
        }
    }

    func save(_ portfolios: [AlfaPortfolioCatalogItem], to fileURL: URL) throws {
        try JSONFilePersistence.save(portfolios, to: fileURL)
    }

    /// 默认预置一个已确认存在公开调仓记录的组合，避免首次启动立即出现空状态。
    static let defaultPortfolios: [AlfaPortfolioCatalogItem] = [
        AlfaPortfolioCatalogItem(
            poCode: "ZH157591",
            name: "华夏全自动超级配置",
            author: "华夏基金",
            category: "长钱"
        ),
    ]
}
