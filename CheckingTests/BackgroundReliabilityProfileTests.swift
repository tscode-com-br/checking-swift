import Foundation
import XCTest
@testable import Checking

final class BackgroundReliabilityProfileTests: XCTestCase {
    func test_validConfiguredValuesResolveExactly() {
        for profile in BackgroundReliabilityProfile.allCases {
            XCTAssertEqual(
                BackgroundReliabilityProfile.resolve(configuredValue: profile.rawValue),
                profile
            )
        }
    }

    func test_missingInvalidAndUnknownValuesFallBackToLegacy() {
        let invalidValues: [Any?] = [
            nil,
            "",
            "candidate ",
            "Candidate",
            "candidateWithMovement",
            "$(CHECKING_BACKGROUND_RELIABILITY_PROFILE)",
            42
        ]

        for value in invalidValues {
            let resolved = BackgroundReliabilityProfile.resolve(configuredValue: value)
            XCTAssertEqual(resolved, .legacyWithDiagnostics)
            XCTAssertFalse(resolved.movementExperimentEnabled)
        }
    }

    func test_profilesMapToNeutralPipelineAndExposeOnlyCoherentExperimentPairs() {
        XCTAssertEqual(
            BackgroundReliabilityProfile.legacyWithDiagnostics.operationalPipeline,
            BackgroundAutomaticEvaluationPipeline.legacy
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.legacyWithDiagnostics.locationCaptureBehavior,
            .legacyCompatible
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.legacyWithDiagnostics.uiLifecycleBehavior,
            .legacyCompatible
        )
        XCTAssertFalse(BackgroundReliabilityProfile.legacyWithDiagnostics.movementExperimentEnabled)

        XCTAssertEqual(
            BackgroundReliabilityProfile.candidate.operationalPipeline,
            BackgroundAutomaticEvaluationPipeline.candidate
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.candidate.locationCaptureBehavior,
            .freshnessValidated
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.candidate.uiLifecycleBehavior,
            .headlessGuarded
        )
        XCTAssertFalse(BackgroundReliabilityProfile.candidate.movementExperimentEnabled)

        XCTAssertEqual(
            BackgroundReliabilityProfile.candidateWithMovementExperiment.operationalPipeline,
            BackgroundAutomaticEvaluationPipeline.candidate
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.candidateWithMovementExperiment.locationCaptureBehavior,
            .freshnessValidated
        )
        XCTAssertEqual(
            BackgroundReliabilityProfile.candidateWithMovementExperiment.uiLifecycleBehavior,
            .headlessGuarded
        )
        XCTAssertTrue(
            BackgroundReliabilityProfile.candidateWithMovementExperiment.movementExperimentEnabled
        )
    }

    func test_defaultPreviewUsesLegacyProfile() {
        XCTAssertEqual(
            AppEnvironment.preview.backgroundReliabilityProfile,
            .legacyWithDiagnostics
        )
    }

