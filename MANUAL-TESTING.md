# Manual Testing

Items that benefit from a human pass in the running app (visual alignment, UX feel, OS integrations).

## Smoke

- [ ] `open -a Kern some.md` opens the file (no crash)
- [ ] Editing feels responsive (typing, selection, scroll)
- [ ] Cmd+S saves (file changes on disk)
- [ ] External change reload shows a toast (“File reloaded from disk”)

## WYSIWYG Core

- [ ] Headings render larger/bolder and hide leading `#` syntax
- [ ] Bullets render as bullets and hide leading `- `
- [ ] Ordered lists render as numbers and hide leading `1. `
- [ ] Inline bold/italic/code render correctly and hide syntax markers

## Tasks / Checkboxes

- [ ] `- [ ] task` renders as a bulleted task; click toggles checkbox
- [ ] `- [x] task` renders checked with appropriate styling
- [ ] `[ ] standalone` renders as a standalone checkbox (no bullet)
- [ ] Checkbox hit target feels reasonable (not tiny); alignment looks centered

## Tables (GFM)

- [ ] A basic GFM table renders as a grid (header styling distinct)
- [ ] Caret navigation inside cells feels sane (arrow keys, selection)
- [ ] Export preserves a valid GFM table

## Code Blocks

- [ ] Code block renders in monospaced font with distinct background
- [ ] Copy button appears when caret is inside a code block
- [ ] Copy copies the full code block contents (not the surrounding document)

## Find / Replace

- [ ] Cmd+F opens Find panel and finds matches
- [ ] Cmd+Shift+H opens Find and Replace
- [ ] “Use Selection for Find” works

