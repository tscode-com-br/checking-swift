import Foundation
@testable import Checking

/// Parser de instante ISO-8601 para timestamps de teste (nomes únicos para não colidir entre arquivos).
func iso(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)!
}

/// Calendário fixo em UTC (os testes de pausa fixam a zona em UTC para evitar DST).
func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}
