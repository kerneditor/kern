# Cold Start Optimization Research

Deep research into minimizing Kern's time from `open -a Kern file.md` to editable content.

## Current Cold Start Sequence

Traced from source — exact order of operations:

```
main.swift
  │  KernDocumentController() — instantiate before app.run()
  │  AppDelegate set as delegate
  │  app.setActivationPolicy(.regular) + app.activate()
  │  app.run() → triggers applicationDidFinishLaunching
  │
  ▼
AppDelegate.applicationDidFinishLaunching         ← BLOCKING MAIN THREAD
  │
  ├─ schemeHandler.loadHTML()                     ~5-20ms    Read 6.5MB from bundle
  ├─ EditorReusePool.shared.warmUp()             ~200-300ms Create 3 WKWebViews SEQUENTIALLY
  ├─ AppearanceManager.shared.startObserving()   ~1ms       KVO observer
  ├─ buildMenuBar()                              ~5-10ms    Programmatic NSMenu
  │
  └─ DispatchQueue.main.async:
       openUntitledIfNeeded()                    Creates first document
         │
         ▼
       EditorDocument.init() + read(from:ofType:)
         │
         ▼
       EditorWindowController.init()             ~20-50ms   NSWindow created
         │
         ▼
       EditorViewController.loadView()
         ├─ EditorReusePool.dequeue()            ~0ms       From pre-warmed pool
         └─ attachWebView()                      ~5ms       Delegates + message handler
         │
         ▼
       EditorViewController.viewDidLoad()
         └─ loadEditorHTML()                     ~1ms       Async load starts
              │
              ▼  (async, WebKit process)
            EditorSchemeHandler serves 6.5MB
              │
              ▼
            WebKit parses HTML + CSS              ~20-50ms
              │
              ▼
            JS parse + compile (all inlined)      ~100-300ms  ← NO BYTECODE CACHE
              │
              ▼
            main.ts init()
              ├─ new Crepe({...})                 ~10-20ms   Plugin registration
              ├─ crepe.editor.use(search, ...)    ~5ms
              ├─ setupBridge(crepe)               ~5ms       window.kern API
              ├─ await crepe.create()             ~200-400ms ← BIGGEST JS BOTTLENECK
              ├─ initSearch()                     ~5ms
              ├─ initInlineNested()               ~2ms
              ├─ initCheckboxIcons()              ~3ms
              └─ postMessage("editorReady")
                   │
                   ▼
       EditorViewController.editorReady()
         ├─ bridge = WebBridge(webView)
         ├─ Task: bridge.setMarkdown(content)     ~50-500ms  Depends on file size
         └─ Task: bridge.setTheme("dark"/"light") ~10ms
```

**Estimated total: \~600-1200ms** from process start to editable content.

## Findings by Layer

### Layer 1: Pre-main (dyld) — ALREADY OPTIMAL

Kern is pure Swift with only system frameworks (AppKit, WebKit). These live in the dyld shared cache — pre-linked, shared across processes. No embedded dylibs, no CocoaPods.

* macOS 14+ deployment target automatically enables **chained fixups** and **page-in linking** (dyld4) — fixups applied lazily on page fault, not all at once

* Swift globals/statics are initialized lazily (no `+load`, no `__attribute__((constructor))`)

* Small class count (\~15 classes) means minimal rebase/bind work

* **Estimated pre-main time: 10-40ms** — nothing to optimize

### Layer 2: applicationDidFinishLaunching — SEVERAL WINS

**Problem 1: Sequential WKWebView warm-up blocks main thread for \~200-300ms**

```swift
// Current: creates 3 WKWebViews in a tight loop
func warmUp() {
    for _ in 0..<min(maxLive, 3) {
        available.append(createWebView())  // ~70-100ms each
    }
}
```

Each `WKWebView(frame:, configuration:)` costs \~70-100ms for the first (WebContent process spawn + JavaScriptCore init), then \~30-50ms for subsequent ones sharing the same process pool.

**Problem 2: No shared WKProcessPool**

Each `createWebView()` call creates a new `WKWebViewConfiguration()` with a new *default* process pool. This means each WKWebView potentially gets its own WebContent process with duplicated overhead. A single shared `WKProcessPool` should be created once and assigned to every configuration.

**Problem 3: Pre-warmed WKWebViews are empty shells**

`warmUp()` creates WKWebViews but does NOT load HTML into them. The HTML + JS compilation only starts when `loadEditorHTML()` runs in `viewDidLoad()`. This means the expensive JS initialization (\~300-600ms) happens AFTER the window appears — the user sees a blank editor.

**Problem 4: Everything runs on main thread synchronously**

`loadHTML()` → `warmUp()` → `startObserving()` → `buildMenuBar()` all sequential. The menu bar and theme observer don't need to wait for WKWebView warm-up.

### Layer 3: WKWebView + WebKit — THE DOMINANT COST

The WKWebView process model has three separate OS processes:

* **UI Process** (your app) — WKWebView API, IPC

* **WebContent Process** (`com.apple.WebKit.WebContent`) — DOM, layout, CSS, JavaScript

* **Networking Process** — HTTP handling (not relevant for local content)

The first WKWebView creation spawns the WebContent process (~50-100ms). Subsequent WKWebViews sharing the same `WKProcessPool` skip this cost.

**Key insight**: There is NO public API to pre-warm the WebContent process independently. The only way is to create a WKWebView instance.

### Layer 4: JavaScript Bundle — 6.5MB ALL INLINED

**Problem: No bytecode caching**

