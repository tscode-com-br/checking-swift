import Foundation
import XCTest
@testable import Checking

final class AuthSessionCoordinatorTests: XCTestCase {
    private let chave = "ABCD"
    private let cookieURL = URL(string: "https://example.invalid/api/web/check/state")!

    func test_useCurrentSessionDoesNotClearOrAuthenticate() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "current-session")

        let generation = await harness.coordinator.useCurrentSession()
        let isCurrent = await harness.coordinator.isCurrent(generation)
        let loginCallCount = await harness.repository.loginCallCount
        let logoutCallCount = await harness.repository.logoutCallCount

        XCTAssertTrue(isCurrent)
        XCTAssertEqual(harness.cookies.cookieHeader(for: cookieURL), "session=current-session")
        XCTAssertEqual(loginCallCount, 0)
        XCTAssertEqual(logoutCallCount, 0)
    }

    func test_mutationTailRemainsSerialAcrossAwait() async {
        let harness = makeHarness()
        let firstGate = AsyncGate()
        await harness.repository.enqueueLoginGate(firstGate)
        let chave = chave

        let first = Task {
            await harness.coordinator.login(chave, "first-password")
        }
        let firstStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(firstStarted)

        let second = Task {
            await harness.coordinator.login(chave, "second-password")
        }
        try? await Task.sleep(for: .milliseconds(30))
        let callCountWhileBlocked = await harness.repository.loginCallCount
        let maxConcurrencyWhileBlocked = await harness.repository.maximumConcurrentLogins
        XCTAssertEqual(callCountWhileBlocked, 1)
        XCTAssertEqual(maxConcurrencyWhileBlocked, 1)

        await firstGate.release()
        _ = await first.value
        _ = await second.value

        let finalCallCount = await harness.repository.loginCallCount
        let finalMaxConcurrency = await harness.repository.maximumConcurrentLogins
        let passwords = await harness.repository.loginPasswords
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(finalMaxConcurrency, 1)
        XCTAssertEqual(passwords, ["first-password", "second-password"])
    }

    func test_twoSilentReloginsShareOneTaskAndStatus() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "savedpw")
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        let expected = authenticatedStatus()
        await harness.repository.setLoginResult(.success(expected))
        let chave = chave

        let first = Task { await harness.coordinator.silentRelogin(chave) }
        let firstStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(firstStarted)
        let second = Task { await harness.coordinator.silentRelogin(chave) }
        try? await Task.sleep(for: .milliseconds(30))
        let callCountWhileBlocked = await harness.repository.loginCallCount
        XCTAssertEqual(callCountWhileBlocked, 1)

        await loginGate.release()

        let firstResult = await first.value
        let secondResult = await second.value
        let finalCallCount = await harness.repository.loginCallCount
        let finalMaxConcurrency = await harness.repository.maximumConcurrentLogins
        XCTAssertEqual(firstResult, .refreshed(expected))
        XCTAssertEqual(secondResult, .refreshed(expected))
        XCTAssertEqual(finalCallCount, 1)
        XCTAssertEqual(finalMaxConcurrency, 1)
    }

    func test_cancelledWaiterDoesNotCancelSharedSilentRelogin() async {
        let joinedRefresh = RefreshJoinProbe()
        let harness = makeHarness(
            didJoinExistingSilentRelogin: { joinedRefresh.markJoined() }
        )
        harness.passwords.setPassword(chave, "savedpw")
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        let expected = authenticatedStatus()
        await harness.repository.setLoginResult(.success(expected))
        let chave = chave

        let cancelledWaiter = Task {
            await harness.coordinator.silentRelogin(chave)
        }
        let firstStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(firstStarted)
        let survivingWaiter = Task {
            await harness.coordinator.silentRelogin(chave)
        }
        let survivorJoined = await waitUntilTrue {
            joinedRefresh.joined
        }
        XCTAssertTrue(survivorJoined)
        cancelledWaiter.cancel()
        await loginGate.release()

        let survivingResult = await survivingWaiter.value
        let cancelledResult = await cancelledWaiter.value
        let callCount = await harness.repository.loginCallCount
        XCTAssertEqual(survivingResult, .refreshed(expected))
        XCTAssertEqual(cancelledResult, .refreshed(expected))
        XCTAssertEqual(callCount, 1)
    }

    func test_silentReloginReadsPasswordOnlyWhenItReachesHeadOfTail() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "oldpw")
        let blockingGate = AsyncGate()
        await harness.repository.enqueueLoginGate(blockingGate)
        let chave = chave

        let blockingLogin = Task {
            await harness.coordinator.login("WXYZ", "blocking-password")
        }
        let blockingLoginStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(blockingLoginStarted)

        let refresh = Task {
            await harness.coordinator.silentRelogin(chave)
        }
        harness.passwords.setPassword(chave, "newpw")
        await blockingGate.release()

        _ = await blockingLogin.value
        _ = await refresh.value
        let passwords = await harness.repository.loginPasswords
        XCTAssertEqual(passwords, ["blocking-password", "newpw"])
    }

    func test_missingPasswordIsTypedAndDoesNotCallLogin() async {
        let harness = makeHarness()

        let result = await harness.coordinator.silentRelogin(chave)
        let loginCallCount = await harness.repository.loginCallCount

        XCTAssertEqual(result, .missingPassword)
        XCTAssertEqual(loginCallCount, 0)
    }

    func test_silentReloginPreservesTypedFailure() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "savedpw")
        await harness.repository.setLoginResult(.failure(.unauthorized))

        let result = await harness.coordinator.silentRelogin(chave)
        let loginCallCount = await harness.repository.loginCallCount

        XCTAssertEqual(result, .failed(.unauthorized))
        XCTAssertEqual(loginCallCount, 1)
    }

    func test_successfulLoginKeepsPostAuthCookieGenerationUsable() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "old-session")
        let olderRequest = harness.cookies.requestSnapshot(for: cookieURL)
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        let chave = chave

        let login = Task {
            await harness.coordinator.login(chave, "interactive-password")
        }
        let loginStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(loginStarted)

        // O boundary HTTP adota a resposta auth e avança a geração atomicamente antes de devolver
        // controle ao repositório/coordenador.
        harness.cookies.saveAuthoritativeSessionResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=fresh-session; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderRequest.generation
        )
        let requestStartedAfterAuthCommit = harness.cookies.requestSnapshot(for: cookieURL)
        await loginGate.release()
        guard case .success = await login.value else {
            return XCTFail("Expected successful login")
        }

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=late-old-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderRequest.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=fresh-session"
        )

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=legitimate-post-auth-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: requestStartedAfterAuthCommit.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=legitimate-post-auth-response",
            "o coordinator não pode dar um segundo bump tardio após o commit atômico do HTTP"
        )
    }

    func test_failedLoginKeepsPostAuthCookieGenerationUsable() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "old-session")
        let olderRequest = harness.cookies.requestSnapshot(for: cookieURL)
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        await harness.repository.setLoginResult(.failure(.unauthorized))
        let chave = chave

        let login = Task {
            await harness.coordinator.login(chave, "invalid-password")
        }
        let loginStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(loginStarted)

        // HTTP status não-2xx também passa pela adoção auth atômica antes de virar `ApiError`.
        harness.cookies.saveAuthoritativeSessionResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=error-response-session; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderRequest.generation
        )
        let requestStartedAfterAuthCommit = harness.cookies.requestSnapshot(for: cookieURL)
        await loginGate.release()
        guard case .failure(.unauthorized) = await login.value else {
            return XCTFail("Expected exact unauthorized failure")
        }

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=late-old-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderRequest.generation
        )

        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=error-response-session"
        )

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=legitimate-after-error-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: requestStartedAfterAuthCommit.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=legitimate-after-error-response"
        )
    }

    func test_replaceIdentityInvalidatesRunningRefreshBeforeAwaitAndClearsAfterIt() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "savedpw")
        seedCookie(harness.cookies, value: "old-session")
        let generation = await harness.coordinator.useCurrentSession()
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        let chave = chave

        let refresh = Task {
            await harness.coordinator.silentRelogin(chave)
        }
        let refreshStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(refreshStarted)
        let replacement = Task {
            await harness.coordinator.replaceIdentity()
        }
        let generationInvalidated = await waitUntilTrue {
            !(await harness.coordinator.isCurrent(generation))
        }
        XCTAssertTrue(generationInvalidated)
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=old-session",
            "invalidar respostas em voo não remove o cookie necessário ao POST logout"
        )
        let logoutCallCountWhileRefreshBlocked = await harness.repository.logoutCallCount
        XCTAssertEqual(logoutCallCountWhileRefreshBlocked, 0)

        await loginGate.release()

        let refreshResult = await refresh.value
        XCTAssertEqual(refreshResult, .staleContext)
        await replacement.value
        let finalLogoutCallCount = await harness.repository.logoutCallCount
        XCTAssertEqual(finalLogoutCallCount, 1)
        XCTAssertNil(harness.cookies.cookieHeader(for: cookieURL))
    }

    func test_explicitLogoutAdvancesGenerationBeforeBlockedRemoteLogout() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "current-session")
        let generation = await harness.coordinator.useCurrentSession()
        let logoutGate = AsyncGate()
        await harness.repository.setLogoutGate(logoutGate)

        let logout = Task {
            await harness.coordinator.explicitLogout()
        }
        let logoutStarted = await waitUntilTrue {
            await harness.repository.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)

        let isCurrentWhileLogoutBlocked = await harness.coordinator.isCurrent(generation)
        XCTAssertFalse(isCurrentWhileLogoutBlocked)
        XCTAssertEqual(harness.cookies.cookieHeader(for: cookieURL), "session=current-session")

        await logoutGate.release()
        await logout.value
        XCTAssertNil(harness.cookies.cookieHeader(for: cookieURL))
    }

    func test_syncInvalidationBlocksUseCurrentAndRejectsLateCookieUntilLogoutCompletes() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "current-session")
        let generation = await harness.coordinator.useCurrentSession()
        let staleRequest = harness.cookies.requestSnapshot(for: cookieURL)
        let logoutGate = AsyncGate()
        await harness.repository.setLogoutGate(logoutGate)

        let invalidation = harness.coordinator.invalidateCurrentIdentity()
        XCTAssertFalse(
            generation.isCurrentNow,
            "o fence síncrono deve revogar o snapshot antes do primeiro await da transição"
        )
        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=late-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: staleRequest.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=current-session",
            "a resposta tardia deve ser rejeitada antes de qualquer clear remoto"
        )

        let completion = Task {
            await harness.coordinator.completeInvalidatedLogout(invalidation)
        }
        let logoutStarted = await waitUntilTrue {
            await harness.repository.logoutCallCount == 1
        }
        XCTAssertTrue(logoutStarted)

        let probe = SessionWaitProbe()
        let currentSessionWaiter = Task {
            await probe.markStarted()
            let generation = await harness.coordinator.useCurrentSession()
            await probe.markCompleted()
            return generation
        }
        let waiterStarted = await waitUntilTrue { await probe.started }
        XCTAssertTrue(waiterStarted)
        try? await Task.sleep(for: .milliseconds(30))
        let completedWhileLogoutBlocked = await probe.completed
        XCTAssertFalse(
            completedWhileLogoutBlocked,
            "useCurrentSession não pode atravessar a janela entre invalidate e complete"
        )

        await logoutGate.release()
        await completion.value
        let resumedGeneration = await currentSessionWaiter.value
        let resumedIsCurrent = await harness.coordinator.isCurrent(resumedGeneration)

        XCTAssertTrue(resumedIsCurrent)
        XCTAssertTrue(resumedGeneration.isCurrentNow)
        XCTAssertNil(harness.cookies.cookieHeader(for: cookieURL))
    }

    func test_cancelledUseCurrentWaiterEscapesOpenInvalidationWithoutClosingSharedBarrier() async {
        let harness = makeHarness()
        let originalGeneration = await harness.coordinator.useCurrentSession()
        let invalidation = harness.coordinator.invalidateCurrentIdentity()
        let probe = SessionWaitProbe()

        let waiter = Task {
            await probe.markStarted()
            let generation = await harness.coordinator.useCurrentSession()
            await probe.markCompleted()
            return generation
        }
        let waiterStarted = await waitUntilTrue { await probe.started }
        XCTAssertTrue(waiterStarted)

        waiter.cancel()
        let waiterCompleted = await waitUntilTrue { await probe.completed }
        XCTAssertTrue(
            waiterCompleted,
            "cancelar um producer durante wipe deve romper somente sua espera, sem deadlock"
        )
        let cancelledGeneration = await waiter.value
        XCTAssertFalse(cancelledGeneration.isCurrentNow)
        XCTAssertFalse(originalGeneration.isCurrentNow)

        let stillBlockedProbe = SessionWaitProbe()
        let survivingWaiter = Task {
            await stillBlockedProbe.markStarted()
            let generation = await harness.coordinator.useCurrentSession()
            await stillBlockedProbe.markCompleted()
            return generation
        }
        let survivorStarted = await waitUntilTrue { await stillBlockedProbe.started }
        XCTAssertTrue(survivorStarted)
        try? await Task.sleep(for: .milliseconds(30))
        let survivorCompletedBeforeOwner = await stillBlockedProbe.completed
        XCTAssertFalse(
            survivorCompletedBeforeOwner,
            "cancelar outro waiter não pode fechar o barrier compartilhado"
        )

        await harness.coordinator.completeInvalidatedTransition(invalidation)
        let resumedGeneration = await survivingWaiter.value
        let resumedIsCurrent = await harness.coordinator.isCurrent(resumedGeneration)
        XCTAssertTrue(resumedIsCurrent)
        XCTAssertTrue(resumedGeneration.isCurrentNow)
        XCTAssertFalse(
            cancelledGeneration.isCurrentNow,
            "um waiter cancelado recebe token detached e não pode se tornar válido retroativamente"
        )
        let cancelledGenerationIsCurrent = await harness.coordinator.isCurrent(
            cancelledGeneration
        )
        XCTAssertFalse(cancelledGenerationIsCurrent)
    }

    func test_awaitIdleDrainsMutationTailWithoutWaitingForIdentityBarrier() async {
        let harness = makeHarness()
        let loginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(loginGate)
        let chave = chave
        let login = Task {
            await harness.coordinator.login(chave, "abc123")
        }
        let loginStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(loginStarted)
        let invalidation = harness.coordinator.invalidateCurrentIdentity()

        let idleProbe = SessionWaitProbe()
        let idle = Task {
            await idleProbe.markStarted()
            await harness.coordinator.awaitIdle()
            await idleProbe.markCompleted()
        }
        let idleStarted = await waitUntilTrue { await idleProbe.started }
        XCTAssertTrue(idleStarted)
        try? await Task.sleep(for: .milliseconds(30))
        let idleCompletedWhileTailBlocked = await idleProbe.completed
        XCTAssertFalse(idleCompletedWhileTailBlocked)

        await loginGate.release()
        _ = await login.value
        let idleCompletedWithBarrierStillOpen = await waitUntilTrue {
            await idleProbe.completed
        }
        XCTAssertTrue(
            idleCompletedWithBarrierStillOpen,
            "awaitIdle deve drenar apenas o tail, sem esperar o owner fechar o barrier"
        )
        await idle.value
        await harness.coordinator.completeInvalidatedTransition(invalidation)
    }

    func test_authMutationsAdmittedDuringOpenInvalidationFailStaleWithoutNetwork() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "savedpw")
        let invalidation = harness.coordinator.invalidateCurrentIdentity()

        let login = await harness.coordinator.login(chave, "abc123")
        let register = await harness.coordinator.registerPassword(chave, nil, "abc123")
        let change = await harness.coordinator.changePassword(chave, "abc123", "def456")
        let selfRegister = await harness.coordinator.selfRegister(
            chave,
            "Full Name",
            ["PRJ"],
            nil,
            "abc123",
            "abc123"
        )
        let refresh = await harness.coordinator.silentRelogin(chave)
        let deletion = await harness.coordinator.deleteAccount()

        for result in [login, register, change, selfRegister] {
            guard case .failure(.unauthorized) = result else {
                XCTFail("Expected queued auth mutation to fail unauthorized while barrier is open")
                continue
            }
        }
        XCTAssertEqual(refresh, .staleContext)
        XCTAssertEqual(deletion, .staleContext)
        let loginCallCount = await harness.repository.loginCallCount
        let deleteCallCount = await harness.repository.deleteCallCount
        XCTAssertEqual(loginCallCount, 0)
        XCTAssertEqual(deleteCallCount, 0)

        await harness.coordinator.completeInvalidatedTransition(invalidation)
    }

    func test_deleteFailurePreservesGenerationAndCookie() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "current-session")
        let olderRequest = harness.cookies.requestSnapshot(for: cookieURL)
        let generation = await harness.coordinator.useCurrentSession()
        let deleteGate = AsyncGate()
        await harness.repository.setDeleteGate(deleteGate)
        await harness.repository.setDeleteResult(.failure(.conflict))

        let deletion = Task { await harness.coordinator.deleteAccount() }
        let deleteStarted = await waitUntilTrue {
            await harness.repository.deleteCallCount == 1
        }
        XCTAssertTrue(deleteStarted)

        // Mesmo sem Set-Cookie, processar a resposta de uma mutação auth sela atomicamente os
        // snapshots anteriores e preserva o cookie vigente.
        harness.cookies.saveAuthoritativeSessionResponse(
            cookieURL,
            headerFields: [:],
            requestGeneration: olderRequest.generation
        )
        let requestStartedAfterDeleteResponse = harness.cookies.requestSnapshot(for: cookieURL)
        await deleteGate.release()

        let result = await deletion.value
        let isCurrent = await harness.coordinator.isCurrent(generation)

        guard case .failed(.conflict) = result else {
            return XCTFail("Expected the exact conflict failure")
        }
        XCTAssertTrue(isCurrent)
        XCTAssertEqual(harness.cookies.cookieHeader(for: cookieURL), "session=current-session")

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=late-before-delete-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: olderRequest.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=current-session",
            "a resposta processada pelo DELETE falho também deve selar snapshots anteriores"
        )

        harness.cookies.saveFromResponse(
            cookieURL,
            headerFields: [
                "Set-Cookie": "session=legitimate-after-delete-response; Path=/; Secure; HttpOnly",
            ],
            requestGeneration: requestStartedAfterDeleteResponse.generation
        )
        XCTAssertEqual(
            harness.cookies.cookieHeader(for: cookieURL),
            "session=legitimate-after-delete-response"
        )
    }

    func test_deleteSuccessRejectsLoginAdmittedWhileDeleteWasInFlight() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "deleted-session")
        let generation = await harness.coordinator.useCurrentSession()
        let deleteGate = AsyncGate()
        await harness.repository.setDeleteGate(deleteGate)
        await harness.repository.setDeleteResult(.success(()))
        let chave = chave

        let deletion = Task {
            await harness.coordinator.deleteAccount()
        }
        let deleteStarted = await waitUntilTrue {
            await harness.repository.deleteCallCount == 1
        }
        XCTAssertTrue(deleteStarted)
        let followingLogin = Task {
            await harness.coordinator.login(chave, "new-session-password")
        }
        try? await Task.sleep(for: .milliseconds(30))
        let loginCountWhileDeleteBlocked = await harness.repository.loginCallCount
        XCTAssertEqual(loginCountWhileDeleteBlocked, 0)

        await deleteGate.release()
        let deletionResult = await deletion.value
        guard case .deleted(let invalidation) = deletionResult else {
            return XCTFail("Expected successful deletion")
        }

        let currentSessionProbe = SessionWaitProbe()
        let currentSessionWaiter = Task {
            await currentSessionProbe.markStarted()
            let generation = await harness.coordinator.useCurrentSession()
            await currentSessionProbe.markCompleted()
            return generation
        }
        let waiterStarted = await waitUntilTrue { await currentSessionProbe.started }
        XCTAssertTrue(waiterStarted)
        try? await Task.sleep(for: .milliseconds(30))
        let waiterCompletedBeforeLocalWipe = await currentSessionProbe.completed
        XCTAssertFalse(
            waiterCompletedBeforeLocalWipe,
            "DELETE aceito mantém a sessão fechada até o caller concluir o wipe local"
        )

        await harness.coordinator.completeInvalidatedTransition(invalidation)
        let adoptedGeneration = await currentSessionWaiter.value
        let followingResult = await followingLogin.value
        guard case .failure(.unauthorized) = followingResult else {
            return XCTFail("Expected stale queued login to terminate as unauthorized")
        }

        let isCurrent = await harness.coordinator.isCurrent(generation)
        let operationTrace = await harness.repository.operationTrace
        let loginCallCount = await harness.repository.loginCallCount
        let adoptedGenerationIsCurrent = await harness.coordinator.isCurrent(adoptedGeneration)
        XCTAssertFalse(isCurrent)
        XCTAssertTrue(adoptedGenerationIsCurrent)
        XCTAssertTrue(adoptedGeneration.isCurrentNow)
        XCTAssertNil(harness.cookies.cookieHeader(for: cookieURL))
        XCTAssertEqual(loginCallCount, 0)
        XCTAssertEqual(operationTrace, ["delete:start", "delete:end"])
    }

    func test_deleteSuccessRevokesGenerationSynchronouslyBeforeReturningAcceptedResult() async {
        let harness = makeHarness()
        seedCookie(harness.cookies, value: "deleted-session")
        let admittedGeneration = await harness.coordinator.useCurrentSession()
        await harness.repository.setDeleteResult(.success(()))

        let result = await harness.coordinator.deleteAccount()

        XCTAssertFalse(
            admittedGeneration.isCurrentNow,
            "o aceite do DELETE deve revogar o token no mesmo trecho síncrono que forma o resultado"
        )
        guard case .deleted(let invalidation) = result else {
            return XCTFail("Expected successful deletion")
        }
        await harness.coordinator.completeInvalidatedTransition(invalidation)
    }

    func test_uiLoginAndBackgroundRefreshNeverRunConcurrently() async {
        let harness = makeHarness()
        harness.passwords.setPassword(chave, "savedpw")
        let uiLoginGate = AsyncGate()
        await harness.repository.enqueueLoginGate(uiLoginGate)
        let chave = chave

        let uiLogin = Task {
            await harness.coordinator.login(chave, "interactive-password")
        }
        let uiLoginStarted = await waitUntilTrue {
            await harness.repository.loginCallCount == 1
        }
        XCTAssertTrue(uiLoginStarted)
        let backgroundRefresh = Task {
            await harness.coordinator.silentRelogin(chave)
        }
        try? await Task.sleep(for: .milliseconds(30))
        let callCountWhileBlocked = await harness.repository.loginCallCount
        XCTAssertEqual(callCountWhileBlocked, 1)

        await uiLoginGate.release()
        _ = await uiLogin.value
        _ = await backgroundRefresh.value

        let finalCallCount = await harness.repository.loginCallCount
        let finalMaxConcurrency = await harness.repository.maximumConcurrentLogins
        XCTAssertEqual(finalCallCount, 2)
        XCTAssertEqual(finalMaxConcurrency, 1)
    }

    private func makeHarness(
        didJoinExistingSilentRelogin: (@Sendable () -> Void)? = nil
    ) -> AuthSessionCoordinatorHarness {
        let repository = AuthSessionCoordinatorRepositoryFake()
        let passwords = InMemorySecurePasswordStore()
        let cookies = InMemorySessionCookieStore(now: { 1_000 })
        return AuthSessionCoordinatorHarness(
            repository: repository,
            passwords: passwords,
            cookies: cookies,
            coordinator: AuthSessionCoordinator(
                authRepository: repository,
                securePasswordStore: passwords,
                cookieStore: cookies,
                didJoinExistingSilentRelogin: didJoinExistingSilentRelogin
            )
        )
    }

    private func authenticatedStatus() -> AuthStatus {
        AuthStatus(
            found: true,
            chave: chave,
            hasPassword: true,
            authenticated: true,
            message: ""
        )
    }

    private func seedCookie(_ store: InMemorySessionCookieStore, value: String) {
        let snapshot = store.requestSnapshot(for: cookieURL)
        store.saveFromResponse(
            cookieURL,
            headerFields: ["Set-Cookie": "session=\(value); Path=/; Secure; HttpOnly"],
            requestGeneration: snapshot.generation
        )
    }

    private func waitUntilTrue(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

private struct AuthSessionCoordinatorHarness {
    let repository: AuthSessionCoordinatorRepositoryFake
    let passwords: InMemorySecurePasswordStore
    let cookies: InMemorySessionCookieStore
    let coordinator: AuthSessionCoordinator
}

/// O único estado cruzado é `didJoin`; toda leitura/escrita passa pelo `NSLock`, portanto este probe é
/// seguro para a callback `@Sendable` síncrona usada no teste de coalescência.
private final class RefreshJoinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didJoin = false

    var joined: Bool { lock.withLock { didJoin } }

    func markJoined() {
        lock.withLock { didJoin = true }
    }
}

