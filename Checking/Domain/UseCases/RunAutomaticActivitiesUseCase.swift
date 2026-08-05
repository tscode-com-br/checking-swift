import Foundation

/// Evento lógico decidido antes do submit. É somente memória, não é `Codable` e preserva identidade/tempo
/// para que uma resposta indeterminada possa ser tratada sem gerar uma segunda atividade no Prompt 14.
struct AutomaticSubmissionContext: Sendable, Equatable {
    let chave: String
    let projeto: String
    let action: CheckAction
    let local: String?
    let informe: InformeType
    let eventTime: Date
    let clientEventId: String
    let fillForms: Bool
}

/// O motor automático — port de RunAutomaticActivitiesUseCase.kt. Orquestra
/// capture → match → decide (matriz) → submit, com exactly-once e enqueue offline.
/// Ver port_spec_decision_engine.md §6.
struct RunAutomaticActivitiesUseCase: Sendable {
    let captureLocationUseCase: any SampleAwareLocationCapturing
    let checkRepository: any CheckRepository
    let offlineQueue: any OfflineCheckQueueing
    let clock: any Clock
    let activityLogger: any ActivityLogging
    private let makeClientEventID: @Sendable () -> String

    init(
        captureLocationUseCase: any SampleAwareLocationCapturing,
        checkRepository: any CheckRepository,
        offlineQueue: any OfflineCheckQueueing,
        clock: any Clock,
        activityLogger: any ActivityLogging,
        makeClientEventID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.captureLocationUseCase = captureLocationUseCase
        self.checkRepository = checkRepository
        self.offlineQueue = offlineQueue
        self.clock = clock
        self.activityLogger = activityLogger
        self.makeClientEventID = makeClientEventID
    }

