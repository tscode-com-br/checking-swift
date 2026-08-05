import CoreLocation
import Foundation

/// Classificação no boundary Core Location. Nunca armazena domínio, descrição ou payload do `Error`; novos
/// códigos degradam para `.other` até serem aprovados nesta whitelist.
extension GeofenceMonitoringFailureCode {
    static func sanitizeCoreLocationError(_ error: Error) -> Self {
        guard let coreLocationError = error as? CLError else { return .other }
        return switch coreLocationError.code {
        case .denied:
            .denied
        case .regionMonitoringDenied:
            .regionMonitoringDenied
        case .regionMonitoringFailure:
            .regionMonitoringFailure
        default:
            .other
        }
    }
}

/// Representação efêmera de uma região que o adapter nativo conhece. `identifier` nunca sai do monitor:
/// serve exclusivamente para reconciliar o callback do Core Location com o expected set da geração atual.
struct GeofenceNativeRegion: Sendable, Equatable {
    let identifier: String
    let centerLat: Double?
    let centerLng: Double?
    let radiusMeters: Double?

    init(identifier: String, centerLat: Double?, centerLng: Double?, radiusMeters: Double?) {
        self.identifier = identifier
        self.centerLat = centerLat
        self.centerLng = centerLng
        self.radiusMeters = radiusMeters
    }

    init(identifier: String, centerLat: Double, centerLng: Double, radiusMeters: Double) {
        self.init(
            identifier: identifier,
            centerLat: Optional(centerLat),
            centerLng: Optional(centerLng),
            radiusMeters: Optional(radiusMeters)
        )
    }

    func hasSameGeometry(as other: GeofenceNativeRegion) -> Bool {
        centerLat == other.centerLat &&
            centerLng == other.centerLng &&
            radiusMeters == other.radiusMeters
    }
}

/// Pequeno adapter para a API nativa. A implementação de Core Location fica no monitor candidato; o
/// protocolo permite provar sem `CLLocationManager` real que callback velho não confirma uma geração nova.
@MainActor
protocol GeofenceNativeRegionMonitoring: AnyObject {
    func monitoredRegions() -> [GeofenceNativeRegion]
    func stopMonitoring(identifier: String)
    func startMonitoring(_ region: GeofenceNativeRegion)
    func requestState(for identifier: String)
}

/// Adapter geracional do caminho candidato. Todo o mapeamento logical→physical e todos os expected sets
/// vivem apenas neste objeto em memória. O token físico novo por mudança real impede que `didStart` ou
/// `didFail` atrasados confirmem uma sincronização posterior que reutilizou o mesmo ID lógico.
@MainActor
final class GeofenceGenerationAdapter {
    private enum ExpectedStatus: Equatable {
        case requested
        case confirmed
        case failed(GeofenceMonitoringFailureCode)
    }

    private struct ExpectedRegion: Equatable {
        var native: GeofenceNativeRegion
        /// Alias efêmero, privado e sem dados de negócio usado apenas pelo deduplicador em memória. Ele
        /// sobrevive a uma nova geração do mesmo ID lógico, mas nunca sai deste adapter.
        let wakeDeduplicationKey: String
        var status: ExpectedStatus
    }

    private struct ActiveGeneration: Equatable {
        let ordinal: UInt64
        let desiredSet: [GeofenceRegion]
        var omittedCount: Int
        /// Se a API estava indisponível na primeira tentativa, uma ressincronização idêntica pode armar o
        /// mesmo expected set depois, sem fabricar uma geração nova nem churn de regiões já existentes.
        var nativeRequestsIssued: Bool
        /// A ordem recebida do priorizador (tier/Haversine/id) é a ordem efetiva dos `startMonitoring`.
        let expectedIdentifiersInPriorityOrder: [String]
        /// Correlação lógica limitada à memória do processo; serve somente para reaproveitar o alias de
        /// dedup quando uma mudança real recria a identidade física da mesma região lógica.
        let wakeDeduplicationKeysByLogicalIdentifier: [String: String]
        /// Um `monitoringDidFailFor(nil, ...)` não traz identidade/generation. Ele jamais falha nem confirma
        /// uma região específica; torna a confirmação do conjunto explicitamente incerta até novo sync.
        var hasUnattributedMonitoringFailure: Bool
        var expectedByIdentifier: [String: ExpectedRegion]
    }

    private let native: any GeofenceNativeRegionMonitoring
    private let makeOpaqueToken: @Sendable () -> String
    private var nextGeneration: UInt64 = 0
    private var activeGeneration: ActiveGeneration?
    private var inheritedUnknownIdentifiers: Set<String>
    private var inheritedWakeDeduplicationKeys: [String: String]

