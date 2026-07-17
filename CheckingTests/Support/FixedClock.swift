import Foundation
@testable import Checking

/// Relógio fixo para testes determinísticos (equivalente ao `Clock` mockado nos testes Kotlin).
struct FixedClock: Clock {
    let instant: Date
    init(_ instant: Date) { self.instant = instant }
    func now() -> Date { instant }
}
