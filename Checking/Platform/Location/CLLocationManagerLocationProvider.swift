import CoreLocation

/// Implementação viva de `LocationProvider` — port de platform/location/LocationProvider.kt ("15s
/// melhor-fix"). Ver port_spec_background_orchestrator §8. Cada chamada a `capture` cria sua própria
/// `CaptureSession` (CLLocationManager + delegate próprios) — sem estado compartilhado entre chamadas
/// concorrentes, fiel ao `callbackFlow` do Kotlin (que também isola callback/`bestRef` por invocação).
/// `CaptureLocationUseCase` é o "único chokepoint (manual + automático)", então chamadas concorrentes
/// (check-in manual + orquestrador em background) são um cenário real, não hipotético.
///
/// `capture`/`CaptureSession` são integração com o CoreLocation real — não cobertos por teste unitário
/// (mesmo padrão de `NWPathMonitorNetworkMonitor`); a lógica que os consome (`CaptureLocationUseCase`,
/// `RunAutomaticActivitiesUseCase`) já é testada com um `LocationProvider` fake. Só `isBetter`/
/// `isValidAccuracy` (puros) são testados diretamente aqui.
struct CLLocationManagerLocationProvider: LocationProvider {
    static let timeBudgetSeconds: TimeInterval = 15

    func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture {
        await CaptureSession(accuracyThresholdMeters: accuracyThresholdMeters).run()
    }

    /// `menor horizontalAccuracy` vence; empate → `timestamp` mais novo (port de `isBetter` do Kotlin).
    /// Accuracy negativa também é tratada como inválida — convenção do CoreLocation (não existe no Android,
    /// onde accuracy nunca é negativa), extensão natural do guard `isFinite()` original do Kotlin.
    static func isBetter(_ candidate: CLLocation, than current: CLLocation?) -> Bool {
        guard let current else { return true }
        if !isValidAccuracy(candidate.horizontalAccuracy) { return false }
        if !isValidAccuracy(current.horizontalAccuracy) { return true }
        if candidate.horizontalAccuracy < current.horizontalAccuracy { return true }
        if candidate.horizontalAccuracy > current.horizontalAccuracy { return false }
        return candidate.timestamp > current.timestamp
    }

    static func isValidAccuracy(_ accuracy: CLLocationAccuracy) -> Bool {
        accuracy.isFinite && accuracy >= 0
    }
}

/// Sessão de captura única (uma por chamada a `capture`) — dona do `CLLocationManager`/delegate/timeout,
/// resolve a `CheckedContinuation` exatamente 1×. `@MainActor`: CLLocationManager precisa de run loop ativo
/// (a thread principal garante isso); os callbacks do delegate chegam nela.
@MainActor
private final class CaptureSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let accuracyThresholdMeters: Int
    private var best: CLLocation?
    private var continuation: CheckedContinuation<LocationCapture, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(accuracyThresholdMeters: Int) {
        self.accuracyThresholdMeters = accuracyThresholdMeters
        super.init()
    }

    func run() async -> LocationCapture {
        // Fiel ao Kotlin: sem permissão do APP é falha RÁPIDA (`SecurityException` síncrona lá), não
        // espera os 15s. Pedir a permissão em si é da escada (port_spec_permissions_diagnostics), não daqui.
        // Deliberadamente SEM checar `CLLocationManager.locationServicesEnabled()` aqui: no Android, o
        // toggle de Localização do sistema desligado não lança (só a permissão do app lança) — o
        // `requestLocationUpdates` some silenciosamente e o capture só resolve no timeout de 15s
        // (`Timeout`, não `Unavailable`). Um guard prévio aqui reproduziria errado esse caso. Nota: o
        // CoreLocation pode ainda reportar isso via `didFailWithError(.denied)` reativamente (§ abaixo) —
        // o iOS não separa "serviço desligado" de "permissão negada" no nível do delegate como o Android
        // separa a exceção; temos que documentar a divergência residual, não fingir que não existe.
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return .unavailable
        }
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.delegate = self
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                // Já cancelado antes de sequer começar (ex.: BGTask expirou entre o gate acima e aqui).
                if Task.isCancelled { finish(timedOut: true); return }
                manager.startUpdatingLocation()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(CLLocationManagerLocationProvider.timeBudgetSeconds * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.finish(timedOut: true)
                }
            }
        } onCancel: {
            // Cancelamento externo (ex.: `expirationHandler` do BGTask) — devolve melhor-fix-parcial se
            // houver, senão `.timeout`. Sem isso, uma captura em voo ignoraria o cancelamento e rodaria
            // até seus próprios 15s, atrapalhando o prazo que o próprio app deu ao BGTask.
            Task { @MainActor [weak self] in self?.finish(timedOut: true) }
        }
    }

    private func finish(timedOut: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        manager.stopUpdatingLocation()
        if let best {
            // Melhor-fix-parcial no timeout mesmo sem bater o threshold — mesma semântica do Kotlin.
            continuation.resume(returning: .success(lat: best.coordinate.latitude, lon: best.coordinate.longitude,
                                                     accuracyMeters: best.horizontalAccuracy))
        } else {
            continuation.resume(returning: timedOut ? .timeout : .unavailable)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, let newest = locations.last else { return }
            if CLLocationManagerLocationProvider.isBetter(newest, than: best) { best = newest }
            if let best, CLLocationManagerLocationProvider.isValidAccuracy(best.horizontalAccuracy),
               best.horizontalAccuracy <= Double(accuracyThresholdMeters) {
                finish(timedOut: false)
            }
        }
    }

    // Erros transitórios (ex.: `.locationUnknown`, sinal momentaneamente indisponível) são ignorados — o
    // CoreLocation segue tentando e o timeout/melhor-fix decide. Só `.denied` (permissão revogada em
    // pleno voo) encerra cedo como `.unavailable` — sem equivalente 1:1 no Kotlin (API diferente), mas é a
    // leitura mais fiel de "erro real" vs. "ainda não temos fix".
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let clError = error as? CLError, clError.code == .denied else { return }
        Task { @MainActor [weak self] in self?.finish(timedOut: false) }
    }
}