    func test_debugHostBundleResolvesLegacyProfile() {
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: BackgroundReliabilityProfile.infoDictionaryKey
            ) as? String,
            BackgroundReliabilityProfile.legacyWithDiagnostics.rawValue
        )
        XCTAssertEqual(BackgroundReliabilityProfile.fromBundle(), .legacyWithDiagnostics)
    }

    func test_previewFactoryInjectsEveryProfileWithoutStartingFunctionalPaths() async {
        for profile in BackgroundReliabilityProfile.allCases {
            let environment = AppEnvironment.makePreview(backgroundReliabilityProfile: profile)

            let orchestratorIsRunning = await environment.orchestrator.isRunningForTest
            let significantMonitorIsActive = await environment.significantLocationMonitor.isActive()
            let offlineDrainCount = await environment.offlineSyncCoordinator.drainCount
            let journalRecords = await environment.evaluationJournal.recent(limit: 1)

            XCTAssertEqual(environment.backgroundReliabilityProfile, profile)
            XCTAssertFalse(orchestratorIsRunning)
            XCTAssertFalse(significantMonitorIsActive)
            XCTAssertEqual(offlineDrainCount, 0)
            XCTAssertTrue(journalRecords.isEmpty)
            XCTAssertEqual(environment.activityLog.count(), 0)
        }
    }

    func test_allBuildConfigurationsExplicitlySelectLegacy() throws {
        let expectedSetting = "CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics"

        for name in ["Debug.xcconfig", "Staging.xcconfig", "Release.xcconfig"] {
            let contents = try String(
                contentsOf: repositoryRoot
                    .appendingPathComponent("Config")
                    .appendingPathComponent(name),
                encoding: .utf8
            )
            let settings = contents
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let assignments = settings.filter {
                $0.hasPrefix("CHECKING_BACKGROUND_RELIABILITY_PROFILE")
            }

            XCTAssertEqual(
                assignments,
                [expectedSetting],
                "\(name) must define the legacy profile exactly once"
            )
        }
    }

    func test_physicalValidationConfigurationIsLocalCandidateWithoutExperiment() throws {
        let physicalConfig = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Config")
                .appendingPathComponent("PhysicalValidation.xcconfig"),
            encoding: .utf8
        )
        let project = try String(
            contentsOf: repositoryRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let releaseConfig = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Config")
                .appendingPathComponent("Release.xcconfig"),
            encoding: .utf8
        )

        for requiredSetting in [
            "CHECKING_BUNDLE_ID = br.com.tscode.checking.physicalvalidation",
            "CHECKING_APP_NAME = Checking Physical Validation",
            "CHECKING_APNS_ENV = production",
            "CHECKING_BACKGROUND_RELIABILITY_PROFILE = candidate",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) PHYSICAL_VALIDATION",
            "SWIFT_OPTIMIZATION_LEVEL = -O",
        ] {
            XCTAssertTrue(physicalConfig.contains(requiredSetting), "Missing: \(requiredSetting)")
        }

        XCTAssertFalse(physicalConfig.contains("candidateWithMovementExperiment"))
        XCTAssertFalse(physicalConfig.contains("DEBUG=1"))
        XCTAssertFalse(physicalConfig.contains("CODE_SIGNING_ALLOWED = NO"))
        XCTAssertFalse(physicalConfig.contains("CODE_SIGNING_REQUIRED = NO"))
        XCTAssertFalse(releaseConfig.contains("PHYSICAL_VALIDATION"))
        XCTAssertEqual(
            BackgroundReliabilityProfile.resolve(configuredValue: "candidate"),
            .candidate
        )
        XCTAssertFalse(BackgroundReliabilityProfile.candidate.movementExperimentEnabled)

        XCTAssertTrue(project.contains("PhysicalValidation: release"))
        XCTAssertTrue(project.contains("PhysicalValidation: Config/PhysicalValidation.xcconfig"))
        XCTAssertTrue(project.contains("Checking (PhysicalValidation):"))
    }

    func test_physicalValidationSurfaceDoesNotReferenceDebugHarnessOrExportTypes() throws {
        let physicalSurface = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Checking/Features/Check/PhysicalValidationSnapshotScreen.swift"),
            encoding: .utf8
        )
        let debugSurface = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Checking/Features/Check/PhysicalValidationScreen.swift"),
            encoding: .utf8
        )
        let route = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Checking/Features/Check/CheckMainScreen.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(physicalSurface.hasPrefix("#if DEBUG || PHYSICAL_VALIDATION"))
        XCTAssertTrue(debugSurface.hasPrefix("#if DEBUG"))
        XCTAssertTrue(route.contains("#elseif PHYSICAL_VALIDATION"))
        for forbiddenType in [
            "BackgroundValidationHarness",
            "BackgroundValidationRecorder",
            "EvaluationDiagnosticsExporter",
            "EvaluationDiagnosticsActivitySheet",
            "UIActivityViewController",
        ] {
            XCTAssertFalse(physicalSurface.contains(forbiddenType), "Unexpected: \(forbiddenType)")
        }
    }

    func test_infoPlistReferencesTheAuditableBuildSetting() throws {
        let data = try Data(
            contentsOf: repositoryRoot
                .appendingPathComponent("Checking")
                .appendingPathComponent("Info.plist")
        )
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            plist[BackgroundReliabilityProfile.infoDictionaryKey] as? String,
            "$(CHECKING_BACKGROUND_RELIABILITY_PROFILE)"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
