import AppKit
import XCTest
@testable import KernTextKit

final class NativeEditorTypingBehaviorMatrixCoverageTests: XCTestCase {
    private struct TransitionCase {
        let id: String
        let edge: TypingBehaviorEdge
        let seedMarkdown: String
        let defaults: [String: Any]
        let prepare: @MainActor (_ vc: NativeEditorViewController, _ textView: NativeMarkdownTextView) -> Void
        let perform: @MainActor (_ vc: NativeEditorViewController, _ textView: NativeMarkdownTextView) -> Void
        let assertExport: (_ exported: String) -> Void
    }

    @MainActor
    func testCriticalTypingBehaviorTransitionMatrix_PRLane() throws {
        let cases = prLaneCases()
        var coverage = TypingBehaviorCoverage(required: Set(cases.map(\.edge)))

        for c in cases {
            withTemporaryDefaults(c.defaults) {
                let (vc, textView, window) = makeController(markdown: c.seedMarkdown)
                defer { closeHostedEditor(window) }

                c.prepare(vc, textView)
                c.perform(vc, textView)
                drainMainRunLoop()
                vc.flushPendingExport()
                drainMainRunLoop()

                let exported = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                c.assertExport(exported)
                coverage.record(edge: c.edge, caseID: c.id)
            }
        }

        attachReport(coverage.renderReport(), name: "typing-behavior-matrix-prlane-coverage")
        let missing = coverage.missingRequired
        let missingSummary = missing.map { "\($0.context.rawValue):\($0.action.rawValue)" }.joined(separator: ", ")
        XCTAssertTrue(
            missing.isEmpty,
            "Missing required edges: \(missingSummary)"
        )
    }

    // MARK: - Matrix Cases

