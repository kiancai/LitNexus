import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var app: AppState

    private var palette: AccentPalette {
        AccentPalette(hue: app.config.theme.accentHue)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch app.route {
            case .chooser: ChooserView()
            case .setup: SetupWizardView()
            case .main: MainView()
            }
        }
        .tint(palette.accent)
        .foregroundStyle(Theme.fg)
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                HStack(spacing: 9) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.fg)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.panel))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.line.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 12, y: 5)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { app.toast = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.toast)
        .environment(\.accentPalette, palette)
    }
}

// 通用：弹系统目录选择框。
enum FolderPicker {
    static func pick(initial: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let initial { panel.directoryURL = initial }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickCSV() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static let dbTypes: [UTType] = [UTType(filenameExtension: "db") ?? .data,
                                    UTType(filenameExtension: "sqlite") ?? .data, .data]

    static func pickDB() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = dbTypes
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveDB(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
