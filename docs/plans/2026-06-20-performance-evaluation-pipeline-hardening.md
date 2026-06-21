# Performance evaluation pipeline hardening

Date: 2026-06-20

Goal: make Kern performance work data-driven before changing image, math, or
Mermaid rendering behavior.

## Principle

No performance-sensitive change should be accepted on “it feels faster” or a
single manual screenshot. Every change needs:

1. a named baseline,
2. a candidate run,
3. comparable fixture hashes,
4. raw data,
5. a generated summary,
6. a regression decision.

## Pipeline tiers

### Tier 0: correctness gate

Purpose: prove the app still behaves correctly before trusting performance data.

Run:

```bash
./scripts/test-native-editor.sh --no-snapshots
```

Use this before collecting a baseline and after each candidate change.

### Tier 1: native XCTest perf benchmark

Purpose: stable in-process import/render/typing measurements.

Run:

```bash
KERN_PERF_ITERATIONS=3 ./scripts/bench-native-editor.sh
```

The script now writes:

- `perf.log`
- `run-manifest.txt`
- `perf-tests.txt`
- `baseline-selection.log`
- `processes-before.txt`
- `processes-after-success.txt` on successful runs
- `metrics-summary.json`
- `summary.md`

It also copies those artifacts into the local ignored benchmark archive and
appends an archive index row.

Failure behavior is also part of the contract:

- `xcodebuild` is time-bounded by `KERN_PERF_XCODEBUILD_TIMEOUT_SECONDS`
  (default: 1800 seconds);
- timeout/failure runs write `failure.txt` and `processes-at-failure.txt`;
- the runner kills only the Kern app launched from its own DerivedData bundle;
- failed runs are still copied into the local ignored benchmark archive;
- baseline auto-selection rejects failed, synthetic/fake, lane-incompatible,
  fixture-incompatible, unparseable, and no-metric candidate runs.

Explicit and automatic baselines are validated mechanically. A selected baseline
must have a run manifest, parsed metrics summary, matching quick/Mermaid lane
flags, and matching committed fixture hashes. A candidate run also fails strict
regression mode if a metric that existed in the baseline is missing from the
candidate.

### Tier 1 quick lane

Purpose: fast sanity signal while iterating.

Run:

```bash
KERN_PERF_ITERATIONS=1 ./scripts/bench-native-editor.sh --quick
```

This is not a release-quality claim. It is a smoke signal for obvious
regressions.

### Tier 1 rich-block lane

Purpose: include Mermaid mode matrix while developing rich block rendering.

Run:

```bash
KERN_PERF_ITERATIONS=3 ./scripts/bench-native-editor.sh --include-mermaid
```

As math/image/Mermaid-specific benchmark cases are added, they should be wired
into this lane rather than mixed into unrelated typing tests.

### Tier 2 isolated worst-case reruns

Purpose: separate real product regressions from XCTest process high-water memory
artifacts.

Run one test at a time with a fresh DerivedData path and explicit
`-only-testing` selection. Use this for:

- mega character-by-character typing;
- interleaved action burst;
- any benchmark with large peak physical memory deltas;
- any benchmark with high relative standard deviation.

### Tier 3 cross-editor benchmark

Purpose: claim-safe Kern vs Zed or other editor comparisons.

Only use the cross-editor runner for external claims. The internal XCTest perf
lane is not claim-safe for public editor-vs-editor comparisons.

Rules:

- official comparisons require the suite-defined roster;
- no existing editor sessions should be running;
- run `--preflight-only` before any real cross-editor claim run so build,
  roster, app/CLI resolution, and cleanup-target idleness are verified without
  launching editors;
- owned-process cleanup must be verified;
- firewall/network popups invalidate timing unless explicitly accounted for;
- publishable claims require the generated JSON and Markdown, not chat-only
  summaries.

Preflight examples:

```bash
./scripts/cross-editor-benchmark.sh --suite benchmark_open_ready --preflight-only --runs 10
./scripts/cross-editor-benchmark.sh --suite benchmark_full_fidelity --preflight-only --runs 10
```

## A/B workflow

For every performance-affecting patch:

