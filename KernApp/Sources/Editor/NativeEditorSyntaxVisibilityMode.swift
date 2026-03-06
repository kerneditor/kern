import Foundation

enum NativeEditorSyntaxVisibilityMode: String, CaseIterable {
    case wysiwyg
    case hybrid
    case markdown

    static let userDefaultsKey = "nativeEditor.syntaxVisibilityMode"
    static let defaultMode: NativeEditorSyntaxVisibilityMode = .wysiwyg

    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> NativeEditorSyntaxVisibilityMode {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let mode = NativeEditorSyntaxVisibilityMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    var isSyntaxVisible: Bool {
        self == .markdown
    }

    var isHybridCaretSyntaxMode: Bool {
        self == .hybrid
    }
}