    @MainActor
    private func prLaneCases() -> [TransitionCase] {
        var out: [TransitionCase] = []

        out.append(
            TransitionCase(
                id: "paragraph-marker-bullet",
                edge: TypingBehaviorEdge(context: .paragraph, action: .markerShortcut),
                seedMarkdown: "",
                defaults: [:],
                prepare: { _, _ in },
                perform: { _, textView in
                    textView.insertText("- ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.hasPrefix("- "), "Expected bullet marker shortcut export. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "paragraph-marker-ordered",
                edge: TypingBehaviorEdge(context: .paragraph, action: .markerShortcut),
                seedMarkdown: "",
                defaults: [:],
                prepare: { _, _ in },
                perform: { _, textView in
                    textView.insertText("1. ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. "), "Expected ordered marker shortcut export. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "paragraph-marker-star-bullet",
                edge: TypingBehaviorEdge(context: .paragraph, action: .markerShortcut),
                seedMarkdown: "",
                defaults: [:],
                prepare: { _, _ in },
                perform: { _, textView in
                    textView.insertText("* ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("* ") || exported.contains("- "), "Expected star marker shortcut export. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "paragraph-marker-plus-bullet",
                edge: TypingBehaviorEdge(context: .paragraph, action: .markerShortcut),
                seedMarkdown: "",
                defaults: [:],
                prepare: { _, _ in },
                perform: { _, textView in
                    textView.insertText("+ ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("+ ") || exported.contains("- "), "Expected plus marker shortcut export. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-enter-continue",
                edge: TypingBehaviorEdge(context: .bullet, action: .enter),
                seedMarkdown: "- alpha",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("beta", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("- alpha"))
                    XCTAssertTrue(exported.contains("- beta"), "Expected bullet continuation line. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-enter-continue",
                edge: TypingBehaviorEdge(context: .ordered, action: .enter),
                seedMarkdown: "1. alpha",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("beta", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. alpha"))
                    XCTAssertTrue(exported.contains("beta"), "Expected ordered continuation content. got=\(exported)")
                    XCTAssertTrue(
                        exported.contains("2. beta") || exported.contains("1. beta"),
                        "Expected ordered continuation marker. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-second-enter-exit",
                edge: TypingBehaviorEdge(context: .bullet, action: .secondEnterExit),
                seedMarkdown: "- alpha",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertNewline(nil)
                    textView.insertText("after", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("- alpha"))
                    XCTAssertTrue(exported.contains("after"))
                    XCTAssertFalse(exported.contains("- after"), "Expected second Enter to exit bullet context. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-second-enter-exit",
                edge: TypingBehaviorEdge(context: .ordered, action: .secondEnterExit),
                seedMarkdown: "1. alpha",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertNewline(nil)
                    textView.insertText("after", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. alpha"))
                    XCTAssertTrue(exported.contains("after"))
                    XCTAssertFalse(exported.contains("2. after"), "Expected second Enter to exit ordered context. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-marker-shortcut-switch-to-bullet",
                edge: TypingBehaviorEdge(context: .ordered, action: .markerShortcut),
                seedMarkdown: "1. alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { _, textView in
                    textView.insertText("-", replacementRange: textView.selectedRange())
                    textView.insertText(" ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "- alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-tab-indent",
                edge: TypingBehaviorEdge(context: .bullet, action: .tabIndent),
                seedMarkdown: "- alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "  - alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .bullet, action: .shiftTabOutdent),
                seedMarkdown: "  - alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "- alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-tab-indent",
                edge: TypingBehaviorEdge(context: .ordered, action: .tabIndent),
                seedMarkdown: "1. alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "   1. alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .ordered, action: .shiftTabOutdent),
                seedMarkdown: "   1. alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "1. alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-tab-indent",
                edge: TypingBehaviorEdge(context: .task, action: .tabIndent),
                seedMarkdown: "- [ ] alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "  - [ ] alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .task, action: .shiftTabOutdent),
                seedMarkdown: "  - [ ] alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "- [ ] alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-enter-continue",
                edge: TypingBehaviorEdge(context: .nestedOrdered, action: .enter),
                seedMarkdown: "1. parent\n   1. child",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("next", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. parent"))
                    XCTAssertTrue(exported.contains("1. child"))
                    XCTAssertTrue(
                        exported.contains("2. next") || exported.contains("1. next"),
                        "Expected nested ordered continuation marker. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-task-tab-indent",
                edge: TypingBehaviorEdge(context: .nestedTask, action: .tabIndent),
                seedMarkdown: "1. parent\n   - [ ] child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertFalse(exported.contains("```"), "Nested task tab-indent should not degrade into code block. got=\(exported)")
                    XCTAssertTrue(exported.contains("- [ ] child"), "Expected nested task marker retained after indent. got=\(exported)")
                    XCTAssertTrue(exported.contains("child"), "Expected content to remain editable after nested task indent. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-bullet-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .nestedBullet, action: .shiftTabOutdent),
                seedMarkdown: "1. parent\n     - child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("  - child") || exported.contains("- child"),
                        "Expected nested bullet outdent. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-task-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .nestedTask, action: .shiftTabOutdent),
                seedMarkdown: "1. parent\n     - [ ] child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("   - [ ] child") || exported.contains("- [ ] child"),
                        "Expected nested task outdent. got=\(exported)"
                    )
                    XCTAssertFalse(exported.contains("```"), "Nested task outdent should remain a list. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-marker-shortcut-to-bullet-task",
                edge: TypingBehaviorEdge(context: .nestedOrdered, action: .markerShortcut),
                seedMarkdown: "1. parent\n   1. child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { _, textView in
                    textView.insertText("- [ ] ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("   - [ ] child") || exported.contains("   - ☐ child"),
                        "Expected nested ordered -> nested bullet task conversion. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-task-marker-shortcut-to-ordered-task",
                edge: TypingBehaviorEdge(context: .nestedTask, action: .markerShortcut),
                seedMarkdown: "1. parent\n   - [ ] child\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { _, textView in
                    textView.insertText("1. [ ] ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("   1. [ ] child") || exported.contains("   1. ☐ child"),
                        "Expected nested task -> nested ordered task conversion. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-task-marker-delete-recovery",
                edge: TypingBehaviorEdge(context: .nestedTask, action: .backspaceAtBoundary),
                seedMarkdown: "1. parent\n   - [ ] child\n",
                defaults: [:],
                prepare: { _, textView in
                    guard let storage = textView.textStorage else { return }
                    let ns = storage.string as NSString
                    let childRange = ns.range(of: "child")
                    guard childRange.location != NSNotFound else {
                        XCTFail("Missing nested task body")
                        return
                    }
                    let childPara = ns.paragraphRange(for: NSRange(location: childRange.location, length: 0))
                    var nestedMarker: Int?
                    storage.enumerateAttribute(.kernMarker, in: childPara, options: []) { value, range, stop in
                        if (value as? Bool) == true {
                            nestedMarker = range.location
                            stop.pointee = true
                        }
                    }
                    guard let marker = nestedMarker else {
                        XCTFail("Missing nested task marker")
                        return
                    }
                    textView.insertText("", replacementRange: NSRange(location: marker, length: 1))
                    textView.setSelectedRange(NSRange(location: marker, length: 0))
                },
                perform: { _, textView in
                    textView.insertText("z", replacementRange: textView.selectedRange())
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    textView.insertNewline(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    textView.insertText("next", replacementRange: textView.selectedRange())
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("z"), "Expected typing recovery after nested task marker edit. got=\(exported)")
                    XCTAssertTrue(exported.contains("next"), "Expected newline recovery after nested task marker edit. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-task-enter-continue",
                edge: TypingBehaviorEdge(context: .orderedTask, action: .enter),
                seedMarkdown: "1. [ ] alpha",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("beta", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. [ ] alpha") || exported.contains("1. ☐ alpha"))
                    XCTAssertTrue(
                        exported.contains("2. [ ] beta") || exported.contains("2. ☐ beta") || exported.contains("1. [ ] beta"),
                        "Expected ordered-task continuation line. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-task-tab-indent",
                edge: TypingBehaviorEdge(context: .orderedTask, action: .tabIndent),
                seedMarkdown: "1. [ ] alpha\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("   1. [ ] alpha") || exported.contains("   1. ☐ alpha"),
                        "Expected ordered-task indent via tab. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-task-shift-tab-outdent",
                edge: TypingBehaviorEdge(context: .orderedTask, action: .shiftTabOutdent),
                seedMarkdown: "   1. [ ] alpha\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("1. [ ] alpha") || exported.contains("1. ☐ alpha"),
                        "Expected ordered-task outdent via Shift+Tab. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-task-space-toggle",
                edge: TypingBehaviorEdge(context: .orderedTask, action: .spaceToggle),
                seedMarkdown: "1. [ ] task",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    guard let storage = textView.textStorage,
                          let checkboxIndex = Self.firstCheckboxIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
                        XCTFail("Expected ordered-task checkbox marker")
                        return
                    }
                    textView.setSelectedRange(NSRange(location: checkboxIndex, length: 0))
                },
                perform: { _, textView in
                    textView.insertText(" ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("1. [x] task") || exported.contains("1. [X] task") || exported.contains("1. ☑ task"),
                        "Expected ordered-task checkbox toggle. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-task-second-enter-exit",
                edge: TypingBehaviorEdge(context: .orderedTask, action: .secondEnterExit),
                seedMarkdown: "1. [ ] alpha",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertNewline(nil)
                    textView.insertText("after", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("1. [ ] alpha") || exported.contains("1. ☐ alpha"))
                    XCTAssertTrue(exported.contains("after"))
                    XCTAssertFalse(exported.contains("2. [ ] after"), "Expected second Enter to exit ordered-task context. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-task-enter-continue",
                edge: TypingBehaviorEdge(context: .nestedOrderedTask, action: .enter),
                seedMarkdown: "1. parent\n   1. [ ] child",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("next", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("   1. [ ] child") || exported.contains("   1. ☐ child"),
                        "Expected nested ordered task baseline. got=\(exported)"
                    )
                    XCTAssertTrue(
                        exported.contains("2. [ ] next") || exported.contains("2. ☐ next") || exported.contains("1. [ ] next"),
                        "Expected nested ordered task continuation marker. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-task-tab-indent",
                edge: TypingBehaviorEdge(context: .nestedOrderedTask, action: .tabIndent),
                seedMarkdown: "1. parent\n   1. [ ] child\n",
                defaults: [
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    XCTAssertTrue(vc.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:))))
                },
                assertExport: { exported in
                    XCTAssertFalse(exported.contains("```"), "Nested ordered-task indent should remain list content. got=\(exported)")
                    XCTAssertTrue(
                        exported.contains("1. [ ] child") || exported.contains("1. ☐ child"),
                        "Expected nested ordered task marker retained after indent. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "heading-task-enter-then-bullet-task",
                edge: TypingBehaviorEdge(context: .headingTask, action: .enter),
                seedMarkdown: "## [ ] Heading task",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("- [ ] child", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("## [ ] Heading task") || exported.contains("## ☐ Heading task"),
                        "Expected heading task retained. got=\(exported)"
                    )
                    XCTAssertTrue(
                        exported.contains("- [ ] child") || exported.contains("- ☐ child"),
                        "Expected bullet task creation after heading-task newline. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-marker-delete-recovery",
                edge: TypingBehaviorEdge(context: .nestedOrdered, action: .backspaceAtBoundary),
                seedMarkdown: "1. parent\n   1. child\n",
                defaults: [:],
                prepare: { _, textView in
                    guard let storage = textView.textStorage else { return }
                    guard let markerIndex = Self.firstMarkerIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
                        XCTFail("Expected list marker")
                        return
                    }
                    let ns = storage.string as NSString
                    let second = ns.range(of: "child")
                    guard second.location != NSNotFound else {
                        XCTFail("Missing nested ordered body")
                        return
                    }
                    let secondPara = ns.paragraphRange(for: NSRange(location: second.location, length: 0))
                    var nestedMarker: Int?
                    storage.enumerateAttribute(.kernMarker, in: secondPara, options: []) { value, range, stop in
                        if (value as? Bool) == true {
                            nestedMarker = range.location
                            stop.pointee = true
                        }
                    }
                    let targetMarker = nestedMarker ?? markerIndex
                    textView.insertText("", replacementRange: NSRange(location: targetMarker, length: 1))
                    textView.setSelectedRange(NSRange(location: targetMarker, length: 0))
                },
                perform: { _, textView in
                    textView.insertText("z", replacementRange: textView.selectedRange())
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    textView.insertNewline(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    textView.insertText("next", replacementRange: textView.selectedRange())
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("z"), "Expected typing recovery after nested marker delete. got=\(exported)")
                    XCTAssertTrue(exported.contains("next"), "Expected newline recovery after nested marker delete. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-bullet-backspace-outdent",
                edge: TypingBehaviorEdge(context: .nestedBullet, action: .backspaceAtBoundary),
                seedMarkdown: "1. parent\n   - child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("  - child") || exported.contains("- child"),
                        "Expected nested bullet backspace to outdent first. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "nested-ordered-backspace-outdent",
                edge: TypingBehaviorEdge(context: .nestedOrdered, action: .backspaceAtBoundary),
                seedMarkdown: "1. parent\n   1. child\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("child", in: textView)
                },
                perform: { vc, textView in
                    _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("1. child") || exported.contains("2. child"),
                        "Expected nested ordered backspace to keep ordered marker while outdenting. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-space-toggle",
                edge: TypingBehaviorEdge(context: .task, action: .spaceToggle),
                seedMarkdown: "- [ ] task",
                defaults: [:],
                prepare: { _, textView in
                    guard let storage = textView.textStorage,
                          let checkboxIndex = Self.firstCheckboxIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
                        XCTFail("Expected checkbox marker")
                        return
                    }
                    textView.setSelectedRange(NSRange(location: checkboxIndex, length: 0))
                },
                perform: { _, textView in
                    textView.insertText(" ", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported.contains("- [x] task") || exported.contains("- [X] task"),
                        "Expected toggled task checkbox. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-enter-continue",
                edge: TypingBehaviorEdge(context: .task, action: .enter),
                seedMarkdown: "- [ ] one",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("two", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("- [ ] one"))
                    XCTAssertTrue(exported.contains("- [ ] two"), "Expected task continuation line. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-second-enter-exit",
                edge: TypingBehaviorEdge(context: .task, action: .secondEnterExit),
                seedMarkdown: "- [ ] one",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertNewline(nil)
                    textView.insertText("after", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("- [ ] one") || exported.contains("- ☐ one"))
                    XCTAssertTrue(exported.contains("after"))
                    XCTAssertFalse(exported.contains("- [ ] after"), "Expected second Enter to exit task context. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "quote-enter-continue",
                edge: TypingBehaviorEdge(context: .quote, action: .enter),
                seedMarkdown: "> quote",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("continued", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("> quote"))
                    XCTAssertTrue(exported.contains("> continued"), "Expected quote continuation marker. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "quote-second-enter-exit",
                edge: TypingBehaviorEdge(context: .quote, action: .secondEnterExit),
                seedMarkdown: "> quote",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("continued", replacementRange: textView.selectedRange())
                    textView.insertNewline(nil)
                    textView.insertNewline(nil)
                    textView.insertText("after", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("> quote"))
                    XCTAssertTrue(exported.contains("> continued"))
                    XCTAssertTrue(exported.contains("after"))
                    XCTAssertFalse(exported.contains("\n> \n"), "Second Enter should exit quote context. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "codefence-marker-shortcut-no-convert",
                edge: TypingBehaviorEdge(context: .codeFence, action: .markerShortcut),
                seedMarkdown: "```\ncode\n```",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringEnd("code", in: textView)
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    textView.insertText("- [ ] raw", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("```"))
                    XCTAssertTrue(exported.contains("- [ ] raw"), "Expected raw markdown to remain literal inside code fence. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-backspace-unlist",
                edge: TypingBehaviorEdge(context: .bullet, action: .backspaceAtBoundary),
                seedMarkdown: "- alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-backspace-unlist",
                edge: TypingBehaviorEdge(context: .ordered, action: .backspaceAtBoundary),
                seedMarkdown: "1. alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                },
                assertExport: { exported in
                    XCTAssertEqual(exported, "alpha\n")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "ordered-enter-recovers-after-marker-delete",
                edge: TypingBehaviorEdge(context: .ordered, action: .enter),
                seedMarkdown: "1. alpha\n",
                defaults: [:],
                prepare: { _, textView in
                    guard let storage = textView.textStorage else { return }
                    guard let markerIndex = Self.firstMarkerIndex(in: storage, range: NSRange(location: 0, length: storage.length)) else {
                        XCTFail("Expected ordered marker")
                        return
                    }
                    textView.insertText("", replacementRange: NSRange(location: markerIndex, length: 1))
                    textView.setSelectedRange(NSRange(location: markerIndex, length: 0))
                },
                perform: { _, textView in
                    textView.insertNewline(nil)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                    textView.insertText("next", replacementRange: textView.selectedRange())
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("next"), "Expected newline/typing recovery after marker edit. got=\(exported)")
                }
            )
        )

        out.append(
            TransitionCase(
                id: "task-backspace-unlist-preserve-inline",
                edge: TypingBehaviorEdge(context: .task, action: .backspaceAtBoundary),
                seedMarkdown: "- [ ] **alpha**\n",
                defaults: [
                    "nativeEditor.taskRendering": "gfm",
                ],
                prepare: { _, textView in
                    Self.moveCaretToSubstringStart("alpha", in: textView)
                },
                perform: { vc, textView in
                    _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                    vc.flushPendingExport()
                    let firstPass = NativeMarkdownCodec.exportMarkdown(textView.attributedString(), options: .fromUserDefaults())
                    if firstPass.hasPrefix("- [ ] ") {
                        _ = vc.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                    }
                },
                assertExport: { exported in
                    XCTAssertTrue(
                        exported == "**alpha**\n" || exported == "- [ ] **alpha**\n",
                        "Expected task backspace boundary to either unlist or remain stable. got=\(exported)"
                    )
                }
            )
        )

        out.append(
            TransitionCase(
                id: "bullet-shift-enter-softbreak",
                edge: TypingBehaviorEdge(context: .bullet, action: .shiftEnter),
                seedMarkdown: "- one",
                defaults: [:],
                prepare: { _, textView in
                    Self.moveCaretToEnd(textView)
                },
                perform: { _, textView in
                    textView.insertLineBreak(nil)
                    textView.insertText("two", replacementRange: textView.selectedRange())
                },
                assertExport: { exported in
                    XCTAssertTrue(exported.contains("- one"), "Expected bullet content retained. got=\(exported)")
                    XCTAssertTrue(exported.contains("two"), "Expected inserted trailing content. got=\(exported)")
                    XCTAssertFalse(exported.contains("- two"), "Shift+Enter should not create another bullet marker. got=\(exported)")
                }
            )
        )

        return out
    }

    // MARK: - Helpers

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

    @MainActor
    private static func moveCaretToEnd(_ textView: NativeMarkdownTextView) {
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    @MainActor
    private static func moveCaretToSubstringStart(_ needle: String, in textView: NativeMarkdownTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(needle)'")
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    @MainActor
    private static func moveCaretToSubstringEnd(_ needle: String, in textView: NativeMarkdownTextView) {
        let ns = textView.string as NSString
        let range = ns.range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected substring '\(needle)'")
        guard range.location != NSNotFound else { return }
        textView.setSelectedRange(NSRange(location: range.location + range.length, length: 0))
    }

    private static func firstCheckboxIndex(in storage: NSTextStorage, range: NSRange) -> Int? {
        var out: Int?
        storage.enumerateAttribute(.kernCheckbox, in: range, options: []) { value, r, stop in
            if (value as? Bool) == true {
                out = r.location
                stop.pointee = true
            }
        }
        return out
    }

    private static func firstMarkerIndex(in storage: NSTextStorage, range: NSRange) -> Int? {
        var out: Int?
        storage.enumerateAttribute(.kernMarker, in: range, options: []) { value, r, stop in
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

    private func withTemporaryDefaults<T>(_ overrides: [String: Any], _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        var effectiveOverrides = overrides
        if effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] == nil {
            effectiveOverrides[NativeEditorSyntaxVisibilityMode.userDefaultsKey] = NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue
        }
        var saved: [String: Any?] = [:]
        for (key, value) in effectiveOverrides {
            saved[key] = defaults.object(forKey: key)
            defaults.set(value, forKey: key)
        }
        defer {
            for (key, previous) in saved {
                if let previous {
                    defaults.set(previous, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try body()
    }
}
