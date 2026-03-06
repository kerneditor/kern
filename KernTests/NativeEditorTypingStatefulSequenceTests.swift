import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorTypingStatefulSequenceTests: XCTestCase {
    private enum SequenceAction: CaseIterable {
        case markerBullet
        case markerOrdered
        case markerQuote
        case enter
        case shiftEnter
        case appendWord
        case backspaceCommand
        case toggleCheckbox
    }

    @MainActor
    func testStatefulTypingSequenceSmoke_PRLane() throws {
        let seedCount = max(1, TestRuntimeConfig.int("KERN_TYPING_STATEFUL_SEEDS", default: 12) ?? 12)
        let stepsPerSeed = max(8, TestRuntimeConfig.int("KERN_TYPING_STATEFUL_STEPS", default: 40) ?? 40)
        let enforce = TestRuntimeConfig.bool("KERN_TYPING_STATEFUL_ENFORCE")
        print("[TypingStateful] seeds=\(seedCount) steps=\(stepsPerSeed) enforce=\(enforce ? 1 : 0)")
        var report: [String] = []
        var failures: [String] = []
        let (vc, textView, window) = makeController(markdown: "")
        defer { closeHostedEditor(window) }

        for seed in 0..<seedCount {
            autoreleasepool {
                vc.stringValue = ""
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.undoManager?.removeAllActions()
                drainMainRunLoop()

                var state = UInt64(seed + 1) * 1_103_515_245 &+ 12_345
                var trace: [String] = []

                for step in 0..<stepsPerSeed {
                    let action = pickAction(state: &state)
                    trace.append("seed=\(seed) step=\(step) action=\(action)")
                    apply(action: action, seed: seed, step: step, vc: vc, textView: textView)
                    drainMainRunLoop()

                    if step % 5 == 0 || step == stepsPerSeed - 1 {
                        let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                        if let invariantError = firstInvariantViolation(in: exported) {
                            failures.append("seed=\(seed) step=\(step) invariant=\(invariantError)\ntrace=\n\(trace.joined(separator: "\n"))\nexport=\n\(exported)")
                            break
                        }
                        if step % 10 == 0 {
                            let roundTrip = roundTripExport(exported)
                            let lhs = normalizeForDiff(exported)
                            let rhs = normalizeForDiff(roundTrip)
                            if lhs != rhs {
                                failures.append("seed=\(seed) step=\(step) roundtrip-mismatch\ntrace=\n\(trace.joined(separator: "\n"))\nexport=\n\(exported)\nroundtrip=\n\(roundTrip)")
                                break
                            }
                        }
                    }
                }

                let finalExport = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                report.append("seed=\(seed) final_bytes=\(finalExport.utf8.count) final_chars=\(textView.string.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "typing-stateful-sequence-report")
        if !failures.isEmpty {
            attachReport(failures.joined(separator: "\n\n---\n\n"), name: "typing-stateful-sequence-failures")
            if enforce {
                let preview = failures.prefix(2).joined(separator: "\n\n---\n\n")
                XCTFail("Stateful typing sequence failures: \(failures.count)\n\(preview)")
            } else {
                XCTContext.runActivity(named: "Stateful typing smoke recorded non-blocking failures (set KERN_TYPING_STATEFUL_ENFORCE=1 to gate)") { _ in }
            }
        }
    }

    // MARK: - Stateful Engine

    @MainActor
    private func apply(action: SequenceAction, seed: Int, step: Int, vc: NativeEditorViewController, textView: NativeMarkdownTextView) {
        // Lightweight context-aware constraint: avoid stacking marker shortcuts inside fenced code blocks
        // where they are expected to remain literal and can create noisy sequence drift.
        let inCodeFence = textView.string.hasPrefix("```") && textView.string.contains("\n```")
        switch action {
        case .markerBullet:
            if !inCodeFence {
                textView.insertText("- ", replacementRange: textView.selectedRange())
            } else {
                textView.insertText("bullet ", replacementRange: textView.selectedRange())
            }
        case .markerOrdered:
            if !inCodeFence {
                textView.insertText("1. ", replacementRange: textView.selectedRange())
            } else {
                textView.insertText("one ", replacementRange: textView.selectedRange())
            }
        case .markerQuote:
            if !inCodeFence {
                textView.insertText("> ", replacementRange: textView.selectedRange())
            } else {
                textView.insertText("quote ", replacementRange: textView.selectedRange())
            }
        case .enter:
            textView.insertNewline(nil)
        case .shiftEnter:
            textView.insertLineBreak(nil)
        case .appendWord:
            textView.insertText("w\(seed)_\(step) ", replacementRange: textView.selectedRange())
        case .backspaceCommand:
            _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
        case .toggleCheckbox:
            if let storage = textView.textStorage,
               let checkboxIndex = firstCheckboxIndex(in: storage, range: NSRange(location: 0, length: storage.length)) {
                textView.setSelectedRange(NSRange(location: checkboxIndex, length: 0))
                textView.insertText(" ", replacementRange: textView.selectedRange())
            } else {
                textView.insertText("- [ ] s\(seed)_\(step)", replacementRange: textView.selectedRange())
            }
        }
    }

    private func pickAction(state: inout UInt64) -> SequenceAction {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let idx = Int(state % UInt64(SequenceAction.allCases.count))
        return SequenceAction.allCases[idx]
    }

    private func firstInvariantViolation(in exported: String) -> String? {
        if exported.contains("\u{0000}") {
            return "contains-nul"
        }
        if exported.contains("\n- []") || exported.contains("\n* []") || exported.contains("\n+ []") {
            return "malformed-task-marker"
        }
        if exported.contains("\n1.. ") {
            return "malformed-ordered-marker"
        }
        if exported.contains("[ ] ]") || exported.contains("[x] ]") || exported.contains("[X] ]") {
            return "malformed-bracket-balance"
        }
        return nil
    }

    @MainActor
    private func roundTripExport(_ markdown: String) -> String {
        let imported = NativeMarkdownCodec.importMarkdown(markdown, options: .fromUserDefaults())
        return NativeMarkdownCodec.exportMarkdown(imported, options: .fromUserDefaults())
    }

    private func normalizeForDiff(_ text: String) -> String {
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]{2,}(?=- \[[ xX]\])"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]{2,}(?=\d+\. \[[ xX]\])"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"[ \t]{2,}(?=\d+\.)"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([-+*])\s{2,}(?=\[[ xX]\])"#,
            with: "$1 ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(\d+\.)\s{2,}(?=\[[ xX]\])"#,
            with: "$1 ",
            options: .regularExpression
        )
        // Hard/soft line break canon:
        // Shift+Enter paths can round-trip "\" vs "\\" at EOL while preserving displayed break semantics.
        while normalized.contains("\\\\") {
            normalized = normalized.replacingOccurrences(of: "\\\\", with: "\\")
        }
        normalized = normalized.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rawLine -> String in
                var line = String(rawLine)
                line = line.replacingOccurrences(
                    of: #"[ \t]+$"#,
                    with: "",
                    options: .regularExpression
                )
                // Canonicalize empty quote-only lines, which can be dropped on import/export.
                if line == ">" { return "" }
                return line
            }
        normalized = lines.joined(separator: "\n")
        while normalized.last == "\n" {
            normalized.removeLast()
        }
        return normalized
    }

    // MARK: - Shared helpers

    @MainActor
    private func makeController(markdown: String) -> (NativeEditorViewController, NativeMarkdownTextView, NSWindow) {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = markdown
        let window = hostInWindow(vc: vc, size: NSSize(width: 900, height: 650), appearance: .init(named: .darkAqua))
        window.displayIfNeeded()
        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        _ = window.makeFirstResponder(textView)
        drainMainRunLoop()
        return (vc, textView, window)
    }

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSWindow {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc
        window.setFrame(rect, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func closeHostedEditor(_ window: NSWindow) {
        window.orderOut(nil)
        window.close()
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    private func firstCheckboxIndex(in storage: NSTextStorage, range: NSRange) -> Int? {
        var out: Int?
        storage.enumerateAttribute(.kernCheckbox, in: range, options: []) { value, r, stop in
            if (value as? Bool) == true {
                out = r.location
                stop.pointee = true
            }
        }
        return out
    }

    @MainActor
    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func attachReport(_ content: String, name: String) {
        let attachment = XCTAttachment(string: content)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
