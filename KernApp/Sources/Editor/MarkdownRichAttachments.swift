import AppKit
import Foundation

@MainActor
final class MarkdownImageAttachment: NSTextAttachment {
    enum LoadState {
        case loading
        case ready
        case failed
    }

    nonisolated static let remoteImageLoadingUserDefaultsKey = "nativeEditor.remoteImageLoadingEnabled"

    let altText: String
    let destination: String
    let sourceMarkdown: String
    let resolvedURL: URL?
    let allowsRemoteLoading: Bool

    private(set) var renderedImage: NSImage?
    private(set) var loadState: LoadState = .loading

    private var displayWidthLimit: CGFloat = 520
    private weak var hostView: NSView?
    private var isLoading = false

    nonisolated(unsafe) private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.name = "com.gradigit.kern.markdown-image-cache"
        // Bound image-memory growth across long editing sessions.
        cache.totalCostLimit = 128 * 1024 * 1024 // 128 MB
        cache.countLimit = 256
        return cache
    }()

    init(
        altText: String,
        destination: String,
        sourceMarkdown: String,
        baseURL: URL?,
        allowsRemoteLoading: Bool
    ) {
        self.altText = altText
        self.destination = destination
        self.sourceMarkdown = sourceMarkdown
        self.resolvedURL = MarkdownImageAttachment.resolveURL(destination: destination, baseURL: baseURL)
        self.allowsRemoteLoading = allowsRemoteLoading
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MarkdownImageAttachmentCell()
        loadImageIfNeeded()
    }

    required init?(coder: NSCoder) {
        self.altText = ""
        self.destination = ""
        self.sourceMarkdown = ""
        self.resolvedURL = nil
        self.allowsRemoteLoading = false
        super.init(coder: coder)
        self.attachmentCell = MarkdownImageAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let containerWidth = max(220, min(900, widthSource - 8))
        // Remote placeholders often include large text; cap their rendered width lower so they
        // stay visually balanced in-document.
        let maxVisualWidth: CGFloat = isRemoteURL ? 560 : 760
        let maxWidth = min(containerWidth, maxVisualWidth)
        displayWidthLimit = maxWidth

        if let image = renderedImage, image.size.width > 0, image.size.height > 0 {
            let maxHeight: CGFloat = 420
            let ratio = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
            let w = max(100, floor(image.size.width * ratio))
            let h = max(48, floor(image.size.height * ratio))
            let captionHeight: CGFloat = altText.isEmpty ? 0 : 18
            return NSRect(x: 0, y: -4, width: w, height: h + captionHeight + 8)
        }

        // Placeholder / error frame.
        let w = min(maxWidth, 360)
        let h: CGFloat = altText.isEmpty ? 84 : 98
        return NSRect(x: 0, y: -4, width: w, height: h)
    }

    var debugHasRenderedImage: Bool {
        renderedImage != nil
    }

    private var isRemoteURL: Bool {
        guard let resolvedURL, let scheme = resolvedURL.scheme?.lowercased() else { return false }
        if resolvedURL.isFileURL { return false }
        return scheme == "http" || scheme == "https"
    }

    private func loadImageIfNeeded() {
        guard !isLoading, renderedImage == nil else { return }
        guard let url = resolvedURL else {
            loadState = .failed
            return
        }

        // Respect remote-loading preference even if the URL was previously cached.
        // Disabled means no remote fetches and no reuse of remote cache entries.
        if isRemoteURL, !allowsRemoteLoading {
            loadState = .failed
            notifyDisplayUpdate()
            return
        }

        if let cached = Self.cache.object(forKey: url as NSURL) {
            renderedImage = cached
            loadState = .ready
            notifyDisplayUpdate()
            return
        }

        if url.isFileURL {
            isLoading = true
            loadState = .loading
            let fileURL = url
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: fileURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    if let image {
                        let cost = Self.estimatedImageCostBytes(image)
                        Self.cache.setObject(image, forKey: fileURL as NSURL, cost: cost)
                        self.renderedImage = image
                        self.loadState = .ready
                    } else {
                        self.loadState = .failed
                    }
                    self.notifyDisplayUpdate()
                }
            }
            return
        }

        isLoading = true
        loadState = .loading

        let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        URLSession.shared.dataTask(with: req) { data, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false

                guard error == nil, let data, let image = NSImage(data: data) else {
                    self.loadState = .failed
                    self.notifyDisplayUpdate()
                    return
                }

                let cost = Self.estimatedImageCostBytes(image)
                Self.cache.setObject(image, forKey: url as NSURL, cost: cost)
                self.renderedImage = image
                self.loadState = .ready
                self.notifyDisplayUpdate()
            }
        }.resume()
    }

    @MainActor
    private func notifyDisplayUpdate() {
        guard let hostView else { return }
        hostView.needsDisplay = true
        if let textView = hostView as? NSTextView {
            guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
            let visibleRectInContainer = textView.visibleRect.offsetBy(
                dx: -textView.textContainerOrigin.x,
                dy: -textView.textContainerOrigin.y
            )
            let visibleGlyphRange = lm.glyphRange(forBoundingRect: visibleRectInContainer, in: tc)
            lm.invalidateDisplay(forGlyphRange: visibleGlyphRange)
        }
    }

    fileprivate func didDraw(in view: NSView?) {
        if let view {
            hostView = view
        }
    }

    private static func resolveURL(destination: String, baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }

        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        let path = NSString(string: unescaped).expandingTildeInPath

        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        if let baseURL {
            let baseDir: URL
            if baseURL.hasDirectoryPath {
                baseDir = baseURL
            } else {
                baseDir = baseURL.deletingLastPathComponent()
            }
            return baseDir.appendingPathComponent(path).standardizedFileURL
        }

        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Estimate decoded RGBA memory footprint so NSCache can evict by memory pressure.
    private static func estimatedImageCostBytes(_ image: NSImage) -> Int {
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let rep = bitmapReps.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            let bytesPerPixel = max(4, rep.bitsPerPixel / 8)
            let rowBytes = max(1, rep.bytesPerRow > 0 ? rep.bytesPerRow : rep.pixelsWide * bytesPerPixel)
            let total = Int64(rowBytes) * Int64(max(1, rep.pixelsHigh))
            return Int(max(1, min(total, Int64(Int.max))))
        }

        // Fallback when bitmap metadata is unavailable.
        let width = Int(max(1, ceil(image.size.width)))
        let height = Int(max(1, ceil(image.size.height)))
        let total = Int64(width) * Int64(height) * 4
        return Int(max(1, min(total, Int64(Int.max))))
    }
}

