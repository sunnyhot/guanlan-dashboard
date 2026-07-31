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

    func fetchPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "mode": mode.rawValue,
            "prod_code": prodCode,
            "manager_name": managerName,
            "group_url": groupURL,
            "group_id": groupID,
            "user_name": userName,
            "keyword": keyword,
            "since": since,
            "until": until,
            "pages": pages,
            "page_size": pageSize,
            "auto_refresh": autoRefresh,
        ]
        payload = payload.filter { _, value in
            if let text = value as? String {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        return payload
    }
}
