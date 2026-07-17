import Foundation

// Motor de decisão de check-in/check-out automático — port 1:1 de
// domain/checkrules/AutoActivities.kt. FONTE ÚNICA DA VERDADE (fluxo ao vivo + replay offline).
// Ver docs/port_spec_decision_engine.md §3/§4.

// Constantes de domínio (byte-exact — preservar UTF-8: ç, ã, "não").
let AUTOMATIC_CHECKOUT_LOCATION = "Fora do Local de Trabalho"
let AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION = "Localização não Cadastrada"
let MIXED_ZONE_LOCATION = "Zona Mista"

// trim → colapsa \s+ → minúsculas (sem locale).
func normalizeLocationName(_ value: String?) -> String {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsed.lowercased()
}

func isCheckoutZoneLocationName(_ value: String?) -> Bool {
    normalizeLocationName(value) == "zona de checkout"
}

func isMixedZoneLocationName(_ value: String?) -> Bool {
    normalizeLocationName(value) == "zona mista"
}

// Precedência: ambos nil → currentAction; só check-in → CHECKIN; só check-out → CHECKOUT;
// ambos → o mais novo vence; empate exato → currentAction; state nil → nil.
func resolveLastRecordedAction(_ state: HistoryState?) -> CheckAction? {
    let inAt = state?.lastCheckinAt
    let outAt = state?.lastCheckoutAt
    if inAt == nil && outAt == nil { return state?.currentAction }
    if inAt != nil && outAt == nil { return .checkIn }
    if inAt == nil && outAt != nil { return .checkOut }
    let i = inAt!
    let o = outAt!
    if i > o { return .checkIn }
    if o > i { return .checkOut }
    return state?.currentAction
}

func resolveRecordedCheckInLocation(_ state: HistoryState?) -> String? {
    (state?.currentAction == .checkIn) ? state?.currentLocal : nil
}

func resolveCurrentRecordedLocation(_ state: HistoryState?) -> String? { state?.currentLocal }

func resolveRecordedActionTimestamp(_ state: HistoryState?, _ action: CheckAction?) -> Date? {
    switch action {
    case .checkIn?: return state?.lastCheckinAt
    case .checkOut?: return state?.lastCheckoutAt
    case nil: return nil
    }
}

struct MixedZoneActivity: Sendable, Equatable {
    let action: CheckAction
    let local: String
    let timestamp: Date
}

func resolveLastRelevantMixedZoneActivity(_ state: HistoryState?) -> MixedZoneActivity? {
    let current = resolveCurrentRecordedLocation(state)
    guard isMixedZoneLocationName(current) else { return nil }
    guard let last = resolveLastRecordedAction(state), last == .checkIn || last == .checkOut else { return nil }
    guard let timestamp = resolveRecordedActionTimestamp(state, last) else { return nil }
    return MixedZoneActivity(action: last, local: current!, timestamp: timestamp)
}

func isLastRelevantActivityInMixedZone(_ state: HistoryState?) -> Bool {
    resolveLastRelevantMixedZoneActivity(state) != nil
}

func resolveMixedZoneCooldownMilliseconds(_ minutes: Int) -> Int64 {
    minutes < 1 ? 0 : Int64(minutes) * 60 * 1000
}

private func epochMillis(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
}

struct MixedZoneDecisionSettings: Sendable {
    let mixedZoneIntervalMinutes: Int
    let referenceTime: Date?
    init(mixedZoneIntervalMinutes: Int, referenceTime: Date? = nil) {
        self.mixedZoneIntervalMinutes = mixedZoneIntervalMinutes
        self.referenceTime = referenceTime
    }
}

// Variante A: exige que currentLocal JÁ seja "Zona Mista".
func isMixedZoneCooldownActive(_ state: HistoryState?, _ minutes: Int, _ referenceTime: Date? = nil) -> Bool {
    guard let last = resolveLastRelevantMixedZoneActivity(state) else { return false }
    let cooldownMs = resolveMixedZoneCooldownMilliseconds(minutes)
    if cooldownMs <= 0 { return false }
    let reference = referenceTime ?? Date()
    return epochMillis(reference) - epochMillis(last.timestamp) < cooldownMs
}

func resolveLastRecordedActivityTimestamp(_ state: HistoryState?) -> Date? {
    guard let last = resolveLastRecordedAction(state), last == .checkIn || last == .checkOut else { return nil }
    return resolveRecordedActionTimestamp(state, last)
}

// Variante B (temp006): última atividade em QUALQUER localização — guarda de drift de GPS.
func isMixedZoneCooldownActiveForLastActivity(_ state: HistoryState?, _ minutes: Int, _ referenceTime: Date? = nil) -> Bool {
    guard let timestamp = resolveLastRecordedActivityTimestamp(state) else { return false }
    let cooldownMs = resolveMixedZoneCooldownMilliseconds(minutes)
    if cooldownMs <= 0 { return false }
    let reference = referenceTime ?? Date()
    return epochMillis(reference) - epochMillis(timestamp) < cooldownMs
}

