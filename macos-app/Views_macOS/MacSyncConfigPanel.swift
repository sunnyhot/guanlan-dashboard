#if os(macOS)
import SwiftUI

// MARK: - macOS 数据同步配置面板
//
// UI 完全为 macOS 原生写,不复用 iOS 版。复用 Core/Sync 的纯逻辑。

struct MacSyncConfigPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var serverURL = SyncClient.shared.serverURL
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isRegistering = false
    @State private var isUploading = false
    @State private var isDownloading = false
    @State private var downloadPreview: SyncImportPreview?
    @State private var pendingPayload: SyncPayload?
    @State private var errorMessage = ""
    @State private var noticeMessage = ""
    @State private var showDownloadConfirm = false
    @State private var showUndoConfirm = false

    private let deviceName: String = {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Mac"
        #endif
    }()

    var body: some View {
        Form {
            Section("同步服务") {
                TextField("服务地址 (https://...)", text: $serverURL)
                    .onChange(of: serverURL) { _, v in SyncClient.shared.serverURL = v }
            }

            if SyncClient.shared.groupId == nil {
                registerSection
            } else {
                statusSection
                actionsSection
                undoSection
            }
        }
        .formStyle(.grouped)
        .onAppear { serverURL = SyncClient.shared.serverURL }
        .confirmationDialog("确认下载并覆盖本机数据?", isPresented: $showDownloadConfirm, titleVisibility: .visible) {
            Button("下载并覆盖", role: .destructive) { applyDownload() }
            Button("取消", role: .cancel) { pendingPayload = nil }
        } message: {
            if let p = downloadPreview { Text(previewText(p)) }
        }
        .alert("同步出错", isPresented: .constant(!errorMessage.isEmpty)) {
            Button("好") { errorMessage = "" }
        } message: { Text(errorMessage) }
        .alert("确认撤销?", isPresented: $showUndoConfirm) {
            Button("撤销", role: .destructive) { undoDownload() }
            Button("取消", role: .cancel) {}
        } message: { Text("将恢复到上次下载前的本地数据。") }
    }

    // MARK: - 注册

    private var registerSection: some View {
        Section {
            SecureField("设置同步密码", text: $password)
            SecureField("再次确认密码", text: $confirmPassword)
            Button {
                Task { await register() }
            } label: {
                if isRegistering { HStack { ProgressView(); Text("注册中…") } }
                else { Text("注册同步组") }
            }
            .disabled(isRegistering || password.isEmpty || password != confirmPassword)
        } header: {
            Text("注册")
        } footer: {
            Text("密码用于加密同步数据,丢失后无法恢复。密码不会上传服务端。")
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("同步状态") {
            if let gid = SyncClient.shared.groupId {
                LabeledContent("同步组") { Text(gid).font(.caption.monospaced()).lineLimit(1) }
            }
            if let time = SyncClient.shared.lastSyncTime {
                LabeledContent("上次同步") {
                    Text(time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
            }
            LabeledContent("版本") { Text("rev \(SyncClient.shared.lastKnownRevision)").foregroundStyle(.secondary) }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            Button {
                Task { await upload() }
            } label: {
                if isUploading { HStack { ProgressView(); Text("上传中…") } }
                else { Label("上传并覆盖云端", systemImage: "icloud.and.arrow.up") }
            }
            .disabled(isUploading || isDownloading)

            Button {
                Task { await download() }
            } label: {
                if isDownloading { HStack { ProgressView(); Text("下载中…") } }
                else { Label("下载并覆盖本机", systemImage: "icloud.and.arrow.down") }
            }
            .disabled(isUploading || isDownloading)
        } header: {
            Text("数据同步")
        } footer: {
            if !noticeMessage.isEmpty { Text(noticeMessage).foregroundStyle(.green) }
        }
    }

    private var undoSection: some View {
        Section {
            Button("撤销上次下载", role: .destructive) { showUndoConfirm = true }
        }
    }

    // MARK: - 动作

    private func register() async {
        clearMessages()
        guard password == confirmPassword else { errorMessage = "两次输入的密码不一致。"; return }
        isRegistering = true
        do {
            try await SyncClient.shared.register(password: password)
            noticeMessage = "同步组注册成功,可以开始同步了。"
        } catch { errorMessage = (error as? SyncError)?.errorDescription ?? error.localizedDescription }
        isRegistering = false
        password = ""; confirmPassword = ""
    }

    private func upload() async {
        clearMessages()
        isUploading = true
        do {
            let payload = model.makeSyncPayload(sourceDeviceName: deviceName)
            try await SyncClient.shared.push(payload: payload, deviceName: deviceName)
            noticeMessage = "已上传到云端(rev \(SyncClient.shared.lastKnownRevision))。"
        } catch let e as SyncError { errorMessage = e.errorDescription ?? "上传失败" }
        catch { errorMessage = "上传失败:\(error.localizedDescription)" }
        isUploading = false
    }

    private func download() async {
        clearMessages()
        isDownloading = true
        do {
            let (payload, preview) = try await SyncClient.shared.pull()
            pendingPayload = payload; downloadPreview = preview
            showDownloadConfirm = true
        } catch let e as SyncError { errorMessage = e.errorDescription ?? "下载失败" }
        catch { errorMessage = "下载失败:\(error.localizedDescription)" }
        isDownloading = false
    }

    private func applyDownload() {
        guard let payload = pendingPayload else { return }
        do {
            try model.applySyncPayload(payload)
            SyncClient.shared.didDownload(revision: SyncClient.shared.lastKnownRevision)
            noticeMessage = "数据已从云端覆盖到本机。如需恢复,点击「撤销上次下载」。"
        } catch { errorMessage = "导入失败:\(error.localizedDescription)" }
        pendingPayload = nil; downloadPreview = nil
    }

    private func undoDownload() {
        do {
            try model.undoLastSyncDownload()
            noticeMessage = "已恢复到下载前的状态。"
        } catch { errorMessage = (error as? SyncError)?.errorDescription ?? "撤销失败" }
    }

    private func clearMessages() { errorMessage = ""; noticeMessage = "" }

    private func previewText(_ p: SyncImportPreview) -> String {
        """
        导出时间:\(p.exportedAt.formatted(date: .abbreviated, time: .shortened))
        来源设备:\(p.sourceDeviceName)
        持仓 \(p.holdingsCount) · 待确认 \(p.pendingTradesCount) · 计划 \(p.plansCount) · 关注 \(p.watchlistCount) · 投顾 \(p.alfaCount)
        \(p.hasTrendConfig ? "含 AI 模型配置" : "")
        此操作将完全覆盖本机数据,不可撤销(除非用「撤销上次下载」)。
        """
    }
}
#endif