    init(
        native: any GeofenceNativeRegionMonitoring,
        makeOpaqueToken: @escaping @Sendable () -> String = {
            UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.native = native
        self.makeOpaqueToken = makeOpaqueToken
        // `monitoredRegions` é compartilhado pelo app: não tomamos posse de regiões de outro manager (por
        // exemplo, o harness Debug). Além do namespace físico candidato, reconhecemos SOMENTE o formato
        // decimal emitido pelo monitor legado deste mesmo app (`String(GeofenceCircle.id)`). Isso é uma
        // ponte de migração bounded: o ID legado nunca é logado/persistido de novo, não confirma a geração
        // candidata e é parado/rearmado no primeiro sync. Outros identifiers continuam fora da nossa posse.
        let inherited = Set(
            native.monitoredRegions().map(\.identifier).filter(Self.isOwnedOrLegacyPhysicalIdentifier)
        )
        inheritedUnknownIdentifiers = inherited
        inheritedWakeDeduplicationKeys = Dictionary(
            uniqueKeysWithValues: inherited.map { ($0, Self.makeEphemeralWakeDeduplicationKey()) }
        )
    }

    var snapshot: GeofenceMonitoringSnapshot {
        guard let activeGeneration else {
            guard !inheritedUnknownIdentifiers.isEmpty else { return .empty }
            return GeofenceMonitoringSnapshot(
                syncGeneration: 0,
                requestedCount: 0,
                confirmedCount: 0,
                failedCount: 0,
                failedCodes: [:],
                omittedCount: 0,
                pendingCount: 0,
                confirmationState: .confirmationUncertain,
                inheritedUnknownCount: inheritedUnknownIdentifiers.count
            )
        }

        var confirmedCount = 0
        var failedCodes: [GeofenceMonitoringFailureCode: Int] = [:]
        var pendingCount = 0
        for expected in activeGeneration.expectedByIdentifier.values {
            switch expected.status {
            case .requested:
                pendingCount += 1
            case .confirmed:
                confirmedCount += 1
            case .failed(let code):
                failedCodes[code, default: 0] += 1
            }
        }
        let failedCount = failedCodes.values.reduce(0, +)
        let confirmationState: GeofenceMonitoringConfirmationState
        if activeGeneration.hasUnattributedMonitoringFailure {
            confirmationState = .confirmationUncertain
        } else if pendingCount > 0 {
            confirmationState = confirmedCount > 0 ? .partiallyConfirmed : .requested
        } else if failedCount > 0 {
            confirmationState = confirmedCount > 0 ? .partiallyConfirmed : .failed
        } else {
            confirmationState = .confirmed
        }
        return GeofenceMonitoringSnapshot(
            syncGeneration: activeGeneration.ordinal,
            requestedCount: activeGeneration.expectedByIdentifier.count,
            confirmedCount: confirmedCount,
            failedCount: failedCount,
            failedCodes: failedCodes,
            omittedCount: activeGeneration.omittedCount,
            pendingCount: pendingCount,
            confirmationState: confirmationState,
            inheritedUnknownCount: 0
        )
    }

    /// Aplica uma sincronização canônica. Somente uma mudança material no conjunto selecionado gera token
    /// físico novo; mesma lista em outra ordem reutiliza a geração, não para/rearma e preserva confirmações.
    func sync(
        _ regions: [GeofenceRegion],
        omittedCount: Int,
        issueNativeRequests: Bool = true
    ) {
        let boundedRegions = Array(regions.prefix(GeofenceRegionPrioritizer.iosRegionCap))
        let boundedOmittedCount = max(0, omittedCount) + max(0, regions.count - boundedRegions.count)
        guard !boundedRegions.isEmpty else {
            removeAll()
            return
        }

        let desiredSet = canonicalDesiredSet(boundedRegions)
        if var activeGeneration, activeGeneration.desiredSet == desiredSet {
            // Não inferimos confirmação por `monitoredRegions`: só `didStart` atual promove pending.
            // Uma mudança somente de omitidas não altera a geração física, mas precisa atualizar o snapshot
            // técnico. A ausência transitória do Core Location tampouco deve exigir uma nova geração.
            activeGeneration.omittedCount = boundedOmittedCount
            // Um stop anterior pode ter sido aceito antes de `monitoredRegions` atualizar. Repetimos apenas
            // a limpeza bounded de remnants conhecidos numa nova intenção idêntica; nunca paramos o set
            // físico atual, nem uma região de namespace externo.
            for identifier in staleOwnedIdentifiersVisibleToNative(
                excluding: Set(activeGeneration.expectedByIdentifier.keys)
            ) {
                native.stopMonitoring(identifier: identifier)
            }
            if issueNativeRequests, !activeGeneration.nativeRequestsIssued {
                activeGeneration.nativeRequestsIssued = true
                self.activeGeneration = activeGeneration
                startExpectedRegions(activeGeneration)
            } else {
                self.activeGeneration = activeGeneration
            }
            return
        }

        // `startMonitoring` pode ainda não aparecer em `monitoredRegions` quando chega uma nova intenção.
        // Por isso a remoção usa também os identifiers expected, que o boundary nativo consegue parar pela
        // própria instância recém-criada. Não deixar esse intervalo armar uma região de conta/projeto antigo.
        let staleIdentifiers = identifiersToStopForReconciliation()
        // Invalida antes de chamar a API: se um callback vier síncrono/tardio durante a remoção, ele não
        // encontra expected set válido. A geração nova é instalada antes dos starts seguintes.
        let ordinal = advanceGeneration()
        let generationToken = makeOpaqueToken()
        var expectedByIdentifier: [String: ExpectedRegion] = [:]
        var expectedIdentifiersInPriorityOrder: [String] = []
        var wakeDeduplicationKeysByLogicalIdentifier: [String: String] = [:]
        let previousWakeDeduplicationKeys = activeGeneration?.wakeDeduplicationKeysByLogicalIdentifier ?? [:]
        for (index, region) in boundedRegions.enumerated() {
            let physicalIdentifier = makePhysicalIdentifier(
                generationToken: generationToken,
                slotToken: makeOpaqueToken(),
                index: index
            )
            let wakeDeduplicationKey = previousWakeDeduplicationKeys[region.id] ??
                Self.makeEphemeralWakeDeduplicationKey()
            let nativeRegion = GeofenceNativeRegion(
                identifier: physicalIdentifier,
                centerLat: region.centerLat,
                centerLng: region.centerLng,
                radiusMeters: region.radiusMeters
            )
            expectedByIdentifier[physicalIdentifier] = ExpectedRegion(
                native: nativeRegion,
                wakeDeduplicationKey: wakeDeduplicationKey,
                status: .requested
            )
            expectedIdentifiersInPriorityOrder.append(physicalIdentifier)
            wakeDeduplicationKeysByLogicalIdentifier[region.id] = wakeDeduplicationKey
        }
        let newGeneration = ActiveGeneration(
            ordinal: ordinal,
            desiredSet: desiredSet,
            omittedCount: boundedOmittedCount,
            nativeRequestsIssued: issueNativeRequests,
            expectedIdentifiersInPriorityOrder: expectedIdentifiersInPriorityOrder,
            wakeDeduplicationKeysByLogicalIdentifier: wakeDeduplicationKeysByLogicalIdentifier,
            hasUnattributedMonitoringFailure: false,
            expectedByIdentifier: expectedByIdentifier
        )
        activeGeneration = newGeneration
        inheritedUnknownIdentifiers.removeAll()
        inheritedWakeDeduplicationKeys.removeAll()

        // Nunca coexistem dois conjuntos de até 20: primeiro interrompe todos os registros herdados/antigos,
        // depois solicita no máximo os 20 selecionados. Não há espera/retry ilimitado nem confirmação falsa.
        for identifier in staleIdentifiers {
            native.stopMonitoring(identifier: identifier)
        }
        guard issueNativeRequests else { return }
        startExpectedRegions(newGeneration)
    }

    /// `didStartMonitoringFor` é a única transição para confirmado. O identificador físico e a geometria
    /// precisam casar com o expected set atual; callback atrasado, herdado ou adulterado não pede state.
    @discardableResult
    func didStartMonitoring(for nativeRegion: GeofenceNativeRegion) -> Bool {
        guard var activeGeneration,
              var expected = activeGeneration.expectedByIdentifier[nativeRegion.identifier],
              expected.native.hasSameGeometry(as: nativeRegion),
              expected.status == .requested
        else { return false }

        expected.status = .confirmed
        activeGeneration.expectedByIdentifier[nativeRegion.identifier] = expected
        self.activeGeneration = activeGeneration
        native.requestState(for: nativeRegion.identifier)
        return true
    }

    /// Falha só é atribuída à geração que ainda espera exatamente essa região física/geométrica. Um erro sem
    /// região não pode ser ligado a uma geração real (nem a uma região): ele preserva as contagens e torna o
    /// snapshot explicitamente `confirmationUncertain`, em vez de contaminar como confirmed/failed.
    @discardableResult
    func monitoringDidFail(for nativeRegion: GeofenceNativeRegion?, error: Error) -> Bool {
        guard let nativeRegion else {
            guard var activeGeneration, !activeGeneration.hasUnattributedMonitoringFailure else { return false }
            activeGeneration.hasUnattributedMonitoringFailure = true
            self.activeGeneration = activeGeneration
            return true
        }
        guard var activeGeneration,
              var expected = activeGeneration.expectedByIdentifier[nativeRegion.identifier],
              expected.native.hasSameGeometry(as: nativeRegion)
        else { return false }

        guard case .failed = expected.status else {
            expected.status = .failed(GeofenceMonitoringFailureCode.sanitizeCoreLocationError(error))
            activeGeneration.expectedByIdentifier[nativeRegion.identifier] = expected
            self.activeGeneration = activeGeneration
            return true
        }
        return false
    }

    /// Zera o snapshot público e invalida o expected set ANTES do stop. Assim `didStart`/`didFail` tardios
    /// não podem ressuscitar uma conta/projeto removido.
    func removeAll() {
        // Capture antes de invalidar: uma solicitação recém-enviada pode não estar em `monitoredRegions`,
        // mas ainda existe no expected set e precisa receber stop no logout/toggle/troca de contexto.
        let identifiersToStop = identifiersToStopForReconciliation()
        activeGeneration = nil
        inheritedUnknownIdentifiers.removeAll()
        inheritedWakeDeduplicationKeys.removeAll()
        for identifier in identifiersToStop {
            native.stopMonitoring(identifier: identifier)
        }
    }

    /// Eventos de transição não confirmam nada. Antes da reconciliação de um relaunch, uma região herdada
    /// pode continuar sendo apenas wake-only; depois disso, só o set físico atual é aceito pelo monitor.
    func mayHandleWake(for identifier: String) -> Bool {
        wakeDeduplicationKey(for: identifier) != nil
    }

    /// Chave somente em memória para manter a deduplicação por região/direção mesmo quando o mesmo ID
    /// lógico recebe uma identidade física nova. Nunca é exposta a log, journal, export ou UI.
    func wakeDeduplicationKey(for identifier: String) -> String? {
        if let expected = activeGeneration?.expectedByIdentifier[identifier] {
            return expected.wakeDeduplicationKey
        }
        return inheritedWakeDeduplicationKeys[identifier]
    }

    private func advanceGeneration() -> UInt64 {
        if nextGeneration == UInt64.max {
            // O token aleatório, e não o ordinal, é a prova de identidade no callback. Reiniciar o contador
            // é seguro após overflow e evita trap em uma sessão extraordinariamente longa.
            nextGeneration = 1
        } else {
            nextGeneration += 1
        }
        return nextGeneration
    }

    private func canonicalDesiredSet(_ regions: [GeofenceRegion]) -> [GeofenceRegion] {
        regions.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.centerLat != rhs.centerLat { return lhs.centerLat < rhs.centerLat }
            if lhs.centerLng != rhs.centerLng { return lhs.centerLng < rhs.centerLng }
            return lhs.radiusMeters < rhs.radiusMeters
        }
    }

