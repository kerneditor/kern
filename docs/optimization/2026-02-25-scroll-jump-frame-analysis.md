# Scroll jump frame analysis (60 FPS)

Date: 2026-02-25
Source: user recording `Screen Recording 2026-02-25 at 2.01.40 AM.mov`.

## Extraction
- Total frames: 463
- Frame rate: 60 FPS
- Duration: ~13.8067s
- Motion CSV: `tmp/video_motion.csv`

## Detected jump events
Primary upward snap candidates in the editor viewport:

1) **Frame 332** (~5.533s)
- Estimated vertical displacement: **-94 px**
- Neighbor frames around this event are mostly stable, so this is an impulse-style jump.

2) **Frame 392** (~6.533s)
- Estimated vertical displacement: **-107 px**
- Immediate stabilization after this frame indicates a single snap jump.

Note:
- Frames 299-302 are stable in motion estimation (dy ~= 0), i.e. no detected viewport translation there.

## Code changes applied
- Updated staged promotion viewport restoration path to always re-anchor to the visual character target instead of preserving raw clip origin for intersecting replacements.
- Added viewport-aware staged promotion capping logic:
  - `stagedPromotionViewportGuardChars`
  - `stagedPromotionViewportMicroStepChars`
  - Environment overrides:
    - `KERN_STAGED_PROMOTION_VIEWPORT_GUARD_CHARS`
    - `KERN_STAGED_PROMOTION_VIEWPORT_MICRO_STEP_CHARS`

## Validation
- Target test suite run:
  - `NativeEditorInitialViewportTests` (10/10 passing)
- App rebuilt and reinstalled to local Applications folder.

## Latest benchmark spot-check
- Suite: `benchmark_open_ready`
- Fixture: `test-fixtures/native-editor-benchmark.md`
- Runs: 3 measured, 1 warmup
- Result snapshot:
  - Kern p50 open latency: **430.5 ms**
  - Zed p50 open latency: **645.94 ms**
