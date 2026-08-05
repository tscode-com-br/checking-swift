import Foundation

extension OfflineCheckQueue {
    /// O guard roda já dentro do actor e lineariza a validade com toda a mutação síncrona. Assim uma
    /// invalidação ocorrida enquanto o caller aguardava o hop de executor não consegue persistir um evento
    /// antigo, e uma invalidação concorrente só retorna depois que a escrita já tem uma ordem definida.
    func enqueueIfCurrent(
        _ event: PendingCheckEvent,
        effectGuard: AutomaticActivitiesEffectGuard
    ) -> Bool {
        effectGuard.performIfCurrent {
            enqueue(event)
        }
    }
}
