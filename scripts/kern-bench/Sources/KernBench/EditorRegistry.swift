import AppKit
import Foundation

struct EditorDefinition {
    let displayName: String
    let appName: String
    let bundleIdentifier: String
    let processName: String
    let architecture: String
    let isElectron: Bool
    /// CLI launch command (e.g., ["code"] for VS Code). Nil = use `open -a`.
    let cliLaunchCommand: [String]?
    /// Extra args for clean launch (suppress session restore).
    let cleanLaunchArgs: [String]
    /// Prefix for helper processes (e.g., "Code Helper" for VS Code Electron children).
    let helperProcessPrefix: String?
    /// Roster-locked v1 membership.
    let requiredForOfficial: Bool
}

/// Locked roster v1 for official benchmark claims.
/// Policy source: architect/prompt.md + architect/dual-benchmark-methodology-plan.md.
let requiredRosterV1: [EditorDefinition] = [
    .init(displayName: "Kern", appName: "Kern",
          bundleIdentifier: "com.gradigit.kern", processName: "Kern",
          architecture: "Native Swift + TextKit", isElectron: false,
          cliLaunchCommand: nil, cleanLaunchArgs: ["-ApplePersistenceIgnoreState", "YES"],
          helperProcessPrefix: nil, requiredForOfficial: true),
    .init(displayName: "VS Code", appName: "Visual Studio Code",
          bundleIdentifier: "com.microsoft.VSCode", processName: "Code",
          architecture: "Electron (Chromium + Node)", isElectron: true,
          cliLaunchCommand: ["code"],
          cleanLaunchArgs: ["--new-window", "--user-data-dir", "/tmp/vscode-bench", "--disable-extensions"],
          helperProcessPrefix: "Code Helper", requiredForOfficial: true),
    .init(displayName: "Zed", appName: "Zed",
          bundleIdentifier: "dev.zed.Zed", processName: "zed",
          architecture: "Native Rust + Metal", isElectron: false,
          cliLaunchCommand: ["zed"],
          cleanLaunchArgs: ["--new", "--user-data-dir", "/tmp/zed-bench"],
          helperProcessPrefix: nil, requiredForOfficial: true),
    .init(displayName: "Sublime Text", appName: "Sublime Text",
          bundleIdentifier: "com.sublimetext.4", processName: "sublime_text",
          architecture: "Native C++", isElectron: false,
          cliLaunchCommand: ["subl"],
          cleanLaunchArgs: ["--new-window"],
          helperProcessPrefix: "/opt/homebrew/bin/subl", requiredForOfficial: true),
    .init(displayName: "TextEdit", appName: "TextEdit",
          bundleIdentifier: "com.apple.TextEdit", processName: "TextEdit",
          architecture: "Native AppKit", isElectron: false,
          cliLaunchCommand: nil, cleanLaunchArgs: [],
          helperProcessPrefix: nil, requiredForOfficial: true),
]

/// Optional editors available for exploratory comparisons only (not part of official roster claims).
let optionalEditors: [EditorDefinition] = [
    .init(displayName: "Typora", appName: "Typora",
          bundleIdentifier: "abnerworks.Typora", processName: "Typora",
          architecture: "Native (WebKit hybrid)", isElectron: false,
          cliLaunchCommand: nil, cleanLaunchArgs: ["-ApplePersistenceIgnoreState", "YES"],
          helperProcessPrefix: nil, requiredForOfficial: false),
]

/// Alias retained for call sites.
let knownEditors: [EditorDefinition] = requiredRosterV1 + optionalEditors

func requiredRosterNames() -> [String] {
    requiredRosterV1.map(\.displayName)
}

func isEditorInstalled(_ editor: EditorDefinition) -> Bool {
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) != nil {
        return true
    }
    let paths = [
        "/Applications/\(editor.appName).app",
        "/System/Applications/\(editor.appName).app",
        NSHomeDirectory() + "/Applications/\(editor.appName).app",
    ]
    return paths.contains { FileManager.default.fileExists(atPath: $0) }
}

func detectInstalledEditors() -> [EditorDefinition] {
    knownEditors.filter { isEditorInstalled($0) }
}

func findEditor(named name: String) -> EditorDefinition? {
    knownEditors.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
}

/// Read the CFBundleShortVersionString from an editor's Info.plist.
func editorVersion(_ editor: EditorDefinition) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) else {
        return nil
    }
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
    guard let dict = NSDictionary(contentsOf: plistURL) else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}
