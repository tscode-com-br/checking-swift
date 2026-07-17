import Foundation

/// O motor automático — port de RunAutomaticActivitiesUseCase.kt. Orquestra
/// capture → match → decide (matriz) → submit, com exactly-once e enqueue offline.
/// Ver port_spec_decision_engine.md §6.
struct RunAutomaticActivitiesUseCase: Sendable {
    let captureLocationUseCase: any LocationCapturing
    let checkRepository: any CheckRepository
    let offlineQueue: any OfflineCheckQueueing
    let clock: any Clock
    let activityLogger: any ActivityLogging

    func callAsFunction(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int
    ) async -> AutoActivitiesResult {
        // 1) Projeto ativo — curto-circuita ANTES de qualquer captura.
        guard let projeto = userProjects?.activeProject, !projeto.isEmpty else {
            activityLogger.logSystem("No active project — skipped.", .warning)
            return .notConfigured
        }

        // 2) Captura + match.
        let match: LocationMatch
        switch await captureLocationUseCase(accuracyThresholdMeters) {
        case .matched(let m):
            match = m
        case .networkError(let reading):
            // Offline com fix → enfileira Raw (o servidor decide no replay).
            if let reading = reading {
                await offlineQueue.enqueue(.raw(PendingCheckEvent.Raw(
                    chave: chave, projeto: projeto, capturedAtEpochMs: epochMs(clock.now()),
                    clientEventId: UUID().uuidString, latitude: reading.lat, longitude: reading.lon,
                    accuracyMeters: reading.accuracyMeters)))
                activityLogger.logLocation("Location reading queued offline — will sync on reconnect.", nil, .warning)
            }
            return .networkError
        case .timeout, .noPermission:
            return .noAction
        }

        // 3) Matriz de decisão (função-mestre pura).
        guard let activity = resolveAutomaticActivityForMatch(match, currentState, mixedZoneIntervalMinutes) else {
            return .noAction
        }

        // 4) Exactly-once: id + timestamp gerados ANTES do submit.
        let clientEventId = UUID().uuidString
        let eventTime = clock.now()

        // 5) Submit.
        switch await checkRepository.submit(chave: chave, projeto: projeto, action: activity.action,
                                            local: activity.local, informe: .normal,
                                            eventTime: eventTime, clientEventId: clientEventId) {
        case .success(let newState):
            if activity.action == .checkIn {
                activityLogger.logCheckIn(.sys, activity.local, success: true)
            } else {
                activityLogger.logCheckOut(.sys, activity.local, success: true)
            }
            return .submitted(action: activity.action, local: activity.local, newState: newState)
        case .failure(let error):
            if case .network = error {
                await offlineQueue.enqueue(.decided(PendingCheckEvent.Decided(
                    chave: chave, projeto: projeto, capturedAtEpochMs: epochMs(eventTime), clientEventId: clientEventId,
                    action: activity.action == .checkOut ? "checkout" : "checkin", local: activity.local, informe: "normal")))
                activityLogger.logQueuedOffline(.sys, activity.action == .checkIn ? .checkIn : .checkOut, activity.local)
            } else {
                if activity.action == .checkIn {
                    activityLogger.logCheckIn(.sys, activity.local, success: false)
                } else {
                    activityLogger.logCheckOut(.sys, activity.local, success: false)
                }
            }
            return .networkError
        }
    }

    private func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
