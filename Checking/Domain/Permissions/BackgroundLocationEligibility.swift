import Foundation

/// Insumos explícitos para classificar a elegibilidade da automação de localização.
///
/// Esta estrutura deliberadamente recebe apenas fatos já avaliados pelo chamador. Não lê preferências,
/// consulta o inspector, sanitiza chave nem inicia/paralisa serviços nativos; assim permanece determinística
/// e não carrega dados de conta, projeto ou localização.
struct BackgroundLocationEligibilityInput: Sendable, Equatable {
    let hasValidAccountContext: Bool
    let automaticActivitiesEnabled: Bool
    let hasActiveProject: Bool
    let hasBackgroundLocationConsent: Bool
    let locationAuthorization: LocationAuthorization
    let preciseAccuracy: Bool
    let locationServicesEnabled: Bool
    let backgroundRefresh: BackgroundRefreshAvailability
    let lowPowerMode: Bool

    init(
        hasValidAccountContext: Bool,
        automaticActivitiesEnabled: Bool,
        hasActiveProject: Bool,
        hasBackgroundLocationConsent: Bool,
        locationAuthorization: LocationAuthorization,
        preciseAccuracy: Bool,
        locationServicesEnabled: Bool,
        backgroundRefresh: BackgroundRefreshAvailability,
        lowPowerMode: Bool
    ) {
        self.hasValidAccountContext = hasValidAccountContext
        self.automaticActivitiesEnabled = automaticActivitiesEnabled
        self.hasActiveProject = hasActiveProject
        self.hasBackgroundLocationConsent = hasBackgroundLocationConsent
        self.locationAuthorization = locationAuthorization
        self.preciseAccuracy = preciseAccuracy
        self.locationServicesEnabled = locationServicesEnabled
        self.backgroundRefresh = backgroundRefresh
        self.lowPowerMode = lowPowerMode
    }
}

/// Classificação pura e somente observacional da capacidade de automação por localização.
///
/// Ela não substitui `PermissionLadderStatus.minimumToStartGranted` (D5), que continua exigindo
/// notificações + localização precisa nos fluxos existentes. Em particular, esta classificação não é um
/// comando para registrar/parar geofences, iniciar/parar significant-change ou alterar o toggle.
struct BackgroundLocationEligibility: Sendable, Equatable {
    enum State: Sendable, Equatable {
        case blocked
        case foregroundOnly
        case operational
    }

    enum BlockingReason: Sendable, Equatable {
        case invalidAccountContext
        case automaticActivitiesDisabled
        case missingActiveProject
        case missingBackgroundLocationConsent
        case locationServicesDisabled
        case locationAuthorizationNotDetermined
        case locationAuthorizationDenied
        case reducedAccuracy
    }

    enum DegradationReason: Sendable, Equatable {
        case whenInUseAuthorization
        case backgroundRefreshDenied
        case backgroundRefreshRestricted
        case lowPowerMode
    }

    /// Capacidade nominal do Core Location para os caminhos nativos de background.
    /// Não promete entrega do sistema, execução de timer, recuperação após force-quit nem periodicidade.
    enum NativeBackgroundReadiness: Sendable, Equatable {
        case notReady
        case readyForCoreLocation
    }

    /// Sinal exclusivo do caminho de timer/oportunidade via Background App Refresh.
    /// Ele não decide sozinho se regiões ou mudanças significativas devem ser mantidas.
    enum TimerBackgroundSignal: Sendable, Equatable {
        case available
        case degradedDenied
        case degradedRestricted
    }

    enum LowPowerSignal: Sendable, Equatable {
        case normal
        case warning
    }

    let state: State
    let canEvaluateInForeground: Bool
    let nativeBackgroundReadiness: NativeBackgroundReadiness
    let blockingReasons: [BlockingReason]
    let degradationReasons: [DegradationReason]
    let timerBackgroundSignal: TimerBackgroundSignal
    let lowPowerSignal: LowPowerSignal

