import AppKit

// 指向线上文档站的稳定链接。app 内引导入口用它打开网页指南。
enum Docs {
    static func retrieval(anchor: String) -> URL {
        URL(string: "https://kiancai.github.io/LitNexus/guide/retrieval/#\(anchor)")!
    }

    static func setup(anchor: String) -> URL {
        URL(string: "https://kiancai.github.io/LitNexus/guide/setup/#\(anchor)")!
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
