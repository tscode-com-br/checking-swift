import Foundation
import XCTest
@testable import Checking

final class BackgroundExecutionControlTests: XCTestCase {
    private final class CancellationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [EvaluationCancellationReason] = []

        func record(_ reason: EvaluationCancellationReason) {
            lock.withLock { reasons.append(reason) }
        }

        var snapshot: [EvaluationCancellationReason] {
            lock.withLock { reasons }
        }
    }

    private final class CompletionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []

        func record(_ value: Bool) {
            lock.withLock { values.append(value) }
        }

        var snapshot: [Bool] {
            lock.withLock { values }
        }
    }

    func test_cancellationReasonIsFirstWins() {
        let sut = EvaluationCancellationContext()

        XCTAssertTrue(sut.cancel(.bgTaskExpired))
        XCTAssertFalse(sut.cancel(.contextInvalidated))
        XCTAssertFalse(sut.cancel(.taskCancelled))
        XCTAssertEqual(sut.reason, .bgTaskExpired)
        XCTAssertTrue(sut.isCancelled)
    }

    func test_handlerInstalledBeforeCancellationIsDeliveredExactlyOnce() {
        let sut = EvaluationCancellationContext()
        let recorder = CancellationRecorder()

        XCTAssertTrue(sut.installCancellationHandler { recorder.record($0) })
        XCTAssertTrue(sut.cancel(.uiBackgroundTimeExpired))
        XCTAssertFalse(sut.cancel(.bgTaskExpired))
        XCTAssertFalse(sut.installCancellationHandler { recorder.record($0) })

        XCTAssertEqual(recorder.snapshot, [.uiBackgroundTimeExpired])
    }

    func test_handlerInstalledAfterCancellationReceivesWinningReasonExactlyOnce() {
        let sut = EvaluationCancellationContext()
        let recorder = CancellationRecorder()

        XCTAssertTrue(sut.cancel(.contextInvalidated))
        XCTAssertTrue(sut.installCancellationHandler { recorder.record($0) })
        XCTAssertFalse(sut.installCancellationHandler { recorder.record($0) })
        XCTAssertFalse(sut.cancel(.taskCancelled))

        XCTAssertEqual(recorder.snapshot, [.contextInvalidated])
    }

    func test_firstOwnerExpirationKeepsWorkAndLastOwnerCancelsIt() {
        let context = EvaluationCancellationContext()
        let recorder = CancellationRecorder()
        XCTAssertTrue(context.installCancellationHandler { recorder.record($0) })
        let sut = BackgroundWorkOwnership(cancellationContext: context)
        let refresh = tryAcquire(.bgAppRefresh, from: sut)
        let ui = tryAcquire(.uiBackgroundTask, from: sut)

        XCTAssertEqual(sut.expire(refresh), .workContinues)
        XCTAssertEqual(sut.activeOwnerCount, 1)
        XCTAssertFalse(context.isCancelled)
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertEqual(
            sut.expirationSnapshot,
            BackgroundWorkExpirationSnapshot(
                expiredOwners: [.bgAppRefresh],
                cancellingOwner: nil
            )
        )

        XCTAssertEqual(sut.expire(ui), .workCancelled)
        XCTAssertEqual(sut.activeOwnerCount, 0)
        XCTAssertEqual(context.reason, .uiBackgroundTimeExpired)
        XCTAssertEqual(recorder.snapshot, [.uiBackgroundTimeExpired])
        XCTAssertEqual(
            sut.expirationSnapshot,
            BackgroundWorkExpirationSnapshot(
                expiredOwners: [.bgAppRefresh, .uiBackgroundTask],
                cancellingOwner: .uiBackgroundTask
            )
        )
        XCTAssertEqual(sut.expire(ui), .ignored)
    }

    func test_normalReleaseDoesNotCancelSharedContext() {
        let sut = BackgroundWorkOwnership()
        let refresh = tryAcquire(.bgAppRefresh, from: sut)

        XCTAssertTrue(sut.release(refresh))
        XCTAssertFalse(sut.release(refresh))
        XCTAssertEqual(sut.activeOwnerCount, 0)
        XCTAssertFalse(sut.cancellationContext.isCancelled)

        XCTAssertNotNil(sut.acquire(.bgAppRefresh))
    }

    func test_contextInvalidationCancelsGloballyAndRemovesEveryOwner() {
        let sut = BackgroundWorkOwnership()
        let refresh = tryAcquire(.bgAppRefresh, from: sut)
        let ui = tryAcquire(.uiBackgroundTask, from: sut)
        let processing = tryAcquire(.bgProcessing, from: sut)

        XCTAssertTrue(sut.invalidateContext())
        XCTAssertFalse(sut.invalidateContext())
        XCTAssertEqual(sut.cancellationContext.reason, .contextInvalidated)
        XCTAssertEqual(sut.activeOwnerCount, 0)
        XCTAssertTrue(sut.isFinished)
        XCTAssertNil(sut.acquire(.bgAppRefresh))
        XCTAssertEqual(sut.expire(refresh), .ignored)
        XCTAssertEqual(sut.expire(ui), .ignored)
        XCTAssertEqual(sut.expire(processing), .ignored)
    }

    func test_ownerStorageIsBoundedToOneTokenPerKnownKind() {
        let sut = BackgroundWorkOwnership()

        for kind in BackgroundWorkOwnerKind.allCases {
            XCTAssertNotNil(sut.acquire(kind))
            XCTAssertNil(sut.acquire(kind))
        }

        XCTAssertEqual(
            sut.activeOwnerCount,
            BackgroundWorkOwnership.maximumOwnerCount
        )
        XCTAssertEqual(
            BackgroundWorkOwnership.maximumOwnerCount,
            BackgroundWorkOwnerKind.allCases.count
        )
    }

    func test_finishClosesAndReleasesWithoutFabricatingCancellation() {
        let context = EvaluationCancellationContext()
        let recorder = CancellationRecorder()
        XCTAssertTrue(context.installCancellationHandler { recorder.record($0) })
        let sut = BackgroundWorkOwnership(cancellationContext: context)
        let refresh = tryAcquire(.bgAppRefresh, from: sut)
        _ = tryAcquire(.uiBackgroundTask, from: sut)

        XCTAssertTrue(sut.finish())
        XCTAssertFalse(sut.finish())
        XCTAssertTrue(sut.isFinished)
        XCTAssertEqual(sut.activeOwnerCount, 0)
        XCTAssertFalse(context.isCancelled)
        XCTAssertFalse(context.cancel(.taskCancelled))
        XCTAssertNil(context.reason)
        XCTAssertTrue(recorder.snapshot.isEmpty)
        XCTAssertFalse(context.installCancellationHandler { recorder.record($0) })
        XCTAssertNil(sut.acquire(.bgProcessing))
        XCTAssertEqual(sut.expire(refresh), .ignored)
    }

    func test_finishAfterCancellationPreservesReasonAndRejectsLateHandler() {
        let context = EvaluationCancellationContext()
        let recorder = CancellationRecorder()
        let sut = BackgroundWorkOwnership(cancellationContext: context)
        _ = tryAcquire(.bgAppRefresh, from: sut)

        XCTAssertTrue(context.cancel(.taskCancelled))
        XCTAssertTrue(sut.finish())
        XCTAssertEqual(context.reason, .taskCancelled)
        XCTAssertFalse(context.cancel(.contextInvalidated))
        XCTAssertFalse(context.installCancellationHandler { recorder.record($0) })
        XCTAssertTrue(recorder.snapshot.isEmpty)
    }

    func test_registrationAppliesExpirationThatWonBeforeCanonicalAttach() async {
        let ownership = BackgroundWorkOwnership()
        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)

        XCTAssertEqual(
            registration.expire(reason: .bgTaskExpired),
            .pendingAttachment
        )
        let expirationReason = await registration.waitForExpiration()
        XCTAssertEqual(expirationReason, .bgTaskExpired)
        XCTAssertTrue(
            registration.release(),
            "o waiter expirado pode fechar antes de a admissão produzir o ownership canônico"
        )
        XCTAssertEqual(
            registration.attach(to: ownership),
            .pendingExpirationApplied(.workCancelled)
        )
        XCTAssertEqual(registration.appliedExpirationResult, .workCancelled)
        XCTAssertEqual(ownership.cancellationContext.reason, .bgTaskExpired)
        XCTAssertEqual(ownership.activeOwnerCount, 0)
        XCTAssertFalse(registration.release())
    }

    func test_registrationExpirationAfterAttachReportsWhetherCanonicalWorkContinues() async {
        let ownership = BackgroundWorkOwnership()
        let ui = tryAcquire(.uiBackgroundTask, from: ownership)
        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)

        XCTAssertEqual(registration.attach(to: ownership), .attached)
        XCTAssertEqual(
            registration.expire(reason: .bgTaskExpired),
            .applied(.workContinues)
        )
        XCTAssertEqual(registration.appliedExpirationResult, .workContinues)
        XCTAssertFalse(
            registration.expire(reason: .contextInvalidated).cancelledCanonicalWork
        )
        let expirationReason = await registration.waitForExpiration()
        XCTAssertEqual(expirationReason, .bgTaskExpired)
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(ownership.activeOwnerCount, 1)

        XCTAssertEqual(ownership.expire(ui), .workCancelled)
        XCTAssertEqual(
            ownership.cancellationContext.reason,
            .uiBackgroundTimeExpired
        )
    }

    func test_registrationReleaseIsIdempotentAndReleasesAttachedOwner() {
        let ownership = BackgroundWorkOwnership()
        let registration = BackgroundWorkOwnerRegistration(kind: .bgProcessing)

        XCTAssertEqual(registration.attach(to: ownership), .attached)
        XCTAssertEqual(ownership.activeOwnerCount, 1)
        XCTAssertTrue(registration.release())
        XCTAssertFalse(registration.release())
        XCTAssertEqual(ownership.activeOwnerCount, 0)
        XCTAssertFalse(ownership.cancellationContext.isCancelled)
        XCTAssertEqual(
            registration.expire(reason: .bgTaskExpired),
            .ignored
        )
    }

    func test_cancellingExpirationWaiterReturnsNilWithoutWaitingForSignal() async {
        let registration = BackgroundWorkOwnerRegistration(kind: .bgAppRefresh)
        let waiter = Task { await registration.waitForExpiration() }

        waiter.cancel()

        let expirationReason = await waiter.value
        XCTAssertNil(expirationReason)
        XCTAssertNil(registration.expirationReason)
    }

    func test_completionGateCallsCallbackOnceAndKeepsWinningValue() {
        let recorder = CompletionRecorder()
        let sut = BGTaskCompletionGate { recorder.record($0) }

        XCTAssertTrue(sut.complete(success: false))
        XCTAssertFalse(sut.complete(success: true))
        XCTAssertFalse(sut.complete(success: false))
        XCTAssertEqual(sut.result, false)
        XCTAssertEqual(recorder.snapshot, [false])
    }

    func test_completionGateRaceHasExactlyOneWinnerAndOneCallback() async {
        let recorder = CompletionRecorder()
        let sut = BGTaskCompletionGate { recorder.record($0) }

        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<100 {
                group.addTask {
                    sut.complete(success: index.isMultiple(of: 2))
                }
            }
            var count = 0
            for await didWin in group where didWin {
                count += 1
            }
            return count
        }

        XCTAssertEqual(winners, 1)
        XCTAssertEqual(recorder.snapshot.count, 1)
        XCTAssertEqual(recorder.snapshot.first, sut.result)
    }

    private func tryAcquire(
        _ kind: BackgroundWorkOwnerKind,
        from ownership: BackgroundWorkOwnership,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> BackgroundWorkOwnerToken {
        guard let token = ownership.acquire(kind) else {
            XCTFail("Expected owner token for \(kind)", file: file, line: line)
            fatalError("Missing owner token")
        }
        return token
    }
}
