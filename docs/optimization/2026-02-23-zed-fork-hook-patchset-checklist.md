# Zed fork bench-ready hook patchset checklist

## Scope

Implement deterministic bench-ready signaling in a Zed fork so `kern-bench` can consume parity-grade readiness events.

## Hook interface contract

CLI additions:
- `--bench-target-file <abs-path>`
- `--bench-ready-signal <json-path|fd|unix-socket>`
- `--bench-ready-mode <first_editable|first_content|styled_stable>`

Event payload:

```json
{
  "event": "bench_ready",
  "target": "/abs/path/file.md",
  "mode": "first_editable",
  "timestamp_monotonic_ns": 123,
  "pid": 999,
  "window_id": 12345
}
```

## Patch units

1. Parse new CLI flags and thread them into open workflow state.
2. Validate target file match before signal emission.
3. Emit exactly once per opened target window.
4. Emit monotonic timestamp from process uptime clock.
5. Handle signal write failures explicitly (log + bench diagnostic).

## Required tests in fork

- exact-once emission on normal open
- no emission on non-target file
- mode value preserved in payload
- payload target path canonicalization
- failure path when signal destination is invalid

## Harness compatibility status

- `kern-bench` already supports:
  - `--zed-bench-hook auto|off|required`
  - payload validation (event/mode/target/timestamp/pid)
  - fallback in `auto` mode
- Current local Zed binary does not support hook args (`required` mode fails launch).