    private func makePhysicalIdentifier(
        generationToken: String,
        slotToken: String,
        index: Int
    ) -> String {
        // O índice não referencia nada do domínio; ele só torna a forma observável no Core Location única
        // dentro do token aleatório da geração. Nenhuma dessas partes é persistida fora da API nativa.
        "gfr1.\(generationToken).\(slotToken).\(String(index, radix: 36))"
    }

    private func startExpectedRegions(_ generation: ActiveGeneration) {
        for identifier in generation.expectedIdentifiersInPriorityOrder {
            guard let expected = generation.expectedByIdentifier[identifier] else { continue }
            native.startMonitoring(expected.native)
        }
    }

    private func identifiersToStopForReconciliation() -> [String] {
        var identifiers = Set(
            native.monitoredRegions()
                .map(\.identifier)
                .filter(Self.isOwnedOrLegacyPhysicalIdentifier)
        )
        identifiers.formUnion(inheritedUnknownIdentifiers)
        if let activeGeneration {
            identifiers.formUnion(activeGeneration.expectedByIdentifier.keys)
        }
        return identifiers.sorted()
    }

    private func staleOwnedIdentifiersVisibleToNative(excluding expectedIdentifiers: Set<String>) -> [String] {
        Set(
            native.monitoredRegions()
                .map(\.identifier)
                .filter(Self.isOwnedOrLegacyPhysicalIdentifier)
                .filter { !expectedIdentifiers.contains($0) }
        )
        .sorted()
    }

    private static func isOwnedOrLegacyPhysicalIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("gfr1.") || isLegacyMonitorIdentifier(identifier)
    }

    /// O predecessor vivo criou `CLCircularRegion.identifier` com `String(Int)`. O parse seguido de
    /// round-trip canônico é deliberadamente mais estreito que "qualquer identifier do app": não alcança
    /// o harness, strings numéricas com zero à esquerda, overflow ou outros managers. Este caminho existe
    /// só para retirar o conjunto legado durante a futura ativação candidate.
    private static func isLegacyMonitorIdentifier(_ identifier: String) -> Bool {
        guard let legacyIdentifier = Int(identifier) else { return false }
        return String(legacyIdentifier) == identifier
    }

    private static func makeEphemeralWakeDeduplicationKey() -> String {
        "gfd1.\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }
}
