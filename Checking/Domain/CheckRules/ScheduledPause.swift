import Foundation

// Pausa programada — port 1:1 de domain/checkrules/ScheduledPause.kt.
// ZonedDateTime → (Date + Calendar com a TimeZone relevante). DayOfWeek → Calendar weekday
// (gregoriano: 1=domingo … 7=sábado). Ver docs/port_spec_decision_engine.md §5.

struct ScheduledPauseSettings: Sendable, Equatable, Codable {
    var scheduledPauseEnabled: Bool
    var scheduledPauseFrom: String   // "HH:mm"
    var scheduledPauseTo: String     // "HH:mm"
    var suspendSaturdays: Bool
    var suspendSundays: Bool
}

struct ScheduledPauseWindow: Sendable, Equatable {
    let start: Date
    let end: Date
}

private func parseMinutesOfDay(_ hhmm: String) -> Int {
    let parts = hhmm.split(separator: ":")
    let h = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
    let m = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    return h * 60 + m
}

private func minutesOfDay(_ date: Date, _ calendar: Calendar) -> Int {
    calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
}

private func isSaturday(_ date: Date, _ calendar: Calendar) -> Bool { calendar.component(.weekday, from: date) == 7 }
private func isSunday(_ date: Date, _ calendar: Calendar) -> Bool { calendar.component(.weekday, from: date) == 1 }

private func startOfDay(_ date: Date, plusDays offset: Int, _ calendar: Calendar) -> Date {
    calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date))!
}

private func dayAtMinutes(_ date: Date, plusDays offset: Int, minutesOfDay t: Int, _ calendar: Calendar) -> Date {
    let day = startOfDay(date, plusDays: offset, calendar)
    return calendar.date(bySettingHour: t / 60, minute: t % 60, second: 0, of: day)!
}

// Ordem: (1) fim de semana (dia inteiro, INDEPENDENTE de scheduledPauseEnabled) → (2) janela.
func isScheduledPauseActiveNow(_ now: Date, _ calendar: Calendar, _ settings: ScheduledPauseSettings) -> Bool {
    if settings.suspendSaturdays && isSaturday(now, calendar) { return true }
    if settings.suspendSundays && isSunday(now, calendar) { return true }

    if settings.scheduledPauseEnabled {
        let f = parseMinutesOfDay(settings.scheduledPauseFrom)
        let t = parseMinutesOfDay(settings.scheduledPauseTo)
        if f != t { // f == t ⇒ janela desabilitada
            let n = minutesOfDay(now, calendar)
            return f < t ? (n >= f && n < t) : (n >= f || n < t)
        }
    }
    return false
}

// Primeiro instante > now em que a pausa termina, ou nil se não está pausado.
func nextResumeInstant(_ now: Date, _ calendar: Calendar, _ settings: ScheduledPauseSettings) -> Date? {
    guard isScheduledPauseActiveNow(now, calendar, settings) else { return nil }

    var candidates: [Date] = []

    if settings.scheduledPauseEnabled {
        let f = parseMinutesOfDay(settings.scheduledPauseFrom)
        let t = parseMinutesOfDay(settings.scheduledPauseTo)
        if f != t {
            for offset in 0...7 {
                let candidate = dayAtMinutes(now, plusDays: offset, minutesOfDay: t, calendar)
                if candidate > now { candidates.append(candidate) }
            }
        }
    }
    for offset in 1...7 {
        candidates.append(startOfDay(now, plusDays: offset, calendar))
    }

    return candidates.sorted().first { !isScheduledPauseActiveNow($0, calendar, settings) }
}

// Primeiro instante > now em que a pausa COMEÇA (transição para pausa), ou nil.
func nextPauseStartInstant(_ now: Date, _ calendar: Calendar, _ settings: ScheduledPauseSettings) -> Date? {
    guard !isScheduledPauseActiveNow(now, calendar, settings) else { return nil }

    var candidates: [Date] = []

    if settings.scheduledPauseEnabled {
        let f = parseMinutesOfDay(settings.scheduledPauseFrom)
        let t = parseMinutesOfDay(settings.scheduledPauseTo)
        if f != t {
            for offset in 0...8 {
                let candidate = dayAtMinutes(now, plusDays: offset, minutesOfDay: f, calendar)
                if candidate > now { candidates.append(candidate) }
            }
        }
    }
    for offset in 0...8 {
        let day = startOfDay(now, plusDays: offset, calendar)
        if day <= now { continue }
        let suspended = (settings.suspendSaturdays && isSaturday(day, calendar))
            || (settings.suspendSundays && isSunday(day, calendar))
        if suspended { candidates.append(day) }
    }

    return candidates.sorted().first { isScheduledPauseActiveNow($0, calendar, settings) }
}

/// Ocorrência contínua que contém `now`. As pausas diárias e os dias inteiros podem se sobrepor;
/// por isso o início é uma transição real de inativo para ativo, não apenas o horário "De".
func currentScheduledPauseWindow(
    _ now: Date,
    _ calendar: Calendar,
    _ settings: ScheduledPauseSettings
) -> ScheduledPauseWindow? {
    guard let end = nextResumeInstant(now, calendar, settings) else { return nil }
    // Todas as regras têm resolução de minuto. Andar sobre `Date` (instantes absolutos), partindo do
    // início do minuto, também atravessa corretamente gaps/repetições de DST e produz fallback estável.
    var start = calendar.dateInterval(of: .minute, for: now)?.start ?? now
    let maximumContinuousMinutes = 10 * 24 * 60
    for _ in 0..<maximumContinuousMinutes {
        let previous = start.addingTimeInterval(-60)
        guard isScheduledPauseActiveNow(previous, calendar, settings) else { break }
        start = previous
    }
    return ScheduledPauseWindow(start: start, end: end)
}
