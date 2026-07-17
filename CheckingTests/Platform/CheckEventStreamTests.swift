import XCTest
@testable import Checking

// Port de CheckEventStream.kt (shareIn WhileSubscribed): 1 upstream compartilhado; re-chave reinicia.
final class CheckEventStreamTests: XCTestCase {

    func test_same_chave_shares_single_upstream_and_broadcasts() async {
        let factory = UpstreamFactory()
        let stream = CheckEventStream(lingerMillis: 50, makeStream: factory.make)
        let s1 = stream.events(chave: "A")
        let s2 = stream.events(chave: "A")

        let c1 = Task { () -> [String] in var out: [String] = []; for await v in s1 { out.append(v); break }; return out }
        let c2 = Task { () -> [String] in var out: [String] = []; for await v in s2 { out.append(v); break }; return out }

        await waitUntil { await stream.currentSubscriberCount == 2 }   // ambos assinaram
        let startCount = await stream.upstreamStartCount
        XCTAssertEqual(startCount, 1)                                  // um único upstream
        XCTAssertEqual(factory.callCount, 1)

        factory.push("hello")
        let r1 = await c1.value; let r2 = await c2.value
        XCTAssertEqual(r1, ["hello"])
        XCTAssertEqual(r2, ["hello"])                                  // transmitido aos dois
    }

    func test_rekey_starts_new_upstream() async {
        let factory = UpstreamFactory()
        let stream = CheckEventStream(lingerMillis: 50, makeStream: factory.make)

        let s1 = stream.events(chave: "A")
        let c1 = Task { for await _ in s1 {} }
        await waitUntil { await stream.upstreamStartCount == 1 }

        let s2 = stream.events(chave: "B")                            // chave diferente → re-chave
        let c2 = Task { for await _ in s2 {} }
        await waitUntil { await stream.upstreamStartCount == 2 }

        let startCount = await stream.upstreamStartCount
        XCTAssertEqual(startCount, 2)
        XCTAssertEqual(factory.chaves, ["A", "B"])
        c1.cancel(); c2.cancel()
    }

    func test_upstream_torn_down_after_linger_when_last_leaves() async {
        let factory = UpstreamFactory()
        let stream = CheckEventStream(lingerMillis: 30, makeStream: factory.make)
        let s1 = stream.events(chave: "A")
        let c1 = Task { for await _ in s1 {} }
        await waitUntil { await stream.isUpstreamActive }             // upstream ligado
        c1.cancel()                                                   // último assinante sai
        await waitUntil(timeout: 3) { await stream.isUpstreamActive == false }   // após o linger → derrubado
        let startCountAfterTeardown = await stream.upstreamStartCount
        XCTAssertEqual(startCountAfterTeardown, 1)
        // nova assinatura recria o upstream (prova que o anterior foi derrubado)
        let s2 = stream.events(chave: "A")
        let c2 = Task { for await _ in s2 {} }
        await waitUntil(timeout: 3) { await stream.upstreamStartCount == 2 }
        let finalCount = await stream.upstreamStartCount
        XCTAssertEqual(finalCount, 2)
        c2.cancel()
    }
}