JavaScriptCore's bytecode disk cache keys on *external* `<script src="...">` URLs. Kern's entire JS bundle is inlined in the HTML via `vite-plugin-singlefile`. This means JSC must lex, parse, and compile the entire codebase from scratch on **every** load — including tab rehydration.

JSC's compilation pipeline:

1. **LLInt** (interpreter) — zero startup cost besides lex + parse. All code starts here.
2. **Baseline JIT** — after \~6 invocations
3. **DFG JIT** — after \~60 invocations
4. **FTL JIT** — after thousands of invocations

For a 6.5MB HTML file with \~1.4MB of application JS (excluding lazy mermaid chunks), parse time alone is \~15-30ms, compilation \~50-100ms.

**Bundle composition** (approximate):

| Component                   | Size       | Notes                                                |
| --------------------------- | ---------- | ---------------------------------------------------- |
| ProseMirror + Milkdown core | \~500 KB   | Critical path — cannot defer                         |
| Milkdown Crepe features     | \~200 KB   | BlockEdit (47KB), Toolbar (19KB), Latex (13KB), etc. |
| Vue runtime                 | \~100 KB   | Used by BlockEdit, Toolbar, Latex features           |
| KaTeX JS                    | \~300 KB   | LaTeX rendering — only needed for `$...$` blocks     |
| KaTeX fonts (base64)        | \~1,168 KB | 59 woff/woff2/ttf files inlined as data URIs         |
| CodeMirror                  | \~200 KB   | Code block syntax highlighting                       |
| Mermaid (lazy chunks)       | \~2,800 KB | Already code-split, \~150 chunks as base64 data URIs |
| Kern app code               | \~50 KB    | bridge, search, checkbox, etc.                       |
| CSS                         | \~77 KB    | Crepe theme + KaTeX + kern.css                       |

**Key finding: Mermaid is already lazy-loaded** via dynamic import in `mermaid.ts`:

```typescript
mermaidModule = await import("mermaid");  // Only when first mermaid block rendered
```

But the ~2.8MB of lazy chunks are base64-encoded *inside* the HTML. WebKit still has to parse the HTML to find them, even though they're not executed until needed. This adds to HTML parse time.

### Layer 5: Crepe.create() — THE JS BOTTLENECK

`await crepe.create()` at \~200-400ms is the single most expensive JS operation. It:

1. Processes all registered plugins through Milkdown's dependency injection
2. Creates ProseMirror `EditorState` with \~35-45 plugins
3. Constructs `EditorView` (contenteditable div, MutationObserver, event handlers)
4. Creates NodeViews for code blocks (CodeMirror instances), list items, tables, images
5. Mounts Vue components for BlockEdit (slash menu + block handle), Toolbar, Latex tooltip

**`Crepe`** **vs** **`CrepeBuilder`**: The `Crepe` class statically imports EVERYTHING — Vue, KaTeX, CodeMirror, all features. The `CrepeBuilder` from `@milkdown/crepe/builder` is only 4.2KB and imports only the base presets (commonmark, GFM, history, clipboard). Features are added individually, enabling tree-shaking.

### Layer 6: `_drawsBackground` — PERCEIVED SPEED

When a WKWebView first appears, it shows a white background until content renders. In dark mode, this causes a visible white flash. MarkEdit prevents this using a private SPI:

```swift
webView.setValue(false, forKey: "drawsBackground")
```

This makes the WKWebView transparent until the HTML `<body>` background renders, eliminating the flash. Combined with `@media (prefers-color-scheme: dark)` CSS, the transition is seamless.

## Optimization Plan — Ranked by Impact

### Tier 1: High Impact (estimated 200-500ms savings)

#### 1A. Pre-load HTML into warm-up WKWebView

**Current**: `warmUp()` creates 3 empty WKWebViews. HTML only loads when a document opens.
**Proposed**: Load HTML into at least 1 WKWebView during warm-up so JS is already compiled and `crepe.create()` is already complete before the first document opens.

```
BEFORE: app launch → create 3 empty WKWebViews → user opens file → load HTML → parse JS → crepe.create() → setMarkdown()
AFTER:  app launch → create 1 WKWebView + load HTML + crepe.create() → user opens file → setMarkdown()
```

The warm WKWebView would have a fully initialized Milkdown editor with empty content. When a document opens, we just call `setMarkdown(content)` — which is \~50-200ms instead of \~500-800ms.

**Complication**: Need to detect when the pre-loaded editor is "ready" before dequeuing it. Add a `isEditorReady` flag to the WKWebView (or track it in the pool). If the user opens a file before the pre-loaded editor finishes initializing, fall back to the current behavior.

**Estimated savings: 300-600ms** on first document open.

#### 1B. Warm only 1 WKWebView synchronously, defer rest

**Current**: Creates 3 WKWebViews blocking main thread (\~200-300ms).
**Proposed**: Create 1 immediately (for first document), defer remaining 2 to after first frame.

```swift
func warmUp() {
    available.append(createWebView())  // Just 1 for immediate use

    DispatchQueue.main.async { [self] in
        for _ in 0..<2 {
            available.append(createWebView())
        }
    }
}
```

**Estimated savings: 100-200ms** off main thread blocking.

#### 1C. Drop LaTeX feature (if not needed for v1)

LaTeX (KaTeX) adds \~1.4MB to the bundle:

* KaTeX JS: \~300 KB

* KaTeX fonts: \~1,168 KB (base64 woff/woff2/ttf)

* KaTeX CSS: \~25 KB

* Latex feature Vue component: \~13 KB

This code is parsed even though it may never be used. Dropping it reduces HTML from 6.5MB to \~5.1MB.

**If LaTeX IS needed**: Consider lazy-loading it like Mermaid — only import KaTeX when a `$...$` block is first encountered.

