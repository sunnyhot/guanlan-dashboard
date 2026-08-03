#if os(macOS)
import SwiftUI

// MARK: - macOS 数据同步配置面板
//
// 使用 SettingsPanel + SettingsCardGroup,与其他设置面板风格一致。

struct MacSyncConfigPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var serverURL = SyncClient.shared.serverURL
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isRegistering = false
    @State private var isJoining = false
    @State private var isUploading = false
    @State private var isDownloading = false
    @State private var joinGroupId = ""
    @State private var joinToken = ""
    @State private var joinPassword = ""
    @State private var downloadPreview: SyncImportPreview?
    @State private var pendingPayload: SyncPayload?
    @State private var errorMessage = ""
    @State private var noticeMessage = ""
    @State private var showDownloadConfirm = false
    @State private var showUndoConfirm = false

    private let deviceName: String = {
        Host.current().localizedName ?? "Mac"
    }()

    var body: some View {
        SettingsPanel(title: "数据同步", subtitle: "跨设备同步持仓、配置与关注列表", icon: "icloud.and.arrow.up.and.down") {
            VStack(alignment: .leading, spacing: AppPalette.spaceXL) {
                serverCard
                if SyncClient.shared.groupId == nil {
                    registerCard
                    joinCard
                } else {
                    statusCard
                    actionsCard
                    undoCard
                }
            }
        }
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

    // MARK: - 服务地址

    private var serverCard: some View {
        SettingsCardGroup(title: "同步服务", subtitle: "服务端地址", icon: "server.rack", tint: AppPalette.brand) {
            SettingsControlRow(title: "地址", detail: "同步服务器的 URL", icon: "link", tint: AppPalette.brand) {
                TextField("https://...", text: $serverURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onChange(of: serverURL) { _, v in SyncClient.shared.serverURL = v }
            }
            SettingsDivider()
            SettingsActionRow {
                Text(noticeMessage)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.positive)
            }
        }
    }

    // MARK: - 注册

    private var registerCard: some View {
        SettingsCardGroup(title: "注册", subtitle: "创建同步组", icon: "person.badge.plus", tint: AppPalette.brand) {
            SettingsControlRow(title: "密码", detail: "用于加密同步数据,丢失无法恢复", icon: "lock", tint: AppPalette.brand) {
                SecureField("同步密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "确认", detail: "再次输入密码", icon: "lock.fill", tint: AppPalette.brand) {
                SecureField("确认密码", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await register() }
                } label: {
                    if isRegistering { HStack { ProgressView(); Text("注册中…") } }
                    else { Text("注册同步组") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .disabled(isRegistering || password.isEmpty || password != confirmPassword)
            }
        }
    }

    // MARK: - 加入已有同步组

    private var joinCard: some View {
        SettingsCardGroup(title: "加入同步组", subtitle: "从其他设备加入", icon: "person.badge.plus", tint: AppPalette.info) {
            SettingsControlRow(title: "同步组 ID", detail: "第一台设备的 groupId", icon: "number", tint: AppPalette.info) {
                TextField("g_xxxxx", text: $joinGroupId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "访问令牌", detail: "第一台设备的 accessToken", icon: "key", tint: AppPalette.info) {
                SecureField("tok_xxxxx", text: $joinToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "同步密码", detail: "与第一台设备相同的密码", icon: "lock", tint: AppPalette.info) {
                SecureField("密码", text: $joinPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await joinGroup() }
                } label: {
                    if isJoining { HStack { ProgressView(); Text("加入中…") } }
                    else { Text("加入同步组") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.info)
                .disabled(isJoining || joinGroupId.isEmpty || joinToken.isEmpty || joinPassword.isEmpty)
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        SettingsCardGroup(title: "同步状态", subtitle: "当前同步信息", icon: "checkmark.seal", tint: AppPalette.positive) {
            if let gid = SyncClient.shared.groupId {
                SettingsRow(title: "同步组", value: gid, detail: "组标识(给其他设备填)", icon: "number", tint: AppPalette.muted)
                SettingsDivider()
            }
            if let tok = SyncClient.shared.accessToken {
                SettingsRow(title: "访问令牌", value: tok, detail: "accessToken(给其他设备填)", icon: "key", tint: AppPalette.muted)
                SettingsDivider()
            }
            if let time = SyncClient.shared.lastSyncTime {
                SettingsRow(title: "上次同步", value: time.formatted(date: .abbreviated, time: .shortened), detail: "最近一次同步", icon: "clock", tint: AppPalette.muted)
                SettingsDivider()
            }
            SettingsRow(title: "版本", value: "rev \(SyncClient.shared.lastKnownRevision)", detail: "服务端版本号", icon: "tag", tint: AppPalette.muted)
            SettingsDivider()
            SettingsActionRow {
                if let gid = SyncClient.shared.groupId, let tok = SyncClient.shared.accessToken {
                    VStack(alignment: .center, spacing: 8) {
                        Text("其他设备扫码加入").font(AppPalette.appFont(.caption)).foregroundStyle(AppPalette.muted)
                        if let qr = QRCodeHelper.generateQRImage(from: QRCodeHelper.encodeSyncCredentials(groupId: gid, accessToken: tok), scale: 10) {
                            Image(nsImage: qr)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: 160, height: 160)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - 操作

    private var actionsCard: some View {
        SettingsCardGroup(title: "数据同步", subtitle: "上传或下载数据", icon: "arrow.up.arrow.down.circle", tint: AppPalette.brand) {
            SettingsActionRow {
                Button {
                    Task { await upload() }
                } label: {
                    if isUploading { HStack { ProgressView(); Text("上传中…") } }
                    else { Label("上传并覆盖云端", systemImage: "icloud.and.arrow.up") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .disabled(isUploading || isDownloading)

                Button {
                    Task { await download() }
                } label: {
                    if isDownloading { HStack { ProgressView(); Text("下载中…") } }
                    else { Label("下载并覆盖本机", systemImage: "icloud.and.arrow.down") }
                }
                .buttonStyle(.appSecondary)
                .tint(AppPalette.brand)
                .disabled(isUploading || isDownloading)
            }
            if !noticeMessage.isEmpty {
                SettingsDivider()
                SettingsActionRow {
                    Text(noticeMessage)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.positive)
                }
            }
        }
    }

    private var undoCard: some View {
        SettingsCardGroup(title: "恢复", subtitle: "撤销上次下载", icon: "arrow.uturn.backward", tint: AppPalette.warning) {
            SettingsActionRow {
                Button("撤销上次下载", role: .destructive) {
                    showUndoConfirm = true
                }
                .buttonStyle(.appDanger)
                .tint(AppPalette.warning)

                Button("重置同步配置", role: .destructive) {
                    resetConfig()
                }
                .buttonStyle(.appDanger)
                .tint(AppPalette.danger)
            }
        }
    }

    // MARK: - 动作

    private func register() async {
        clearMessages()
        guard password == confirmPassword else { errorMessage = "两次输入的密码不一致。"; return }
        isRegistering = true
        do {
            try await SyncClient.shared.register(password: password)
            noticeMessage = "同步组注册成功。请上传数据,然后在其他设备用下方 groupId/token 加入。"
        } catch { errorMessage = (error as? SyncError)?.errorDescription ?? error.localizedDescription }
        isRegistering = false
        password = ""; confirmPassword = ""
    }

    private func joinGroup() async {
        clearMessages()
        isJoining = true
        do {
            try await SyncClient.shared.joinGroup(existingGroupId: joinGroupId, accessToken: joinToken, password: joinPassword)
            noticeMessage = "已加入同步组,可以下载云端数据了。"
        } catch { errorMessage = (error as? SyncError)?.errorDescription ?? error.localizedDescription }
        isJoining = false
        joinGroupId = ""; joinToken = ""; joinPassword = ""
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

    private func resetConfig() {
        SyncClient.shared.groupId = nil
        SyncClient.shared.syncPassword = nil
        KeychainHelper.delete(account: KeychainHelper.Account.syncAccessToken)
        UserDefaults.standard.removeObject(forKey: "qieman.sync.accessToken")
        UserDefaults.standard.removeObject(forKey: "qieman.sync.deviceId")
        UserDefaults.standard.removeObject(forKey: "qieman.sync.lastRevision")
        noticeMessage = "已重置同步配置,请重新注册。"
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
