# Research: README Best Practices For Kern
Date: 2026-02-17
Depth: Full

## Executive Summary
The strongest pattern across authoritative sources is that a repository README should answer a small set of first-visit questions quickly: what this project is, why it exists, how to get started, where to get help, and how to contribute. For Kern, that means leading with the real problem it solves (editing Markdown files directly from local workflows), then showing exact run/test commands and linking to deeper docs for implementation detail. Confidence is high.

## Sub-Questions Investigated
1. What content should every high-quality README include?
Answer: Core project purpose and value, quick-start usage, support/contribution paths, and maintainer context.

2. How long and detailed should a README be?
Answer: It should be enough to start using/contributing; move deep documentation to linked docs/wiki pages.

3. Where should README live for maximum visibility?
Answer: Root-level `README.md` is the most universally expected choice; GitHub also surfaces `.github/README.md` and `docs/README.md` with priority rules.

4. Which sections are optional but useful?
Answer: status/roadmap, license, contributor guidance, visuals, and architecture summaries when relevant.

## Detailed Findings

### 1) README should answer first-visit questions, not everything
- GitHub Docs and Open Source Guides both emphasize the same first-visit questions: what it does, why it is useful, getting started, help/support, and maintainers/contributors.
- Make a README supports this with practical section guidance (Description, Usage, Support, Contributing, License, Status).
- Practical implication for Kern: lead with product intent and pain points solved, then show immediate usage/build/test paths.

### 2) Keep README startup-oriented; link to deeper docs
- GitHub Docs explicitly position README as startup documentation and recommend deeper, longer documentation elsewhere.
- Google style guidance for READMEs is similarly minimal at the directory/package level: summary + usage + status + links to docs.
- Practical implication for Kern: include concise architecture/context, but push deep test plans/spec trackers to linked documents.

### 3) Placement and naming matter for discoverability
- GitHub docs describe where READMEs are auto-surfaced and how priority is chosen when multiple files exist.
- Google style guidance reinforces top-level `README.md` for discoverability.
- Make a README also points to top-level placement as user expectation.
- Practical implication for Kern: keep a single canonical root `README.md` as the source of truth.

### 4) Contribution metadata should be explicit early
- GitHub docs and Open Source Guides both connect README quality with healthier contributions by setting expectations and linking supporting files (`CONTRIBUTING`, `LICENSE`, code of conduct, support channels).
- Practical implication for Kern: README should clearly state contribution posture and where to open issues/discussions.

## Hypothesis Tracking

| Hypothesis | Confidence | Supporting Evidence | Contradicting Evidence |
|------------|------------|---------------------|------------------------|
| H1: A strong README prioritizes what/why/how/help in the first screen. | High | GitHub Docs, Open Source Guides, Make a README | None found |
| H2: README should be exhaustive and contain most docs inline. | Low | Weak support from generic templates | GitHub Docs and Google guidance both favor concise startup focus + links |
| H3: Root-level placement is best default for repo discoverability. | High | GitHub Docs, Google styleguide, Make a README | None found |

## Verification Status

### Verified (2+ sources)
- README should communicate: what project does, why useful, getting started, and where to get help.
- Root-level `README.md` is the default expected location for repository discoverability.
- README should include enough for onboarding, then link to deeper docs for extended material.
- Contribution expectations and supporting files improve contributor experience.

### Unverified (single source)
- GitHub-specific rendering note: content beyond 500 KiB is truncated in rendered README view.

### Conflicts Resolved
- “Long README vs short README” guidance appears conflicting in community templates.
- Resolution: use “complete for onboarding, concise for depth,” and move deep material to linked docs. This aligns with GitHub + Google guidance while preserving useful detail.

## Self-Critique
- Completeness: covered structure, placement, content scope, and contribution metadata.
- Source quality: prioritized GitHub Docs, Open Source Guides, and Google style docs; avoided listicle-heavy low-signal pages.
- Bias check: balanced prescriptive docs with practical template guidance.
- Gaps: no large-scale empirical dataset comparing README conversion metrics by section order.
- Recency: key sources are current and maintained as of 2026-02-17.

## Recommendations Applied To Kern README
1. Open with product thesis + pain points solved.
2. Add “Why this rewrite exists” (WebKit -> native TextKit) with clear boundaries.
3. Keep setup commands copy-pasteable and grouped by intent (run, test, exhaustive).
4. Link to deep plans/spec docs instead of embedding long process details.
5. State project status honestly (active work + current focus areas).

## Sources
| Source | URL | Quality | Accessed |
|--------|-----|---------|----------|
| GitHub Docs: About the repository README file | https://docs.github.com/en/enterprise-server@3.19/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes | High (official) | 2026-02-17 |
| GitHub Docs: Setting up your project for healthy contributions | https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions | High (official) | 2026-02-17 |
| Open Source Guides: Starting an Open Source Project | https://opensource.guide/starting-a-project/ | High (maintainer guidance) | 2026-02-17 |
| Make a README | https://www.makeareadme.com/ | Medium (community template) | 2026-02-17 |
| Google Style Guide: READMEs | https://google.github.io/styleguide/docguide/READMEs.html | High (large-project documentation standard) | 2026-02-17 |