**Estimated savings: 30-80ms** parse time reduction.

### Tier 2: Medium Impact (estimated 50-200ms savings)

#### 2A. Shared WKProcessPool

**Current**: Each `createWebView()` gets a default process pool.
**Proposed**: Single shared pool.

```swift
private let processPool = WKProcessPool()

func createWebView() -> WKWebView {
    let config = WKWebViewConfiguration()
    config.processPool = processPool  // ← add this
    // ... rest unchanged
}
```

This ensures all WKWebViews share one WebContent process. The 2nd and 3rd WKWebView creation drops from \~70-100ms to \~30-50ms each.

**Estimated savings: 40-100ms** (off warm-up time for WKWebViews 2 and 3).

#### 2B. Externalize JS for bytecode caching

**Current**: All JS is inlined in HTML. JSC re-parses and re-compiles on every load.
**Proposed**: Serve JS as a separate file via `WKURLSchemeHandler`.

```html
<!-- Instead of inline <script>...</script> -->
<script src="kern://editor/app.js"></script>
```

The `EditorSchemeHandler` would serve two files:

* `kern://editor/index.html` — minimal HTML shell

* `kern://editor/app.js` — the bundled JS

JSC's bytecode disk cache keys on the source URL of external scripts. If the cache works with custom schemes (unconfirmed — needs testing), subsequent loads and rehydrations would skip JS compilation entirely.

**Estimated savings: 50-150ms** per load/rehydration (if bytecode caching works).
**Risk**: Needs verification that JSC caches custom scheme URLs. If not, savings = 0.
**Build change**: Replace `vite-plugin-singlefile` with a custom plugin that outputs separate HTML + JS, both served via scheme handler.

#### 2C. Switch from `Crepe` to `CrepeBuilder`

**Current**: `import { Crepe } from "@milkdown/crepe"` pulls in ALL features statically.
**Proposed**: Use `CrepeBuilder` with selective feature imports.

```typescript
import { CrepeBuilder } from "@milkdown/crepe/builder";
import { CodeMirror } from "@milkdown/crepe/feature/code-mirror";
import { BlockEdit } from "@milkdown/crepe/feature/block-edit";
import { ListItem } from "@milkdown/crepe/feature/list-item";
import { LinkTooltip } from "@milkdown/crepe/feature/link-tooltip";
import { Table } from "@milkdown/crepe/feature/table";
import { ImageBlock } from "@milkdown/crepe/feature/image-block";
import { Cursor } from "@milkdown/crepe/feature/cursor";
// Skip: Toolbar (native menu), Latex (not needed or lazy), Placeholder
```

Features we can skip:

* **Toolbar** — Kern uses native AppKit menu bar for formatting

* **Latex** — Can be lazy-loaded or dropped entirely

* **Placeholder** — Empty editor placeholder, minimal value

**Estimated savings**: Hard to quantify without measuring. The primary benefit is enabling Vite tree-shaking to remove unused feature code. Could save 50-200KB of JS + associated CSS.

#### 2D. Parallel file read and WKWebView init

**Current**: `loadHTML()` runs first (blocking), then `warmUp()` runs.
**Proposed**: Move `loadHTML()` to before `app.run()` in `main.swift`, or run it on a background thread.

Since `loadHTML()` is pure file I/O (reading 6.5MB from bundle) and `createWebView()` is main-thread-only (WebKit requirement), these can't truly run in parallel. But moving `loadHTML()` earlier (into `main.swift` before the run loop) means the data is ready sooner.

```swift
// main.swift
let app = NSApplication.shared
let dc = KernDocumentController()
let delegate = AppDelegate()
app.delegate = delegate

// Pre-cache HTML bytes before run loop starts
EditorReusePool.shared.schemeHandler.loadHTML()

app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
```

**Estimated savings: 5-20ms** (overlaps with other pre-main work).

### Tier 3: Low Impact / Polish (estimated 5-50ms savings)

#### 3A. `_drawsBackground = false` to eliminate white flash

```swift
func createWebView() -> WKWebView {
    // ...
    let webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    // ...
}
```

Plus CSS for instant correct background:

```css
body {
    background: #ffffff;
}
@media (prefers-color-scheme: dark) {
    body { background: #1e1e1e; }
}
```

Not a real time savings, but eliminates the perceived flash that makes the app feel slower. MarkEdit uses this successfully and it passes App Store review.

#### 3B. Defer non-critical JS initialization

Move these AFTER posting `editorReady`:

```typescript
await crepe.create();

// Post editorReady FIRST so Swift can start setMarkdown()
window.webkit?.messageHandlers.nativeBridge.postMessage({ type: "editorReady" });

// Then do non-critical init
requestIdleCallback(() => {
    initSearch(crepe);        // Only needed on Cmd+F
    initInlineNested();       // Only needed when nested checkboxes exist
    initCheckboxIcons();      // Visual polish, can be slightly delayed
});
```

**Estimated savings: 10-20ms** off time-to-editable.

#### 3C. Defer `AppearanceManager.startObserving()`

Theme observation doesn't need to happen at launch. The theme is applied in `editorReady()` anyway. Move to after first frame.

**Estimated savings: 1-2ms** (negligible, but cleaner).

#### 3D. Lazy-load search bar DOM

The search bar HTML is created and inserted into the DOM at init time but hidden with `display: none`. Could defer creation until first `Cmd+F`:

```typescript
// Instead of creating DOM on init, create on first use
let searchBarCreated = false;
function ensureSearchBar() {
    if (!searchBarCreated) {
        createSearchBarDOM();
        searchBarCreated = true;
    }
}
```

