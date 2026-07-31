import SwiftUI

struct SettingsPanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(AppPalette.appFont(.title2, weight: .semibold))
                    .foregroundStyle(AppPalette.brand)
                    .frame(width: 40, height: 40)
                    .background(
                        AppPalette.brandSoft,
                        in: RoundedRectangle(cornerRadius: AppPalette.controlRadius)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(AppPalette.appFont(.largeTitle, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(AppPalette.appFont(.subheadline))
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(AppPalette.card)

            Divider()
                .overlay(AppPalette.brand.opacity(panelBorderOpacity))

            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.surfaceVariant.opacity(0.28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppPalette.card,
            in: RoundedRectangle(cornerRadius: AppPalette.panelRadius)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.panelRadius)
                .stroke(AppPalette.hairline.opacity(panelBorderOpacity), lineWidth: 1)
        )
        .shadow(
            color: AppPalette.panelShadowColor,
            radius: AppPalette.panelShadowRadius + 2,
            y: AppPalette.panelShadowY + 1
        )
    }

    private var panelBorderOpacity: Double {
        colorSchemeContrast == .increased ? AppPalette.borderHeavy : AppPalette.borderMedium
    }
}

struct SettingsCardGroup<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

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
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: AppPalette.iconBoxRadius))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppPalette.appFont(.headline, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(subtitle)
                        .font(AppPalette.appFont(.caption))
                        .foregroundStyle(AppPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 13)
            .background(tint.opacity(0.075))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }

            Divider()
                .overlay(tint.opacity(groupDividerOpacity))

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppPalette.card)
        }
        .background(
            AppPalette.card,
            in: RoundedRectangle(cornerRadius: AppPalette.cardRadius)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppPalette.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AppPalette.cardRadius)
                .stroke(AppPalette.hairline.opacity(groupBorderOpacity), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.035), radius: 5, y: 2)
    }

    private var groupBorderOpacity: Double {
        colorSchemeContrast == .increased ? AppPalette.borderHeavy : AppPalette.borderMedium
    }

    private var groupDividerOpacity: Double {
        colorSchemeContrast == .increased ? 0.64 : 0.30
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
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.footnote))
                    .foregroundStyle(AppPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 12)

            Text(value)
                .font(AppPalette.appFont(.body, weight: .semibold, design: .rounded))
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
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.footnote))
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
                .font(AppPalette.appFont(.headline, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppPalette.appFont(.body, weight: .semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(detail)
                    .font(AppPalette.appFont(.footnote))
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
            .font(AppPalette.appFont(.footnote, weight: .semibold))
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
