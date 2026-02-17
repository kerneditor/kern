import AppKit

@MainActor
final class CodeBlockLanguagePillView: NSView {
    private let label = NSTextField(labelWithString: "")

    private let paddingX: CGFloat = 8
    // Slightly taller vertical padding to avoid the optical impression of the text
    // touching the pill edge in dark mode.
    private let paddingY: CGFloat = 7

    var stringValue: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(labelAccessibilityIdentifier: String) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.06).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        label.setAccessibilityIdentifier(labelAccessibilityIdentifier)
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .center
        label.maximumNumberOfLines = 1
        // The chrome should either fit or overflow; never show ellipsis for language tokens.
        label.lineBreakMode = .byClipping
        label.cell?.wraps = false
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byClipping
        label.cell?.truncatesLastVisibleLine = false
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func measuredLabelSize() -> NSSize {
        let text = label.stringValue
        guard !text.isEmpty else { return .zero }

        let font = label.font ?? NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let raw = (text as NSString).size(withAttributes: attrs)
        // NSTextField intrinsic size can be slightly wider than NSString metrics (kerning/cell metrics).
        // Use the larger value to avoid clipping.
        let intrinsic = label.intrinsicContentSize
        return NSSize(
            width: ceil(max(raw.width, intrinsic.width)),
            height: ceil(max(raw.height, intrinsic.height))
        )
    }

    override var intrinsicContentSize: NSSize {
        let s = measuredLabelSize()
        return NSSize(width: ceil(s.width + paddingX * 2), height: ceil(s.height + paddingY * 2))
    }

    override func layout() {
        super.layout()

        let labelSize = measuredLabelSize()
        let w = max(labelSize.width, bounds.width - paddingX * 2)
        let x = paddingX
        // NSTextField's text can appear slightly high relative to its frame; bias down by 1px.
        let y = floor((bounds.height - labelSize.height) / 2) + 1
        label.frame = NSRect(x: x, y: y, width: w, height: labelSize.height)
    }
}

@MainActor
final class CodeBlockChromeView: NSView {
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let languagePill: CodeBlockLanguagePillView

    var maxLanguageWidth: CGFloat? {
        didSet {
            if oldValue != maxLanguageWidth {
                needsLayout = true
                invalidateIntrinsicContentSize()
            }
        }
    }

    var showsLanguage: Bool {
        get { !languagePill.isHidden }
        set {
            languagePill.isHidden = !newValue
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    private let spacing: CGFloat = 8

    init(copyButtonAccessibilityIdentifier: String, languageLabelAccessibilityIdentifier: String) {
        languagePill = CodeBlockLanguagePillView(labelAccessibilityIdentifier: languageLabelAccessibilityIdentifier)
        super.init(frame: .zero)

        wantsLayer = false

        copyButton.setAccessibilityIdentifier(copyButtonAccessibilityIdentifier)
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        addSubview(languagePill)
        addSubview(copyButton)

        showsLanguage = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLanguage(_ lang: String?) {
        let trimmed = (lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            showsLanguage = false
            return
        }
        languagePill.stringValue = trimmed
        showsLanguage = true
    }

    func preferredSize() -> NSSize {
        let copySize = copyButton.intrinsicContentSize
        var width = copySize.width
        var height = copySize.height

        if showsLanguage {
            let pillSize = languagePill.intrinsicContentSize
            let clampedPillW: CGFloat
            if let maxLanguageWidth {
                clampedPillW = min(pillSize.width, max(0, maxLanguageWidth))
            } else {
                clampedPillW = pillSize.width
            }

            if clampedPillW >= 18 {
                width += spacing + clampedPillW
                height = max(height, pillSize.height)
            }
        }

        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func layout() {
        super.layout()

        let copySize = copyButton.intrinsicContentSize
        let totalH = bounds.height
        let copyY = floor((totalH - copySize.height) / 2)
        copyButton.frame = NSRect(
            x: bounds.width - copySize.width,
            y: copyY,
            width: copySize.width,
            height: copySize.height
        )

        guard showsLanguage else {
            languagePill.isHidden = true
            return
        }

        let desired = languagePill.intrinsicContentSize
        let pillW: CGFloat
        if let maxLanguageWidth {
            pillW = min(desired.width, max(0, maxLanguageWidth))
        } else {
            pillW = desired.width
        }

        if pillW < 18 {
            languagePill.isHidden = true
            return
        }

        languagePill.isHidden = false
        let pillY = floor((totalH - desired.height) / 2)
        languagePill.frame = NSRect(
            x: max(0, copyButton.frame.minX - spacing - pillW),
            y: pillY,
            width: pillW,
            height: desired.height
        )
    }
}
