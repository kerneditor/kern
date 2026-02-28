# Phase 0 Baseline Snapshot

## Source runs
- Open-ready run: `benchmark-archive/open-ready-check2.json`
- WOW-internal run: `benchmark-archive/wow-internal-latest.json`

## Kern metrics (current)

### Open-ready suite
| metric | min | p50 | max | n |
|---|---:|---:|---:|---:|
| open_latency_ms | 316.16 | 403.30 | 407.93 | 3 |
| window_visible_ms | 270.67 | 354.73 | 364.41 | 3 |
| automation_overhead_ms | 43.52 | 45.49 | 48.57 | 3 |
| wow_open_ready_latency_ms | 43.52 | 45.49 | 48.57 | 3 |
| wow_parse_latency_ms | 21.71 | 21.97 | 22.88 | 3 |
| wow_paint_ready_latency_ms | 67.22 | 73.72 | 77.42 | 3 |

### WOW-internal suite
| metric | min | p50 | max | n |
|---|---:|---:|---:|---:|
| window_visible_ms | 319.35 | 658.57 | 1020.12 | 3 |
| automation_overhead_ms | 717.52 | 918.37 | 1166.05 | 3 |
| wow_open_ready_latency_ms | 45.08 | 104.24 | 110.10 | 3 |
| wow_parse_latency_ms | 21.89 | 32.82 | 48.81 | 3 |
| wow_paint_ready_latency_ms | 71.70 | 149.46 | 413.32 | 3 |
| wow_full_document_fidelity_ready_latency_ms | 7977.66 | 10662.91 | 11014.23 | 3 |
| wow_save_serialize_latency_ms | 1547.52 | 1990.68 | 2346.98 | 3 |

## Immediate read
- Open-ready variance is dominated by window-visible launch variance under load.
- Renderer open-ready cost (WOW open-ready) is much lower than total open when launch variance spikes.
- Full-document fidelity is currently in multi-second range and remains the main optimization target.
