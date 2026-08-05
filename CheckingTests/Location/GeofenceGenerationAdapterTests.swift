import CoreLocation
import XCTest
@testable import Checking

/// Prova do gate de viabilidade do Prompt 15. `CLLocationManager` não entrega uma geração no callback;
/// portanto o adapter cria identificadores físicos novos por geração e só aceita token + geometria atuais.
@MainActor
final class GeofenceGenerationAdapterTests: XCTestCase {
    @MainActor
    private final class NativeSpy: GeofenceNativeRegionMonitoring {
        enum Operation: Equatable {
            case stop(String)
            case start(String)
            case requestState(String)
        }

        var regions: [GeofenceNativeRegion]
        private let reflectsStartedRegionsImmediately: Bool
        private(set) var operations: [Operation] = []
        private(set) var startedRegions: [GeofenceNativeRegion] = []

        init(
            regions: [GeofenceNativeRegion] = [],
            reflectsStartedRegionsImmediately: Bool = true
        ) {
            self.regions = regions
            self.reflectsStartedRegionsImmediately = reflectsStartedRegionsImmediately
        }

        func monitoredRegions() -> [GeofenceNativeRegion] {
            regions
        }

        func stopMonitoring(identifier: String) {
            operations.append(.stop(identifier))
            regions.removeAll { $0.identifier == identifier }
        }

        func startMonitoring(_ region: GeofenceNativeRegion) {
            operations.append(.start(region.identifier))
            startedRegions.append(region)
            guard reflectsStartedRegionsImmediately else { return }
            regions.removeAll { $0.identifier == region.identifier }
            regions.append(region)
        }

        func requestState(for identifier: String) {
            operations.append(.requestState(identifier))
        }
    }

    private final class TokenSource: @unchecked Sendable {
        private var values: [String]

        init(_ values: [String]) {
            self.values = values
        }

        func next() -> String {
            precondition(!values.isEmpty, "test token source exhausted")
            return values.removeFirst()
        }
    }

    private func region(
        _ id: String = "42",
        lat: Double = -23.5,
        lng: Double = -46.6,
        radius: Double = 150
    ) -> GeofenceRegion {
        GeofenceRegion(id: id, centerLat: lat, centerLng: lng, radiusMeters: radius)
    }

    private func makeSUT(
        native: NativeSpy = NativeSpy(),
        tokens: [String] = ["generation-a", "slot-a", "generation-b", "slot-b", "generation-c", "slot-c"]
    ) -> (GeofenceGenerationAdapter, NativeSpy) {
        let source = TokenSource(tokens)
        let adapter = GeofenceGenerationAdapter(
            native: native,
            makeOpaqueToken: { source.next() }
        )
        return (adapter, native)
    }

    func test_requestedStaysPendingUntilCurrentDidStart() {
        let (sut, native) = makeSUT()

        sut.sync([region()], omittedCount: 2)

        XCTAssertEqual(
            sut.snapshot,
            GeofenceMonitoringSnapshot(
                syncGeneration: 1,
                requestedCount: 1,
                confirmedCount: 0,
                failedCount: 0,
                failedCodes: [:],
                omittedCount: 2,
                pendingCount: 1,
                confirmationState: .requested,
                inheritedUnknownCount: 0
            )
        )
        XCTAssertEqual(native.operations.count, 1)
        guard case .start = native.operations[0] else {
            return XCTFail("a região nova precisa ser apenas solicitada")
        }
    }

    func test_oldCallbackCannotConfirmReusedLogicalIdentifierInNewGeneration() {
        let (sut, native) = makeSUT()
        let first = region()
        sut.sync([first], omittedCount: 0)
        let oldPhysical = try! XCTUnwrap(native.regions.first)

        // O ID lógico continua 42, mas a alteração real de geometria exige uma geração física nova.
        let changed = region(radius: 200)
        sut.sync([changed], omittedCount: 0)
        let currentPhysical = try! XCTUnwrap(native.regions.first)

        XCTAssertNotEqual(oldPhysical.identifier, currentPhysical.identifier)
        XCTAssertFalse(oldPhysical.identifier.contains("42"))
        XCTAssertFalse(currentPhysical.identifier.contains("42"))

        sut.didStartMonitoring(for: oldPhysical)
        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)
        XCTAssertFalse(native.operations.contains(.requestState(oldPhysical.identifier)))

