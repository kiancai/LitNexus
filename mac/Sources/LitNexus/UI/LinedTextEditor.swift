import SwiftUI
import AppKit

// 带行号的等宽编辑器，用于「每行一条」的列表（期刊 / 检索式）。
// 文本照常换行；行号按逻辑行（\n 切分）编号，画在每个逻辑行的起始位置。
// 一条检索式太长换行成多视觉行时，行号保持不变——视觉上多行，逻辑上仍是一条。
struct LinedTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> EditorView {
        let editor = EditorView()
        editor.textView.delegate = context.coordinator
        context.coordinator.editor = editor
        editor.setText(text)
        return editor
    }

    func updateNSView(_ editor: EditorView, context: Context) {
        // SwiftUI 可以在同一 representable 身份上换一个 Binding；协调器应始终回写当前绑定。
        context.coordinator.text = $text
        editor.setText(text)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var editor: EditorView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            editor?.textDidChange()
        }
    }

    /// NSViewRepresentable 的初始 bounds 在 SwiftUI 中可以是 0。这个容器在自己的
    /// `layout()` 中读取已经落位的 NSScrollView/NSClipView 尺寸，再设置 TextKit 容器；
    /// 不依赖 GeometryReader，也不依赖 documentView 的 autoresizing mask。
    final class EditorView: NSView {
        static let gutterWidth: CGFloat = 34
        static let horizontalInset: CGFloat = 40
        static let verticalInset: CGFloat = 6

        let textView: NSTextView
        private let scrollView = NSScrollView()
        private let gutter = GutterView()
        private var observers: [NSObjectProtocol] = []
        private var updatingDocumentGeometry = false

        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame frameRect: NSRect) {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: NSSize(width: 1,
                                                              height: CGFloat.greatestFiniteMagnitude))
            textContainer.widthTracksTextView = false
            textContainer.heightTracksTextView = false
            textContainer.lineFragmentPadding = 0
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            textView = NSTextView(frame: .zero, textContainer: textContainer)

            super.init(frame: frameRect)
            configureViews()
        }

        convenience init() {
            self.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func configureViews() {
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.documentView = textView

            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.drawsBackground = false
            textView.backgroundColor = .clear
            textView.isEditable = true
            textView.isSelectable = true
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            textView.font = font
            textView.textColor = .litNexusForeground
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.litNexusForeground,
            ]
            textView.textContainerInset = NSSize(width: Self.horizontalInset,
                                                  height: Self.verticalInset)
            textView.textContainer?.lineBreakMode = .byWordWrapping

            gutter.textView = textView
            addSubview(scrollView)
            // Gutter 是容器的 overlay，而不是 NSScrollView 的额外子视图。这样
            // NSScrollView 仍然独占管理 contentView/documentView 的布局。
            addSubview(gutter)

            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.gutter.needsDisplay = true
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                // 垂直滚动条出现/消失会改变 clipView 宽度。下一次 layout 用新宽度重排。
                self?.needsLayout = true
                self?.gutter.needsDisplay = true
            })
        }

        override func layout() {
            super.layout()
            scrollView.frame = bounds
            gutter.frame = NSRect(x: 0, y: 0,
                                  width: Self.gutterWidth, height: bounds.height)
            updateDocumentGeometry()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            textView.needsDisplay = true
            gutter.needsDisplay = true
        }

        func setText(_ value: String) {
            guard textView.string != value else { return }
            textView.string = value
            updateDocumentGeometry()
        }

        func textDidChange() {
            updateDocumentGeometry()
            gutter.needsDisplay = true
        }

        private func updateDocumentGeometry() {
            guard !updatingDocumentGeometry,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            let clipSize = scrollView.contentView.bounds.size
            // 等 SwiftUI/AppKit 给这个 representable 首次分配真实尺寸；之后 layout() 会再进来。
            guard clipSize.width > 0, clipSize.height >= 0 else { return }

            updatingDocumentGeometry = true
            defer { updatingDocumentGeometry = false }

            let textWidth = max(1, floor(clipSize.width - Self.horizontalInset * 2))
            var textFrame = textView.frame
            textFrame.origin = .zero
            textFrame.size.width = clipSize.width
            textFrame.size.height = max(textFrame.height, clipSize.height)
            textView.frame = textFrame
            textContainer.size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            // 以 \n 结尾时，TextKit 会把可编辑的末尾空行放在 extra fragment 中，
            // 它不包含在 usedRect 里；高度也要把它算进去。
            let contentBottom = max(usedRect.maxY, layoutManager.extraLineFragmentRect.maxY)
            textFrame.size.height = max(clipSize.height,
                                        ceil(contentBottom) + Self.verticalInset * 2)
            textView.frame = textFrame
            gutter.needsDisplay = true
        }
    }

    final class GutterView: NSView {
        weak var textView: NSTextView?

        override var isFlipped: Bool { true }

        // 让点击穿过行号列，仍由下方的 NSTextView 接收焦点和插入点事件。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            // NSView 默认不会把绘制裁到自身 bounds；dirtyRect 可能来自父视图并且比
            // 34pt gutter 宽得多。只能填自身 bounds，不能填 dirtyRect，否则会盖住编辑器。
            NSColor.litNexusEditorGutter.setFill()
            NSBezierPath(rect: bounds).fill()
            NSColor.litNexusLine.withAlphaComponent(0.72).setFill()
            NSBezierPath(rect: NSRect(x: bounds.maxX - 1,
                                      y: bounds.minY,
                                      width: 1,
                                      height: bounds.height)).fill()

            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            layoutManager.ensureLayout(for: textContainer)

            let string = textView.string as NSString
            let clipY = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            let textOriginY = textView.textContainerOrigin.y
            let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: NSColor.litNexusMuted,
            ]
            let defaultLineHeight = layoutManager.defaultLineHeight(for: textView.font ?? numberFont)

            for (offset, characterLocation) in logicalLineStarts(in: string).enumerated() {
                let placement = linePlacement(
                    forCharacterAt: characterLocation,
                    stringLength: string.length,
                    layoutManager: layoutManager,
                    textContainer: textContainer,
                    defaultLineHeight: defaultLineHeight
                )
                let y = placement.y + textOriginY - clipY
                guard y <= bounds.maxY, y + placement.height >= bounds.minY else { continue }

                let number = "\(offset + 1)" as NSString
                let size = number.size(withAttributes: attributes)
                number.draw(
                    at: NSPoint(x: bounds.maxX - size.width - 6,
                                y: y + (placement.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
        }

        /// 只枚举 \n 后的字符位置，故视觉折行不会产生额外行号。
        private func logicalLineStarts(in string: NSString) -> [Int] {
            var starts = [0]
            var searchStart = 0
            while searchStart < string.length {
                let newline = string.range(
                    of: "\n",
                    options: [],
                    range: NSRange(location: searchStart,
                                   length: string.length - searchStart)
                )
                guard newline.location != NSNotFound else { break }
                starts.append(newline.location + 1)
                searchStart = newline.location + 1
            }
            return starts
        }

        /// NSLayoutManager 的 line fragment 给出逻辑行首实际落在哪一条视觉 fragment 上。
        /// 这正是长行换行后仍保持原逻辑行号的关键。
        private func linePlacement(
            forCharacterAt characterLocation: Int,
            stringLength: Int,
            layoutManager: NSLayoutManager,
            textContainer: NSTextContainer,
            defaultLineHeight: CGFloat
        ) -> (y: CGFloat, height: CGFloat) {
            guard layoutManager.numberOfGlyphs > 0 else {
                return (0, defaultLineHeight)
            }

            // 结尾是 \n 时，最后一个逻辑空行没有 glyph；它位于已使用区域的下一行。
            guard characterLocation < stringLength else {
                let extra = layoutManager.extraLineFragmentRect
                if !extra.isEmpty {
                    return (extra.minY, max(extra.height, defaultLineHeight))
                }
                return (layoutManager.usedRect(for: textContainer).maxY, defaultLineHeight)
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterLocation, length: 0),
                actualCharacterRange: nil
            )
            let glyphIndex = min(glyphRange.location, layoutManager.numberOfGlyphs - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: nil)
            return (lineRect.minY, max(lineRect.height, defaultLineHeight))
        }
    }
}

/// 首次设置与配置页共用的输入面，避免同一种检索列表出现两套样式。
struct LinedEditorField: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        LinedTextEditor(text: $text)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Theme.control)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private extension NSColor {
    static let litNexusForeground = dynamic(light: 0x17201C, dark: 0xF1F5F3)
    static let litNexusMuted = dynamic(light: 0x6E7973, dark: 0x9AA59F)
    // 行号列需要与白色编辑面和 panel2 外层卡片都保持清晰层级。
    // 与 Theme.editorGutter 保持一致；AppKit 绘制路径需要 NSColor 版本。
    static let litNexusEditorGutter = dynamic(light: 0xE4ECE8, dark: 0x1C2320)
    static let litNexusLine = dynamic(light: 0xDFE5E1, dark: 0x303633)

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