private actor SessionWaitProbe {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() { started = true }
    func markCompleted() { completed = true }
}

private actor AuthSessionCoordinatorRepositoryFake: AuthRepository {
    private var configuredLoginResult: AppResult<AuthStatus> = .success(AuthStatus(
        found: true,
        chave: "ABCD",
        hasPassword: true,
        authenticated: true,
        message: ""
    ))
    private var configuredDeleteResult: AppResult<Void> = .success(())
    private var loginGates: [AsyncGate] = []
    private var logoutGate: AsyncGate?
    private var deleteGate: AsyncGate?
    private(set) var loginPasswords: [String] = []
    private(set) var operationTrace: [String] = []
    private(set) var logoutCallCount = 0
    private(set) var deleteCallCount = 0
    private var activeLogins = 0
    private(set) var maximumConcurrentLogins = 0

    var loginCallCount: Int { loginPasswords.count }

    func setLoginResult(_ result: AppResult<AuthStatus>) {
        configuredLoginResult = result
    }

    func setDeleteResult(_ result: AppResult<Void>) {
        configuredDeleteResult = result
    }

    func enqueueLoginGate(_ gate: AsyncGate) {
        loginGates.append(gate)
    }

    func setLogoutGate(_ gate: AsyncGate) {
        logoutGate = gate
    }

    func setDeleteGate(_ gate: AsyncGate) {
        deleteGate = gate
    }

    func getStatus(_ chave: String) async -> AppResult<AuthStatus> {
        .failure(.unknown(description: nil))
    }

    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus> {
        let gate = loginGates.isEmpty ? nil : loginGates.removeFirst()
        let result = configuredLoginResult
        loginPasswords.append(password)
        operationTrace.append("login:start")
        activeLogins += 1
        maximumConcurrentLogins = max(maximumConcurrentLogins, activeLogins)
        await gate?.wait()
        activeLogins -= 1
        operationTrace.append("login:end")
        return result
    }

    func logout() async -> AppResult<Void> {
        logoutCallCount += 1
        let gate = logoutGate
        logoutGate = nil
        await gate?.wait()
        return .success(())
    }

    func deleteAccount() async -> AppResult<Void> {
        deleteCallCount += 1
        operationTrace.append("delete:start")
        let gate = deleteGate
        deleteGate = nil
        let result = configuredDeleteResult
        await gate?.wait()
        operationTrace.append("delete:end")
        return result
    }

    func registerPassword(
        _ chave: String,
        _ project: String?,
        _ password: String
    ) async -> AppResult<AuthStatus> {
        configuredLoginResult
    }

    func changePassword(
        _ chave: String,
        _ oldPassword: String,
        _ newPassword: String
    ) async -> AppResult<AuthStatus> {
        configuredLoginResult
    }

    func selfRegister(
        _ chave: String,
        _ nome: String,
        _ projetos: [String],
        _ email: String?,
        _ password: String,
        _ confirmPassword: String
    ) async -> AppResult<AuthStatus> {
        configuredLoginResult
    }

    func getHistory(_ chave: String) async -> AppResult<HistoryState> {
        .failure(.unknown(description: nil))
    }
}
