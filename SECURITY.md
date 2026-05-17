# Security Policy

## Reporting a vulnerability

For non-security support, use [SUPPORT.md](SUPPORT.md) instead of this path.

Use **GitHub private vulnerability reporting** for sensitive security issues in this repository:

- `https://github.com/kerneditor/kern/security/advisories/new`

Do **not** open a public issue for an undisclosed vulnerability.

For general support, install/build help, and non-security bug reports, use [SUPPORT.md](SUPPORT.md).

If you cannot access the advisory form, contact GitHub Support privately and mention this repository.

## What to include

Please include:

- affected version or commit
- impact
- reproduction steps
- proof-of-concept or minimal sample if available
- any suggested mitigation

## Response expectations

Response is best-effort.

Target expectations:

- initial acknowledgement within **3 business days**
- status update after triage
- coordinated disclosure after a fix or mitigation is available

## Scope

Examples of issues that are in scope:

- unintended remote fetch behavior
- unsafe local file handling
- path traversal or sandbox escape behavior
- code execution paths triggered by crafted markdown or assets
- suspicious published release assets or checksum mismatches
- suspected release-asset tampering or replacement
- data loss or corruption caused by malformed input

Examples that are usually out of scope:

- feature requests
- benchmark/performance complaints without a security impact
- UI bugs with no security consequence

## Supported code

Best-effort support is limited to:

- the `main` branch
- the latest tagged release, if tags exist