private final class MarkdownImageAttachmentCell: NSTextAttachmentCell {
    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 96)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let owner = attachment as? MarkdownImageAttachment else { return }
        owner.didDraw(in: controlView)

        let frame = cellFrame.integral
        let background = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        background.lineWidth = 1
        background.stroke()

        switch owner.loadState {
        case .ready:
            drawLoadedImage(owner: owner, in: frame)
        case .loading:
            drawPlaceholder(
                in: frame,
                title: "Loading image",
                subtitle: owner.altText.isEmpty ? owner.destination : owner.altText
            )
        case .failed:
            drawPlaceholder(
                in: frame,
                title: "Image unavailable",
                subtitle: owner.altText.isEmpty ? owner.destination : owner.altText
            )
        }
    }

    private func drawLoadedImage(owner: MarkdownImageAttachment, in frame: NSRect) {
        guard let image = owner.renderedImage, image.size.width > 0, image.size.height > 0 else {
            drawPlaceholder(in: frame, title: "Image unavailable", subtitle: owner.altText)
            return
        }

        let captionHeight: CGFloat = owner.altText.isEmpty ? 0 : 18
        let imageRect = NSRect(
            x: frame.minX + 4,
            y: frame.minY + 4 + captionHeight,
            width: frame.width - 8,
            height: frame.height - 8 - captionHeight
        )
        let fittedImageRect = aspectFitRect(for: image.size, in: imageRect)
        image.draw(in: fittedImageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        if !owner.altText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let textRect = NSRect(
                x: frame.minX + 8,
                y: frame.minY + 4,
                width: frame.width - 16,
                height: captionHeight - 2
            )
            (owner.altText as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    private func drawPlaceholder(in frame: NSRect, title: String, subtitle: String) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let clippedSubtitle = subtitle.isEmpty ? "" : subtitle
        let titleRect = NSRect(x: frame.minX + 10, y: frame.midY - 4, width: frame.width - 20, height: 18)
        let subtitleRect = NSRect(x: frame.minX + 10, y: frame.midY - 20, width: frame.width - 20, height: 16)

        (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
        if !clippedSubtitle.isEmpty {
            (clippedSubtitle as NSString).draw(in: subtitleRect, withAttributes: subtitleAttrs)
        }
    }

    private func aspectFitRect(for imageSize: CGSize, in targetRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, targetRect.width > 0, targetRect.height > 0 else {
            return targetRect
        }
        let scale = min(targetRect.width / imageSize.width, targetRect.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale
        return NSRect(
            x: targetRect.midX - (fittedWidth / 2),
            y: targetRect.midY - (fittedHeight / 2),
            width: fittedWidth,
            height: fittedHeight
        ).integral
    }
}

@MainActor
final class MarkdownMathBlockAttachment: NSTextAttachment {
    let sourceMarkdown: String
    let displayText: String

    private let lineHeight: CGFloat = 26
    private var displayWidth: CGFloat = 420

    init(sourceMarkdown: String) {
        self.sourceMarkdown = sourceMarkdown
        self.displayText = MathTextRenderer.renderBlockMath(from: sourceMarkdown)
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MarkdownMathBlockAttachmentCell()
    }

    required init?(coder: NSCoder) {
        self.sourceMarkdown = ""
        self.displayText = ""
        super.init(coder: coder)
        self.attachmentCell = MarkdownMathBlockAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let maxWidth = max(220, min(880, widthSource - 8))
        displayWidth = maxWidth
        let lineCount = max(1, displayText.split(separator: "\n", omittingEmptySubsequences: false).count)
        let h = CGFloat(lineCount) * lineHeight + 18
        return NSRect(x: 0, y: -4, width: maxWidth, height: h)
    }
}

private final class MarkdownMathBlockAttachmentCell: NSTextAttachmentCell {
    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 56)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let owner = attachment as? MarkdownMathBlockAttachment else { return }
        let frame = cellFrame.integral

        let bg = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        ("MATH" as NSString).draw(
            in: NSRect(x: frame.maxX - 56, y: frame.maxY - 18, width: 44, height: 12),
            withAttributes: badgeAttrs
        )

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let textAttrs = attrs.merging([.paragraphStyle: para]) { _, rhs in rhs }
        let textRect = NSRect(
            x: frame.minX + 10,
            y: frame.minY + 8,
            width: frame.width - 20,
            height: frame.height - 24
        )
        (owner.displayText as NSString).draw(in: textRect, withAttributes: textAttrs)
    }
}

@MainActor
final class MarkdownMermaidAttachment: NSTextAttachment {
    struct Node {
        let id: String
        let label: String
    }

    struct Edge {
        let from: String
        let to: String
        let label: String?
    }

    fileprivate struct ASCIILayout {
        let lines: [String]
        let size: CGSize
        let lineHeight: CGFloat
        let font: NSFont
    }

    let sourceMarkdown: String
    nonisolated fileprivate let requestedRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode
    nonisolated fileprivate let effectiveRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode
    nonisolated fileprivate let kind: MermaidMiniParser.DiagramKind
    nonisolated let nodes: [Node]
    nonisolated let edges: [Edge]
    nonisolated(unsafe) private var cachedLayoutWidthKey: Int?
    nonisolated(unsafe) private var cachedLayoutResult: MermaidMiniLayout.Result?
    nonisolated(unsafe) private var cachedASCIIWidthKey: Int?
    nonisolated(unsafe) private var cachedASCIILayout: ASCIILayout?

    init(
        sourceMarkdown: String,
        requestedRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode = .rich
    ) {
        self.sourceMarkdown = sourceMarkdown
        let parsed = MermaidMiniParser.parse(sourceMarkdown: sourceMarkdown)
        self.kind = parsed.kind
        self.nodes = parsed.nodes
        self.edges = parsed.edges
        self.requestedRenderMode = requestedRenderMode
        self.effectiveRenderMode = MarkdownMermaidAttachment.resolveRenderMode(
            requested: requestedRenderMode,
            kind: parsed.kind,
            nodes: parsed.nodes,
            edges: parsed.edges
        )
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MarkdownMermaidAttachmentCell()
    }

    required init?(coder: NSCoder) {
        self.sourceMarkdown = ""
        self.requestedRenderMode = .rich
        self.effectiveRenderMode = .rich
        self.kind = .generic
        self.nodes = []
        self.edges = []
        super.init(coder: coder)
        self.attachmentCell = MarkdownMermaidAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let availableWidth = max(280, min(920, widthSource - 8))
        let contentWidth = max(220, availableWidth - MermaidChromeMetrics.horizontalPadding * 2)
        let width: CGFloat
        let height: CGFloat
        if effectiveRenderMode == .ascii {
            let layout = asciiLayout(maxContentWidth: contentWidth)
            width = min(availableWidth, layout.size.width + MermaidChromeMetrics.horizontalPadding * 2)
            height = max(
                MermaidChromeMetrics.minimumHeightASCII,
                layout.size.height + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
            )
        } else {
            let layout = layoutResult(maxContentWidth: contentWidth)
            width = min(availableWidth, layout.size.width + MermaidChromeMetrics.horizontalPadding * 2)
            height = max(
                MermaidChromeMetrics.minimumHeight,
                layout.size.height + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
            )
        }
        return NSRect(x: 0, y: -4, width: width, height: height)
    }

    nonisolated fileprivate func layoutResult(maxContentWidth: CGFloat) -> MermaidMiniLayout.Result {
        // Bucket widths to reduce cache churn during TextKit's iterative line-fragment probing.
        let widthBucket: CGFloat = 16
        let widthKey = max(1, Int((maxContentWidth / widthBucket).rounded()) * Int(widthBucket))
        if cachedLayoutWidthKey == widthKey, let cachedLayoutResult {
            return cachedLayoutResult
        }

        let layout = MermaidMiniLayout.layout(
            kind: kind,
            nodes: nodes,
            edges: edges,
            maxContentWidth: CGFloat(widthKey)
        )
        cachedLayoutWidthKey = widthKey
        cachedLayoutResult = layout
        return layout
    }

    nonisolated fileprivate func asciiLayout(maxContentWidth: CGFloat) -> ASCIILayout {
        let widthBucket: CGFloat = 16
        let widthKey = max(1, Int((maxContentWidth / widthBucket).rounded()) * Int(widthBucket))
        if cachedASCIIWidthKey == widthKey, let cachedASCIILayout {
            return cachedASCIILayout
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let charWidth = max(5.8, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let maxChars = max(24, Int((CGFloat(widthKey) - 16) / charWidth))

        let baseLines = MermaidASCIIFormatter.lines(kind: kind, nodes: nodes, edges: edges)
        let wrappedLines = MermaidASCIIFormatter.wrap(lines: baseLines, maxColumns: maxChars)
        let maxLineChars = max(maxChars, wrappedLines.map(\.count).max() ?? maxChars)
        let lineHeight = max(13, ceil(NSLayoutManager().defaultLineHeight(for: font)))
        let textHeight = CGFloat(wrappedLines.count) * lineHeight
        let maxTextWidth = CGFloat(maxLineChars) * charWidth
        let size = CGSize(
            width: min(CGFloat(widthKey), maxTextWidth + 16),
            height: max(72, textHeight + 12)
        )
        let layout = ASCIILayout(lines: wrappedLines, size: size, lineHeight: lineHeight, font: font)
        cachedASCIIWidthKey = widthKey
        cachedASCIILayout = layout
        return layout
    }

    nonisolated fileprivate static func resolveRenderMode(
        requested: NativeMarkdownCodec.Options.MermaidRenderMode,
        kind: MermaidMiniParser.DiagramKind,
        nodes: [Node],
        edges: [Edge]
    ) -> NativeMarkdownCodec.Options.MermaidRenderMode {
        guard requested == .auto else { return requested }
        let score = mermaidComplexityScore(kind: kind, nodes: nodes, edges: edges)
        let threshold = mermaidAutoASCIIThreshold()
        return score >= threshold ? .ascii : .rich
    }

    nonisolated fileprivate static func mermaidComplexityScore(
        kind: MermaidMiniParser.DiagramKind,
        nodes: [Node],
        edges: [Edge]
    ) -> Int {
        let kindWeight: Int
        switch kind {
        case .flowchart: kindWeight = 10
        case .sequence: kindWeight = 16
        case .generic: kindWeight = 12
        }
        let nodeLabelChars = nodes.reduce(0) { $0 + $1.label.count }
        let edgeLabelChars = edges.reduce(0) { partial, edge in
            partial + (edge.label?.count ?? 0)
        }
        let topologyScore = nodes.count * 5 + edges.count * 7
        let labelScore = min(220, (nodeLabelChars + edgeLabelChars) / 6)
        return kindWeight + topologyScore + labelScore
    }

    nonisolated fileprivate static func mermaidAutoASCIIThreshold() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_NATIVE_MERMAID_AUTO_ASCII_THRESHOLD"], let parsed = Int(raw) {
            return max(30, parsed)
        }
        if let raw = UserDefaults.standard.object(forKey: "nativeEditor.mermaidAutoAsciiThreshold") as? NSNumber {
            return max(30, raw.intValue)
        }
        if let raw = UserDefaults.standard.string(forKey: "nativeEditor.mermaidAutoAsciiThreshold"),
           let parsed = Int(raw) {
            return max(30, parsed)
        }
        return 100
    }

    var debugNodeCount: Int { nodes.count }
    var debugEdgeCount: Int { edges.count }
    var debugNodeHeightsForTesting: [CGFloat] {
        Array(layoutResult(maxContentWidth: 560).nodeFrames.values.map(\.height))
    }
    var debugShowsEdgeLabelsForTesting: Bool { kind != .sequence }
    var debugEffectiveRenderModeForTesting: NativeMarkdownCodec.Options.MermaidRenderMode { effectiveRenderMode }
}

private enum MermaidChromeMetrics {
    static let horizontalPadding: CGFloat = 12
    static let topChromeHeight: CGFloat = 26
    static let bottomPadding: CGFloat = 10
    static let minimumHeight: CGFloat = 170
    static let minimumHeightASCII: CGFloat = 128
}

private final class MarkdownMermaidAttachmentCell: NSTextAttachmentCell {
    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 220)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let owner = attachment as? MarkdownMermaidAttachment else { return }
        let frame = cellFrame.integral

        let bg = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let badgeText = owner.effectiveRenderMode == .ascii ? "MERMAID ASCII" : "MERMAID"
        drawBadge(text: badgeText, in: frame)

        let contentRect = NSRect(
            x: frame.minX + MermaidChromeMetrics.horizontalPadding,
            y: frame.minY + MermaidChromeMetrics.bottomPadding,
            width: frame.width - MermaidChromeMetrics.horizontalPadding * 2,
            height: frame.height - MermaidChromeMetrics.topChromeHeight - MermaidChromeMetrics.bottomPadding
        ).integral
        guard contentRect.width > 10, contentRect.height > 10 else { return }

        if owner.effectiveRenderMode == .ascii {
            drawASCII(owner: owner, contentRect: contentRect)
            return
        }

        let layout = owner.layoutResult(maxContentWidth: contentRect.width)
        let scale = min(
            1,
            contentRect.width / max(layout.size.width, 1),
            contentRect.height / max(layout.size.height, 1)
        )
        let drawWidth = layout.size.width * scale
        let drawHeight = layout.size.height * scale
        let origin = CGPoint(
            x: contentRect.minX + (contentRect.width - drawWidth) / 2,
            y: contentRect.maxY - drawHeight
        )

        let canvasRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: drawWidth,
            height: drawHeight
        )
        let canvas = NSBezierPath(roundedRect: canvasRect, xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.withAlphaComponent(0.72).setFill()
        canvas.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        canvas.lineWidth = 1
        canvas.stroke()

        drawEdges(layout: layout, origin: origin, scale: scale, showLabels: owner.kind != .sequence)
        drawNodes(layout: layout, origin: origin, scale: scale)
    }

    private func drawASCII(owner: MarkdownMermaidAttachment, contentRect: NSRect) {
        let layout = owner.asciiLayout(maxContentWidth: contentRect.width)

        let canvasRect = NSRect(
            x: contentRect.minX,
            y: contentRect.maxY - layout.size.height,
            width: min(contentRect.width, layout.size.width),
            height: min(contentRect.height, layout.size.height)
        ).integral

        let canvas = NSBezierPath(roundedRect: canvasRect, xRadius: 8, yRadius: 8)
        NSColor.textBackgroundColor.withAlphaComponent(0.72).setFill()
        canvas.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        canvas.lineWidth = 1
        canvas.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let leftInset: CGFloat = 8
        let topInset: CGFloat = 6
        let maxVisibleLines = max(1, Int((canvasRect.height - topInset * 2) / layout.lineHeight))
        let visibleLines = layout.lines.prefix(maxVisibleLines)
        for (index, line) in visibleLines.enumerated() {
            let y = canvasRect.maxY - topInset - CGFloat(index + 1) * layout.lineHeight
            let lineRect = NSRect(
                x: canvasRect.minX + leftInset,
                y: y,
                width: canvasRect.width - leftInset * 2,
                height: layout.lineHeight
            )
            (line as NSString).draw(in: lineRect, withAttributes: attrs)
        }
    }

    private func drawBadge(text: String, in frame: NSRect) {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        let pillRect = NSRect(
            x: frame.maxX - textSize.width - 18,
            y: frame.maxY - 20,
            width: textSize.width + 10,
            height: 14
        ).integral
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
        pill.fill()
        (text as NSString).draw(
            in: NSRect(
                x: pillRect.midX - textSize.width / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            ).integral,
            withAttributes: textAttrs
        )
    }

    private func drawEdges(layout: MermaidMiniLayout.Result, origin: CGPoint, scale: CGFloat, showLabels: Bool) {
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()

        for edge in layout.edges {
            guard let from = layout.nodeFrames[edge.from], let to = layout.nodeFrames[edge.to] else { continue }
            let horizontal = abs(to.midX - from.midX) >= abs(to.midY - from.midY)
            let startRaw = CGPoint(
                x: horizontal ? (to.midX >= from.midX ? from.maxX - 2 : from.minX + 2) : from.midX,
                y: horizontal ? from.midY : (to.midY >= from.midY ? from.maxY - 2 : from.minY + 2)
            )
            let endRaw = CGPoint(
                x: horizontal ? (to.midX >= from.midX ? to.minX + 2 : to.maxX - 2) : to.midX,
                y: horizontal ? to.midY : (to.midY >= from.midY ? to.minY + 2 : to.maxY - 2)
            )
            let start = CGPoint(x: origin.x + startRaw.x * scale, y: origin.y + startRaw.y * scale)
            let end = CGPoint(x: origin.x + endRaw.x * scale, y: origin.y + endRaw.y * scale)

            let path = NSBezierPath()
            path.move(to: start)
            if abs(start.y - end.y) > 6 {
                let c1 = CGPoint(x: start.x + (end.x - start.x) * 0.45, y: start.y)
                let c2 = CGPoint(x: start.x + (end.x - start.x) * 0.55, y: end.y)
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            } else {
                path.line(to: end)
            }
            path.lineWidth = max(1, 1.5 * scale)
            path.stroke()

            // Arrow head.
            let arrowSize = max(4.5, 5.5 * scale)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrow = NSBezierPath()
            arrow.move(to: end)
            arrow.line(to: CGPoint(
                x: end.x - arrowSize * cos(angle - .pi / 7),
                y: end.y - arrowSize * sin(angle - .pi / 7)
            ))
            arrow.move(to: end)
            arrow.line(to: CGPoint(
                x: end.x - arrowSize * cos(angle + .pi / 7),
                y: end.y - arrowSize * sin(angle + .pi / 7)
            ))
            arrow.lineWidth = max(1, 1.2 * scale)
            arrow.stroke()

            if showLabels, let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                drawEdgeLabel(label, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            }
        }
    }

    private func drawNodes(layout: MermaidMiniLayout.Result, origin: CGPoint, scale: CGFloat) {
        for node in layout.nodes {
            guard let rect = layout.nodeFrames[node.id] else { continue }
            let drawRect = NSRect(
                x: origin.x + rect.origin.x * scale,
                y: origin.y + rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )

            let nodePath = NSBezierPath(roundedRect: drawRect, xRadius: max(5, 7 * scale), yRadius: max(5, 7 * scale))
            NSColor(white: 1, alpha: 0.95).setFill()
            nodePath.fill()
            NSColor(white: 0, alpha: 0.22).setStroke()
            nodePath.lineWidth = max(1, 1 * scale)
            nodePath.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let textFont = NSFont.systemFont(ofSize: max(10, 12 * scale), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1.0),
                .paragraphStyle: paragraph,
            ]
            let insetRect = drawRect.insetBy(dx: max(6, 8 * scale), dy: max(4, 6 * scale))
            let measured = (node.label as NSString).boundingRect(
                with: CGSize(width: insetRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            let textHeight = max(1, min(insetRect.height, ceil(measured.height)))
            let centeredRect = NSRect(
                x: insetRect.minX,
                y: insetRect.midY - textHeight / 2,
                width: insetRect.width,
                height: textHeight
            )
            (node.label as NSString).draw(in: centeredRect, withAttributes: attrs)
        }
    }

    private func drawEdgeLabel(_ label: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let normalized = String(label.prefix(24))
        let size = (normalized as NSString).size(withAttributes: attrs)
        let pillRect = NSRect(
            x: center.x - (size.width + 8) / 2,
            y: center.y - (size.height + 4) / 2,
            width: size.width + 8,
            height: size.height + 4
        ).integral
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill()
        pill.fill()
        (normalized as NSString).draw(
            in: NSRect(
                x: pillRect.midX - size.width / 2,
                y: pillRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ).integral,
            withAttributes: attrs
        )
    }
}

