import SwiftUI
import AppKit

// 色彩为动态色：随当前外观（浅/深）自动解析。界面以低对比石墨为底，
// 青绿色只用于可交互的焦点与关键状态，避免默认系统蓝、侧栏渐变和多种强调色抢视线。

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

    /// 用同一色相生成随浅深外观变化的动态色。项目只保存 hue，其余参数由产品调色板控制。
    static func dynamic(
        lightHue: Double, lightSaturation: Double, lightBrightness: Double,
        darkHue: Double, darkSaturation: Double, darkBrightness: Double
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hue = isDark ? darkHue : lightHue
            let saturation = isDark ? darkSaturation : lightSaturation
            let brightness = isDark ? darkBrightness : lightBrightness
            return NSColor(
                calibratedHue: CGFloat(hue),
                saturation: CGFloat(saturation),
                brightness: CGFloat(brightness),
                alpha: 1)
        })
    }
}

// 安静的石墨工作台：侧栏、画布、内容层三层分明，但不把每一个区域都做成厚重的卡片。
enum Theme {
    static let bg = Color.dynamic(light: 0xF7F9F8, dark: 0x151716)
    static let canvas = Color.dynamic(light: 0xFBFCFB, dark: 0x171918)
    static let sidebar = Color.dynamic(light: 0xF0F3F1, dark: 0x1B1E1D)
    static let toolbar = Color.dynamic(light: 0xF5F7F5, dark: 0x202321)
    static let panel = Color.dynamic(light: 0xFFFFFF, dark: 0x1E2120)
    static let panel2 = Color.dynamic(light: 0xF4F7F5, dark: 0x262A28)
    static let control = Color.dynamic(light: 0xFFFFFF, dark: 0x222624)
    static let line = Color.dynamic(light: 0xDFE5E1, dark: 0x303633)
    // 外层内容面比输入框/分隔线更清晰：同一层级统一使用这组边界与投影。
    static let surfaceLine = Color.dynamic(light: 0xCBD5CF, dark: 0x414A45)
    static let surfaceShadow = Color.black.opacity(0.075)
    static let fg = Color.dynamic(light: 0x17201C, dark: 0xF1F5F3)
    static let muted = Color.dynamic(light: 0x6E7973, dark: 0x9AA59F)

    static let accent = Color.dynamic(light: 0x0B8E80, dark: 0x2DD4BF)
    static let accentSoft = Color.dynamic(light: 0xD8F0EC, dark: 0x153D38)
    static let accentLine = Color.dynamic(light: 0x9FD7D0, dark: 0x276C64)

    // 语义色只用于结果、警告与破坏性操作；常规交互一律使用 accent。
    static let green = Color.dynamic(light: 0x168765, dark: 0x38C996)
    static let amber = Color.dynamic(light: 0xC77A09, dark: 0xF0A52A)
    static let red = Color.dynamic(light: 0xD14646, dark: 0xF06A6A)
    static let cyan = Color.dynamic(light: 0x0B766B, dark: 0x5AD7C7)
    static let radius: CGFloat = 14
}

/// 工作区的强调色调色板。
///
/// `AppConfig` 仅持久化色相；此类型为浅色、深色、选中背景与边界生成一组可读的颜色，
/// 并通过 SwiftUI Environment 注入，避免让静态全局状态在项目切换时滞后。
struct AccentPalette {
    private let customHue: Double?

    init(hue: Double? = nil) {
        customHue = ThemeConfig.normalizedAccentHue(hue)
    }

    /// 项目主色。没有自定义色相时保持现有 LitNexus teal，不改变旧项目外观。
    var accent: Color {
        guard let hue = customHue else { return Theme.accent }
        return .dynamic(
            lightHue: hue, lightSaturation: 0.76, lightBrightness: 0.50,
            darkHue: hue, darkSaturation: 0.70, darkBrightness: 0.84)
    }

    /// 选中行、弱提示等低强调背景。
    var accentSoft: Color {
        guard let hue = customHue else { return Theme.accentSoft }
        return .dynamic(
            lightHue: hue, lightSaturation: 0.22, lightBrightness: 0.96,
            darkHue: hue, darkSaturation: 0.45, darkBrightness: 0.28)
    }

    /// 选中行与焦点控件的描边。
    var accentLine: Color {
        guard let hue = customHue else { return Theme.accentLine }
        return .dynamic(
            lightHue: hue, lightSaturation: 0.38, lightBrightness: 0.77,
            darkHue: hue, darkSaturation: 0.55, darkBrightness: 0.49)
    }

    /// 主按钮在浅、深模式下分别采用能与强调背景保持对比的前景色。
    var accentForeground: Color {
        Color.dynamic(light: 0xFFFFFF, dark: 0x10201D)
    }

    /// 给原生色盘的稳定编辑颜色；色盘只修改 hue，饱和度/亮度由调色板统一管理。
    static func editorColor(hue: Double?) -> Color {
        Color(hue: ThemeConfig.normalizedAccentHue(hue) ?? 0.48, saturation: 0.72, brightness: 0.75)
    }

    /// 从原生色盘返回值中取得色相。无色相的灰阶不会意外覆盖项目主题色。
    static func hue(from color: Color) -> Double? {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0.05 else {
            return nil
        }
        return ThemeConfig.normalizedAccentHue(Double(hue))
    }
}

private struct AccentPaletteKey: EnvironmentKey {
    static let defaultValue = AccentPalette()
}

extension EnvironmentValues {
    var accentPalette: AccentPalette {
        get { self[AccentPaletteKey.self] }
        set { self[AccentPaletteKey.self] = newValue }
    }
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
    /// AppKit controls, title bars, and Theme.dynamic colors must resolve from the
    /// same appearance as SwiftUI. `nil` delegates back to the user's system mode.
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

// 统一内容层：外层卡片始终使用同一条较清晰的边界与柔和投影；
// Toast、菜单和弹窗仍使用更高一级的悬浮感。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(fill: Theme.panel, cornerRadius: Theme.radius)
    }
}

private struct SurfaceStyle: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.stroke(Theme.surfaceLine, lineWidth: 1))
            .shadow(color: Theme.surfaceShadow.opacity(elevated ? 1 : 0.72),
                    radius: elevated ? 10 : 7,
                    y: elevated ? 3 : 2)
    }
}

extension View {
    /// 主要信息卡片与运行页面板统一使用。`elevated` 仅用于当前任务等一级关键面板。
    func surface(fill: Color = Theme.panel, cornerRadius: CGFloat = Theme.radius, elevated: Bool = false) -> some View {
        modifier(SurfaceStyle(fill: fill, cornerRadius: cornerRadius, elevated: elevated))
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

// 主操作按钮：唯一的交互强调色。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.accentPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.accentForeground)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(palette.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// 次操作按钮：保留存在感，但不与主操作争夺注意力。
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.accentPalette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(configuration.isPressed ? palette.accentSoft : Theme.control.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(configuration.isPressed ? palette.accentLine : Theme.line.opacity(0.9), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
