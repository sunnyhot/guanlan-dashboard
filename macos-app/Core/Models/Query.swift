import Foundation

enum QueryMode: String {
    case groupManager = "group-manager"
}

struct QueryFormState {
    var mode: QueryMode = .groupManager
    var prodCode: String = "LONG_WIN"
    var managerName: String = ""
    var groupURL: String = ""
    var groupID: String = ""
    var userName: String = "ETF拯救世界"
    var keyword: String = ""
    var since: String = ""
    var until: String = ""
    /// 留空表示持续翻页直到接口没有更多记录。
    var pages: String = ""
    var pageSize: String = "50"
    var autoRefresh: String = ""

}