1. Capture baseline:

   ```bash
   KERN_PERF_ITERATIONS=3 ./scripts/bench-native-editor.sh
   ```

2. Make one scoped code change.

3. Run correctness gate:

   ```bash
   ./scripts/test-native-editor.sh --no-snapshots
   ```

4. Capture candidate:

   ```bash
   KERN_PERF_ITERATIONS=3 ./scripts/bench-native-editor.sh --fail-on-regression
   ```

5. If candidate regresses:
   - isolate the worst case in a fresh process;
   - inspect raw log values and relative standard deviation;
   - decide revert/fix/accept with written rationale.

6. Persist the decision:
   - leave the raw run artifacts in the ignored benchmark archive;
   - update the relevant implementation plan or research note with the result
     summary when the result changes product direction.

## Regression policy

Default thresholds for the native XCTest perf report:

- timing regression: >15% and >20 ms absolute;
- memory regression: >25% and >10 MB absolute.

These are gates for investigation, not automatic product truth. Peak memory
inside one XCTest process can inherit previous high-water state, so any memory
failure must be confirmed with an isolated per-test run before it is used as a
product claim.

## Required artifact interpretation

Use `metrics-summary.json` as the machine-readable source of truth. The Markdown
summary is for human review.

Important fields:

- `git`: branch, commit, dirty state;
- `environment`: Xcode, OS, hardware;
- `metrics`: parsed XCTest performance metrics and raw sample values;
- `comparisons`: baseline/candidate deltas and regression booleans;
- `missing_baseline_metrics`: metrics present in the selected baseline but
  absent from the candidate;
- `thresholds`: gate values used for that report.

## Known current pipeline gaps

These should be closed before relying on broader rich-block performance claims:

1. Measured deterministic import + attachment-bounds cases now exist for local
   images, math blocks, and Mermaid blocks.
2. Image async decode/draw perf cases still need a controlled fixture and
   isolated timing so network, cache, and TextKit invalidation do not skew the
   result.
3. Mermaid canonical SVG renderer perf cases cannot exist until that renderer is
   prototyped.
4. Native XCTest peak memory must be treated carefully because process-level
   high-water behavior can make later tests look worse than they are.
5. Cross-editor tests remain sensitive to OS permissions, firewall prompts, and
   running editor sessions.

## Immediate next benchmark work

1. Run the parser/report unit tests.
2. Run a quick native perf lane to prove end-to-end artifact generation.
3. Run a full native perf baseline before image/math/Mermaid changes.
4. Extend rich-block-specific benchmark cases beyond the deterministic
   import/bounds metrics:
   - local image async decode/cache/draw;
   - block math draw/cache cost once a richer renderer exists;
   - inline math baseline/layout churn;
   - Mermaid canonical/cold;
   - Mermaid canonical/warm-cache.

Do not treat a run as a baseline if the machine is already running unrelated
Xcode benchmark/test workloads. The manifest and process snapshot exist so those
conditions can be detected rather than silently folded into performance claims.

## Initial validation notes

This pipeline was validated first as a harness, not as an app-performance
baseline:

- parser unit tests passed;
- parser discovery across script tests passed;
- baseline selector unit tests passed;
- an existing real XCTest performance log parsed into 12 metrics across 4
  tests;
- self-comparing that same real log produced 12 comparable metrics and 0
  regressions;
- an intentional 1-second timeout produced `failure.txt`,
  `processes-at-failure.txt`, archive copies, and no owned Kern/xcodebuild
  process leak from the benchmark DerivedData path;
- a stubbed `xcodebuild` success run produced `perf.log`,
  `metrics-summary.json`, `summary.md`, process snapshots, baseline-selection
  notes, and archive/index entries without launching the app;
- a stubbed timeout run produced `failure.txt`, timeout reason,
  process snapshots, archive copies, and no strict process-hygiene leak;
- full native perf roster auditing found 0 omitted discovered XCTest
  performance tests;
- low-iteration functional validation ran the new image, math, and Mermaid
  import/bounds performance tests successfully; those numbers are not a
  baseline because unrelated system load was high.

A new real baseline still needs a quiet machine with unrelated Xcode/Kern jobs
stopped. Until then, any real app-performance number collected on this machine
should be treated as contaminated.
