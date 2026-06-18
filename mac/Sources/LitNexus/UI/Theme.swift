import SwiftUI

// 石墨黑 + 靓蓝（Linear 风），暗色为应用主基调。

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0A0A0B)
    static let panel = Color(hex: 0x18181B)
    static let panel2 = Color(hex: 0x1F1F23)
    static let line = Color(hex: 0x27272A)
    static let fg = Color(hex: 0xFAFAFA)
    static let muted = Color(hex: 0xA1A1AA)
    static let accent = Color(hex: 0x6366F1)
    static let green = Color(hex: 0x10B981)
    static let amber = Color(hex: 0xF59E0B)
    static let red = Color(hex: 0xEF4444)
    static let cyan = Color(hex: 0x22D3EE)
    static let radius: CGFloat = 12
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
        Text(text).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.fg)
    }
}

// 主操作按钮（靓蓝填充）。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
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
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.fg)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.panel2 : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
