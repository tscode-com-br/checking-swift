import Foundation
import XCTest
@testable import Checking

final class BackgroundExecutionLeaseTests: XCTestCase {
    private static let invalidToken = -1

    func test_expirationNotifiesOwnerAndEndsPhysicalTaskExactlyOnce() async {
        let operations = LeaseOperations(token: 41)
        let expiration = CallbackCounter()
        let sut = makeSUT(operations)

        let lease = await sut.begin(name: "candidate evaluation") {
            expiration.increment()
        }
        operations.fireExpiration()
        operations.fireExpiration()
        lease.end()

        XCTAssertEqual(operations.beginNames, ["candidate evaluation"])
        XCTAssertEqual(expiration.value, 1)
        XCTAssertEqual(operations.endTokens, [41])
    }

    func test_endCalledTwiceEndsPhysicalTaskOnceWithoutReportingExpiration() async {
        let operations = LeaseOperations(token: 42)
        let expiration = CallbackCounter()
        let sut = makeSUT(operations)

        let lease = await sut.begin(name: "candidate evaluation") {
            expiration.increment()
        }
        lease.end()
        lease.end()
        operations.fireExpiration()

        XCTAssertEqual(expiration.value, 0)
        XCTAssertEqual(operations.endTokens, [42])
    }

    func test_expirationDuringBeginStillEndsReturnedTokenExactlyOnce() async {
        let operations = LeaseOperations(token: 43, expiresBeforeBeginReturns: true)
        let expiration = CallbackCounter()
        let sut = makeSUT(operations)

        let lease = await sut.begin(name: "candidate evaluation") {
            expiration.increment()
        }
        lease.end()

        XCTAssertEqual(expiration.value, 1)
        XCTAssertEqual(operations.endTokens, [43])
    }

    func test_invalidTokenProducesSafeNoopLease() async {
        let operations = LeaseOperations(token: Self.invalidToken)
        let expiration = CallbackCounter()
        let sut = makeSUT(operations)

        let lease = await sut.begin(name: "candidate evaluation") {
            expiration.increment()
        }
        lease.end()
        lease.end()

        XCTAssertEqual(expiration.value, 0)
        XCTAssertEqual(operations.endTokens, [])
    }

    func test_noopLeasingIsDeterministicAndNeverExpiresOwner() async {
        let expiration = CallbackCounter()
        let sut: any BackgroundExecutionLeasing = NoopBackgroundExecutionLeasing()

        let lease = await sut.begin(name: "preview") {
            expiration.increment()
        }
        lease.end()
        lease.end()

        XCTAssertEqual(expiration.value, 0)
    }

    func test_legacyGuardContractRemainsAvailable() async {
        let operations = LeaseOperations(token: 44)
        let concrete = makeSUT(operations)
        let sut: any BackgroundTaskGuard = concrete

        let token = await sut.begin()
        sut.end(token)

        XCTAssertEqual(operations.beginNames, ["Checking automatic evaluation"])
        XCTAssertEqual(operations.endTokens, [44])
    }

    func test_endAndExpirationRaceEndsPhysicalTaskExactlyOnce() async {
        for iteration in 0..<100 {
            let operations = LeaseOperations(token: 1_000 + iteration)
            let expiration = CallbackCounter()
            let sut = makeSUT(operations)
            let lease = await sut.begin(name: "race") {
                expiration.increment()
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { lease.end() }
                group.addTask { operations.fireExpiration() }
            }

            XCTAssertEqual(operations.endTokens, [1_000 + iteration])
            XCTAssertLessThanOrEqual(expiration.value, 1)
        }
    }

    private func makeSUT(_ operations: LeaseOperations) -> UIKitBackgroundTaskGuard {
        UIKitBackgroundTaskGuard(
            invalidToken: Self.invalidToken,
            beginOperation: { name, expirationHandler in
                operations.begin(name: name, expirationHandler: expirationHandler)
            },
            endOperation: { token in
                operations.end(token: token)
            }
        )
    }
}

private final class LeaseOperations: @unchecked Sendable {
    private let lock = NSLock()
    private let token: Int
    private let expiresBeforeBeginReturns: Bool
    private var recordedBeginNames: [String] = []
    private var recordedEndTokens: [Int] = []
    private var expirationHandler: (@Sendable () -> Void)?

    init(token: Int, expiresBeforeBeginReturns: Bool = false) {
        self.token = token
        self.expiresBeforeBeginReturns = expiresBeforeBeginReturns
    }

    var beginNames: [String] { lock.withLock { recordedBeginNames } }
    var endTokens: [Int] { lock.withLock { recordedEndTokens } }

    func begin(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) -> Int {
        lock.withLock {
            recordedBeginNames.append(name)
            self.expirationHandler = expirationHandler
        }
        if expiresBeforeBeginReturns { expirationHandler() }
        return token
    }

    func end(token: Int) {
        lock.withLock {
            recordedEndTokens.append(token)
        }
    }

    func fireExpiration() {
        let handler = lock.withLock { expirationHandler }
        handler?()
    }
}

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
