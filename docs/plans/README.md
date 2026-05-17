# Plans index

This directory contains both current planning documents and historical implementation plans.

## Canonical active plans

Read these first when changing editor behavior, tests, or Markdown semantics:

- `native-editor-test-suite.md`
- `native-editor-missing-features-implementation-plan.md`
- `markdown-spec-failure-tracker.md`

## Active deferred work

These plans describe known future or deferred work. They are not release blockers for the current unsigned DMG release path unless a maintainer explicitly promotes them:

- `2026-03-01-feat-beat-zed-all-benchmarks-plan.md`
- `2026-03-01-feat-full-fidelity-performance-optimization-plan.md`
- `2026-03-02-feat-full-fidelity-parser-throughput-phase3-plan.md`

## Completed or historical planning

The remaining dated plans are retained as implementation history and rationale. Treat them as context, not as current acceptance criteria, unless a current canonical plan links to them directly.

## Maintenance rule

When a plan changes status, update its front matter or top status section and keep this index aligned. Avoid adding new root-level `research-*.md` files; public research belongs in `docs/research/`, and maintainer-private scratch belongs under ignored internal paths.
