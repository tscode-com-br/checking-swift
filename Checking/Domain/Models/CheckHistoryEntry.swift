import Foundation

/// Item do histórico de check — port de domain/model/CheckHistoryEntry.kt.
/// `time` é `Date?` (parse ISO com fallback nil no boundary). Ver port_spec_network_contracts §12.
struct CheckHistoryEntry: Sendable, Equatable {
    var action: CheckAction
    var projeto: String
    var local: String?
    var time: Date?
    var informe: InformeType
}
