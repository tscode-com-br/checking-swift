import UIKit

/// Solicita ao iOS alguns instantes para concluir uma avaliação já iniciada quando o app transita para
/// segundo plano. Não mantém o app vivo indefinidamente; apenas protege o fechamento do evento corrente.
///
/// As duas closures armazenadas são imutáveis e `@Sendable`; o único estado mutável de cada concessão vive
/// no `BackgroundExecutionLease` lock-backed. Isso justifica a conformidade Sendable desta classe de glue.
final class UIKitBackgroundTaskGuard:
    BackgroundTaskGuard,
    BackgroundExecutionLeasing,
    @unchecked Sendable
{
    typealias BeginOperation = @Sendable (
        _ name: String,
        _ expirationHandler: @escaping @Sendable () -> Void
    ) async -> Int
    typealias EndOperation = @Sendable (_ token: Int) -> Void

    private static let legacyTaskName = "Checking automatic evaluation"

    private let invalidToken: Int
    private let beginOperation: BeginOperation
    private let endOperation: EndOperation

    convenience init() {
        self.init(
            invalidToken: UIBackgroundTaskIdentifier.invalid.rawValue,
            beginOperation: { name, expirationHandler in
                await MainActor.run {
                    UIApplication.shared.beginBackgroundTask(
                        withName: name,
                        expirationHandler: expirationHandler
                    ).rawValue
                }
            },
            endOperation: { token in
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(
                        UIBackgroundTaskIdentifier(rawValue: token)
                    )
                }
            }
        )
    }

    /// Adapter injetável para testes. Produção usa as closures MainActor da convenience initializer.
    init(
        invalidToken: Int,
        beginOperation: @escaping BeginOperation,
        endOperation: @escaping EndOperation
    ) {
        self.invalidToken = invalidToken
        self.beginOperation = beginOperation
        self.endOperation = endOperation
    }

    // Contrato legado preservado para `legacyWithDiagnostics`. O callback vazio é intencionalmente não
    // nil; propagação de expiração pertence somente ao novo seam candidato.
    func begin() async -> Int {
        await beginOperation(Self.legacyTaskName, {})
    }

    func end(_ token: Int) {
        guard token != invalidToken else { return }
        endOperation(token)
    }

    func begin(
        name: String,
        onExpiration: @escaping @Sendable () -> Void
    ) async -> BackgroundExecutionLease {
        let lease = BackgroundExecutionLease(onExpiration: onExpiration)
        let token = await beginOperation(name) {
            lease.expire()
        }
        guard token != invalidToken else { return lease }
        lease.installEndHandler { [endOperation] in
            endOperation(token)
        }
        return lease
    }
}
