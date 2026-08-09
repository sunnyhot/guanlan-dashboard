#if os(iOS)
import SwiftUI

// MARK: - iOS 数据同步配置页
//
// UI 完全为 iOS 原生写,不复用 macOS 版。复用 Core/Sync 的纯逻辑:
// SyncClient(register/push/pull)、AppModel(makeSyncPayload/applySyncPayload)。

struct IOSSyncConfigView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var sync = SyncSettingsController()
    @State private var showScanner = false

    private let deviceName = UIDevice.current.name

    var body: some View {
        List {
            configSection
            if sync.groupID == nil {
                registerSection
                joinSection
            } else {
                statusSection
                actionsSection
                undoSection
            }
        }
        .navigationTitle("数据同步")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.refreshConfiguration() }
        .confirmationDialog("确认下载并覆盖本机数据?", isPresented: $sync.showsDownloadConfirmation, titleVisibility: .visible) {
            Button("下载并覆盖", role: .destructive) { sync.applyDownload(to: model) }
            Button("取消", role: .cancel) { sync.cancelPendingDownload() }
        } message: {
            if let preview = sync.downloadPreview { Text(preview.confirmationText) }
        }
        .alert("同步出错", isPresented: $sync.showsError) {
            Button("好") { sync.dismissError() }
        } message: { Text(sync.errorMessage) }
        .alert("确认撤销?", isPresented: $sync.showsUndoConfirmation) {
            Button("撤销", role: .destructive) { sync.undoDownload(on: model) }
            Button("取消", role: .cancel) {}
        } message: { Text("将恢复到上次下载前的本地数据。") }
    }

    // MARK: - 服务地址

    private var configSection: some View {
        Section("同步服务") {
            TextField("https://your-server.com", text: $sync.serverURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    // MARK: - 注册

    private var registerSection: some View {
        Section {
            SecureField("设置同步密码", text: $sync.password)
            SecureField("再次确认密码", text: $sync.confirmPassword)
            Button {
                Task { await sync.register() }
            } label: {
                if sync.isRegistering { HStack { ProgressView(); Text("注册中…") } }
                else { Text("注册同步组") }
            }
            .disabled(sync.isRegistering || sync.password.isEmpty || sync.password != sync.confirmPassword)
        } header: {
            Text("注册")
        } footer: {
            Text("密码用于加密同步数据,丢失后无法恢复。密码不会上传服务端。")
        }
    }

    // MARK: - 加入同步组

    private var joinSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("扫码加入", systemImage: "qrcode.viewfinder")
            }
            TextField("同步组 ID (g_xxx)", text: $sync.joinGroupID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("访问令牌 (tok_xxx)", text: $sync.joinToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("同步密码", text: $sync.joinPassword)
            Button {
                Task { await sync.joinGroup() }
            } label: {
                if sync.isJoining { HStack { ProgressView(); Text("加入中…") } }
                else { Text("加入同步组") }
            }
            .disabled(sync.isJoining || sync.joinGroupID.isEmpty || sync.joinToken.isEmpty || sync.joinPassword.isEmpty)
        } header: {
            Text("加入已有同步组")
        } footer: {
            Text("扫码或手动填入第一台设备的 groupId、accessToken 和同步密码。")
        }
        .sheet(isPresented: $showScanner) {
            IOSQRScannerView { raw in
                if let cred = QRCodeHelper.decodeSyncCredentials(raw) {
                    sync.joinGroupID = cred.groupId
                    sync.joinToken = cred.accessToken
                }
                showScanner = false
            }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section("同步状态") {
            if let gid = sync.groupID {
                LabeledContent("同步组") { Text(gid).font(.caption.monospaced()).lineLimit(1) }
            }
            if let time = sync.lastSyncTime {
                LabeledContent("上次同步") {
                    Text(time.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(IOSDesign.muted)
                }
            }
            LabeledContent("版本") { Text("rev \(sync.lastKnownRevision)").foregroundStyle(IOSDesign.muted) }
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        Section {
            Button {
                Task { await sync.upload(model: model, deviceName: deviceName) }
            } label: {
                if sync.isUploading { HStack { ProgressView(); Text("上传中…") } }
                else { Label("上传并覆盖云端", systemImage: "icloud.and.arrow.up") }
            }
            .disabled(sync.isUploading || sync.isDownloading)

            Button {
                Task { await sync.download() }
            } label: {
                if sync.isDownloading { HStack { ProgressView(); Text("下载中…") } }
                else { Label("下载并覆盖本机", systemImage: "icloud.and.arrow.down") }
            }
            .disabled(sync.isUploading || sync.isDownloading)
        } header: {
            Text("数据同步")
        } footer: {
            if !sync.noticeMessage.isEmpty { Text(sync.noticeMessage).foregroundStyle(.green) }
        }
    }

    private var undoSection: some View {
        Section {
            Button("撤销上次下载", role: .destructive) { sync.showsUndoConfirmation = true }
            Button("重置同步配置", role: .destructive) { sync.resetConfiguration() }
        }
    }
}
#endif
