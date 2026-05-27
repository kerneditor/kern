## Summary

- what changed
- why it changed

## Validation

- [ ] `./scripts/test-native-editor.sh --no-snapshots`
- [ ] `./scripts/test-markdown-spec-conformance.sh`
- [ ] `./scripts/run-typing-behavior-gate.sh --lane pr`
- [ ] `cd scripts/kern-bench && swift test -c release`
- [ ] not applicable; no editing-behavior change
- [ ] not applicable; no benchmark-harness change
- [ ] docs-only change; no app/test run required

## Artifacts

List any relevant artifacts when useful:

- screenshots
- snapshot diffs
- benchmark results
- strict spec output

## Checklist

- [ ] tests/docs were updated with the change
- [ ] change is narrow and scoped
- [ ] no sensitive details were posted publicly
