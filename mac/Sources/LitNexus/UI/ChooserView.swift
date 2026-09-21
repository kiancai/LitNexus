import SwiftUI
import AppKit

struct ChooserView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accentPalette) private var palette
    @State private var path: String = ChooserView.defaultPath().path

    static func defaultPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let docs = home.appendingPathComponent("Documents")
        var isDir: ObjCBool = false
        let base = FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDir) && isDir.boolValue ? docs : home
        return base.appendingPathComponent("LitNexusDB")
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let url = Bundle.main.url(forResource: "litnexus-mark", withExtension: "png"),
                   let ns = NSImage(contentsOf: url) {
                    Image(nsImage: ns)
                        .resizable().scaledToFit()
                        .frame(width: 88, height: 88)
                } else {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 49))
                        .foregroundStyle(palette.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, 10)
            Text("LitNexus").font(.system(size: 31, weight: .bold))
            .padding(.bottom, 20)

            Card {
                Text("项目文件夹").font(.system(size: 13)).foregroundStyle(Theme.muted)
                TextField("", text: $path)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Theme.panel2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button("浏览…") {
                        if let url = FolderPicker.pick(initial: URL(fileURLWithPath: path).deletingLastPathComponent()) {
                            path = url.path
                        }
                    }.buttonStyle(OutlineButtonStyle())
                    Button("打开 / 新建") {
                        app.openOrCreate(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                    }.buttonStyle(PrimaryButtonStyle())
                }

                let recent = WorkspaceStore.listRecent()
                if !recent.isEmpty {
                    Divider().overlay(Theme.line)
                    Text("最近打开").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    ForEach(recent.prefix(5), id: \.self) { r in
                        Button(r.path) { app.openOrCreate(r) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .frame(width: 440)
        }
        .padding(40)
        .sheet(item: $app.pendingInit) { pending in
            WorkspaceInitSheet(pending: pending)
        }
    }
}
