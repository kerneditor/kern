#!/bin/bash
# open-ui-test-permissions.sh — Compatibility stub for the removed XCUI runner.
#
# Usage:
#   ./scripts/open-ui-test-permissions.sh

set -euo pipefail
echo "Kern no longer ships an XCUI runner."
echo "There are no active UI-test permissions to grant for the current unit-only test suite."
echo "If a future UI runner is reintroduced, restore this script with the new scheme/app path."