**Estimated savings: 2-5ms**.

### Tier 4: Requires Investigation

#### 4A. Externalize mermaid chunks from HTML

The \~150 mermaid lazy chunks are base64-encoded inside the HTML (\~3.7MB with base64 overhead). Even though they're not executed on load, WebKit must parse the HTML to find them.

**Approach**: Serve mermaid chunks as separate files via `WKURLSchemeHandler`:

* Store each chunk as a file in the app bundle

* Scheme handler serves `kern://editor/chunks/chunk-XXXX.js`

* HTML drops from 6.5MB to \~2.8MB

**Estimated savings: 10-30ms** off HTML parse time. Higher savings when combined with 1C (drop LaTeX).

**Build complexity**: Requires replacing `vite-plugin-singlefile` with a custom build that keeps the main app code inlined but serves lazy chunks externally.

#### 4B. Order files for binary layout

Instructs the linker to group startup-critical functions together, reducing page faults. Used by Facebook, Uber, DoorDash for iOS.

**Expected impact for Kern: <5ms.** Kern's binary is small. This technique benefits large binaries with thousands of symbols scattered across many pages. Not worth the build complexity for Kern.

#### 4C. `XCTApplicationLaunchMetric` for regression testing

Add a performance test to catch launch time regressions:

```swift
func testLaunchPerformance() throws {
    measure(metrics: [XCTApplicationLaunchMetric()]) {
        XCUIApplication().launch()
    }
}
```

Not an optimization itself, but prevents future regressions.

## Measurement Plan

Before implementing any changes, establish baselines:

### 1. Instruments App Launch Template

* Profile a Release build (not Debug)

* Reboot before cold-start measurement

* Measure 5+ times, report median

* Key metrics: time-to-first-frame, time-to-interactive

### 2. Manual Timing Points

Add `CFAbsoluteTimeGetCurrent()` markers at key points:

```swift
// main.swift
let t0 = CFAbsoluteTimeGetCurrent()

// AppDelegate
let t1 = CFAbsoluteTimeGetCurrent()  // Start of didFinishLaunching
// ... after loadHTML
let t2 = CFAbsoluteTimeGetCurrent()
// ... after warmUp
let t3 = CFAbsoluteTimeGetCurrent()
// ... after buildMenuBar
let t4 = CFAbsoluteTimeGetCurrent()
```

```typescript
// main.ts
const t0 = performance.now();
// ... after new Crepe()
const t1 = performance.now();
// ... after crepe.create()
const t2 = performance.now();
// ... after all init
const t3 = performance.now();
console.log(`[Kern Perf] Crepe constructor: ${t1-t0}ms, create(): ${t2-t1}ms, post-init: ${t3-t2}ms`);
```

### 3. End-to-End

```bash
# Time from launch to editor ready
time open -a Kern /path/to/test.md
# Plus: add NSLog timestamp when editorReady fires in Swift
```

## Implementation Priority

Based on impact/effort ratio, recommended order:

| # | Change                                     | Impact    | Effort     | Dependencies                               |
| - | ------------------------------------------ | --------- | ---------- | ------------------------------------------ |
| 1 | Shared WKProcessPool                       | 40-100ms  | 2 lines    | None                                       |
| 2 | Warm only 1 WKWebView sync, defer rest     | 100-200ms | 5 lines    | None                                       |
| 3 | `_drawsBackground = false`                 | Perceived | 1 line     | None                                       |
| 4 | Pre-load HTML into warm-up WKWebView       | 300-600ms | \~30 lines | Needs ready detection                      |
| 5 | Move editorReady before non-critical inits | 10-20ms   | 5 lines    | None                                       |
| 6 | Drop LaTeX/Toolbar, use CrepeBuilder       | 30-200ms  | \~50 lines | Verify features still work                 |
| 7 | Externalize JS for bytecode caching        | 50-150ms  | \~40 lines | Needs testing if JSC caches custom schemes |
| 8 | Reduce HTML size (externalize mermaid)     | 10-30ms   | High       | Build system changes                       |

**Quick wins (items 1-3)**: Minimal code change, no risk. Do first.
**Big win (item 4)**: Most impactful single change. Requires careful pool management — the pre-loaded editor must be "ready" before it's assigned to a document, with fallback.
**Medium wins (items 5-7)**: Good returns, moderate effort.
**Complex (item 8)**: High effort, requires replacing the single-file build system. Save for later.

## Combined Estimated Impact

| Scenario                   | Time to Editable Content |
| -------------------------- | ------------------------ |
| Current                    | \~600-1200ms             |
| Quick wins only (1-3)      | \~450-900ms              |
| + Pre-loaded WKWebView (4) | \~150-400ms              |
| + All optimizations (1-8)  | \~100-300ms              |

The biggest single win is pre-loading the editor HTML into a warm-up WKWebView. Combined with deferred warm-up and shared process pool, Kern could reach **sub-200ms** time-to-editable content in the common case (warm cache, Apple Silicon).

## References