    /// Fachada histórica: todas as chamadas existentes continuam equivalentes a uma aquisição nova.
    func callAsFunction(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int
    ) async -> AutoActivitiesResult {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters
        ).result
    }

    func callAsFunction(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> AutoActivitiesResult {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt
        ).result
    }

    func execute(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int
    ) async -> AutomaticActivitiesExecution {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: .acquire
        )
    }

    func execute(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> AutomaticActivitiesExecution {
        await execute(
            chave: chave,
            userProjects: userProjects,
            currentState: currentState,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt,
            effectGuard: .unrestricted
        )
    }

    func execute(
        chave: String,
        userProjects: UserProjects?,
        currentState: HistoryState?,
        mixedZoneIntervalMinutes: Int,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution {
        switch preflight(
            chave: chave,
            userProjects: userProjects,
            mixedZoneIntervalMinutes: mixedZoneIntervalMinutes
        ) {
        case .terminal(let execution):
            return execution
        case .ready(let configuration):
            switch await prepare(
                configuration,
                accuracyThresholdMeters: accuracyThresholdMeters,
                locationAttempt: locationAttempt,
                effectGuard: effectGuard
            ) {
            case .terminal(let execution):
                return execution
            case .ready(let prepared):
                return await complete(
                    prepared,
                    currentState: currentState,
                    effectGuard: effectGuard
                )
            }
        }
    }

    /// Validação compartilhada pela fachada histórica e pelo pipeline candidato. O orquestrador pode
    /// executar este passo antes da captura do TIMER sem copiar a regra nem a mensagem legada.
    func preflight(
        chave: String,
        userProjects: UserProjects?,
        mixedZoneIntervalMinutes: Int
    ) -> AutomaticActivitiesPreflight {
        guard let projeto = userProjects?.activeProject, !projeto.isEmpty else {
            activityLogger.logSystem("No active project — skipped.", .warning)
            return .terminal(
                execution(
                    result: .notConfigured,
                    maximumStage: .started
                )
            )
        }
        return .ready(
            AutomaticActivitiesConfiguration(
                chave: chave,
                projeto: projeto,
                mixedZoneIntervalMinutes: mixedZoneIntervalMinutes
            )
        )
    }

    /// Resolve uma tentativa até o match. Uma `.finalSample` é revalidada pelo chokepoint de captura e
    /// nunca reabre orçamento de provider. Falhas de match, inclusive Raw offline, terminam aqui e não
    /// exigem state.
    func prepare(
        _ configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput
    ) async -> AutomaticActivitiesPreparation {
        await prepare(
            configuration,
            accuracyThresholdMeters: accuracyThresholdMeters,
            locationAttempt: locationAttempt,
            effectGuard: .unrestricted
        )
    }

    func prepare(
        _ configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int,
        locationAttempt: LocationAttemptInput,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesPreparation {
        let captureExecution = await captureLocationUseCase.execute(
            accuracyThresholdMeters,
            locationAttempt: locationAttempt,
            effectGuard: effectGuard
        )
        guard !Task.isCancelled else {
            return .terminal(
                execution(
                    result: .locationTimeout,
                    maximumStage: captureExecution.maximumStage,
                    capture: captureExecution.capture,
                    failure: .cancelled(.taskCancelled)
                )
            )
        }
        switch captureExecution.result {
        case .matched(let m):
            return .ready(
                PreparedAutomaticActivitiesMatch(
                    configuration: configuration,
                    match: m,
                    capture: captureExecution.capture
                )
            )
        case .networkError(let reading):
            // Offline com fix → enfileira Raw (o servidor decide no replay).
            var disposition: AutomaticOfflineDisposition?
            if let reading = reading {
                guard !Task.isCancelled else {
                    return .terminal(
                        execution(
                            result: .locationTimeout,
                            maximumStage: captureExecution.maximumStage,
                            capture: captureExecution.capture,
                            failure: .cancelled(.taskCancelled)
                        )
                    )
                }
                let pendingEvent = PendingCheckEvent.raw(PendingCheckEvent.Raw(
                    chave: configuration.chave,
                    projeto: configuration.projeto,
                    capturedAtEpochMs: epochMs(clock.now()),
                    clientEventId: makeClientEventID(), latitude: reading.lat, longitude: reading.lon,
                    accuracyMeters: reading.accuracyMeters))
                guard await offlineQueue.enqueueIfCurrent(
                    pendingEvent,
                    effectGuard: effectGuard
                ) else {
                    return .terminal(
                        execution(
                            result: .locationTimeout,
                            maximumStage: captureExecution.maximumStage,
                            capture: captureExecution.capture,
                            failure: .cancelled(.contextInvalidated)
                        )
                    )
                }
                activityLogger.logLocation("Location reading queued offline — will sync on reconnect.", nil, .warning)
                disposition = .queuedRaw
            }
            return .terminal(
                execution(
                    result: .networkError,
                    maximumStage: captureExecution.maximumStage,
                    capture: captureExecution.capture,
                    failure: automaticFailure(from: captureExecution.failure),
                    offlineDisposition: disposition,
                    matchRetryContext: automaticMatchRetryContext(
                        from: captureExecution,
                        configuration: configuration,
                        accuracyThresholdMeters: accuracyThresholdMeters
                    )
                )
            )
        case .timeout:
            return .terminal(
                execution(
                    result: .locationTimeout,
                    maximumStage: captureExecution.maximumStage,
                    capture: captureExecution.capture,
                    failure: automaticFailure(from: captureExecution.failure)
                        ?? .acquisition(.timeout)
                )
            )
        case .noPermission:
            return .terminal(
                execution(
                    result: .noPermission,
                    maximumStage: captureExecution.maximumStage,
                    capture: captureExecution.capture,
                    failure: automaticFailure(from: captureExecution.failure)
                        ?? .acquisition(.unavailable)
                )
            )
        }
    }

    /// Única continuação depois do match: accuracy handling, matriz, identidade, submit e fila Decided.
    /// Ela não possui acesso ao provider nem a `LocationSample`, portanto não pode recapturar.
    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?
    ) async -> AutomaticActivitiesExecution {
        await complete(
            prepared,
            currentState: currentState,
            suppressingDuplicateOf: nil,
            effectGuard: .unrestricted
        )
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution {
        await complete(
            prepared,
            currentState: currentState,
            suppressingDuplicateOf: nil,
            effectGuard: effectGuard
        )
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf actionToSuppress: CheckAction?
    ) async -> AutomaticActivitiesExecution {
        await complete(
            prepared,
            currentState: currentState,
            suppressingDuplicateOf: actionToSuppress,
            effectGuard: .unrestricted
        )
    }

    func complete(
        _ prepared: PreparedAutomaticActivitiesMatch,
        currentState: HistoryState?,
        suppressingDuplicateOf actionToSuppress: CheckAction?,
        effectGuard: AutomaticActivitiesEffectGuard
    ) async -> AutomaticActivitiesExecution {
        let match = prepared.match
        let configuration = prepared.configuration

        guard !Task.isCancelled else {
            return execution(
                result: .locationTimeout,
                maximumStage: .matched,
                capture: prepared.capture,
                failure: .cancelled(.taskCancelled)
            )
        }

        if match.status == .accuracyTooLow {
            let lastAction = resolveLastRecordedAction(currentState)
            let expectedAction: CheckAction? =
                lastAction == nil || lastAction == .checkOut ? .checkIn : nil
            return execution(
                result: .accuracyTooLow(expectedAction: expectedAction),
                maximumStage: .matched,
                capture: prepared.capture
            )
        }

        // Matriz de decisão (função-mestre pura e intocada).
        guard let activity = resolveAutomaticActivityForMatch(
            match,
            currentState,
            configuration.mixedZoneIntervalMinutes
        ) else {
            return execution(
                result: .noAction,
                maximumStage: .decisionCompleted,
                capture: prepared.capture
            )
        }
        if activity.action == actionToSuppress {
            return execution(
                result: .noAction,
                maximumStage: .decisionCompleted,
                capture: prepared.capture
            )
        }

        // Exactly-once: id + timestamp gerados ANTES do submit.
        let submission = AutomaticSubmissionContext(
            chave: configuration.chave,
            projeto: configuration.projeto,
            action: activity.action,
            local: activity.local,
            informe: .normal,
            eventTime: clock.now(),
            clientEventId: makeClientEventID(),
            fillForms: true
        )

        // 5) Submit.
        guard !Task.isCancelled else {
            return execution(
                result: .locationTimeout,
                maximumStage: .decisionCompleted,
                capture: prepared.capture,
                failure: .cancelled(.taskCancelled),
                submissionContext: submission
            )
        }
        guard effectGuard.allowsIrreversibleEffect() else {
            return execution(
                result: .locationTimeout,
                maximumStage: .decisionCompleted,
                capture: prepared.capture,
                failure: .cancelled(.contextInvalidated),
                submissionContext: submission
            )
        }
        let guardedSubmitResult = await checkRepository.submit(
            chave: submission.chave,
            projeto: submission.projeto,
            action: submission.action,
            local: submission.local,
            informe: submission.informe,
            eventTime: submission.eventTime,
            clientEventId: submission.clientEventId,
            fillForms: submission.fillForms,
            effectGuard: effectGuard
        )
        guard case .dispatched(let submitResult) = guardedSubmitResult else {
            return execution(
                result: .locationTimeout,
                maximumStage: .decisionCompleted,
                capture: prepared.capture,
                failure: .cancelled(.contextInvalidated),
                submissionContext: submission
            )
        }

        // Uma resposta de sucesso já confirma o evento lógico no servidor. Invalidação/cancelamento que
        // ocorreu durante o await só pode suprimir efeitos locais da identidade antiga; não pode apagar o
        // outcome conhecido nem convertê-lo em falha/retry de um submit já aceito.
        if case .success(let newState) = submitResult {
            if !Task.isCancelled, effectGuard.allowsIrreversibleEffect() {
                if submission.action == .checkIn {
                    activityLogger.logCheckIn(.sys, submission.local, success: true)
                } else {
                    activityLogger.logCheckOut(.sys, submission.local, success: true)
                }
            }
            return execution(
                result: .submitted(
                    action: submission.action,
                    local: submission.local,
                    newState: newState
                ),
                maximumStage: .submitted,
                capture: prepared.capture,
                submissionContext: submission
            )
        }

        guard !Task.isCancelled else {
            return execution(
                result: .locationTimeout,
                maximumStage: .submitStarted,
                capture: prepared.capture,
                failure: .cancelled(.taskCancelled),
                submissionContext: submission
            )
        }
        guard effectGuard.allowsIrreversibleEffect() else {
            return execution(
                result: .locationTimeout,
                maximumStage: .submitStarted,
                capture: prepared.capture,
                failure: .cancelled(.contextInvalidated),
                submissionContext: submission
            )
        }
        switch submitResult {
        case .success:
            // Consumido acima para distinguir outcome confirmado de falha/indeterminação de transporte.
            assertionFailure("submit success must be handled before cancellation guards")
            return execution(
                result: .locationTimeout,
                maximumStage: .submitStarted,
                capture: prepared.capture,
                failure: .cancelled(.taskCancelled),
                submissionContext: submission
            )
        case .failure(let error):
            var disposition: AutomaticOfflineDisposition?
            if case .network = error {
                guard !Task.isCancelled else {
                    return execution(
                        result: .locationTimeout,
                        maximumStage: .submitStarted,
                        capture: prepared.capture,
                        failure: .cancelled(.taskCancelled),
                        submissionContext: submission
                    )
                }
                let pendingEvent = PendingCheckEvent.decided(PendingCheckEvent.Decided(
                    chave: submission.chave,
                    projeto: submission.projeto,
                    capturedAtEpochMs: epochMs(submission.eventTime),
                    clientEventId: submission.clientEventId,
                    action: submission.action == .checkOut ? "checkout" : "checkin",
                    local: submission.local,
                    informe: "normal"
                ))
                guard await offlineQueue.enqueueIfCurrent(
                    pendingEvent,
                    effectGuard: effectGuard
                ) else {
                    return execution(
                        result: .locationTimeout,
                        maximumStage: .submitStarted,
                        capture: prepared.capture,
                        failure: .cancelled(.contextInvalidated),
                        submissionContext: submission
                    )
                }
                activityLogger.logQueuedOffline(
                    .sys,
                    submission.action == .checkIn ? .checkIn : .checkOut,
                    submission.local
                )
                disposition = .queuedDecided
            } else {
                if submission.action == .checkIn {
                    activityLogger.logCheckIn(.sys, submission.local, success: false)
                } else {
                    activityLogger.logCheckOut(.sys, submission.local, success: false)
                }
            }
            return execution(
                result: .networkError,
                maximumStage: .submitStarted,
                capture: prepared.capture,
                failure: .submit(error),
                offlineDisposition: disposition,
                submissionContext: submission
            )
        }
    }

    private func execution(
        result: AutoActivitiesResult,
        maximumStage: AutomaticActivitiesStage,
        capture: AutomaticCaptureTrace? = nil,
        failure: AutomaticActivitiesFailure? = nil,
        offlineDisposition: AutomaticOfflineDisposition? = nil,
        submissionContext: AutomaticSubmissionContext? = nil,
        matchRetryContext: AutomaticMatchRetryContext? = nil
    ) -> AutomaticActivitiesExecution {
        AutomaticActivitiesExecution(
            result: result,
            trace: AutomaticActivitiesTrace(
                maximumStage: maximumStage,
                capture: capture,
                failure: failure,
                offlineDisposition: offlineDisposition
            ),
            submissionContext: submissionContext,
            matchRetryContext: matchRetryContext
        )
    }

    private func automaticMatchRetryContext(
        from captureExecution: LocationCaptureExecution,
        configuration: AutomaticActivitiesConfiguration,
        accuracyThresholdMeters: Int
    ) -> AutomaticMatchRetryContext? {
        guard case .match(.unauthorized) = captureExecution.failure,
              let sample = captureExecution.retryableMatchSample else {
            return nil
        }
        return AutomaticMatchRetryContext(
            configuration: configuration,
            accuracyThresholdMeters: accuracyThresholdMeters,
            sample: sample
        )
    }

    private func automaticFailure(
        from failure: LocationCaptureExecutionFailure?
    ) -> AutomaticActivitiesFailure? {
        switch failure {
        case .acquisition(let acquisition):
            .acquisition(acquisition)
        case .sampleRejected(let validity):
            .sampleRejected(validity)
        case .match(let error):
            .match(error)
        case .cancelled(let reason):
            .cancelled(reason)
        case nil:
            nil
        }
    }

    private func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
