import Foundation

/// A fronteira mínima entre o registro UIKit de `BGTask` e os executores por perfil.
///
/// `BGTask` em si não é construível em testes. Este adaptador mantém o framework no `AppDelegate`, mas
/// torna verificável que um handler registra **um** caminho coerente: o controller candidato ou o handler
/// legado, nunca ambos. A rota é deliberadamente síncrona para que o expiration handler seja instalado
/// antes de o callback do sistema retornar.
@MainActor
protocol SystemBackgroundTaskHandling: AnyObject {
    func installExpirationHandler(_ handler: @escaping @Sendable () -> Void)
}

/// Handle sem estado persistente, seguro para ser capturado pelo `expirationHandler` síncrono do sistema.
/// O próprio controller/handler decide como linearizar chamadas repetidas de `expire()`.
struct SystemBackgroundTaskExpirationHandle: Sendable {
    private let expireOperation: @Sendable () -> Void

    init(expire: @escaping @Sendable () -> Void) {
        expireOperation = expire
    }

    func expire() {
        expireOperation()
    }
}

/// Seleciona e instala exatamente um handler de task de sistema para o perfil ativo.
///
/// A mesma rota é usada para `BGAppRefresh` e `BGProcessing`; isso impede que uma configuração candidata
/// construa acidentalmente o handler legado em paralelo. Os starters são executados imediatamente na
/// MainActor, e o único valor que cruza a fronteira do expiration handler é o handle `Sendable` acima.
@MainActor
enum AppDelegateBackgroundTaskHandlerRouter {
    typealias Starter = () -> SystemBackgroundTaskExpirationHandle

    static func install(
        profile: BackgroundReliabilityProfile,
        task: any SystemBackgroundTaskHandling,
        startCandidate: Starter,
        startLegacy: Starter
    ) {
        let expirationHandle: SystemBackgroundTaskExpirationHandle
        switch profile.operationalPipeline {
        case .candidate:
            expirationHandle = startCandidate()
        case .legacy:
            expirationHandle = startLegacy()
        }
        task.installExpirationHandler {
            expirationHandle.expire()
        }
    }
}
