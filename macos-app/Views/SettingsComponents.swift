import SwiftUI

struct SettingsPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let content: Content

    init(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 36, height: 36)
                    .background(
                        AppPalette.brandSoft,
                        in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(18)

            Divider()
                .overlay(AppPalette.hairline.opacity(AppPalette.strokeSubtle))

            content
                .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.panelBackground.opacity(AppPalette.bgSettings),
            in: RoundedRectangle(cornerRadius: AppPalette.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.strokeSubtle), lineWidth: 1)
        )
        .shadow(
            color: AppPalette.panelShadowColor,
            radius: AppPalette.panelShadowRadius,
            y: AppPalette.panelShadowY
        )
    }
}

struct SettingsCardGroup<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
                .overlay(AppPalette.hairline.opacity(AppPalette.borderFaint))

            content
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
        .background(
            AppPalette.cardStrong.opacity(0.62),
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.hairline.opacity(AppPalette.borderFaint), lineWidth: 1)
        )
    }
}

struct SettingsRow: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 54)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityHint(detail)
        }
        .frame(minHeight: 54)
    }
}

struct SettingsControlRow<Control: View>: View {
    let title: String
    let detail: String
    let icon: String
    let tint: Color
    let control: Control

    init(
        title: String,
        detail: String,
        icon: String,
        tint: Color,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.tint = tint
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            control
        }
        .frame(minHeight: 56)
    }
}

struct SettingsGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppPalette.muted)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

struct SettingsActionRow<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(.vertical, 13)
    }
}

struct SettingsDivider: View {
    var isInset = false

    var body: some View {
        Divider()
            .overlay(AppPalette.hairline.opacity(AppPalette.strokeSubtle))
            .padding(.leading, isInset ? 35 : 0)
    }
}