enum MathTextRenderer {
    static func renderInlineMath(_ expression: String) -> String {
        normalize(expression)
    }

    static func renderBlockMath(from sourceMarkdown: String) -> String {
        let lines = sourceMarkdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body = lines
        if !body.isEmpty, body.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "$$" {
            body.removeFirst()
        }
        if !body.isEmpty, body.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "$$" {
            body.removeLast()
        }
        return normalize(body.joined(separator: "\n"))
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw
        let replacements: [(String, String)] = [
            (#"\\alpha"#, "alpha"),
            (#"\\beta"#, "beta"),
            (#"\\gamma"#, "gamma"),
            (#"\\delta"#, "delta"),
            (#"\\theta"#, "theta"),
            (#"\\lambda"#, "lambda"),
            (#"\\mu"#, "mu"),
            (#"\\pi"#, "pi"),
            (#"\\sigma"#, "sigma"),
            (#"\\phi"#, "phi"),
            (#"\\omega"#, "omega"),
            (#"\\int"#, "integral"),
            (#"\\sum"#, "sum"),
            (#"\\prod"#, "prod"),
            (#"\\cdot"#, "·"),
            (#"\\times"#, "x"),
            (#"\\leq"#, "<="),
            (#"\\geq"#, ">="),
            (#"\\neq"#, "!="),
            (#"\\to"#, "->"),
            (#"\\rightarrow"#, "->"),
            (#"\\left"#, ""),
            (#"\\right"#, ""),
            (#"\\,"#, " "),
        ]
        for (pattern, replacement) in replacements {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        s = collapseSuperscriptsAndSubscripts(in: s)
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")
        s = s.replacingOccurrences(of: "\\", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSuperscriptsAndSubscripts(in text: String) -> String {
        var s = text

        let superscriptMap: [Character: Character] = [
            "0": "0", "1": "1", "2": "2", "3": "3", "4": "4",
            "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
            "+": "+", "-": "-", "=": "=",
        ]
        let subscriptMap: [Character: Character] = [
            "0": "0", "1": "1", "2": "2", "3": "3", "4": "4",
            "5": "5", "6": "6", "7": "7", "8": "8", "9": "9",
            "+": "+", "-": "-", "=": "=",
        ]

        // Keep rendering deterministic without introducing non-ASCII glyph surprises in tests.
        func convertGroup(_ group: String, with map: [Character: Character]) -> String {
            String(group.map { map[$0] ?? $0 })
        }

        if let regex = try? NSRegularExpression(pattern: #"\^\{([^}]+)\}"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches where m.numberOfRanges > 1 {
                let whole = m.range(at: 0)
                let inner = ns.substring(with: m.range(at: 1))
                let converted = convertGroup(inner, with: superscriptMap)
                s = (s as NSString).replacingCharacters(in: whole, with: "^\(converted)")
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"_\{([^}]+)\}"#) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches where m.numberOfRanges > 1 {
                let whole = m.range(at: 0)
                let inner = ns.substring(with: m.range(at: 1))
                let converted = convertGroup(inner, with: subscriptMap)
                s = (s as NSString).replacingCharacters(in: whole, with: "_\(converted)")
            }
        }
        return s
    }
}

private enum MermaidMiniParser {
    enum DiagramKind {
        case flowchart
        case sequence
        case generic
    }

    struct ParseResult {
        let kind: DiagramKind
        let nodes: [MarkdownMermaidAttachment.Node]
        let edges: [MarkdownMermaidAttachment.Edge]
    }

    private struct MutableNode {
        var id: String
        var label: String
    }

    static func parse(sourceMarkdown: String) -> ParseResult {
        let body = extractBody(sourceMarkdown)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmedLower = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var nodeOrder: [String] = []
        var nodes: [String: MutableNode] = [:]
        var edges: [MarkdownMermaidAttachment.Edge] = []
        var kind: DiagramKind = .generic
        if trimmedLower.contains(where: { $0.hasPrefix("sequencediagram") }) {
            kind = .sequence
        } else if trimmedLower.contains(where: { $0.hasPrefix("flowchart") || $0.hasPrefix("graph") }) {
            kind = .flowchart
        }

        func ensureNode(id: String, label: String? = nil) {
            guard !id.isEmpty else { return }
            let cleanLabel = label.map(normalizeLabel)
            if nodes[id] == nil {
                nodes[id] = MutableNode(id: id, label: cleanLabel ?? id)
                nodeOrder.append(id)
            } else if let cleanLabel, !cleanLabel.isEmpty, nodes[id]?.label == id {
                nodes[id]?.label = cleanLabel
            }
        }

        let nodePatterns = [
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\[\s*\"?([^\]]+?)\"?\s*\]"#,
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\(([^\)]+)\)"#,
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\{([^\}]+)\}"#,
        ]
        let flowEdgePattern = #"([A-Za-z][A-Za-z0-9_-]*)\s*--[^>]*>\s*(?:\|([^|]*)\|\s*)?([A-Za-z][A-Za-z0-9_-]*)"#
        let sequenceParticipantPattern = #"^\s*participant\s+([A-Za-z][A-Za-z0-9_-]*)(?:\s+as\s+(.+))?\s*$"#
        let sequenceEdgePattern = #"^\s*([A-Za-z][A-Za-z0-9_-]*)\s*[-.]+[<>]{1,2}\s*([A-Za-z][A-Za-z0-9_-]*)\s*:?\s*(.*)$"#

        for line in lines {
            if kind == .sequence {
                if let participant = regexCaptures(pattern: sequenceParticipantPattern, in: line).first,
                   participant.count >= 2
                {
                    ensureNode(id: participant[0], label: participant[1].isEmpty ? participant[0] : participant[1])
                }
                if let sequenceEdge = regexCaptures(pattern: sequenceEdgePattern, in: line).first,
                   sequenceEdge.count >= 3
                {
                    let from = sequenceEdge[0]
                    let to = sequenceEdge[1]
                    let label = normalizeLabel(sequenceEdge[2])
                    ensureNode(id: from)
                    ensureNode(id: to)
                    if edges.count < 40 {
                        edges.append(.init(from: from, to: to, label: label.isEmpty ? nil : label))
                    }
                }
            }

            for pattern in nodePatterns {
                for match in regexCaptures(pattern: pattern, in: line) where match.count >= 2 {
                    ensureNode(id: match[0], label: match[1])
                }
            }

            for match in regexCaptures(pattern: flowEdgePattern, in: line) where match.count >= 3 {
                let from = match[0]
                let label = normalizeLabel(match[1])
                let to = match[2]
                ensureNode(id: from)
                ensureNode(id: to)
                if edges.count < 40 {
                    edges.append(.init(from: from, to: to, label: label.isEmpty ? nil : label))
                }
            }
        }

        // Fallback for non-flowchart mermaid content.
        if nodeOrder.isEmpty {
            let fallback = Array(lines.prefix(6))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    let lower = line.lowercased()
                    guard !line.isEmpty else { return false }
                    guard !lower.hasPrefix("flowchart"), !lower.hasPrefix("graph"), !lower.hasPrefix("sequencediagram") else {
                        return false
                    }
                    return true
                }
            for (i, line) in fallback.enumerated() where i < 6 {
                let id = "L\(i + 1)"
                ensureNode(id: id, label: normalizeLabel(line))
                if i > 0 {
                    edges.append(.init(from: "L\(i)", to: id, label: nil))
                }
            }
        }

        let finalNodes = nodeOrder
            .prefix(18)
            .compactMap { key -> MarkdownMermaidAttachment.Node? in
                guard let node = nodes[key] else { return nil }
                return .init(id: node.id, label: node.label)
            }
        let allowedIDs = Set(finalNodes.map(\.id))
        let finalEdges = edges.filter { allowedIDs.contains($0.from) && allowedIDs.contains($0.to) }

        return ParseResult(kind: kind, nodes: finalNodes, edges: finalEdges)
    }

    private static func extractBody(_ sourceMarkdown: String) -> String {
        let lines = sourceMarkdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return sourceMarkdown }
        var body = lines
        if body.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            body.removeFirst()
        }
        if body.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            body.removeLast()
        }
        return body.joined(separator: "\n")
    }

    private static func regexCaptures(pattern: String, in source: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: source, options: [], range: range).map { match in
            (1..<match.numberOfRanges).map { idx in
                let r = match.range(at: idx)
                guard r.location != NSNotFound else { return "" }
                return ns.substring(with: r)
            }
        }
    }

    private static func normalizeLabel(_ raw: String) -> String {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (label.hasPrefix("\"") && label.hasSuffix("\"")) || (label.hasPrefix("'") && label.hasSuffix("'")) {
            label = String(label.dropFirst().dropLast())
        }
        label = label.replacingOccurrences(of: "`", with: "")
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(label.prefix(120))
    }
}

private enum MermaidMiniLayout {
    struct Result {
        let size: CGSize
        let nodes: [MarkdownMermaidAttachment.Node]
        let edges: [MarkdownMermaidAttachment.Edge]
        let nodeFrames: [String: CGRect]
    }

    static func layout(
        kind: MermaidMiniParser.DiagramKind,
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxContentWidth: CGFloat
    ) -> Result {
        guard !nodes.isEmpty else {
            return Result(size: CGSize(width: 320, height: 180), nodes: [], edges: [], nodeFrames: [:])
        }

        let incoming = Dictionary(grouping: edges, by: \.to).mapValues(\.count)
        let outgoing = Dictionary(grouping: edges, by: \.from)

        // Depth assignment must be cycle-safe. Using "longest path" updates can loop forever on
        // self/cyclic edges (common in sequence/flow diagrams) and explode memory/CPU.
        var depth: [String: Int] = [:]
        var queue: [String] = nodes.map(\.id).filter { incoming[$0] == nil }
        if queue.isEmpty {
            queue = [nodes[0].id]
        }
        for root in queue {
            depth[root] = 0
        }

        let maxDepth = max(0, nodes.count - 1)
        var qi = 0
        while qi < queue.count {
            let current = queue[qi]
            qi += 1
            let currentDepth = depth[current] ?? 0
            for edge in outgoing[current] ?? [] {
                // Visit each node once during BFS to guarantee termination on cyclic graphs.
                guard depth[edge.to] == nil else { continue }
                depth[edge.to] = min(currentDepth + 1, maxDepth)
                queue.append(edge.to)
            }
        }

        // Any disconnected/cycle-only nodes that did not get a depth are placed after known columns.
        if depth.count < nodes.count {
            var fallbackDepth = min((depth.values.max() ?? -1) + 1, maxDepth)
            for node in nodes where depth[node.id] == nil {
                depth[node.id] = fallbackDepth
                fallbackDepth = min(fallbackDepth + 1, maxDepth)
            }
        }

        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let measuredLabelWidths = nodes.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }
        let baseNodeWidth = min(220, max(104, (measuredLabelWidths.max() ?? 104) + 28))

        let margin: CGFloat = 18
        let gapX: CGFloat = 40
        let gapY: CGFloat = 18
        let minNodeWidth: CGFloat = 92
        let maxColumnsByKind = (kind == .sequence) ? 4 : 6

        let uniqueDepths = Array(Set(nodes.map { depth[$0.id] ?? 0 })).sorted()
        var depthRank: [Int: Int] = [:]
        for (i, d) in uniqueDepths.enumerated() {
            depthRank[d] = i
        }

        let preferredColumns = max(1, uniqueDepths.count)
        let widthForColumns = maxContentWidth - margin * 2
        var columnCount = min(preferredColumns, maxColumnsByKind)
        columnCount = max(columnCount, 1)
        while columnCount > 1 {
            let candidateWidth = (widthForColumns - CGFloat(columnCount - 1) * gapX) / CGFloat(columnCount)
            if candidateWidth >= minNodeWidth { break }
            columnCount -= 1
        }
        let fittedNodeWidth = max(
            minNodeWidth,
            min(baseNodeWidth, (widthForColumns - CGFloat(max(0, columnCount - 1)) * gapX) / CGFloat(max(columnCount, 1)))
        )
        let labelParagraph = NSMutableParagraphStyle()
        labelParagraph.alignment = .center
        labelParagraph.lineBreakMode = .byWordWrapping
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .paragraphStyle: labelParagraph,
        ]
        let labelTextWidth = max(40, fittedNodeWidth - 16)
        let minimumNodeHeight: CGFloat = 34
        let maximumNodeHeight: CGFloat = 96
        func measuredNodeHeight(for label: String) -> CGFloat {
            let measured = (label as NSString).boundingRect(
                with: CGSize(width: labelTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: labelAttrs
            )
            let padded = ceil(measured.height) + 12
            return min(maximumNodeHeight, max(minimumNodeHeight, padded))
        }
        let nodeHeights: [String: CGFloat] = Dictionary(uniqueKeysWithValues: nodes.map { node in
            (node.id, measuredNodeHeight(for: node.label))
        })

        func compressedColumn(for depthValue: Int) -> Int {
            let rank = depthRank[depthValue] ?? 0
            if preferredColumns <= columnCount { return rank }
            let denominator = max(1, preferredColumns - 1)
            return Int(round(CGFloat(rank) * CGFloat(columnCount - 1) / CGFloat(denominator)))
        }

        var columns: [Int: [MarkdownMermaidAttachment.Node]] = [:]
        for node in nodes {
            let d = compressedColumn(for: depth[node.id] ?? 0)
            columns[d, default: []].append(node)
        }
        let sortedColumns = columns.keys.sorted()

        var frames: [String: CGRect] = [:]
        var maxX: CGFloat = margin
        var maxY: CGFloat = margin

        for d in sortedColumns {
            let col = columns[d] ?? []
            var y = margin
            for node in col {
                let x = margin + CGFloat(d) * (fittedNodeWidth + gapX)
                let nodeHeight = nodeHeights[node.id] ?? minimumNodeHeight
                let rect = CGRect(x: x, y: y, width: fittedNodeWidth, height: nodeHeight)
                frames[node.id] = rect
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
                y = rect.maxY + gapY
            }
        }

        let size = CGSize(
            width: min(maxContentWidth, maxX + margin),
            height: maxY + margin
        )
        return Result(size: size, nodes: nodes, edges: edges, nodeFrames: frames)
    }
}

private enum MermaidASCIIFormatter {
    static func lines(
        kind: MermaidMiniParser.DiagramKind,
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge]
    ) -> [String] {
        var out: [String] = []
        out.reserveCapacity(2 + nodes.count + edges.count)
        out.append("diagram: \(kindLabel(kind))")
        out.append(String(repeating: "-", count: 36))

        if nodes.isEmpty {
            out.append("(no nodes parsed)")
        } else {
            out.append("nodes:")
            for node in nodes.prefix(24) {
                out.append("  [\(node.id)] \(node.label)")
            }
            if nodes.count > 24 {
                out.append("  … +\(nodes.count - 24) more nodes")
            }
        }

        if !edges.isEmpty {
            out.append("")
            out.append("edges:")
            for edge in edges.prefix(48) {
                var line = "  \(edge.from) -> \(edge.to)"
                if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    line += "  (\(label))"
                }
                out.append(line)
            }
            if edges.count > 48 {
                out.append("  … +\(edges.count - 48) more edges")
            }
        }
        return out
    }

    static func wrap(lines: [String], maxColumns: Int) -> [String] {
        let columns = max(16, maxColumns)
        var out: [String] = []
        for line in lines {
            out.append(contentsOf: wrap(line: line, maxColumns: columns))
        }
        return out
    }

    private static func wrap(line: String, maxColumns: Int) -> [String] {
        guard line.count > maxColumns else { return [line] }
        var remaining = line[...]
        var wrapped: [String] = []
        while remaining.count > maxColumns {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxColumns)
            let prefix = remaining[..<splitIndex]
            if let ws = prefix.lastIndex(where: { $0.isWhitespace }), ws > remaining.startIndex {
                let chunk = String(remaining[..<ws]).trimmingCharacters(in: .whitespaces)
                wrapped.append(chunk)
                let next = remaining.index(after: ws)
                remaining = remaining[next...]
            } else {
                wrapped.append(String(prefix))
                remaining = remaining[splitIndex...]
            }
        }
        wrapped.append(String(remaining))
        return wrapped
    }

    private static func kindLabel(_ kind: MermaidMiniParser.DiagramKind) -> String {
        switch kind {
        case .flowchart: return "flowchart"
        case .sequence: return "sequence"
        case .generic: return "generic"
        }
    }
}
