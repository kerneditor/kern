import AppKit
import os

/// Monotonic process start time (nanoseconds) for perf logging.
let processStartNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
private let signposter = OSSignposter(subsystem: "com.gradigit.kern", category: "Launch")
let launchInterval = signposter.beginInterval("AppLaunch")

func msSinceStart() -> String {
    let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - processStartNs
    return String(format: "%.1f", Double(elapsed) / 1_000_000)
}

NSLog("[Perf] Process start at 0.0ms")

// Native editor preferences (UI tests / automation).
//
// Important: UI tests must be deterministic and must not mutate a developer's persisted defaults.
// We achieve this by applying overrides in a *volatile* UserDefaults domain when `KERN_UI_TESTING=1`.
let env = ProcessInfo.processInfo.environment
let isUITesting = env["KERN_UI_TESTING"] == "1"

if isUITesting {
    // Baseline defaults for tests (GFM-first, with optional Kern extensions toggled per-test via env).
    var overrides: [String: Any] = [
        "nativeEditor.exportDialect": "gfm",
        "nativeEditor.gfmExtensionExportStrategy": "preserve",
        "nativeEditor.taskRendering": "gfm",
        "nativeEditor.orderedTasksEnabled": false,
        "nativeEditor.headingCheckboxesEnabled": false,
        "nativeEditor.orderedListNumbering": "gfmDefault",
        "nativeEditor.checkboxHitTarget": "glyph",
    ]

    // Apply per-run/per-test overrides from env.
    if let v = env["KERN_NATIVE_EXPORT_DIALECT"] { overrides["nativeEditor.exportDialect"] = v } // gfm | kern
    if let v = env["KERN_NATIVE_GFM_EXTENSION_EXPORT"] { overrides["nativeEditor.gfmExtensionExportStrategy"] = v } // preserve | portable | lint
    if let v = env["KERN_NATIVE_TASK_RENDERING"] { overrides["nativeEditor.taskRendering"] = v } // gfm | kern
    if let v = env["KERN_NATIVE_ORDERED_TASKS"] { overrides["nativeEditor.orderedTasksEnabled"] = (v == "1") }
    if let v = env["KERN_NATIVE_HEADING_CHECKBOXES"] { overrides["nativeEditor.headingCheckboxesEnabled"] = (v == "1") }
    if let v = env["KERN_NATIVE_ORDERED_NUMBERING"] { overrides["nativeEditor.orderedListNumbering"] = v } // gfmDefault | preserveTyped
    if let v = env["KERN_NATIVE_CHECKBOX_HIT_TARGET"] { overrides["nativeEditor.checkboxHitTarget"] = v } // glyph | marker

    // Use NSArgumentDomain (highest-precedence, in-memory) so overrides win over any persisted defaults
    // without mutating the developer's preferences on disk.
    UserDefaults.standard.setVolatileDomain(overrides, forName: "NSArgumentDomain")
} else {
    // Runtime defaults for the native editor profile. Keep GFM export defaults, but enable
    // Kern extension rendering features by default for WYSIWYG readability.
    //
    // One-time migration: older builds persisted these as `false`, which makes ordered
    // and heading task checkboxes render literally in stress fixtures. Flip them to `true`
    // once for existing installs, then preserve user preference afterward.
    if !UserDefaults.standard.bool(forKey: "nativeEditor.didMigrateTaskDefaultsV1") {
        UserDefaults.standard.set(true, forKey: "nativeEditor.orderedTasksEnabled")
        UserDefaults.standard.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
        UserDefaults.standard.set(true, forKey: "nativeEditor.didMigrateTaskDefaultsV1")
    }

    if UserDefaults.standard.object(forKey: "nativeEditor.orderedTasksEnabled") == nil {
        UserDefaults.standard.set(true, forKey: "nativeEditor.orderedTasksEnabled")
    }
    if UserDefaults.standard.object(forKey: "nativeEditor.headingCheckboxesEnabled") == nil {
        UserDefaults.standard.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
    }

    // Normal runs: allow env vars to override persisted defaults (useful for manual profiling/debugging).
    if let v = env["KERN_NATIVE_EXPORT_DIALECT"] {
        UserDefaults.standard.set(v, forKey: "nativeEditor.exportDialect") // gfm | kern
    }
    if let v = env["KERN_NATIVE_GFM_EXTENSION_EXPORT"] {
        UserDefaults.standard.set(v, forKey: "nativeEditor.gfmExtensionExportStrategy") // preserve | portable | lint
    }
    if let v = env["KERN_NATIVE_TASK_RENDERING"] {
        UserDefaults.standard.set(v, forKey: "nativeEditor.taskRendering") // gfm | kern
    }
    if let v = env["KERN_NATIVE_ORDERED_TASKS"] {
        UserDefaults.standard.set(v == "1", forKey: "nativeEditor.orderedTasksEnabled")
    }
    if let v = env["KERN_NATIVE_HEADING_CHECKBOXES"] {
        UserDefaults.standard.set(v == "1", forKey: "nativeEditor.headingCheckboxesEnabled")
    }
    if let v = env["KERN_NATIVE_ORDERED_NUMBERING"] {
        UserDefaults.standard.set(v, forKey: "nativeEditor.orderedListNumbering") // gfmDefault | preserveTyped
    }
    if let v = env["KERN_NATIVE_CHECKBOX_HIT_TARGET"] {
        UserDefaults.standard.set(v, forKey: "nativeEditor.checkboxHitTarget") // glyph | marker
    }
}

// Swizzle AX bundle loading to background thread (saves 10-30ms on main thread)
_ = NSObject.swizzleAccessibilityBundlesOnce

// Instantiate KernDocumentController FIRST — the first NSDocumentController
// created becomes NSDocumentController.shared. This must happen before app.run()
// so Apple Event handling routes through our subclass.
let _ = KernDocumentController()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
