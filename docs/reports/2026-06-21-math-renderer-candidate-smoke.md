# Math Renderer Candidate Smoke — 2026-06-21

## Scope

This is a compile/integration smoke for native math-renderer candidates. It is
not decision-quality timing because the machine was still under high system load
and the run used one measured sample per formula.

The shipped Kern app target still has no new third-party math dependency.
Candidates were built in throwaway SwiftPM packages under ignored local scratch
space and reports were written under ignored benchmark output.

## Command

```bash
KERN_MATH_BENCH_RUNS=1 KERN_MATH_BENCH_WARMUPS=0 ./scripts/bench-math-renderer-candidates.sh
```

## Result

- `iosMath` 2.3.1 built and ran.
- `SwiftMath` 1.7.1 built and ran.
- Both candidates evaluated all 14 tracked math corpus cases from
  `test-fixtures/rich-block-eval/math-renderer-corpus.json`.
- Both candidates reported parser errors for:
  - `block-operatorname-softmax` (`\operatorname` unsupported by this API path);
  - `block-invalid-command` (expected invalid-input case).

## Smoke timing snapshot

These values are useful only to confirm the harness works. Do not use them to
choose a renderer.

| Candidate | Cases | Error cases | Notes |
|---|---:|---:|---|
| iosMath 2.3.1 | 14 | 2 | Mature native option; Objective-C/AppKit API compiled in standalone SwiftPM harness. |
| SwiftMath 1.7.1 | 14 | 2 | Pure-Swift option; compiled in standalone SwiftPM harness. |

## Interpretation

- The corpus-driven candidate harness now works.
- Neither candidate is automatically full TeX parity for Kern's desired corpus;
  `\operatorname` already needs preprocessing, fallback handling, or a higher
  fidelity renderer/oracle path.
- Next renderer-selection run must use more iterations on a quiet machine and
  include visual contact sheets, not only parse/layout/draw timings.
