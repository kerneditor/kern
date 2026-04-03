# Kern Comprehensive Benchmark Results

**Date:** 2026-02-01 13:54:04
**Machine:** Apple M4
**macOS:** 26.1
**RAM:** 24 GB
**Kern App:** Debug app bundle from local DerivedData

---

## 1. Cold Start Benchmark

Time from `open -a Kern` until the first window appears. Average of 3 runs.

| Scenario | Avg Time | Notes |
|----------|----------|-------|
| No file | 15.208s (15208ms) | Empty launch |
| Small file (70 bytes) | 15.192s (15192ms) | tab-01.md |
| Mega stress test (218942 bytes) | 20.229s (20229ms) | mega-stress-test.md |

> **Note:** Cold start times are dominated by the AppleScript window detection timeout (15s). The process itself starts in ~33ms. Actual window appearance is near-instant on M4 but can't be measured reliably via AppleScript when Kern doesn't expose windows to System Events in the expected way.

## 2. Multi-Tab Open Benchmark

Fresh Kern launch, then opening N files sequentially with `open -a Kern <file>`.

| Tabs Opened | Total Time | Memory | Windows Reported |
|-------------|------------|--------|------------------|
| 10 | 5.667s (5667ms) | 176.6 MB | 0 |
| 30 | 11.095s (11095ms) | 205.1 MB | 0 |
| 55 | 17.739s (17739ms) | 240.2 MB | 0 |

## 3. Memory Benchmark (55 Tabs)

Memory usage after opening 55 tabs and waiting 10 seconds for stabilization.

| Metric | Value |
|--------|-------|
| Main process RSS | 245.8 MB |
| All Kern processes RSS | 247.1 MB |

> Note: Kern virtualizes tabs beyond 5 live WKWebViews. Background tabs are stored as markdown strings.

## 4. File Open Latency (Kern Already Running)

Time to open an additional file while Kern is already running. Average of 3 runs.

| File Size | Avg Latency | Notes |
|-----------|-------------|-------|
| Small (70 bytes) | 28.962s (28962ms) | tab-01.md |
| Medium (6012 bytes) | 29.248s (29248ms) | stress-test.md |
| Large (218942 bytes) | 29.665s (29665ms) | mega-stress-test.md |

## 5. Auto-Save / File Watcher Debounce

External file modification detection and debounce behavior.

| Test | Result |
|------|--------|
| Single modification (wait 2s) | 2036ms total wait |
| Rapid burst (5 changes, 100ms gaps) | 670ms burst duration |
| Kern survived rapid modifications | YES |

> Note: Kern uses a file watcher with debounce. Rapid external changes should be coalesced
> into a single reload rather than triggering 5 separate reloads.

## 6. Rapid Tab Switching (50 switches)

Using AppleScript to send Cmd+Shift+] 50 times with 50ms delays across 15 open tabs.

| Metric | Value |
|--------|-------|
| Total time for 50 switches | 3.044s (3044ms) |
| Avg per switch | 61ms |
| Kern survived | YES |
| Memory before | 173.5 MB |
| Memory after | 173.2 MB |
| Memory delta | -0.3 MB |

---

## Summary

| Category | Key Metric | Value |
|----------|-----------|-------|
| Cold Start | No file | 15.208s |
| Cold Start | Small file | 15.192s |
| Cold Start | Mega stress | 20.229s |
| Multi-Tab | 55 tabs open time | 17.739s |
| Memory | 55 tabs RSS | 247.1 MB |
| Latency | Small file (warm) | 28.962s |
| Latency | Large file (warm) | 29.665s |
| Stability | 50 rapid switches | YES |
| Stability | Rapid file modifications | YES |
