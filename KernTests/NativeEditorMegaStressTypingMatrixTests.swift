import AppKit
import XCTest
@testable import KernTextKit

/// Exhaustive (non-XCUITest) typing and action-permutation coverage.
///
/// Why this exists:
/// - It exercises real editor typing behavior without Accessibility/XCUITest friction.
/// - It runs generated feature x action permutations with deterministic logs.
/// - It includes an end-to-end "type the entire mega stress file" path.
final class NativeEditorMegaStressTypingMatrixTests: XCTestCase {
    private struct PreferenceProfile {
        let name: String
        let defaults: [String: Any]
    }

    private enum CaretPlacement {
        case endOfDocument
        case firstOccurrence(String)
    }

    private struct FeatureSeed {
        let name: String
        let markdown: String
        let caretPlacement: CaretPlacement
    }

    private enum EditAction: String, CaseIterable {
        case insertASCII
        case insertMarkdownInline
        case newline
        case lineBreak   // Shift+Enter — soft break
        case backspace
        case deleteForward
        case moveLeft
        case moveRight
        case moveLineStart
        case moveLineEnd
        case moveDocumentStart
        case moveDocumentEnd
        case selectWordAroundCaret
        case selectCurrentLine
        case replaceSelectionPreservingText
        case cutSelection
        case pasteClipboard
        case undo
        case redo
        case space
        case toggleBold
        case toggleItalic
        case toggleCode
    }

    private let profileKeys: [String] = [
        "nativeEditor.exportDialect",
        "nativeEditor.gfmExtensionExportStrategy",
        "nativeEditor.taskRendering",
        "nativeEditor.orderedTasksEnabled",
        "nativeEditor.headingCheckboxesEnabled",
        "nativeEditor.orderedListNumbering",
        "nativeEditor.mermaidRenderMode",
        "nativeEditor.checkboxHitTarget",
        MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey,
    ]

    private let actionAlphabetForCrossProductMatrix: [EditAction] = [
        .insertASCII,
        .insertMarkdownInline,
        .newline,
        .lineBreak,
        .backspace,
        .deleteForward,
        .moveLeft,
        .moveRight,
        .moveLineStart,
        .moveLineEnd,
        .space,
        .toggleBold,
        .toggleItalic,
        .toggleCode,
    ]

    private var inMemoryClipboard: String = ""

    @MainActor
    func testTypeEntireMegaStressFileCharacterByCharacter_CanonicalProfiles() throws {
        try TestGates.skipUnlessExhaustive()
        guard TestRuntimeConfig.bool("KERN_ENABLE_MEGA_CHAR_BY_CHAR") else {
            throw XCTSkip("Set KERN_ENABLE_MEGA_CHAR_BY_CHAR=1 to run mega char-by-char typing test")
        }

        let sourceMarkdown = try loadFixture(name: "mega-stress-test.md")
        XCTAssertGreaterThan(sourceMarkdown.count, 100_000, "Expected mega stress fixture to be large")
        let markdown = boundedFixture(
            sourceMarkdown,
            envLimitKey: "KERN_EXHAUSTIVE_MEGA_CHAR_LIMIT",
            defaultLimit: 40_000
        )
        let requiredTokens = representativeHeadingTokens(from: markdown, maxCount: 18) + requiredTokensPresentInSource(markdown, candidates: [
            "```",
            "|",
            "- [ ]",
            "```mermaid",
            "$$",
        ])

        var report: [String] = []
        report.append("mega_stress_char_by_char")
        report.append("fixture_bytes_source=\(sourceMarkdown.utf8.count)")
        report.append("fixture_bytes_effective=\(markdown.utf8.count)")
        report.append("fixture_truncated=\(markdown.utf8.count < sourceMarkdown.utf8.count ? "1" : "0")")
        report.append("profiles=\(canonicalProfiles().count)")
        var failures: [String] = []
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }

        for profile in canonicalProfiles() {
            try withPreferenceProfile(profile) {
                resetEditor(vc: hosted.vc, textView: hosted.textView)

                let start = CFAbsoluteTimeGetCurrent()
                typeCharacterByCharacter(markdown, in: hosted.textView)
                settleLayout(vc: hosted.vc)
                let typingElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                if let diff = roundTripDiff(exported) {
                    failures.append("roundtrip profile=\(profile.name) scenario=mega-char-by-char \(diff)")
                }
                let missing = missingRequiredTokens(exported, tokens: requiredTokens)
                if !missing.isEmpty {
                    failures.append("missing-tokens profile=\(profile.name) scenario=mega-char-by-char tokens=\(missing.joined(separator: ","))")
                }

                report.append("profile=\(profile.name) typing_ms=\(typingElapsedMs) visible_chars=\(hosted.textView.string.count) export_bytes=\(exported.utf8.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "mega-stress-char-by-char-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "mega-stress-char-by-char-failures")
            XCTFail("Mega char-by-char failures (\(failures.count)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    @MainActor
    func testTypeUltimateStressFileCharacterByCharacter_AllPreferencePermutations() throws {
        try TestGates.skipUnlessExhaustive()

        let sourceMarkdown = try loadFixture(name: "ultimate-stress-test.md")
        XCTAssertGreaterThan(sourceMarkdown.count, 15_000, "Expected ultimate stress fixture to be non-trivial")
        let markdown = boundedFixture(
            sourceMarkdown,
            envLimitKey: "KERN_EXHAUSTIVE_ULTIMATE_CHAR_LIMIT",
            defaultLimit: 24_000
        )
        let fullCrossProfile = TestRuntimeConfig.bool("KERN_EXHAUSTIVE_ULTIMATE_FULL")
        let profiles = boundedProfiles(
            from: allPreferenceProfiles(),
            envLimitKey: "KERN_EXHAUSTIVE_ULTIMATE_PROFILE_LIMIT",
            defaultLimit: fullCrossProfile ? nil : 16
        )
        let requiredHeadingTokens = representativeHeadingTokens(from: markdown, maxCount: 24)

        var report: [String] = []
        report.append("ultimate_stress_char_by_char")
        report.append("full_cross_profile=\(fullCrossProfile ? "1" : "0")")
        report.append("fixture_bytes_source=\(sourceMarkdown.utf8.count)")
        report.append("fixture_bytes_effective=\(markdown.utf8.count)")
        report.append("fixture_truncated=\(markdown.utf8.count < sourceMarkdown.utf8.count ? "1" : "0")")
        report.append("profiles_total=\(allPreferenceProfiles().count)")
        report.append("profiles_effective=\(profiles.count)")
        var failures: [String] = []
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }

        for (profileIndex, profile) in profiles.enumerated() {
            try withPreferenceProfile(profile) {
                resetEditor(vc: hosted.vc, textView: hosted.textView)

                let start = CFAbsoluteTimeGetCurrent()
                typeCharacterByCharacter(markdown, in: hosted.textView)
                settleLayout(vc: hosted.vc)
                let typingElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                // This stress lane validates resilience under huge live typing matrices.
                // Exact syntax round-trip invariants are covered by dedicated codec/matrix tests.
                if exported.utf8.count < markdown.utf8.count / 2 {
                    failures.append("size-collapse profile=\(profile.name) export_bytes=\(exported.utf8.count) source_bytes=\(markdown.utf8.count)")
                }
                let missing = missingRequiredTokens(exported, tokens: requiredHeadingTokens)
                if !missing.isEmpty {
                    failures.append("missing-headings profile=\(profile.name) scenario=ultimate-char-by-char tokens=\(missing.joined(separator: ","))")
                }

                report.append("profile=\(profile.name) typing_ms=\(typingElapsedMs) visible_chars=\(hosted.textView.string.count) export_bytes=\(exported.utf8.count)")
            }
            if (profileIndex + 1) % 4 == 0 || profileIndex == profiles.count - 1 {
                print("ultimate-char-by-char progress \(profileIndex + 1)/\(profiles.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "ultimate-stress-char-by-char-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "ultimate-stress-char-by-char-failures")
            XCTFail("Ultimate char-by-char failures (\(failures.count)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    @MainActor
    func testTypeUltimateStressFileCharacterByCharacter_WithInterleavedActionPrograms_AllPreferencePermutations() throws {
        try TestGates.skipUnlessExhaustive()

        let sourceMarkdown = try loadFixture(name: "ultimate-stress-test.md")
        XCTAssertGreaterThan(sourceMarkdown.count, 15_000, "Expected ultimate stress fixture to be non-trivial")
        let markdown = boundedFixture(
            sourceMarkdown,
            envLimitKey: "KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_CHAR_LIMIT",
            defaultLimit: 10_000
        )
        let fullCrossProfile = TestRuntimeConfig.bool("KERN_EXHAUSTIVE_ULTIMATE_INTERLEAVED_FULL")
            || TestRuntimeConfig.bool("KERN_EXHAUSTIVE_ULTIMATE_FULL")
        let profiles = boundedProfiles(
            from: allPreferenceProfiles(),
            envLimitKey: "KERN_EXHAUSTIVE_INTERLEAVED_PROFILE_LIMIT",
            defaultLimit: fullCrossProfile ? nil : 6
        )
        let programs = interleavedActionPrograms()
        let interval = max(31, TestRuntimeConfig.int("KERN_EXHAUSTIVE_INTERLEAVED_INTERVAL", default: 131) ?? 131)
        let maxProgramsPerProfile = configuredPositiveInt(
            key: "KERN_EXHAUSTIVE_INTERLEAVED_PROGRAM_LIMIT",
            defaultValue: fullCrossProfile ? programs.count : min(4, programs.count)
        )
        let effectivePrograms = Array(programs.prefix(maxProgramsPerProfile))

        var report: [String] = []
        report.append("ultimate_stress_char_by_char_with_interleaved_actions")
        report.append("full_cross_profile=\(fullCrossProfile ? "1" : "0")")
        report.append("fixture_bytes_source=\(sourceMarkdown.utf8.count)")
        report.append("fixture_bytes_effective=\(markdown.utf8.count)")
        report.append("fixture_truncated=\(markdown.utf8.count < sourceMarkdown.utf8.count ? "1" : "0")")
        report.append("profiles_total=\(allPreferenceProfiles().count)")
        report.append("profiles_effective=\(profiles.count)")
        report.append("programs_total=\(programs.count)")
        report.append("programs_effective=\(effectivePrograms.count)")
        report.append("interval_chars=\(interval)")

        var failures: [String] = []
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }

        for (profileIndex, profile) in profiles.enumerated() {
            try withPreferenceProfile(profile) {
                resetEditor(vc: hosted.vc, textView: hosted.textView)

                let start = CFAbsoluteTimeGetCurrent()
                typeCharacterByCharacterWithInterleavedActions(
                    markdown,
                    in: hosted.textView,
                    controller: hosted.vc,
                    programs: effectivePrograms,
                    interval: interval
                )
                settleLayout(vc: hosted.vc)
                let typingElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                if exported.utf8.count < markdown.utf8.count / 2 {
                    failures.append("size-collapse profile=\(profile.name) export_bytes=\(exported.utf8.count) source_bytes=\(markdown.utf8.count)")
                }

                report.append("profile=\(profile.name) typing_ms=\(typingElapsedMs) visible_chars=\(hosted.textView.string.count) export_bytes=\(exported.utf8.count)")
            }
            if (profileIndex + 1) % 4 == 0 || profileIndex == profiles.count - 1 {
                print("ultimate-interleaved progress \(profileIndex + 1)/\(profiles.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "ultimate-stress-interleaved-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "ultimate-stress-interleaved-failures")
            XCTFail("Ultimate interleaved typing failures (\(failures.count)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    @MainActor
    func testTypeMegaStressFileCharacterByCharacter_WithInterleavedActionPrograms_CanonicalProfiles() throws {
        try TestGates.skipUnlessExhaustive()

        let sourceMarkdown = try loadFixture(name: "mega-stress-test.md")
        XCTAssertGreaterThan(sourceMarkdown.count, 100_000, "Expected mega stress fixture to be large")
        let markdown = boundedFixture(
            sourceMarkdown,
            envLimitKey: "KERN_EXHAUSTIVE_MEGA_INTERLEAVED_CHAR_LIMIT",
            defaultLimit: 45_000
        )
        let programs = interleavedActionPrograms()
        let interval = max(31, TestRuntimeConfig.int("KERN_EXHAUSTIVE_MEGA_INTERLEAVED_INTERVAL", default: 173) ?? 173)
        let maxProgramsPerProfile = max(1, TestRuntimeConfig.int("KERN_EXHAUSTIVE_MEGA_INTERLEAVED_PROGRAM_LIMIT", default: programs.count) ?? programs.count)
        let effectivePrograms = Array(programs.prefix(maxProgramsPerProfile))

        var report: [String] = []
        report.append("mega_stress_char_by_char_with_interleaved_actions")
        report.append("fixture_bytes_source=\(sourceMarkdown.utf8.count)")
        report.append("fixture_bytes_effective=\(markdown.utf8.count)")
        report.append("fixture_truncated=\(markdown.utf8.count < sourceMarkdown.utf8.count ? "1" : "0")")
        report.append("profiles_total=\(canonicalProfiles().count)")
        report.append("programs_total=\(programs.count)")
        report.append("programs_effective=\(effectivePrograms.count)")
        report.append("interval_chars=\(interval)")
        var failures: [String] = []
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }

        for profile in canonicalProfiles() {
            try withPreferenceProfile(profile) {
                resetEditor(vc: hosted.vc, textView: hosted.textView)

                let start = CFAbsoluteTimeGetCurrent()
                typeCharacterByCharacterWithInterleavedActions(
                    markdown,
                    in: hosted.textView,
                    controller: hosted.vc,
                    programs: effectivePrograms,
                    interval: interval
                )
                settleLayout(vc: hosted.vc)
                let typingElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                if exported.utf8.count < markdown.utf8.count / 2 {
                    failures.append("size-collapse profile=\(profile.name) export_bytes=\(exported.utf8.count) source_bytes=\(markdown.utf8.count)")
                }

                report.append("profile=\(profile.name) typing_ms=\(typingElapsedMs) visible_chars=\(hosted.textView.string.count) export_bytes=\(exported.utf8.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "mega-stress-interleaved-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "mega-stress-interleaved-failures")
            XCTFail("Mega interleaved typing failures (\(failures.count)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    @MainActor
    func testTypeMegaStressFileCharacterByCharacter_WithInterleavedActionPrograms_AllPreferencePermutations() throws {
        try TestGates.skipUnlessExhaustive()
        guard TestRuntimeConfig.bool("KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX") else {
            throw XCTSkip("Set KERN_ENABLE_MEGA_ALL_PROFILE_MATRIX=1 to run mega all-profile matrix")
        }

        let sourceMarkdown = try loadFixture(name: "mega-stress-test.md")
        XCTAssertGreaterThan(sourceMarkdown.count, 100_000, "Expected mega stress fixture to be large")
        let markdown = boundedFixture(
            sourceMarkdown,
            envLimitKey: "KERN_EXHAUSTIVE_MEGA_INTERLEAVED_CHAR_LIMIT",
            defaultLimit: 45_000
        )
        let baseProfiles = allPreferenceProfiles()
        let shardedProfiles = shardProfiles(baseProfiles)
        let profiles = boundedProfiles(
            from: shardedProfiles,
            envLimitKey: "KERN_EXHAUSTIVE_MEGA_ALL_PROFILE_LIMIT",
            defaultLimit: 12
        )
        let programs = interleavedActionPrograms()
        let interval = max(31, TestRuntimeConfig.int("KERN_EXHAUSTIVE_MEGA_ALL_PROFILE_INTERVAL", default: 173) ?? 173)
        let maxProgramsPerProfile = configuredPositiveInt(
            key: "KERN_EXHAUSTIVE_MEGA_ALL_PROFILE_PROGRAM_LIMIT",
            defaultValue: min(8, programs.count)
        )
        let effectivePrograms = Array(programs.prefix(maxProgramsPerProfile))

        var report: [String] = []
        report.append("mega_stress_char_by_char_with_interleaved_actions_all_profiles")
        report.append("fixture_bytes_source=\(sourceMarkdown.utf8.count)")
        report.append("fixture_bytes_effective=\(markdown.utf8.count)")
        report.append("fixture_truncated=\(markdown.utf8.count < sourceMarkdown.utf8.count ? "1" : "0")")
        report.append("profiles_total=\(baseProfiles.count)")
        report.append("profiles_sharded=\(shardedProfiles.count)")
        report.append("profiles_effective=\(profiles.count)")
        report.append("programs_total=\(programs.count)")
        report.append("programs_effective=\(effectivePrograms.count)")
        report.append("interval_chars=\(interval)")
        report.append("shard=\(shardDescriptor())")
        var failures: [String] = []
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }

        for profile in profiles {
            try withPreferenceProfile(profile) {
                resetEditor(vc: hosted.vc, textView: hosted.textView)

                let start = CFAbsoluteTimeGetCurrent()
                typeCharacterByCharacterWithInterleavedActions(
                    markdown,
                    in: hosted.textView,
                    controller: hosted.vc,
                    programs: effectivePrograms,
                    interval: interval
                )
                settleLayout(vc: hosted.vc)
                let typingElapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                if exported.utf8.count < markdown.utf8.count / 2 {
                    failures.append("size-collapse profile=\(profile.name) export_bytes=\(exported.utf8.count) source_bytes=\(markdown.utf8.count)")
                }

                report.append("profile=\(profile.name) typing_ms=\(typingElapsedMs) visible_chars=\(hosted.textView.string.count) export_bytes=\(exported.utf8.count)")
            }
        }

        attachReport(report.joined(separator: "\n"), name: "mega-stress-interleaved-all-profiles-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "mega-stress-interleaved-all-profiles-failures")
            XCTFail("Mega interleaved all-profile failures (\(failures.count)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    @MainActor
    func testFeatureActionPermutationMatrix_AllPreferencePermutations() throws {
        try TestGates.skipUnlessExhaustive()
        let fullCrossProduct = TestRuntimeConfig.bool("KERN_EXHAUSTIVE_ACTION_FULL")
        let depth = max(1, min(3, TestRuntimeConfig.int("KERN_EXHAUSTIVE_ACTION_DEPTH", default: 2) ?? 2))
        let permutations = allActionPermutations(maxDepth: depth, alphabet: actionAlphabetForCrossProductMatrix)
        XCTAssertFalse(permutations.isEmpty)

        let features = featureSeeds()
        let baseProfiles = allPreferenceProfiles()
        let shardedProfiles = shardProfiles(
            baseProfiles,
            countKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT",
            indexKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX"
        )
        let profiles = boundedProfiles(from: shardedProfiles, envLimitKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_LIMIT")
        XCTAssertFalse(profiles.isEmpty)
        let combosPerProfile = features.count * permutations.count
        let totalPossibleScenariosAllProfiles = baseProfiles.count * combosPerProfile
        let totalPossibleScenariosInRun = profiles.count * combosPerProfile
        let scenarioBudget: Int = fullCrossProduct
            ? totalPossibleScenariosInRun
            : configuredPositiveInt(key: "KERN_EXHAUSTIVE_ACTION_SCENARIO_BUDGET", defaultValue: 1_000)
        let scenarioLogLimit = configuredPositiveInt(key: "KERN_EXHAUSTIVE_ACTION_LOG_LIMIT", defaultValue: 1_200)
        let progressEvery = configuredPositiveInt(key: "KERN_EXHAUSTIVE_ACTION_PROGRESS_EVERY", defaultValue: 2_000)
        let profileProgressEvery = configuredPositiveInt(key: "KERN_EXHAUSTIVE_ACTION_PROFILE_PROGRESS_EVERY", defaultValue: 8)
        let strictRoundTrip = TestRuntimeConfig.bool("KERN_EXHAUSTIVE_ACTION_STRICT_ROUNDTRIP")
        let exportInterval = configuredPositiveInt(
            key: "KERN_EXHAUSTIVE_ACTION_EXPORT_INTERVAL",
            defaultValue: fullCrossProduct ? 16 : 4
        )
        let roundTripInterval = configuredPositiveInt(
            key: "KERN_EXHAUSTIVE_ACTION_ROUNDTRIP_INTERVAL",
            defaultValue: fullCrossProduct ? 128 : 16
        )
        let scenariosPerProfileBase = fullCrossProduct ? combosPerProfile : max(1, scenarioBudget / max(1, profiles.count))
        let scenariosPerProfileRemainder = fullCrossProduct ? 0 : max(0, scenarioBudget - scenariosPerProfileBase * profiles.count)

        var report: [String] = []
        report.append("feature_action_permutation_matrix")
        report.append("actions=\(EditAction.allCases.map(\.rawValue).joined(separator: ","))")
        report.append("full_cross_product=\(fullCrossProduct ? "1" : "0")")
        report.append("max_depth=\(depth)")
        report.append("permutation_count=\(permutations.count)")
        report.append("feature_count=\(features.count)")
        report.append("profiles_total=\(baseProfiles.count)")
        report.append("profiles_sharded=\(shardedProfiles.count)")
        report.append("profiles_effective=\(profiles.count)")
        report.append("action_shard=\(shardDescriptor(countKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT", indexKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX"))")
        report.append("combos_per_profile=\(combosPerProfile)")
        report.append("scenario_budget=\(scenarioBudget)")
        report.append("scenario_log_limit=\(scenarioLogLimit)")
        report.append("progress_every=\(progressEvery)")
        report.append("profile_progress_every=\(profileProgressEvery)")
        report.append("export_interval=\(exportInterval)")
        report.append("roundtrip_interval=\(roundTripInterval)")
        report.append("strict_roundtrip=\(strictRoundTrip ? "1" : "0")")
        report.append("total_possible_scenarios_all_profiles=\(totalPossibleScenariosAllProfiles)")
        report.append("total_possible_scenarios_in_run=\(totalPossibleScenariosInRun)")
        report.append("scenarios_per_profile_base=\(scenariosPerProfileBase)")
        report.append("scenarios_per_profile_remainder=\(scenariosPerProfileRemainder)")

        let maxFailures: Int = {
            guard let raw = TestRuntimeConfig.string("KERN_EXHAUSTIVE_MAX_FAILURES"),
                  let value = Int(raw),
                  value > 0 else {
                return .max
            }
            return value
        }()
        var failures: [String] = []
        var scenarioCount = 0
        var stopEarly = false
        let runStart = CFAbsoluteTimeGetCurrent()
        let hosted = makeHostedEditor()
        defer { closeHostedEditor(hosted.window) }
        print("action-matrix start shard=\(shardDescriptor(countKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_COUNT", indexKey: "KERN_EXHAUSTIVE_ACTION_PROFILE_SHARD_INDEX")) profiles=\(profiles.count)/\(baseProfiles.count) target_scenarios=\(scenarioBudget)")
        for (profileIndex, profile) in profiles.enumerated() {
            if stopEarly { break }
            if profileIndex == 0
                || profileIndex == profiles.count - 1
                || (profileIndex + 1) % profileProgressEvery == 0 {
                print("action-matrix profile \(profileIndex + 1)/\(profiles.count) \(profile.name)")
            }
            try withPreferenceProfile(profile) {
                inMemoryClipboard = ""
                let profileBudget = fullCrossProduct
                    ? combosPerProfile
                    : min(combosPerProfile, scenariosPerProfileBase + (profileIndex < scenariosPerProfileRemainder ? 1 : 0))
                for localIndex in 0..<profileBudget {
                    if stopEarly { break }
                    scenarioCount += 1

                    // In bounded mode, rotate starting offsets per profile so the budgeted subset
                    // still covers different feature/action combinations across profiles.
                    let comboIndex: Int
                    if fullCrossProduct {
                        comboIndex = localIndex
                    } else {
                        comboIndex = (profileIndex * 17 + localIndex * 37) % combosPerProfile
                    }

                    let feature = features[comboIndex % features.count]
                    let actions = permutations[(comboIndex / features.count) % permutations.count]

                    autoreleasepool {
                        resetEditorFast(vc: hosted.vc, textView: hosted.textView)
                        seedFeatureFast(feature, vc: hosted.vc, textView: hosted.textView)
                        placeCaret(feature.caretPlacement, in: hosted.textView)

                        let start = CFAbsoluteTimeGetCurrent()
                        apply(actions: actions, controller: hosted.vc, textView: hosted.textView)
                        let shouldExport = scenarioCount % exportInterval == 0
                        if shouldExport {
                            settleLayout(vc: hosted.vc)
                        }
                        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

                        let shouldRoundTrip = strictRoundTrip && shouldExport && (scenarioCount % roundTripInterval == 0)
                        var exportBytes = -1
                        if shouldExport {
                            let exported = NativeMarkdownCodec.exportMarkdown(hosted.textView.attributedString(), options: .fromUserDefaults())
                            exportBytes = exported.utf8.count
                            if exported.isEmpty && !hosted.textView.string.isEmpty {
                                failures.append("empty-export profile=\(profile.name) feature=\(feature.name) actions=\(actionsLabel(actions))")
                            } else if shouldRoundTrip, let diff = roundTripDiff(exported) {
                                failures.append("roundtrip profile=\(profile.name) feature=\(feature.name) actions=\(actionsLabel(actions)) \(diff)")
                            }
                        }

                        if scenarioCount <= scenarioLogLimit {
                            report.append("profile=\(profile.name) feature=\(feature.name) actions=\(actionsLabel(actions)) elapsed_ms=\(elapsedMs) export_bytes=\(exportBytes)")
                        }
                    }

                    if scenarioCount % progressEvery == 0 {
                        let elapsed = Int((CFAbsoluteTimeGetCurrent() - runStart) * 1000)
                        report.append("progress scenarios=\(scenarioCount) elapsed_ms=\(elapsed) failures=\(failures.count)")
                        print("action-matrix progress scenarios=\(scenarioCount) elapsed_ms=\(elapsed) failures=\(failures.count)")
                    }

                    if failures.count >= maxFailures {
                        stopEarly = true
                    }
                }
            }
        }

        report.append("scenarios_total=\(scenarioCount)")
        report.append("scenarios_truncated=\(scenarioCount < totalPossibleScenariosInRun ? "1" : "0")")
        report.append("failures_total=\(failures.count)")
        report.append("max_failures_threshold=\(maxFailures == .max ? "unbounded" : String(maxFailures))")
        attachReport(report.joined(separator: "\n"), name: "feature-action-permutation-report")
        if !failures.isEmpty {
            let joined = failures.joined(separator: "\n")
            attachReport(joined, name: "feature-action-permutation-failures")
            XCTFail("Feature action matrix failures (\(failures.count), threshold=\(maxFailures)):\n\(failures.prefix(20).joined(separator: "\n"))")
        }
    }

    // MARK: - Actions

    @MainActor
    private func apply(actions: [EditAction], controller: NativeEditorViewController, textView: NativeMarkdownTextView) {
        for action in actions {
            let safeCaret = min(max(0, textView.selectedRange().location), textView.string.count)
            textView.setSelectedRange(NSRange(location: safeCaret, length: 0))

            switch action {
            case .insertASCII:
                textView.insertText("x", replacementRange: textView.selectedRange())
            case .insertMarkdownInline:
                textView.insertText(" **b** `c` ", replacementRange: textView.selectedRange())
            case .newline:
                textView.insertNewline(nil)
            case .lineBreak:
                textView.insertLineBreak(nil)
            case .backspace:
                if textView.selectedRange().location > 0 {
                    let handled = controller.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
                    if !handled {
                        textView.deleteBackward(nil)
                    }
                }
            case .deleteForward:
                if textView.selectedRange().location < textView.string.count {
                    textView.deleteForward(nil)
                }
            case .moveLeft:
                if textView.selectedRange().location > 0 {
                    textView.setSelectedRange(NSRange(location: textView.selectedRange().location - 1, length: 0))
                }
            case .moveRight:
                if textView.selectedRange().location < textView.string.count {
                    textView.setSelectedRange(NSRange(location: textView.selectedRange().location + 1, length: 0))
                }
            case .moveLineStart:
                let ns = textView.string as NSString
                let para = ns.paragraphRange(for: textView.selectedRange())
                textView.setSelectedRange(NSRange(location: para.location, length: 0))
            case .moveLineEnd:
                let ns = textView.string as NSString
                let para = ns.paragraphRange(for: textView.selectedRange())
                let end = max(para.location, para.location + max(0, para.length - 1))
                textView.setSelectedRange(NSRange(location: min(end, textView.string.count), length: 0))
            case .moveDocumentStart:
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            case .moveDocumentEnd:
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            case .selectWordAroundCaret:
                _ = selectWordAroundCaret(in: textView)
            case .selectCurrentLine:
                selectCurrentLine(in: textView)
            case .replaceSelectionPreservingText:
                if textView.selectedRange().length == 0 {
                    _ = selectWordAroundCaret(in: textView)
                }
                let range = textView.selectedRange()
                if range.length > 0 {
                    let ns = textView.string as NSString
                    let selected = ns.substring(with: range)
                    textView.insertText(selected, replacementRange: range)
                }
            case .cutSelection:
                if textView.selectedRange().length == 0 {
                    _ = selectWordAroundCaret(in: textView)
                }
                let range = textView.selectedRange()
                if range.length > 0 {
                    let ns = textView.string as NSString
                    inMemoryClipboard = ns.substring(with: range)
                    textView.insertText("", replacementRange: range)
                }
            case .pasteClipboard:
                if !inMemoryClipboard.isEmpty {
                    textView.insertText(inMemoryClipboard, replacementRange: textView.selectedRange())
                }
            case .undo:
                textView.undoManager?.undo()
            case .redo:
                textView.undoManager?.redo()
            case .space:
                textView.insertText(" ", replacementRange: textView.selectedRange())
            case .toggleBold:
                controller.toggleBold(nil)
            case .toggleItalic:
                controller.toggleItalic(nil)
            case .toggleCode:
                controller.toggleCode(nil)
            }
        }
    }

    @MainActor
    private func selectCurrentLine(in textView: NativeMarkdownTextView) {
        let ns = textView.string as NSString
        let caret = textView.selectedRange()
        let para = ns.paragraphRange(for: caret)
        textView.setSelectedRange(para)
    }

    @MainActor
    private func selectWordAroundCaret(in textView: NativeMarkdownTextView) -> Bool {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }

        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let caret = min(max(0, textView.selectedRange().location), ns.length)
        var start = max(0, min(caret, ns.length - 1))
        var end = start

        func scalar(at idx: Int) -> UnicodeScalar? {
            guard idx >= 0 && idx < ns.length else { return nil }
            let value = ns.character(at: idx)
            return UnicodeScalar(value)
        }

        if let s = scalar(at: start), !wordChars.contains(s), start > 0 {
            start -= 1
            end = start
        }
        guard let initial = scalar(at: start), wordChars.contains(initial) else { return false }

        while start > 0, let s = scalar(at: start - 1), wordChars.contains(s) {
            start -= 1
        }
        while end + 1 < ns.length, let s = scalar(at: end + 1), wordChars.contains(s) {
            end += 1
        }

        let length = max(0, end - start + 1)
        guard length > 0 else { return false }
        textView.setSelectedRange(NSRange(location: start, length: length))
        return true
    }

    // MARK: - Fixtures / Matrix

    private func featureSeeds() -> [FeatureSeed] {
        [
            .init(name: "heading", markdown: "# Title\nBody\n", caretPlacement: .firstOccurrence("Title")),
            .init(name: "heading-task", markdown: "## [ ] heading task\n", caretPlacement: .firstOccurrence("heading task")),
            .init(name: "bullet", markdown: "- item\n", caretPlacement: .endOfDocument),
            .init(name: "bullet-nested-task", markdown: "- parent\n  - [ ] child task\n", caretPlacement: .endOfDocument),
            .init(name: "ordered", markdown: "1. item\n2. next\n", caretPlacement: .endOfDocument),
            .init(name: "ordered-task", markdown: "1. [ ] task item\n2. [x] done item\n", caretPlacement: .endOfDocument),
            .init(name: "blockquote", markdown: "> quote with **bold** text\n", caretPlacement: .firstOccurrence("quote")),
            .init(name: "code-fence-js", markdown: "```javascript\nconsole.log(\"hi\")\n```\n", caretPlacement: .firstOccurrence("console")),
            .init(name: "code-fence-python", markdown: "```python\nprint(\"hi\")\n```\n", caretPlacement: .firstOccurrence("print")),
            .init(name: "table", markdown: "| A | B |\n| --- | --- |\n| c | d |\n", caretPlacement: .firstOccurrence("c")),
            .init(name: "horizontal-rule", markdown: "above\n\n---\n\nbelow\n", caretPlacement: .firstOccurrence("below")),
            .init(name: "image-local", markdown: "![Local sample](screenshots/01-default-sample.png)\n", caretPlacement: .endOfDocument),
            .init(name: "math-inline", markdown: "Inline math $E=mc^2$ sample\n", caretPlacement: .firstOccurrence("Inline")),
            .init(name: "math-block", markdown: "$$\nE=mc^2\n$$\n", caretPlacement: .endOfDocument),
            .init(name: "mermaid", markdown: "```mermaid\ngraph TD\nA-->B\n```\n", caretPlacement: .endOfDocument),
            .init(name: "link-inline", markdown: "[link](https://example.com)\n", caretPlacement: .firstOccurrence("link")),
            .init(name: "autolink", markdown: "<https://example.com/docs>\n", caretPlacement: .endOfDocument),
        ]
    }

    private func canonicalProfiles() -> [PreferenceProfile] {
        [
            .init(
                name: "gfm-default",
                defaults: [
                    "nativeEditor.exportDialect": "gfm",
                    "nativeEditor.gfmExtensionExportStrategy": "preserve",
                    "nativeEditor.taskRendering": "gfm",
                    "nativeEditor.orderedTasksEnabled": false,
                    "nativeEditor.headingCheckboxesEnabled": false,
                    "nativeEditor.orderedListNumbering": "gfmDefault",
                    "nativeEditor.mermaidRenderMode": "rich",
                    "nativeEditor.checkboxHitTarget": "glyph",
                    MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey: true,
                ]
            ),
            .init(
                name: "kern-extensions",
                defaults: [
                    "nativeEditor.exportDialect": "kern",
                    "nativeEditor.gfmExtensionExportStrategy": "preserve",
                    "nativeEditor.taskRendering": "kern",
                    "nativeEditor.orderedTasksEnabled": true,
                    "nativeEditor.headingCheckboxesEnabled": true,
                    "nativeEditor.orderedListNumbering": "preserveTyped",
                    "nativeEditor.mermaidRenderMode": "rich",
                    "nativeEditor.checkboxHitTarget": "marker",
                    MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey: true,
                ]
            ),
        ]
    }

    private func allPreferenceProfiles() -> [PreferenceProfile] {
        var out: [PreferenceProfile] = []

        let dialects = ["gfm", "kern"]
        let extensionStrategiesForDialect: [String: [String]] = [
            "gfm": ["preserve", "portable", "lint"],
            "kern": ["preserve"],
        ]
        let taskRenderingModes = ["gfm", "kern"]
        let bools = [false, true]
        let orderedNumberingModes = ["gfmDefault", "preserveTyped"]
        let mermaidModes = ["rich", "ascii", "auto"]
        let checkboxHitTargets = ["glyph", "marker"]

        for dialect in dialects {
            for gfmStrategy in extensionStrategiesForDialect[dialect] ?? ["preserve"] {
                for taskRendering in taskRenderingModes {
                    for orderedTasks in bools {
                        for headingCheckboxes in bools {
                            for orderedNumbering in orderedNumberingModes {
                                for mermaidMode in mermaidModes {
                                    for checkboxHitTarget in checkboxHitTargets {
                                        for remoteImages in bools {
                                            let name = [
                                                "dialect=\(dialect)",
                                                "gfmExt=\(gfmStrategy)",
                                                "task=\(taskRendering)",
                                                "orderedTasks=\(orderedTasks ? "1" : "0")",
                                                "headingTasks=\(headingCheckboxes ? "1" : "0")",
                                                "numbering=\(orderedNumbering)",
                                                "mermaid=\(mermaidMode)",
                                                "hit=\(checkboxHitTarget)",
                                                "remoteImages=\(remoteImages ? "1" : "0")",
                                            ].joined(separator: ",")

                                            out.append(
                                                .init(
                                                    name: name,
                                                    defaults: [
                                                        "nativeEditor.exportDialect": dialect,
                                                        "nativeEditor.gfmExtensionExportStrategy": gfmStrategy,
                                                        "nativeEditor.taskRendering": taskRendering,
                                                        "nativeEditor.orderedTasksEnabled": orderedTasks,
                                                        "nativeEditor.headingCheckboxesEnabled": headingCheckboxes,
                                                        "nativeEditor.orderedListNumbering": orderedNumbering,
                                                        "nativeEditor.mermaidRenderMode": mermaidMode,
                                                        "nativeEditor.checkboxHitTarget": checkboxHitTarget,
                                                        MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey: remoteImages,
                                                    ]
                                                )
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return out
    }

    private func boundedProfiles(from profiles: [PreferenceProfile], envLimitKey: String, defaultLimit: Int? = nil) -> [PreferenceProfile] {
        guard let raw = TestRuntimeConfig.string(envLimitKey),
              let limit = Int(raw),
              limit > 0 else {
            if let defaultLimit, defaultLimit > 0 {
                return Array(profiles.prefix(defaultLimit))
            }
            return profiles
        }
        return Array(profiles.prefix(limit))
    }

    private func configuredPositiveInt(key: String, defaultValue: Int) -> Int {
        guard let raw = TestRuntimeConfig.string(key),
              let value = Int(raw),
              value > 0 else {
            return max(1, defaultValue)
        }
        return value
    }

    private func shardProfiles(
        _ profiles: [PreferenceProfile],
        countKey: String = "KERN_EXHAUSTIVE_PROFILE_SHARD_COUNT",
        indexKey: String = "KERN_EXHAUSTIVE_PROFILE_SHARD_INDEX"
    ) -> [PreferenceProfile] {
        guard let shardCountRaw = TestRuntimeConfig.string(countKey),
              let shardCount = Int(shardCountRaw),
              shardCount > 1 else {
            return profiles
        }

        guard let shardIndexRaw = TestRuntimeConfig.string(indexKey),
              let shardIndex = Int(shardIndexRaw),
              shardIndex >= 0,
              shardIndex < shardCount else {
            return profiles
        }

        return profiles.enumerated().compactMap { idx, profile in
            (idx % shardCount == shardIndex) ? profile : nil
        }
    }

    private func shardDescriptor(
        countKey: String = "KERN_EXHAUSTIVE_PROFILE_SHARD_COUNT",
        indexKey: String = "KERN_EXHAUSTIVE_PROFILE_SHARD_INDEX"
    ) -> String {
        let count = TestRuntimeConfig.string(countKey) ?? "1"
        let index = TestRuntimeConfig.string(indexKey) ?? "0"
        return "\(index)/\(count)"
    }

    private func allActionPermutations(maxDepth: Int, alphabet: [EditAction]) -> [[EditAction]] {
        guard !alphabet.isEmpty else { return [] }

        var out: [[EditAction]] = []
        for depth in 1...maxDepth {
            var buffer = Array(repeating: alphabet[0], count: depth)
            func dfs(_ idx: Int) {
                if idx == depth {
                    out.append(buffer)
                    return
                }
                for a in alphabet {
                    buffer[idx] = a
                    dfs(idx + 1)
                }
            }
            dfs(0)
        }
        return out
    }

    private func actionsLabel(_ actions: [EditAction]) -> String {
        actions.map(\.rawValue).joined(separator: "+")
    }

    // MARK: - Editor Harness

    @MainActor
    private func makeHostedEditor() -> (vc: NativeEditorViewController, textView: NativeMarkdownTextView, window: NSWindow?) {
        let vc = NativeEditorViewController()
        vc.disablesDebouncedExportsForTesting = true
        _ = vc.view

        let rect = NSRect(x: 0, y: 0, width: 1100, height: 800)
        vc.view.frame = rect
        vc.view.layoutSubtreeIfNeeded()
        vc.view.displayIfNeeded()

        guard let textView = findTextView(in: vc.view) else {
            fatalError("Missing NativeEditor.TextView")
        }
        // Prevent unbounded undo stack growth during huge char-by-char stress typing.
        textView.allowsUndo = false
        textView.undoManager?.removeAllActions()
        return (vc, textView, nil)
    }

    @MainActor
    private func closeHostedEditor(_ window: NSWindow?) {
        guard let window else { return }
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }

    @MainActor
    private func resetEditor(vc: NativeEditorViewController, textView: NativeMarkdownTextView) {
        vc.stringValue = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        settleLayout(vc: vc)
    }

    @MainActor
    private func resetEditorFast(vc: NativeEditorViewController, textView: NativeMarkdownTextView) {
        vc.stringValue = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
    }

    @MainActor
    private func seedFeature(_ feature: FeatureSeed, vc: NativeEditorViewController, textView: NativeMarkdownTextView) {
        vc.stringValue = feature.markdown
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.undoManager?.removeAllActions()
        settleLayout(vc: vc)
    }

    @MainActor
    private func seedFeatureFast(_ feature: FeatureSeed, vc: NativeEditorViewController, textView: NativeMarkdownTextView) {
        vc.stringValue = feature.markdown
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        textView.undoManager?.removeAllActions()
    }

    @MainActor
    private func placeCaret(_ placement: CaretPlacement, in textView: NativeMarkdownTextView) {
        switch placement {
        case .endOfDocument:
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        case let .firstOccurrence(needle):
            let ns = textView.string as NSString
            let found = ns.range(of: needle)
            if found.location == NSNotFound {
                textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: found.location, length: 0))
            }
        }
    }

    @MainActor
    private func typeCharacterByCharacter(_ markdown: String, in textView: NativeMarkdownTextView) {
        for ch in markdown {
            if ch == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(ch), replacementRange: textView.selectedRange())
            }
        }
    }

    @MainActor
    private func typeCharacterByCharacterWithInterleavedActions(
        _ markdown: String,
        in textView: NativeMarkdownTextView,
        controller: NativeEditorViewController,
        programs: [[EditAction]],
        interval: Int
    ) {
        guard interval > 0, !programs.isEmpty else {
            typeCharacterByCharacter(markdown, in: textView)
            return
        }

        inMemoryClipboard = ""
        var typedChars = 0
        var programIndex = 0

        for ch in markdown {
            if ch == "\n" {
                textView.insertNewline(nil)
            } else {
                textView.insertText(String(ch), replacementRange: textView.selectedRange())
            }
            typedChars += 1

            if typedChars % interval == 0 {
                let program = programs[programIndex % programs.count]
                apply(actions: program, controller: controller, textView: textView)
                programIndex += 1
            }
        }
    }

    private func interleavedActionPrograms() -> [[EditAction]] {
        [
            [.moveLeft, .moveRight],
            [.moveLineStart, .moveLineEnd],
            [.moveDocumentStart, .moveDocumentEnd],
            [.insertASCII, .backspace],
            [.newline, .backspace],
            [.lineBreak, .newline],
            [.selectWordAroundCaret, .replaceSelectionPreservingText],
            [.selectCurrentLine, .replaceSelectionPreservingText],
            [.selectWordAroundCaret, .cutSelection, .pasteClipboard],
            [.selectCurrentLine, .cutSelection, .pasteClipboard],
            [.toggleBold, .toggleBold],
            [.toggleItalic, .toggleItalic],
            [.toggleCode, .toggleCode],
        ]
    }

    @MainActor
    private func settleLayout(vc: NativeEditorViewController) {
        vc.view.layoutSubtreeIfNeeded()
        vc.view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }

    @MainActor
    private func findTextView(in view: NSView) -> NativeMarkdownTextView? {
        if let tv = view as? NativeMarkdownTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Assertions / Reporting

    private func missingRequiredTokens(_ exported: String, tokens: [String]) -> [String] {
        tokens.filter { !exported.contains($0) }
    }

    @MainActor
    private func roundTripDiff(_ exported: String) -> String? {
        let reimported = NativeMarkdownCodec.importMarkdown(exported, options: .fromUserDefaults())
        let reexported = NativeMarkdownCodec.exportMarkdown(reimported, options: .fromUserDefaults())

        let n1 = normalizeForRoundTripComparison(exported)
        let n2 = normalizeForRoundTripComparison(reexported)
        guard n1 != n2 else { return nil }
        return firstDiffSummary(expected: n1, actual: n2)
    }

    private func representativeHeadingTokens(from markdown: String, maxCount: Int) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tokens: [String] = []
        for line in lines {
            guard line.hasPrefix("# ") || line.hasPrefix("## ") else { continue }
            let token = line
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            tokens.append(token)
            if tokens.count >= maxCount {
                break
            }
        }
        return tokens
    }

    private func requiredTokensPresentInSource(_ source: String, candidates: [String]) -> [String] {
        candidates.filter { source.contains($0) }
    }

    private func boundedFixture(_ source: String, envLimitKey: String, defaultLimit: Int) -> String {
        let limit = configuredPositiveInt(key: envLimitKey, defaultValue: defaultLimit)
        guard source.count > limit else { return source }
        let end = source.index(source.startIndex, offsetBy: limit)
        let prefix = String(source[..<end])
        // Keep line boundaries stable for parser behavior.
        var bounded = prefix
        if let lastNewline = prefix.lastIndex(of: "\n") {
            bounded = String(prefix[...lastNewline])
        }
        if hasOddFencedCodeMarkerCount(bounded) {
            bounded += "```\n"
        }
        return bounded
    }

    private func hasOddFencedCodeMarkerCount(_ text: String) -> Bool {
        let count = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("```") }
            .count
        return count % 2 != 0
    }

    private func normalizeNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func normalizeForRoundTripComparison(_ s: String) -> String {
        var normalized = normalizeNewlines(s)
        // List indentation between adjacent task markers can be canonicalized by the exporter.
        // Normalize these to avoid false negatives in stress round-trip comparisons.
        normalized = normalized.replacingOccurrences(
            of: #"\s{2,}(?=- \[[ xX]\])"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s{2,}(?=\d+\. \[[ xX]\])"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s{2,}(?=\d+\.)"#,
            with: " ",
            options: .regularExpression
        )
        // Task marker spacing inside lists/quotes can be canonicalized from e.g. "-  [x]" to "- [x]".
        normalized = normalized.replacingOccurrences(
            of: #"([-+*])\s{2,}(?=\[[ xX]\])"#,
            with: "$1 ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"(\d+\.)\s{2,}(?=\[[ xX]\])"#,
            with: "$1 ",
            options: .regularExpression
        )
        while normalized.last == "\n" {
            normalized.removeLast()
        }
        return normalized
    }

    private func firstDiffSummary(expected: String, actual: String) -> String {
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let maxLines = max(expectedLines.count, actualLines.count)

        for i in 0..<maxLines {
            let e = i < expectedLines.count ? expectedLines[i] : "<EOF>"
            let a = i < actualLines.count ? actualLines[i] : "<EOF>"
            if e != a {
                return "line=\(i + 1) expected='\(e)' actual='\(a)'"
            }
        }
        return "no-line-diff-found"
    }

    private func loadFixture(name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func attachReport(_ content: String, name: String) {
        let attachment = XCTAttachment(string: content)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Defaults Profile Isolation

    private func withPreferenceProfile(_ profile: PreferenceProfile, run: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let original: [String: Any?] = Dictionary(uniqueKeysWithValues: profileKeys.map { ($0, defaults.object(forKey: $0)) })

        for key in profileKeys {
            defaults.removeObject(forKey: key)
        }
        for (k, v) in profile.defaults {
            defaults.set(v, forKey: k)
        }

        defer {
            for key in profileKeys {
                defaults.removeObject(forKey: key)
            }
            for (k, v) in original {
                if let v {
                    defaults.set(v, forKey: k)
                }
            }
        }

        try run()
    }
}
