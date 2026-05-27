# Kern social demo storyboard

Format: 24 seconds, muted-first, caption-led. The core visual is an actual Kern screen recording; Remotion adds positioning copy around the live app footage.

## Message hierarchy

1. Kern is true WYSIWYG Markdown: the rendered document is the editing surface.
2. Kern is a fully native macOS app built with Swift, AppKit, and TextKit.
3. Kern does not use Electron, Tauri, or any WebView/browser editor shell.
4. Kern keeps normal local Markdown files portable while making them feel like native Mac documents.
5. Kern is open source and focused on local writing.

## Timeline

- 0-5.2s: Hook — rendered Markdown opens directly, no split preview.
- 5.2-10.2s: TextKit-native editing primitives — selection, typing, scrolling, layout.
- 10.2-15.4s: No Electron, no Tauri, no WebView.
- 15.4-20.1s: Plain Markdown on disk, native document feel.
- 20.1-24s: Open source Mac-first Markdown editor.

## Current implementation note

The source recording is an actual Kern session opening a Markdown file, editing rendered text in place, and toggling rendered task checkboxes. Remotion wraps that footage with native-positioning callouts for social posting.
