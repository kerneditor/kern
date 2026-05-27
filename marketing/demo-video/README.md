# Kern demo video

Remotion source for the short Kern social demo video.

## What it renders

- `KernTwitterDemoLandscape`: 1920x1080, 30fps, 24 seconds.
- `KernTwitterDemoPortrait`: 1080x1350, 30fps, 24 seconds.

The composition is caption-led and designed for muted social autoplay. It uses an actual Kern app recording as the core footage, then adds positioning copy around it: true WYSIWYG Markdown, TextKit-native editing, fully native macOS app, no Electron, no Tauri, no WebView.

## Commands

```bash
npm install
npm run compositions
npm run render:landscape
npm run render:portrait
npm run still:poster
npm run render:all
```

Rendered videos are written to the repo-level `dist/social` directory, which is ignored by git.

## Updating the source recording

1. Capture a fresh Kern app-use recording that shows rendered Markdown editing directly.
2. Save the normalized MP4 at `dist/social/kern-live-wysiwyg-recording.mp4`.
3. Run `npm run render:all` from this package.

The asset preparation script copies the live recording into `public/generated` before render.
