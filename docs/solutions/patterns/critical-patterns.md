# Critical patterns for benchmark integrity

## 1) Fail explicit, never silently

Every missing/timeout stage must emit a machine-readable reason. Do not convert unknown failure into success-like nulls.

## 2) Keep deadline provenance

Timeouts must preserve whether the failure was caused by per-stage timeout or global run/suite budget exhaustion.

## 3) Prefer event signals over sleeps

Use deterministic event/predicate waits (bench hook, file signal, doc match) before polling timeouts. Avoid fixed sleeps in critical path.

## 4) Guard against helper-window false fast

Window selection must reject tiny/non-layer0 windows and prefer document-matching titles before area fallback.

## 5) Separate performance from automation noise

Always report automation-attributed metrics (`automation_overhead_ms`, `unattributed_open_budget_ms`) and track their drift independently from app-internal spans.

## 6) Preserve claim-lane isolation

Do not mix internal microbenchmark metrics into cross-editor claim tables. Enforce suite-kind policies in regression and publishing tools.