* [WebKit Bytecode Format](https://webkit.org/blog/9329/a-new-bytecode-format-for-javascriptcore/) — JSC disk caching

* [JavaScriptCore Architecture](https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html) — JIT tiers

* [WWDC19 Optimizing App Launch](https://developer.apple.com/videos/play/wwdc2019/423/) — App launch phases

* [WWDC22 Link Fast](https://developer.apple.com/videos/play/wwdc2022/110362/) — Page-in linking

* [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper) — Pre-warming benchmarks

* [Emerge Tools: Order Files](https://www.emergetools.com/blog/posts/FasterAppStartupOrderFiles) — Binary layout

* [DoorDash: 60% Launch Reduction](https://doordash.engineering/2023/01/31/how-we-reduced-our-ios-app-launch-time-by-60/)

* MarkEdit source checkout — `_drawsBackground`, pool patterns

* [Milkdown CrepeBuilder](https://github.com/milkdown/milkdown) — Selective feature loading

***

## Deep Research (Feb 2026) — New Findings

This section synthesizes findings from deep research across 6 parallel investigations: WKWebView internals, MarkEdit source analysis, app launch case studies, Milkdown/ProseMirror performance, measurement tooling, and Vite build splitting.

### CORRECTION: WKProcessPool Does NOT Share WebContent Processes

**Our original plan item 2A is based on outdated information.** The claim that sharing a `WKProcessPool` makes WKWebViews share a WebContent process is **no longer true on macOS 10.15+**.

Since macOS 10.15 Catalina / iOS 13, each WKWebView gets its **own** WebContent process regardless of pool configuration. The sharing threshold behavior was eliminated. A shared `WKProcessPool` still provides:

* Shared cookies and session storage

* Shared Networking process

* Reduced pool creation overhead (\~5-10ms per pool)

But it does **not** reduce memory usage or process spawn costs for subsequent WKWebViews.

**Impact**: Our estimated 40-100ms savings from shared WKProcessPool should be revised to **5-10ms** (avoiding redundant pool instantiation only). The first WKWebView still spawns a process (\~70-100ms), and each subsequent WKWebView spawns its own process (\~50-80ms each), regardless of pool sharing.

**Source**: [SegmentFault: Things about WKWebView in iOS container](https://segmentfault.com/a/1190000040652799/en), [Apple Documentation: WKProcessPool](https://developer.apple.com/documentation/webkit/wkprocesspool)

### No Public WKWebView Pre-Warming API (Confirmed)

As of macOS 15 Sequoia (WWDC 2024), Apple has **not** introduced any public API for pre-warming the WebContent process. WebKit has an internal `_WKProcessPoolConfiguration.prewarmedProcessCountLimitForTesting` but it's private SPI for testing only.

The only way to trigger WebContent process creation is to instantiate a `WKWebView`. This is confirmed by WebKit source and multiple open-source pre-warming libraries.

**Source**: [WebKit Bug 196451](https://bugs.webkit.org/show_bug.cgi?id=196451), [WebViewWarmUper](https://github.com/bernikovich/WebViewWarmUper), [Apple Developer Forums](https://developer.apple.com/forums/thread/733774)

### JSC Bytecode Caching — Source Code Analysis

Investigated the WebKit source to determine if JSC's bytecode disk cache works with custom URL schemes:

1. **No URL scheme filtering**: The `CodeCache.h` header shows caching operates at the `SourceCodeKey` level (URL + content hash). No scheme checks exclude custom protocols.
2. **Inline scripts confirmed NOT cached**: `fetchFromDisk` returns `nullptr` for `UnlinkedEvalCodeBlock`. Inline `<script>` blocks lack a stable URL for cache keys.
3. **Network Process involvement unclear**: The bytecode cache is managed by the Network Process. Resources via `WKURLSchemeHandler` bypass the standard network stack — whether the cache pipeline is invoked for scheme handler responses is undocumented.
4. **WebKit has an internal AOTC project** (`webkit-aotc`) that saves JSC bytecode to `.bytecode` sidecar files, confirming the format is serializable — but this is not exposed as a public API.

**Conclusion**: Externalizing JS to `kern://editor/app.js` is worth testing empirically. The architecture doesn't prevent custom scheme caching, but it's not confirmed to work either.

**Source**: [WebKit CodeCache.h](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/CodeCache.h), [webkit-aotc project](https://github.com/ispras/webkit-aotc)

### `_drawsBackground` Status (Feb 2026)

* **Still private SPI** on WKWebView. Not made public in macOS 14 or 15.

* **App Store risk is real but inconsistent**. MarkEdit uses it and ships on the App Store. Tauri/Wry explicitly warns against it.

* **MarkEdit's approach**: Subclasses `WKWebViewConfiguration` and overrides `_drawsBackground()` as an `@objc` method returning `false`. This is cleaner than KVC `setValue(false, forKey:)`.

* **`underPageBackgroundColor`** **(macOS 12+)** is NOT equivalent — only controls scroll-bounce area, not initial load background.

* **Best non-private-API alternative**: Match CSS `body { background }` to window color via `@media (prefers-color-scheme: dark)`. Not as seamless but eliminates most of the flash.

**Source**: [WebKit Bug 151054](https://bugs.webkit.org/show_bug.cgi?id=151054), [FB7539179](https://github.com/feedback-assistant/reports/issues/81)

### MarkEdit Reference Patterns (NEW)

Deep analysis of MarkEdit's source reveals several cold start optimizations Kern hasn't implemented:

#### 1. Accessibility Framework Swizzle

MarkEdit's `AppHacks.swift` swizzles `loadAXBundles` to load the Accessibility framework on a background thread instead of the main thread during launch. Comment: "Performance regression, there's a good chance to hang at launch."

```swift
// Moves AX framework loading to background thread
NSObject.swizzleAccessibilityBundlesOnce  // in Application.main(), before NSApplicationMain
```

This avoids a potential **50-200ms hang** during accessibility framework initialization. **Kern should evaluate if AX loading affects our launch time.**

#### 2. Spell Checker Pre-Warming

```swift
NSSpellChecker.shared.checkSpelling(of: "warmup", startingAt: 0)
```

Called during pool warm-up to pre-initialize the spell checker. First invocation of `NSSpellChecker` is expensive (loads dictionaries). Pre-warming avoids lazy init delay when user starts typing. Multiple swizzles in `NSSpellChecker+Extension.swift` control inline completion, correction indicators, and avoid macOS 14+ hangs.

#### 3. Deferred Pool Warm-Up (1 Second Delay!)

Surprisingly, MarkEdit delays pool warm-up by **1 full second** after app launch:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    EditorReusePool.shared.warmUp()
}
```

This ensures the first frame renders immediately with zero WKWebView creation blocking. The warm-up happens in the background after the UI is fully responsive. **Tradeoff**: First document open is slightly slower if opened within 1 second of launch (rare for file-based editor).

#### 4. Code Splitting via Vite + EditorChunkLoader

MarkEdit does NOT use `vite-plugin-singlefile`. Instead, it uses standard Vite code splitting:

```typescript
// vite.config.mts
{
  base: command === 'build' ? '/chunk-loader/' : '',
  build: {
    assetsDir: 'chunks',
    chunkSizeWarningLimit: 768,
  }
}
```

A custom `WKURLSchemeHandler` named `EditorChunkLoader` serves JS chunks from the app bundle via `chunk-loader://chunks/chunk-XXXX.js`. This enables:

* **Smaller HTML**: Only the entry point is loaded initially

* **On-demand chunk loading**: Lazy chunks load via native scheme handler

* **Potential bytecode caching**: External `<script src>` enables JSC disk cache

**This is the exact pattern we need for Kern.** It's proven in a shipping App Store app.

#### 5. HTML Assembly on Background Thread

```swift
DispatchQueue.global(qos: .userInitiated).async {
    let html = [config, styles, customizations].joined(separator: "\n")
    DispatchQueue.main.async {
        webView.loadHTMLString(html, baseURL: EditorWebView.baseURL)
    }
}
```

HTML string assembly happens off the main thread. Only the final `loadHTMLString` call (which must be main-thread) blocks.

#### 6. NSMenu Crash Workaround

Swizzles `_isUpdatedExcludingContentTypes:` on `NSMenu` to prevent "Populating a menu window that is already visible" crash and associated hang. Applied before `NSApplicationMain` via `Application.main()`.

**Key file paths** (for reference):

* `MarkEditMac/Sources/Main/Application/Application.swift`

* `MarkEditMac/Sources/Main/AppHacks.swift`

* `MarkEditMac/Sources/Editor/EditorChunkLoader.swift`

* `MarkEditKit/Sources/Extensions/WKWebViewConfiguration+Extension.swift`

### Milkdown CrepeBuilder — Deep Analysis

#### Why `Crepe` bundles everything

`Crepe` extends `CrepeBuilder`. The `loadFeature()` function in `packages/crepe/src/feature/loader.ts` uses **static imports** (not dynamic). All 10 feature modules are imported at the top of the file; the function is a switch routing to pre-imported functions. Vite/Rollup cannot tree-shake conditional runtime checks on statically imported modules.

Even setting `features: { [CrepeFeature.CodeMirror]: false }` does NOT remove CodeMirror from the bundle.

#### CrepeBuilder solves this

```typescript
import { CrepeBuilder } from '@milkdown/crepe/builder'
import { blockEdit } from '@milkdown/crepe/feature/block-edit'

const builder = new CrepeBuilder({ root: '#editor', defaultValue: '' })
builder.addFeature(blockEdit)
await builder.create()
```

Features not imported never enter the bundle. Issue [#1533](https://github.com/Milkdown/milkdown/issues/1533) documents that CodeMirror pulls in **all language definitions** (including Brainfuck) — the single largest bundle bloat source. Users generating \~150 lazy-loaded chunks.

#### Lazy feature loading after `create()` — NOT supported

No officially supported way to add Milkdown features after `crepe.create()`. ProseMirror's `EditorState.reconfigure()` works for keymaps/decorations but NOT for plugins that define schema nodes (which CodeMirror, KaTeX, and Tables all do).

**Practical implication**: Schema nodes must be registered at creation. But the heavy rendering libraries (CodeMirror language packs, KaTeX engine) could potentially use dynamic imports while keeping schema stubs registered from the start.

#### No performance improvements in Milkdown 7.15-7.18

Reviewed full CHANGELOG. Changes are bug fixes, features, dependency upgrades. Notable: 7.15.2 replaced lodash with lodash-es (better tree-shaking), 7.17.2 upgraded ProseMirror packages.

### Vite Build Splitting for WKWebView

#### The `type="module"` problem

Vite outputs `<script type="module">` by default. WKWebView blocks ES module scripts loaded from `file://` URLs due to CORS restrictions. Three solutions:

1. **WKURLSchemeHandler (recommended)**: Serve via custom scheme like `kern://` or `chunk-loader://`. MarkEdit uses this approach. No private API needed.

2. **`allowFileAccessFromFileURLs`** **(private)**: `config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")` — works but is private API.

3. **IIFE format**: Configure Vite with `rollupOptions.output.format: 'iife'` + `inlineDynamicImports: true`. Avoids modules entirely but prevents code splitting.

#### Recommended Vite config for Kern (replacing vite-plugin-singlefile)

```typescript
// vite.config.ts
export default defineConfig({
  base: '/kern-editor/',  // Matches scheme handler base path
  build: {
    target: 'safari17',
    assetsInlineLimit: 0,  // Don't base64-encode fonts/assets
    assetsDir: 'chunks',
    rollupOptions: {
      output: {
        assetFileNames: 'chunks/[name]-[hash][extname]',
        chunkFileNames: 'chunks/[name]-[hash].js',
        entryFileNames: 'app-[hash].js',
      },
    },
  },
})
```

Combined with a `WKURLSchemeHandler` that serves:

* `kern://editor/index.html` → entry HTML

* `kern://editor/app-[hash].js` → main JS bundle

* `kern://editor/chunks/*` → lazy chunks, fonts, CSS

**Estimated HTML size reduction**: 6.2MB → \~1.5-2MB (mermaid chunks + KaTeX fonts externalized).

#### `_registerURLSchemeAsSecure:` — Private API, NOT App Store safe

A technique exists to make WKWebView treat custom schemes as secure (`WKProcessPool._registerURLSchemeAsSecure:`). This enables fetch() and ES modules from custom schemes. However, the article explicitly warns it uses private API and is **not App Store safe**.

### Launch Optimization Case Studies

#### VSCode (Electron)

VSCode team actively working on lazy code loading (Issue [#164068](https://github.com/microsoft/vscode/issues/164068)). Key findings:

* Moving non-critical features to `LifecyclePhase.Eventually` speeds up startup

* Extension bundling reduced activation times by **50%** (Azure Account: 6.2MB → 840KB)

* Docker extension: cold activation from **20 seconds to 2 seconds** via bundling

* Migrating from AMD to ESM for proper code splitting is a "large multi-month project"

#### Tauri 2.0

Achieves **<200ms startup** on macOS (simple apps: <200ms, \~15MB memory). Key: uses native WKWebView (no bundled browser), Rust backend compiles to native binary. Known issue: Windows cold start can be 20+ seconds due to WebView2 initialization.

#### DoorDash (60% Launch Reduction)

Techniques applicable to Kern:

* **Startup task dependency graph**: Model all init tasks as a DAG, execute in optimal order

* **Lazy initialization**: Defer everything not needed for first frame

* **Binary size reduction**: Smaller binary = fewer page faults = faster pre-main

#### Slack/Notion (Electron)

Slack engineering blog details how they improved startup:

* V8 code caching (equivalent of our JSC bytecode cache investigation)

* Deferred loading of non-visible UI

* Skeleton screens during web content loading

### Measurement Tooling Recommendations

#### Swift-Side Timing

Use `mach_absolute_time()` or `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` for launch timing:

```swift
import os

let signposter = OSSignposter(subsystem: "com.kern.app", category: "Launch")

// In main.swift
let launchState = signposter.beginInterval("AppLaunch")

// After WKWebView warm-up
signposter.emitEvent("WarmUpComplete", id: launchState)

// After editorReady
signposter.endInterval("AppLaunch", launchState)
```

**NOT** `CFAbsoluteTimeGetCurrent()` — it's not monotonic and can be affected by NTP adjustments. Our existing plan should be updated.

| API                                       | Monotonic | Overhead     | Best For                        |
| ----------------------------------------- | --------- | ------------ | ------------------------------- |
| `mach_absolute_time`                      | Yes       | Lowest       | Tight loops                     |
| `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` | Yes       | Very low     | General timing                  |
| `ContinuousClock.now` (Swift 5.9+)        | Yes       | \~250ns/call | Convenience                     |
| `CFAbsoluteTimeGetCurrent`                | **No**    | Low          | **Don't use for launch timing** |

#### JS-Side Timing

`performance.now()` in WKWebView with `loadHTMLString` has **reduced precision** (~100µs) because the page can't be cross-origin isolated. Adequate for measuring ~200-400ms operations like `crepe.create()` but not for sub-millisecond measurements.

**Paint Timing API**: Supported in Safari 14.1+ (WebKit). Can use `PerformanceObserver` for `first-contentful-paint`:

```typescript
const observer = new PerformanceObserver((list) => {
    for (const entry of list.getEntries()) {
        console.log(`[Kern Perf] ${entry.name}: ${entry.startTime}ms`);
    }
});
observer.observe({ type: 'paint', buffered: true });
```

**Navigation Timing**: Known WebKit bug (#186919) — data can be corrupt in WKWebView. Don't rely on it.

#### Instruments Integration

Use `OSSignposter` (macOS 12+) instead of the legacy `os_signpost`. Intervals appear in Instruments' Points of Interest track:

```swift
import os

private let signposter = OSSignposter(subsystem: "com.kern.app", category: "Launch")

func applicationDidFinishLaunching(_ notification: Notification) {
    let state = signposter.beginInterval("didFinishLaunching")
    // ... setup work ...
    signposter.endInterval("didFinishLaunching", state)
}
```

#### `DYLD_PRINT_STATISTICS`

Still works on macOS 14/15 for profiling pre-main time. Set as environment variable in Xcode scheme:

```
DYLD_PRINT_STATISTICS=1
```

Output includes: total time, dylib loading, rebase/binding, ObjC setup, initializer time.

### WebKit Internal Improvements (Automatic Benefits)

Safari 17.4+ / macOS 14.4+ includes these JSC performance improvements that benefit all WKWebView apps:

1. **Lazy CodeBlock destruction**: Previously eagerly destroyed dead CodeBlocks + JIT code during GC. Now deferred to idle time — reduces GC pauses during initialization.
2. **Call IC redesign**: Integrated two Call IC architectures across JIT tiers. Lower tiers avoid JIT code generation overhead.
3. **IOSurface cache increase**: 64MB → 256MB, \~2.7x better cache hit rate (\~80%), \~0.7% Speedometer improvement.

These improvements are free — Kern gets them automatically on macOS 14.4+.

**Source**: [WebKit: Optimizing for Speedometer 3.0](https://webkit.org/blog/15249/)

### WebKit Process Caches

Matt Jacobson's 2024 blog documents two internal caches:

1. **WebProcessCache**: Stores WebContent processes for 30 minutes after tabs close, enabling reuse for same-domain navigation. Clears after 5 minutes of app inactivity.
2. **Back-Forward Cache**: Retains previous pages as suspended pages for up to 30 minutes.

For testing, these can be disabled:

```bash
defaults write -g WebProcessCacheCachedProcessLifetimeInSeconds -float 1.0
```

**Source**: [Disabling WebKit's process caches — Matt Jacobson (Jan 2024)](https://mjacobson.net/blog/2024-01-WebKit-cache.html)

## Updated Implementation Priority

Based on new findings, the priority order changes significantly:

| #  | Change                                                 | Impact                  | Effort         | Notes                                                                                                      |
| -- | ------------------------------------------------------ | ----------------------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| 1  | **Pre-load HTML into warm-up WKWebView**               | 300-600ms               | \~30 lines     | Still the biggest single win. MarkEdit does `_ = self.webView` in init() to trigger immediate pre-loading. |
| 2  | **Warm only 1 WKWebView sync, defer rest**             | 100-200ms               | 5 lines        | MarkEdit goes further: defers ALL warm-up by 1 second. Consider the same.                                  |
| 3  | **`_drawsBackground = false`**                         | Perceived               | 3 lines        | Use MarkEdit's subclass pattern. Eliminates white/dark flash.                                              |
| 4  | **Defer non-critical JS init**                         | 10-20ms                 | 5 lines        | Move search, inline-nested, checkbox icons to `requestIdleCallback`.                                       |
| 5  | **Switch to CrepeBuilder**                             | 30-200ms                | \~50 lines     | Drops unused KaTeX, Toolbar, Placeholder. Biggest bundle reduction.                                        |
| 6  | **Replace vite-plugin-singlefile with code splitting** | 30-80ms                 | \~80 lines     | Follow MarkEdit's EditorChunkLoader pattern. HTML drops from 6.2MB to \~1.5MB.                             |
| 7  | **Externalize JS for bytecode caching**                | 50-150ms                | Included in #6 | Comes free with code splitting. External `<script src>` enables JSC cache.                                 |
| 8  | ~~Shared WKProcessPool~~                               | ~~40-100ms~~ **5-10ms** | 2 lines        | **Downgraded**: Doesn't share processes on macOS 10.15+. Still worth doing for cleanliness.                |
| 9  | **AX framework background loading**                    | 0-200ms                 | \~20 lines     | Investigate if AX init affects Kern's launch. Copy MarkEdit's swizzle if so.                               |
| 10 | **Spell checker pre-warming**                          | 0-50ms                  | 1 line         | `NSSpellChecker.shared.checkSpelling(of: "warmup", startingAt: 0)`                                         |
| 11 | **OSSignposter instrumentation**                       | 0ms (tooling)           | \~15 lines     | Replace CFAbsoluteTimeGetCurrent with proper Instruments integration.                                      |

### Removed / Downgraded Items

* **WKProcessPool sharing** (was #1): Downgraded from 40-100ms to 5-10ms impact. Still do it, but it's cosmetic.

* **Binary layout ordering**: Confirmed <5ms impact for small apps. Not worth the complexity.

* **ProseMirror lazy rendering**: Confirmed impossible — intentionally not implemented by ProseMirror's author.

### Updated Combined Impact Estimates

| Scenario                              | Time to Editable Content |
| ------------------------------------- | ------------------------ |
| Current                               | \~600-1200ms             |
| Quick wins (1-4)                      | \~200-500ms              |
| + CrepeBuilder + code splitting (5-7) | \~100-300ms              |
| + All optimizations (1-11)            | \~80-250ms               |

The biggest single win remains **pre-loading HTML into the warm-up WKWebView** (item 1). Combined with CrepeBuilder (item 5) and code splitting (item 6), Kern should reach **sub-200ms** time-to-editable on Apple Silicon with warm disk cache.

## Additional References (Feb 2026 Research)

* [Disabling WebKit Process Caches — Matt Jacobson](https://mjacobson.net/blog/2024-01-WebKit-cache.html) — Process cache behavior

* [WebKit: Optimizing for Speedometer 3.0](https://webkit.org/blog/15249/) — JSC performance improvements in Safari 17.4+

* [Tauri vs Electron (2025)](https://www.gethopp.app/blog/tauri-vs-electron) — Startup benchmarks

* [VSCode Lazy Code Loading (Issue #164068)](https://github.com/microsoft/vscode/issues/164068) — Deferred feature loading

* [DoorDash: 60% Launch Reduction](https://doordash.engineering/2023/01/31/how-we-reduced-our-ios-app-launch-time-by-60/) — Startup task DAG

* [Milkdown Issue #1533](https://github.com/Milkdown/milkdown/issues/1533) — CrepeBuilder bundle size

* [Vite/WKWebView type="module" issue](https://github.com/vitejs/vite/discussions/14485) — Module loading restrictions

* [Emerge Tools: Swift Protocol Conformance Cost](https://www.emergetools.com/blog/posts/SwiftProtocolConformance) — Swift-specific startup costs

* [Swift's Native Clocks Are Very Inefficient](https://wadetregaskis.com/swifts-native-clocks-are-very-inefficient/) — Timing API benchmarks

* [WebKit Bug 228137](https://bugs.webkit.org/show_bug.cgi?id=228137) — Timer precision in cross-origin isolation

* [WKWebView secure custom scheme (private API)](https://dev.to/alastaircoote/getting-wkwebview-to-treat-a-custom-scheme-as-secure-3dl3) — Not App Store safe

<br />
