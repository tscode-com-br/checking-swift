import Foundation

/// Relógio injetável — permite testes com um instante fixo. Espelha o `core/time/Clock` do Kotlin.
///
/// - Note: a zona `singapore` é o default do "dia atual" (`resolveCalendarDayKey`);
///   a Pausa Programada usa o fuso do APARELHO. Ver port_spec_persistence_foundation §7.
public protocol Clock: Sendable {
    func now() -> Date
}

public enum ClockZone {
    /// Zona usada para a chave de dia calendário ("Hoje"/"Ontem").
    public static let singapore = TimeZone(identifier: "Asia/Singapore")!
}

/// Implementação de produção — delega ao relógio do sistema.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}
