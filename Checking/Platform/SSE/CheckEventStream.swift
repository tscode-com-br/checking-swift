import Foundation

/// Conexão SSE única compartilhada de `/check/stream`, fanned-out a todos os coletores — port de
/// CheckEventStream.kt (`shareIn` + `WhileSubscribed`). Um upstream enquanto ≥1 assinante; teardown
/// `linger` (5s) após o último sair; re-chaveia quando a `chave` muda (relogin). Ver port_spec_network_contracts §3.
///
/// Simplificação documentada: um único upstream é transmitido a TODOS os assinantes correntes. Em
/// produção, check e acidente usam a MESMA `chave`, e o re-chave coincide com a re-assinatura (os VMs
/// antigos saem no relogin), então assinantes de chaves distintas ao mesmo tempo não ocorrem.
actor CheckEventStream {
    private let makeStream: @Sendable (String) -> AsyncStream<String>
    private let lingerMillis: Int

    private var chave: String?
    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]
    private var terminated: Set<UUID> = []        // ids que terminaram ANTES de registrar (corrida add/remove)
    private var upstreamTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private(set) var upstreamStartCount = 0        // observabilidade p/ teste
    var currentSubscriberCount: Int { subscribers.count }
    var isUpstreamActive: Bool { upstreamTask != nil }

    init(lingerMillis: Int = 5000, makeStream: @escaping @Sendable (String) -> AsyncStream<String>) {
        self.lingerMillis = lingerMillis
        self.makeStream = makeStream
    }

    nonisolated func events(chave: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addSubscriber(id, chave: chave, continuation: continuation) }
            continuation.onTermination = { _ in Task { await self.removeSubscriber(id) } }
        }
    }

    private func addSubscriber(_ id: UUID, chave: String, continuation: AsyncStream<String>.Continuation) {
        if terminated.remove(id) != nil { continuation.finish(); return }   // já terminou antes de registrar → não vaza
        teardownTask?.cancel(); teardownTask = nil
        if self.chave != chave {                    // re-chave (relogin) → encerra assinantes antigos + reinicia
            for old in subscribers.values { old.finish() }   // saem via onTermination; nunca recebem a chave nova
            self.chave = chave
            upstreamTask?.cancel(); upstreamTask = nil
        }
        subscribers[id] = continuation
        if upstreamTask == nil { startUpstream(chave) }
    }

    private func startUpstream(_ chave: String) {
        upstreamStartCount += 1
        let stream = makeStream(chave)
        upstreamTask = Task { [weak self] in
            for await data in stream { await self?.broadcast(data) }
        }
    }

    private func broadcast(_ data: String) {
        for continuation in subscribers.values { continuation.yield(data) }
    }

    private func removeSubscriber(_ id: UUID) {
        if subscribers.removeValue(forKey: id) == nil {
            terminated.insert(id)                    // terminou ANTES de addSubscriber → marca p/ não registrar depois
            return
        }
        guard subscribers.isEmpty else { return }
        teardownTask = Task { [lingerMillis] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, lingerMillis)) * 1_000_000)
            if !Task.isCancelled { await self.tearDown() }
        }
    }

    private func tearDown() {
        guard subscribers.isEmpty else { return }
        upstreamTask?.cancel(); upstreamTask = nil
        chave = nil
    }
}
