import SwiftUI
import AppKit

// 石墨黑 + 靓蓝（Linear 风）。颜色为「动态色」：随当前外观（浅/深）自动取对应值，
// 因此全项目的 Theme.xxx 调用无需关心明暗——切换外观时自动重算。

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }

    // 浅色 / 深色两套值；由系统按视图当前外观（受 preferredColorScheme 影响）解析。
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                           green: Double((hex >> 8) & 0xFF) / 255,
                           blue: Double(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

// 暖石墨（warm graphite / stone）+ 青绿（teal）强调。中性偏暖、更耐看；强调色克制单一。
enum Theme {
    static let bg = Color.dynamic(light: 0xFAF9F7, dark: 0x1A1816)
    static let panel = Color.dynamic(light: 0xFFFFFF, dark: 0x232120)
    static let panel2 = Color.dynamic(light: 0xF1EFEC, dark: 0x2C2A27)
    static let line = Color.dynamic(light: 0xE7E3DE, dark: 0x39342F)
    static let fg = Color.dynamic(light: 0x1C1917, dark: 0xF5F4F2)
    static let muted = Color.dynamic(light: 0x78716C, dark: 0xA8A29E)
    static let accent = Color.dynamic(light: 0x0D9488, dark: 0x2DD4BF)   // teal
    static let green = Color.dynamic(light: 0x059669, dark: 0x10B981)    // 纳入/成功，翡翠绿，与 teal 同family更和谐
    static let amber = Color.dynamic(light: 0xD97706, dark: 0xF59E0B)
    static let red = Color.dynamic(light: 0xDC2626, dark: 0xEF4444)
    static let cyan = Color.dynamic(light: 0x0F766E, dark: 0x5EEAD4)     // 日志分组标题，并入 teal 家族
    static let radius: CGFloat = 12
}

// 外观偏好：跟随系统 / 浅色 / 深色。存 UserDefaults，由 preferredColorScheme 落地。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// 统一的卡片容器样式。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.fg)
    }
}

// 整行可点的折叠区（替代 DisclosureGroup 只能点小箭头的问题）。
struct Expander<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    @ViewBuilder var content: Content

    init(_ title: String, expanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self._expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.fg)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusable(false)

            if expanded { content.padding(.top, 12) }
        }
    }
}

// 主操作按钮（靓蓝填充）。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// 次操作按钮（描边）。
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.panel2 : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