func shouldAttemptAutomaticMixedZoneLocationEvent(
    _ locationMatch: LocationMatch?,
    _ remoteState: HistoryState?,
    _ settings: MixedZoneDecisionSettings
) -> Bool {
    let resolvedLocal = locationMatch?.resolvedLocal
    guard isMixedZoneLocationName(resolvedLocal) else { return false }

    let lastRecordedAction = resolveLastRecordedAction(remoteState)
    let currentRecordedLocation = resolveCurrentRecordedLocation(remoteState)
    let lastCheckInLocation = resolveRecordedCheckInLocation(remoteState)
    let cooldownMs = resolveMixedZoneCooldownMilliseconds(settings.mixedZoneIntervalMinutes)

    // Branch A: estado já registrado na própria Zona Mista.
    if !normalizeLocationName(resolvedLocal).isEmpty,
       normalizeLocationName(resolvedLocal) == normalizeLocationName(currentRecordedLocation) {
        if !isLastRelevantActivityInMixedZone(remoteState) || cooldownMs <= 0 { return false }
        return !isMixedZoneCooldownActive(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime)
    }

    // Branch B (temp006): gate de cooldown com estado registrado em OUTRA localização.
    if isMixedZoneCooldownActiveForLastActivity(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime) {
        return false
    }

    if lastRecordedAction != .checkIn { return true }

    return normalizeLocationName(resolvedLocal) != normalizeLocationName(lastCheckInLocation)
}

// Situações 1-4, 6-8: decide se dispara evento para uma localização MATCHED.
func shouldAttemptAutomaticLocationEvent(
    _ locationMatch: LocationMatch?,
    _ remoteState: HistoryState?,
    _ settings: MixedZoneDecisionSettings
) -> Bool {
    let resolvedLocal = locationMatch?.resolvedLocal
    let lastRecordedAction = resolveLastRecordedAction(remoteState)

    if isCheckoutZoneLocationName(resolvedLocal) {
        return lastRecordedAction == .checkIn
    }
    if isMixedZoneLocationName(resolvedLocal) {
        return shouldAttemptAutomaticMixedZoneLocationEvent(locationMatch, remoteState, settings)
    }
    if lastRecordedAction != .checkIn { return true }

    // Change A (P6.1): re-check-in numa área MATCHED só dispara se o local mudou.
    let lastCheckInLocation = resolveRecordedCheckInLocation(remoteState)
    return !normalizeLocationName(resolvedLocal).isEmpty
        && normalizeLocationName(resolvedLocal) != normalizeLocationName(lastCheckInLocation)
}

// Situação 1 (far) + Situação 2: check-out quando OUTSIDE_WORKPLACE e o último foi check-in.
func shouldAttemptAutomaticOutOfRangeCheckout(_ locationMatch: LocationMatch?, _ remoteState: HistoryState?) -> Bool {
    guard let match = locationMatch, match.status == .outsideWorkplace else { return false }
    return resolveLastRecordedAction(remoteState) == .checkIn
}

// Situação 5: perto mas fora — nunca alvo válido de check-in automático.
func shouldAttemptAutomaticNearbyWorkplaceCheckIn(_ locationMatch: LocationMatch?, _ remoteState: HistoryState?) -> Bool {
    false
}

// Mixed zone alterna a partir da última ação; checkout zone → CHECKOUT; senão → CHECKIN.
func resolveAutomaticLocationAction(_ locationMatch: LocationMatch?, _ remoteState: HistoryState?) -> CheckAction {
    let resolvedLocal = locationMatch?.resolvedLocal
    if isMixedZoneLocationName(resolvedLocal) {
        return resolveLastRecordedAction(remoteState) == .checkIn ? .checkOut : .checkIn
    }
    return isCheckoutZoneLocationName(resolvedLocal) ? .checkOut : .checkIn
}

// Função-mestre. Ordem: OUTSIDE_WORKPLACE → MATCHED → NOT_IN_KNOWN_LOCATION → nil.
// SEM caso especial de primeiro registro.
func resolveAutomaticActivityForMatch(
    _ match: LocationMatch,
    _ currentState: HistoryState?,
    _ mixedZoneIntervalMinutes: Int
) -> AutomaticActivity? {
    let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: mixedZoneIntervalMinutes)

    if match.status == .outsideWorkplace {
        return shouldAttemptAutomaticOutOfRangeCheckout(match, currentState)
            ? AutomaticActivity(action: .checkOut, local: AUTOMATIC_CHECKOUT_LOCATION)
            : nil
    }

    if match.status == .matched {
        guard shouldAttemptAutomaticLocationEvent(match, currentState, settings) else { return nil }
        let action = resolveAutomaticLocationAction(match, currentState)
        return AutomaticActivity(action: action, local: match.resolvedLocal)
    }

    if match.status == .notInKnownLocation {
        // Change A continuation (P6.2): só como MUDANÇA, e só para usuário em check-in.
        let lastCheckInLocation = resolveRecordedCheckInLocation(currentState)
        if resolveLastRecordedAction(currentState) == .checkIn,
           normalizeLocationName(lastCheckInLocation) != normalizeLocationName(AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION) {
            return AutomaticActivity(action: .checkIn, local: AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION)
        }
        return nil
    }

    return nil // ACCURACY_TOO_LOW / NO_KNOWN_LOCATIONS
}