        sut.didStartMonitoring(for: currentPhysical)
        XCTAssertEqual(sut.snapshot.confirmedCount, 1)
        XCTAssertEqual(sut.snapshot.pendingCount, 0)
        XCTAssertEqual(native.operations.last, .requestState(currentPhysical.identifier))
    }

    func test_oldFailureCannotContaminateCurrentGeneration_butCurrentFailureIsCountedOnce() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let oldPhysical = try! XCTUnwrap(native.regions.first)
        sut.sync([region(radius: 200)], omittedCount: 0)
        let currentPhysical = try! XCTUnwrap(native.regions.first)

        sut.monitoringDidFail(for: oldPhysical, error: CLError(.regionMonitoringDenied))
        XCTAssertEqual(sut.snapshot.failedCount, 0)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)

        sut.monitoringDidFail(for: currentPhysical, error: CLError(.regionMonitoringDenied))
        sut.monitoringDidFail(for: currentPhysical, error: CLError(.regionMonitoringDenied))

        XCTAssertEqual(sut.snapshot.failedCount, 1)
        XCTAssertEqual(sut.snapshot.pendingCount, 0)
        XCTAssertEqual(sut.snapshot.failedCodes, [.regionMonitoringDenied: 1])
        XCTAssertEqual(sut.snapshot.confirmationState, .failed)
    }

    func test_identicalResyncReusesGenerationAndDoesNotChurnNativeRegions() {
        let (sut, native) = makeSUT()
        sut.sync([region("42"), region("77", lat: -23.6)], omittedCount: 0)
        let firstGeneration = sut.snapshot.syncGeneration
        let initialOperations = native.operations

        sut.sync([region("77", lat: -23.6), region("42")], omittedCount: 0)

        XCTAssertEqual(sut.snapshot.syncGeneration, firstGeneration)
        XCTAssertEqual(native.operations, initialOperations)
    }

    func test_identicalResyncUpdatesOmittedCountWithoutPhysicalChurn() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 1)
        let firstGeneration = sut.snapshot.syncGeneration
        let initialOperations = native.operations

        // O top-20 pode permanecer idêntico mesmo quando a resposta remota ganha/perde regiões omitidas.
        sut.sync([region()], omittedCount: 4)

        XCTAssertEqual(sut.snapshot.syncGeneration, firstGeneration)
        XCTAssertEqual(sut.snapshot.omittedCount, 4)
        XCTAssertEqual(native.operations, initialOperations)
    }

    func test_identicalResyncArmsPendingGenerationAfterAvailabilityRecovers() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0, issueNativeRequests: false)
        XCTAssertTrue(native.operations.isEmpty)
        let firstGeneration = sut.snapshot.syncGeneration

        sut.sync([region()], omittedCount: 0, issueNativeRequests: true)

        XCTAssertEqual(sut.snapshot.syncGeneration, firstGeneration)
        XCTAssertEqual(native.operations.count, 1)
        guard case .start = native.operations[0] else {
            return XCTFail("a mesma geração pendente deve ser armada quando a API voltar")
        }
    }

    func test_matchingNativeRegionDoesNotBecomeConfirmedWithoutDidStart() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let physical = try! XCTUnwrap(native.regions.first)

        sut.sync([region()], omittedCount: 0)

        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)
        XCTAssertFalse(native.operations.contains(.requestState(physical.identifier)))
    }

    func test_didStartRequiresMatchingGeometryBeforeRequestingState() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let physical = try! XCTUnwrap(native.regions.first)
        let wrongGeometry = GeofenceNativeRegion(
            identifier: physical.identifier,
            centerLat: physical.centerLat,
            centerLng: physical.centerLng,
            radiusMeters: 999
        )

        sut.didStartMonitoring(for: wrongGeometry)

        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertFalse(native.operations.contains(.requestState(physical.identifier)))

        sut.didStartMonitoring(for: physical)
        XCTAssertEqual(sut.snapshot.confirmedCount, 1)
        guard let startedAt = native.operations.firstIndex(of: .start(physical.identifier)),
              let requestedAt = native.operations.firstIndex(of: .requestState(physical.identifier)) else {
            return XCTFail("o callback atual deve pedir estado")
        }
        XCTAssertLessThan(startedAt, requestedAt)
    }

    func test_duplicateDidStartDoesNotRequestStateTwice() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let physical = try! XCTUnwrap(native.regions.first)

        XCTAssertTrue(sut.didStartMonitoring(for: physical))
        XCTAssertFalse(sut.didStartMonitoring(for: physical))

        XCTAssertEqual(native.operations.filter { $0 == .requestState(physical.identifier) }.count, 1)
        XCTAssertEqual(sut.snapshot.confirmedCount, 1)
    }

    func test_partialConfirmationAndFailureRemainTechnicallyPartial() {
        let (sut, native) = makeSUT(tokens: [
            "generation-a", "slot-a", "slot-b", "generation-b", "slot-c", "slot-d"
        ])
        sut.sync([region("42"), region("77", lat: -23.6)], omittedCount: 0)
        let first = native.regions.first { $0.centerLat == -23.5 }!
        let second = native.regions.first { $0.centerLat == -23.6 }!

        sut.didStartMonitoring(for: first)
        XCTAssertEqual(sut.snapshot.confirmationState, .partiallyConfirmed)
        XCTAssertEqual(sut.snapshot.confirmedCount, 1)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)

        sut.monitoringDidFail(for: second, error: CLError(.regionMonitoringFailure))
        XCTAssertEqual(sut.snapshot.confirmationState, .partiallyConfirmed)
        XCTAssertEqual(sut.snapshot.confirmedCount, 1)
        XCTAssertEqual(sut.snapshot.failedCount, 1)
        XCTAssertEqual(sut.snapshot.pendingCount, 0)
    }

    func test_sameLogicalRegionKeepsPrivateDeduplicationKeyAcrossGeneration() {
        let (sut, native) = makeSUT()
        sut.sync([region("42")], omittedCount: 0)
        let oldPhysical = try! XCTUnwrap(native.regions.first)
        let originalDeduplicationKey = try! XCTUnwrap(
            sut.wakeDeduplicationKey(for: oldPhysical.identifier)
        )

        sut.sync([region("42", radius: 200)], omittedCount: 0)
        let currentPhysical = try! XCTUnwrap(native.regions.first)

        XCTAssertNotEqual(oldPhysical.identifier, currentPhysical.identifier)
        XCTAssertNil(sut.wakeDeduplicationKey(for: oldPhysical.identifier))
        XCTAssertEqual(
            sut.wakeDeduplicationKey(for: currentPhysical.identifier),
            originalDeduplicationKey
        )
    }

    func test_distinctLogicalRegionsUseDistinctPrivateDeduplicationKeys() {
        let (sut, native) = makeSUT(tokens: ["generation-a", "slot-a", "slot-b"])
        sut.sync([region("42"), region("77", lat: -23.6)], omittedCount: 0)
        let physical = native.regions.sorted { $0.identifier < $1.identifier }

        XCTAssertEqual(physical.count, 2)
        XCTAssertNotEqual(
            sut.wakeDeduplicationKey(for: physical[0].identifier),
            sut.wakeDeduplicationKey(for: physical[1].identifier)
        )
    }

    func test_nativeStartsPreservePrioritizerOrderRatherThanRandomPhysicalIdentifierOrder() {
        let (sut, native) = makeSUT(tokens: ["generation-a", "slot-a", "slot-b"])
        let firstPriority = region("99", lat: -23.1)
        let secondPriority = region("1", lat: -23.9)

        sut.sync([firstPriority, secondPriority], omittedCount: 0)

        XCTAssertEqual(native.startedRegions.compactMap(\.centerLat), [-23.1, -23.9])
    }

    func test_relaunchInheritedRegionsAreUncertainUntilBoundedReconciliation() {
        let inherited = GeofenceNativeRegion(
            identifier: "gfr1.previous-generation.previous-slot.0",
            centerLat: -23.5,
            centerLng: -46.6,
            radiusMeters: 150
        )
        let native = NativeSpy(regions: [inherited])
        let (sut, _) = makeSUT(native: native)

        XCTAssertEqual(sut.snapshot.confirmationState, .confirmationUncertain)
        XCTAssertEqual(sut.snapshot.inheritedUnknownCount, 1)
        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertTrue(sut.mayHandleWake(for: inherited.identifier))

        sut.sync([region()], omittedCount: 0)
        let currentPhysical = try! XCTUnwrap(native.regions.first)

        XCTAssertEqual(sut.snapshot.confirmationState, .requested)
        XCTAssertEqual(sut.snapshot.inheritedUnknownCount, 0)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)
        XCTAssertFalse(sut.mayHandleWake(for: inherited.identifier))
        XCTAssertTrue(sut.mayHandleWake(for: currentPhysical.identifier))
        XCTAssertEqual(
            Array(native.operations.prefix(2)),
            [.stop(inherited.identifier), .start(native.regions[0].identifier)]
        )
    }

    func test_candidateMigratesOnlyDecimalLegacyIdentifiersIntoFreshOpaqueGeneration() {
        // O monitor legado persistia `String(GeofenceCircle.id)` no Core Location. O candidato reconhece
        // exclusivamente esse namespace estreito para removê-lo/rearmá-lo; não o toma como confirmação.
        let legacy = GeofenceNativeRegion(
            identifier: "42",
            centerLat: -23.5,
            centerLng: -46.6,
            radiusMeters: 150
        )
        let native = NativeSpy(regions: [legacy])
        let (sut, _) = makeSUT(native: native)

        XCTAssertEqual(sut.snapshot.confirmationState, .confirmationUncertain)
        XCTAssertEqual(sut.snapshot.inheritedUnknownCount, 1)
        XCTAssertTrue(sut.mayHandleWake(for: legacy.identifier))

        sut.sync([region("42")], omittedCount: 0)
        let currentPhysical = try! XCTUnwrap(native.regions.first)

        XCTAssertTrue(currentPhysical.identifier.hasPrefix("gfr1."))
        XCTAssertFalse(currentPhysical.identifier.contains("42"))
        XCTAssertEqual(Array(native.operations.prefix(2)), [
            .stop(legacy.identifier),
            .start(currentPhysical.identifier)
        ])
        XCTAssertEqual(sut.snapshot.confirmationState, .requested)
        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertFalse(sut.mayHandleWake(for: legacy.identifier))
        XCTAssertTrue(sut.mayHandleWake(for: currentPhysical.identifier))
    }

    func test_removeAllInvalidatesInheritedWakeAliases() {
        let inherited = GeofenceNativeRegion(
            identifier: "gfr1.previous-generation.previous-slot.0",
            centerLat: -23.5,
            centerLng: -46.6,
            radiusMeters: 150
        )
        let native = NativeSpy(regions: [inherited])
        let (sut, _) = makeSUT(native: native)

        XCTAssertTrue(sut.mayHandleWake(for: inherited.identifier))

        sut.removeAll()

        XCTAssertEqual(sut.snapshot, .empty)
        XCTAssertFalse(sut.mayHandleWake(for: inherited.identifier))
        XCTAssertTrue(native.operations.contains(.stop(inherited.identifier)))
    }

    func test_removeAllInvalidatesExpectedGenerationBeforeLateCallback() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let physical = try! XCTUnwrap(native.regions.first)

        sut.removeAll()
        sut.didStartMonitoring(for: physical)

        XCTAssertEqual(sut.snapshot, .empty)
        XCTAssertFalse(native.operations.contains(.requestState(physical.identifier)))
    }

    func test_foreignNativeRegionIsNotClaimedStoppedOrUsedForWake() {
        let foreign = GeofenceNativeRegion(
            identifier: "debug.background-validation.singapore",
            centerLat: 1.3521,
            centerLng: 103.8198,
            radiusMeters: 250
        )
        // "042" parece numérico, mas nunca poderia ter sido emitido por `String(Int)` no monitor legado.
        // O candidato não deve tomar posse de um namespace externo só por parecer um ID de negócio.
        let nonCanonicalNumericForeign = GeofenceNativeRegion(
            identifier: "042",
            centerLat: 0,
            centerLng: 0,
            radiusMeters: 100
        )
        let native = NativeSpy(regions: [foreign, nonCanonicalNumericForeign])
        let (sut, _) = makeSUT(native: native)

        XCTAssertEqual(sut.snapshot, .empty)
        XCTAssertFalse(sut.mayHandleWake(for: foreign.identifier))
        XCTAssertFalse(sut.mayHandleWake(for: nonCanonicalNumericForeign.identifier))
        sut.sync([region()], omittedCount: 0)
        sut.removeAll()

        XCTAssertFalse(native.operations.contains(.stop(foreign.identifier)))
        XCTAssertFalse(native.operations.contains(.stop(nonCanonicalNumericForeign.identifier)))
    }

    func test_removeAllStopsExpectedRegionEvenBeforeNativeListReflectsStart() {
        let native = NativeSpy(reflectsStartedRegionsImmediately: false)
        let (sut, _) = makeSUT(native: native)

        sut.sync([region()], omittedCount: 0)
        guard case .start(let physicalIdentifier)? = native.operations.first else {
            return XCTFail("a solicitação nativa deveria ter sido emitida")
        }
        XCTAssertTrue(native.regions.isEmpty, "fake reproduz a janela antes de monitoredRegions atualizar")

        sut.removeAll()

        XCTAssertEqual(native.operations, [.start(physicalIdentifier), .stop(physicalIdentifier)])
        XCTAssertEqual(sut.snapshot, .empty)
    }

    func test_generationChangeStopsPendingRegionEvenBeforeNativeListReflectsStart() {
        let native = NativeSpy(reflectsStartedRegionsImmediately: false)
        let (sut, _) = makeSUT(native: native)

        sut.sync([region()], omittedCount: 0)
        guard case .start(let oldPhysicalIdentifier)? = native.operations.first else {
            return XCTFail("a solicitação nativa deveria ter sido emitida")
        }

        sut.sync([region(radius: 200)], omittedCount: 0)

        XCTAssertTrue(native.operations.contains(.stop(oldPhysicalIdentifier)))
        XCTAssertEqual(sut.snapshot.requestedCount, 1)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)
    }

    func test_failureCodeUsesClosedWhitelist() {
        let (sut, native) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let physical = try! XCTUnwrap(native.regions.first)
        let raw = NSError(
            domain: "private.domain",
            code: 999,
            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_MUST_NOT_ESCAPE"]
        )

        sut.monitoringDidFail(for: physical, error: raw)

        XCTAssertEqual(sut.snapshot.failedCodes, [.other: 1])
        XCTAssertFalse(sut.snapshot.failedCodes.keys.contains { $0.rawValue.contains("PRIVATE") })
    }

    func test_failureForUnknownPhysicalRegionDoesNotChangeCurrentGeneration() {
        let (sut, _) = makeSUT()
        sut.sync([region()], omittedCount: 0)
        let before = sut.snapshot
        let unknown = GeofenceNativeRegion(
            identifier: "gfr1.old-generation.old-slot.0",
            centerLat: -23.5,
            centerLng: -46.6,
            radiusMeters: 150
        )

        XCTAssertFalse(sut.monitoringDidFail(for: unknown, error: CLError(.regionMonitoringFailure)))

        XCTAssertEqual(sut.snapshot, before)
    }

    func test_unattributedFailureMakesCurrentGenerationExplicitlyUncertain() {
        let (sut, _) = makeSUT()
        sut.sync([region()], omittedCount: 0)

        XCTAssertTrue(sut.monitoringDidFail(for: nil, error: CLError(.regionMonitoringFailure)))
        XCTAssertFalse(sut.monitoringDidFail(for: nil, error: CLError(.regionMonitoringFailure)))

        XCTAssertEqual(sut.snapshot.confirmationState, .confirmationUncertain)
        XCTAssertEqual(sut.snapshot.confirmedCount, 0)
        XCTAssertEqual(sut.snapshot.failedCount, 0)
        XCTAssertEqual(sut.snapshot.pendingCount, 1)
    }
}
