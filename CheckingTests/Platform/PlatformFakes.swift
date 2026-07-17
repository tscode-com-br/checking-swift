import Foundation
@testable import Checking

/// Faz poll até a condição ou timeout (para asserções sobre estado assíncrono de actors/streams).
func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Portão async controlado pelo teste (bloqueia `wait()` até `release()`).
actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { self.continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// Monitor de rede fake — emite o estado atual ao assinar, depois em cada `set()` (distinct).
final class FakeNetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var current: Bool
    init(online: Bool) { self.current = online }
    var subscriberCount: Int { lock.withLock { continuations.count } }

    func onlineStates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation; continuation.yield(current) }
            continuation.onTermination = { _ in self.lock.withLock { _ = self.continuations.removeValue(forKey: id) } }
        }
    }
    func set(_ online: Bool) {
        lock.withLock {
            guard online != current else { return }        // distinctUntilChanged
            current = online
            for continuation in continuations.values { continuation.yield(online) }
        }
    }
}

/// Conexão SSE roteirizada — cada `connect()` consome o próximo comportamento (dados + fim/erro).
final class ScriptedSSEConnection: SSEConnecting, @unchecked Sendable {
    enum Behavior { case dataThenFinish([String]); case dataThenError([String], Error) }
    private let lock = NSLock()
    private var behaviors: [Behavior]
    private var count = 0
    var connectCount: Int { lock.withLock { count } }
    init(_ behaviors: [Behavior]) { self.behaviors = behaviors }

    func connect(_ url: URL) -> AsyncThrowingStream<String, Error> {
        let behavior: Behavior? = lock.withLock {
            count += 1
            return behaviors.isEmpty ? nil : behaviors.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .none:
                continuation.finish()                       // scripts acabaram → fim normal
            case .dataThenFinish(let items):
                items.forEach { continuation.yield($0) }; continuation.finish()
            case .dataThenError(let items, let error):
                items.forEach { continuation.yield($0) }; continuation.finish(throwing: error)
            }
        }
    }
}

/// Sleeper que só grava os delays pedidos (sem esperar de verdade).
final class RecordingSleeper: Sleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    var delays: [Int] { lock.withLock { recorded } }
    func sleep(milliseconds: Int) async { lock.withLock { recorded.append(milliseconds) } }
}

/// Spy do drainer offline — conta chamadas, pode sinalizar/bloquear (p/ single-flight).
final class SpyDrainer: OfflineDraining, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    var onDrain: (@Sendable () -> Void)?
    var block: (@Sendable () async -> Void)?
    var result: DrainResult = .completed
    func drain() async -> DrainResult {
        lock.withLock { calls += 1 }
        onDrain?()
        if let block { await block() }
        return result
    }
}

/// Fábrica de upstream p/ os testes do CheckEventStream — grava as chaves e transmite via `push()`.
final class UpstreamFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedChaves: [String] = []
    private var continuations: [AsyncStream<String>.Continuation] = []
    var callCount: Int { lock.withLock { recordedChaves.count } }
    var chaves: [String] { lock.withLock { recordedChaves } }

    func make(_ chave: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            lock.withLock { recordedChaves.append(chave); continuations.append(continuation) }
        }
    }
    func push(_ value: String) { lock.withLock { continuations.forEach { $0.yield(value) } } }
}