    static func evaluate(_ input: BackgroundLocationEligibilityInput) -> Self {
        let blockingReasons = blockingReasons(for: input)
        let degradationReasons = degradationReasons(for: input)
        let timerBackgroundSignal = timerSignal(for: input.backgroundRefresh)
        let lowPowerSignal: LowPowerSignal = input.lowPowerMode ? .warning : .normal

        guard blockingReasons.isEmpty else {
            return Self(
                state: .blocked,
                canEvaluateInForeground: false,
                nativeBackgroundReadiness: .notReady,
                blockingReasons: blockingReasons,
                degradationReasons: degradationReasons,
                timerBackgroundSignal: timerBackgroundSignal,
                lowPowerSignal: lowPowerSignal
            )
        }

        switch input.locationAuthorization {
        case .whenInUse:
            return Self(
                state: .foregroundOnly,
                canEvaluateInForeground: true,
                nativeBackgroundReadiness: .notReady,
                blockingReasons: [],
                degradationReasons: degradationReasons,
                timerBackgroundSignal: timerBackgroundSignal,
                lowPowerSignal: lowPowerSignal
            )
        case .always:
            return Self(
                state: .operational,
                canEvaluateInForeground: true,
                nativeBackgroundReadiness: .readyForCoreLocation,
                blockingReasons: [],
                degradationReasons: degradationReasons,
                timerBackgroundSignal: timerBackgroundSignal,
                lowPowerSignal: lowPowerSignal
            )
        case .notDetermined, .denied:
            // `blockingReasons(for:)` cobre ambos; manter um fallback fechado evita afirmar prontidão se
            // uma alteração futura acrescentar um caso de autorização sem atualizar a função auxiliar.
            return Self(
                state: .blocked,
                canEvaluateInForeground: false,
                nativeBackgroundReadiness: .notReady,
                blockingReasons: blockingReasons,
                degradationReasons: degradationReasons,
                timerBackgroundSignal: timerBackgroundSignal,
                lowPowerSignal: lowPowerSignal
            )
        }
    }

    private static func blockingReasons(for input: BackgroundLocationEligibilityInput) -> [BlockingReason] {
        var reasons: [BlockingReason] = []

        if !input.hasValidAccountContext { reasons.append(.invalidAccountContext) }
        if !input.automaticActivitiesEnabled { reasons.append(.automaticActivitiesDisabled) }
        if !input.hasActiveProject { reasons.append(.missingActiveProject) }
        if !input.hasBackgroundLocationConsent { reasons.append(.missingBackgroundLocationConsent) }

        guard input.locationServicesEnabled else {
            reasons.append(.locationServicesDisabled)
            return reasons
        }

        switch input.locationAuthorization {
        case .notDetermined:
            reasons.append(.locationAuthorizationNotDetermined)
        case .denied:
            reasons.append(.locationAuthorizationDenied)
        case .whenInUse, .always:
            if !input.preciseAccuracy { reasons.append(.reducedAccuracy) }
        }

        return reasons
    }

    private static func degradationReasons(for input: BackgroundLocationEligibilityInput) -> [DegradationReason] {
        var reasons: [DegradationReason] = []

        if input.locationAuthorization == .whenInUse {
            reasons.append(.whenInUseAuthorization)
        }
        switch input.backgroundRefresh {
        case .available:
            break
        case .denied:
            reasons.append(.backgroundRefreshDenied)
        case .restricted:
            reasons.append(.backgroundRefreshRestricted)
        }
        if input.lowPowerMode { reasons.append(.lowPowerMode) }

        return reasons
    }

    private static func timerSignal(for availability: BackgroundRefreshAvailability) -> TimerBackgroundSignal {
        switch availability {
        case .available: .available
        case .denied: .degradedDenied
        case .restricted: .degradedRestricted
        }
    }
}
