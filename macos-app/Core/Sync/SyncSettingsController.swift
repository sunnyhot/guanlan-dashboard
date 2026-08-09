import Combine
import Foundation

/// macOS / iOS 同步设置页共用的业务状态与操作。
///
/// 两端保留各自的 SwiftUI 布局；网络调用、下载确认状态、错误转换和配置重置
/// 统一在这里，避免跨端行为漂移。
@MainActor
final class SyncSettingsController: ObservableObject {
    private let client: SyncClient

    @Published var serverURL: String {
        didSet { client.serverURL = serverURL }
    }
    @Published var password = ""
    @Published var confirmPassword = ""
    @Published var joinGroupID = ""
    @Published var joinToken = ""
    @Published var joinPassword = ""

    @Published private(set) var isRegistering = false
    @Published private(set) var isJoining = false
    @Published private(set) var isUploading = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadPreview: SyncImportPreview?
    @Published private(set) var pendingPayload: SyncPayload?
    @Published private(set) var errorMessage = ""
    @Published private(set) var noticeMessage = ""
    @Published var showsError = false
    @Published var showsDownloadConfirmation = false
    @Published var showsUndoConfirmation = false

    private var pendingRevision: Int?

    init(client: SyncClient? = nil) {
        let resolvedClient = client ?? .shared
        self.client = resolvedClient
        self.serverURL = resolvedClient.serverURL
    }

    var groupID: String? { client.groupId }
    var accessToken: String? { client.accessToken }
    var lastSyncTime: Date? { client.lastSyncTime }
    var lastKnownRevision: Int { client.lastKnownRevision }

    func refreshConfiguration() {
        serverURL = client.serverURL
    }

    func register() async {
        clearMessages()
        guard password == confirmPassword else {
            presentError("两次输入的密码不一致。")
            return
        }

        isRegistering = true
        defer {
            isRegistering = false
            password = ""
            confirmPassword = ""
        }
        do {
            try await client.register(password: password)
            noticeMessage = "同步组注册成功。请上传数据，然后在其他设备使用同步组 ID 和访问令牌加入。"
        } catch {
            presentError(message(for: error, fallback: "注册失败"))
        }
    }

    func joinGroup() async {
        clearMessages()
        isJoining = true
        defer {
            isJoining = false
            joinGroupID = ""
            joinToken = ""
            joinPassword = ""
        }
        do {
            try await client.joinGroup(
                existingGroupId: joinGroupID,
                accessToken: joinToken,
                password: joinPassword
            )
            noticeMessage = "已加入同步组，可以下载云端数据了。"
        } catch {
            presentError(message(for: error, fallback: "加入同步组失败"))
        }
    }

    func upload(model: AppModel, deviceName: String) async {
        clearMessages()
        isUploading = true
        defer { isUploading = false }
        do {
            let payload = model.makeSyncPayload(sourceDeviceName: deviceName)
            try await client.push(payload: payload)
            noticeMessage = "已上传到云端（rev \(client.lastKnownRevision)）。"
        } catch {
            presentError(message(for: error, fallback: "上传失败"))
        }
    }

    func download() async {
        clearMessages()
        isDownloading = true
        defer { isDownloading = false }
        do {
            let result = try await client.pull()
            pendingPayload = result.payload
            downloadPreview = result.preview
            pendingRevision = result.revision
            showsDownloadConfirmation = true
        } catch {
            presentError(message(for: error, fallback: "下载失败"))
        }
    }

    func applyDownload(to model: AppModel) {
        guard let pendingPayload, let pendingRevision else { return }
        do {
            try model.applySyncPayload(pendingPayload)
            client.didDownload(revision: pendingRevision)
            noticeMessage = "数据已从云端覆盖到本机。如需恢复，请点击“撤销上次下载”。"
        } catch {
            presentError("导入失败：\(error.localizedDescription)")
        }
        clearPendingDownload()
    }

    func cancelPendingDownload() {
        clearPendingDownload()
    }

    func undoDownload(on model: AppModel) {
        do {
            try model.undoLastSyncDownload()
            noticeMessage = "已恢复到下载前的状态。"
        } catch {
            presentError(message(for: error, fallback: "撤销失败"))
        }
    }

    func resetConfiguration() {
        client.resetConfiguration()
        clearPendingDownload()
        noticeMessage = "已重置同步配置，请重新注册。"
    }

    func dismissError() {
        errorMessage = ""
        showsError = false
    }

    private func clearPendingDownload() {
        pendingPayload = nil
        downloadPreview = nil
        pendingRevision = nil
        showsDownloadConfirmation = false
    }

    private func clearMessages() {
        errorMessage = ""
        noticeMessage = ""
        showsError = false
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showsError = true
    }

    private func message(for error: Error, fallback: String) -> String {
        if let syncError = error as? SyncError {
            return syncError.errorDescription ?? fallback
        }
        return "\(fallback)：\(error.localizedDescription)"
    }
}
