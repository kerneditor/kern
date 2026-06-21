# Kern design system exploration

This note captures the current appearance/product-direction work for Kern’s
native TextKit editor. It is deliberately implementation-facing: the goal is to
make visual experiments reproducible without locking the product into a final
brand direction too early.

## Inputs reviewed

- Notion page styling patterns:
  - a normal page has a readable centered content area;
  - a desktop/web page can be widened through a Full width page option;
  - callouts, table headers, dividers, page icons, covers, and columns are
    product-level blocks rather than plain Markdown primitives.
- Markdown/editor precedent:
  - Markdown Monster exposes editor max-width as a setting so wide displays can
    keep a manageable column without forcing that layout on every user.
  - Obsidian and other note apps treat “readable line length” as a preference,
    not as an unconditional product stance.
- macOS settings precedent:
  - user-facing choice controls should show the current selection;
  - dependent controls should be disabled when they do not apply.
- Wonder visual system references:
  - Wonder editorial reference style: monochrome editorial, cream/off-white surfaces,
    light borders, quiet typography;
  - Wonder UI tokens: neutral, brand, secondary, success, warning, error, and info
    tonal ramps.

## Product decision implemented

Kern now treats Notion-style centering as a preference instead of forcing it:

- Default: **Full width**.
- Optional: **Centered readable**.
- Centered-readable max width:
  - default: 760 px;
  - range: 560 px to 1400 px;
  - preferences UI rounds slider values to 20 px increments.

This keeps the app suitable for both writing-focused narrow columns and
power-user full-screen editing.

## Theme candidates added

Two Wonder-derived candidates were added for A/B testing:

- **Wonder Light**
  - off-white editor surface;
  - cream code/callout/sidebar surfaces;
  - near-black primary text;
  - restrained blue/teal/status accents from Wonder token ramps.
- **Wonder Graphite**
  - deep neutral background;
  - graphite code and inline-code surfaces;
  - pale text;
  - softened Wonder token accents for syntax, links, and callouts.

These are candidates, not a final Kern identity. The likely final direction is a
Kern-specific hybrid: editorial neutrals from Wonder, stronger native-macOS
restraint, and a small number of memorable accent rules for WYSIWYG affordances.

## Current visual QA artifact path

Generate theme/layout comparison screenshots with:

```bash
xcodegen generate
xcodebuild \
  -project KernTextKit.xcodeproj \
  -scheme KernTextKitDesignPreviews \
  -derivedDataPath .derived-data/tests \
  -only-testing:KernTextKitTests/NativeEditorDesignPreviewTests/testCaptureThemeAndWidthComparisonPreviews \
  test
```

The test writes PNGs under `test-results/design-previews/<timestamp>/`.

The current comparison set covers:

- Kern Paper centered at 860 px;
- Kern Graphite centered at 860 px;
- Kern Ice centered at 860 px;
- Kern Ink centered at 860 px;
- Kern Wonder centered at 860 px.

Each scenario captures a top-of-document editor view, a rich-block editor slice,
and the settings window preview.

## Next design questions

1. Should the eventual default be Kern Light/Dark, Wonder-derived, or a new
   “Kern Porcelain / Kern Graphite” pair?
2. Should callouts stay colorful by semantic type, or should the default theme
   use mostly monochrome callouts with a small accent stripe?
3. Should inline code use a pill-like background, or a subtler flat background
   aligned to the line fragment?
4. Should tables look more like Notion’s grid/table blocks or more like
   developer documentation tables?
5. Should Mermaid/math blocks share code-block chrome or have their own native
   block styling?
