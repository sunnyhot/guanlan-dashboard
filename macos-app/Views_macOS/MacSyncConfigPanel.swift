#if os(macOS)
import SwiftUI

// MARK: - macOS 数据同步配置面板
//
// 使用 SettingsPanel + SettingsCardGroup,与其他设置面板风格一致。

struct MacSyncConfigPanel: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var sync = SyncSettingsController()

    private let deviceName: String = {
        Host.current().localizedName ?? "Mac"
    }()

    var body: some View {
        SettingsPanel(title: "数据同步", subtitle: "跨设备同步持仓、配置与关注列表", icon: "icloud.and.arrow.up.and.down") {
            VStack(alignment: .leading, spacing: AppPalette.spaceXL) {
                serverCard
                if sync.groupID == nil {
                    registerCard
                    joinCard
                } else {
                    statusCard
                    actionsCard
                    undoCard
                }
            }
        }
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

    private var serverCard: some View {
        SettingsCardGroup(title: "同步服务", subtitle: "服务端地址", icon: "server.rack", tint: AppPalette.brand) {
            SettingsControlRow(title: "地址", detail: "同步服务器的 URL", icon: "link", tint: AppPalette.brand) {
                TextField("https://...", text: $sync.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            SettingsDivider()
            SettingsActionRow {
                Text(sync.noticeMessage)
                    .font(AppPalette.appFont(.caption))
                    .foregroundStyle(AppPalette.positive)
            }
        }
    }

    // MARK: - 注册

    private var registerCard: some View {
        SettingsCardGroup(title: "注册", subtitle: "创建同步组", icon: "person.badge.plus", tint: AppPalette.brand) {
            SettingsControlRow(title: "密码", detail: "用于加密同步数据,丢失无法恢复", icon: "lock", tint: AppPalette.brand) {
                SecureField("同步密码", text: $sync.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "确认", detail: "再次输入密码", icon: "lock.fill", tint: AppPalette.brand) {
                SecureField("确认密码", text: $sync.confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await sync.register() }
                } label: {
                    if sync.isRegistering { HStack { ProgressView(); Text("注册中…") } }
                    else { Text("注册同步组") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .disabled(sync.isRegistering || sync.password.isEmpty || sync.password != sync.confirmPassword)
            }
        }
    }

    // MARK: - 加入已有同步组

    private var joinCard: some View {
        SettingsCardGroup(title: "加入同步组", subtitle: "从其他设备加入", icon: "person.badge.plus", tint: AppPalette.info) {
            SettingsControlRow(title: "同步组 ID", detail: "第一台设备的 groupId", icon: "number", tint: AppPalette.info) {
                TextField("g_xxxxx", text: $sync.joinGroupID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "访问令牌", detail: "第一台设备的 accessToken", icon: "key", tint: AppPalette.info) {
                SecureField("tok_xxxxx", text: $sync.joinToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsControlRow(title: "同步密码", detail: "与第一台设备相同的密码", icon: "lock", tint: AppPalette.info) {
                SecureField("密码", text: $sync.joinPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsActionRow {
                Button {
                    Task { await sync.joinGroup() }
                } label: {
                    if sync.isJoining { HStack { ProgressView(); Text("加入中…") } }
                    else { Text("加入同步组") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.info)
                .disabled(sync.isJoining || sync.joinGroupID.isEmpty || sync.joinToken.isEmpty || sync.joinPassword.isEmpty)
            }
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        SettingsCardGroup(title: "同步状态", subtitle: "当前同步信息", icon: "checkmark.seal", tint: AppPalette.positive) {
            if let gid = sync.groupID {
                SettingsRow(title: "同步组", value: gid, detail: "组标识(给其他设备填)", icon: "number", tint: AppPalette.muted)
                SettingsDivider()
            }
            if let tok = sync.accessToken {
                SettingsRow(title: "访问令牌", value: tok, detail: "accessToken(给其他设备填)", icon: "key", tint: AppPalette.muted)
                SettingsDivider()
            }
            if let time = sync.lastSyncTime {
                SettingsRow(title: "上次同步", value: time.formatted(date: .abbreviated, time: .shortened), detail: "最近一次同步", icon: "clock", tint: AppPalette.muted)
                SettingsDivider()
            }
            SettingsRow(title: "版本", value: "rev \(sync.lastKnownRevision)", detail: "服务端版本号", icon: "tag", tint: AppPalette.muted)
            SettingsDivider()
            SettingsActionRow {
                if let gid = sync.groupID, let tok = sync.accessToken {
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
                    Task { await sync.upload(model: model, deviceName: deviceName) }
                } label: {
                    if sync.isUploading { HStack { ProgressView(); Text("上传中…") } }
                    else { Label("上传并覆盖云端", systemImage: "icloud.and.arrow.up") }
                }
                .buttonStyle(.appPrimary)
                .tint(AppPalette.brand)
                .disabled(sync.isUploading || sync.isDownloading)

                Button {
                    Task { await sync.download() }
                } label: {
                    if sync.isDownloading { HStack { ProgressView(); Text("下载中…") } }
                    else { Label("下载并覆盖本机", systemImage: "icloud.and.arrow.down") }
                }
                .buttonStyle(.appSecondary)
                .tint(AppPalette.brand)
                .disabled(sync.isUploading || sync.isDownloading)
            }
            if !sync.noticeMessage.isEmpty {
                SettingsDivider()
                SettingsActionRow {
                    Text(sync.noticeMessage)
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
                    sync.showsUndoConfirmation = true
                }
                .buttonStyle(.appDanger)
                .tint(AppPalette.warning)

                Button("重置同步配置", role: .destructive) {
                    sync.resetConfiguration()
                }
                .buttonStyle(.appDanger)
                .tint(AppPalette.danger)
            }
        }
    }

}
#endif
