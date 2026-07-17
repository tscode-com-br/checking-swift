# Spec de porte — Motor de decisão automática (Domain)

> Especificação executável para portar o motor de check-in/check-out automático do Android (Kotlin) para iOS (Swift), com fidelidade 1:1.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta + auditoria de ground-truth (2026-07-14).
> Escopo: **camada de domínio pura** (`AutoActivities.kt`, `ScheduledPause.kt`) + os dois casos de uso (`RunAutomaticActivitiesUseCase`, `CaptureLocationUseCase`).
> Fora de escopo (camada de plataforma — ver spec de background): filtro de movimento, captura GPS de 15s, gatilhos (geofence/significant/timer/foreground/BGTask), single-flight, caches, submit HTTP/SSE. Este documento marca a fronteira.

Arquivos-fonte Kotlin:
- [AutoActivities.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/checkrules/AutoActivities.kt)
- [ScheduledPause.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/checkrules/ScheduledPause.kt)
- [RunAutomaticActivitiesUseCase.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/usecase/RunAutomaticActivitiesUseCase.kt)
- [CaptureLocationUseCase.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/usecase/CaptureLocationUseCase.kt)
- [CheckModels.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/model/CheckModels.kt) · [GeofenceCircle.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/model/GeofenceCircle.kt)

---

## 0. Por que este subsistema primeiro

1. É **lógica pura e determinística** — portável 1:1 sem dependências de plataforma.
2. É a **única fonte de verdade** da matriz de situações, usada tanto pelo fluxo ao vivo (`RunAutomaticActivitiesUseCase`) quanto pelo replay offline (`SyncPendingChecksWorker`). Portar **uma** função pura chamada pelos dois caminhos.
3. O plano (§11) o prioriza; **~135 testes** o cobrem — o maior ganho de portabilidade de testes.
4. Não tem nenhuma das ambiguidades do `decision_log.md` — é o alicerce limpo.

## 1. Regras de dependência

- O motor é **`Domain`**: importa apenas `Foundation` (para `Date`). **Nunca** `CoreLocation`, `SwiftUI`, `UIKit`, `URLSession`.
- A geometria de localização é **sempre do servidor** (`POST /check/location` retorna `MatchStatus` + `resolvedLocal`). O cliente **não** faz cálculo de área. `GeofenceCircle` serve só para armar geofences nativos (camada de plataforma).
- As dependências do caso de uso (`CheckRepository`, `LocationProvider`, `OfflineCheckQueue`, `ActivityLogger`, `Clock`) são **protocolos injetáveis** — mockáveis em teste.

## 2. Modelo de tipos (Swift)

Port direto de `CheckModels.kt` + `GeofenceCircle.kt`. `Instant` → `Date`. `data class` → `struct`. Enums preservam a ordem.

```swift
import Foundation

enum CheckAction { case checkIn, checkOut }            // Kotlin CHECKIN, CHECKOUT
enum InformeType { case normal, retroativo }           // Kotlin NORMAL, RETROATIVO

enum MatchStatus {                                     // ordem preservada
    case matched                // MATCHED
    case accuracyTooLow         // ACCURACY_TOO_LOW
    case notInKnownLocation     // NOT_IN_KNOWN_LOCATION
    case outsideWorkplace       // OUTSIDE_WORKPLACE
    case noKnownLocations       // NO_KNOWN_LOCATIONS
}

struct HistoryState {
    let found: Bool
    let chave: String
    let projeto: String?
    let currentAction: CheckAction?
    let currentLocal: String?
    let hasCurrentDayCheckin: Bool
    let lastCheckinAt: Date?
    let lastCheckoutAt: Date?
    let transportEnabled: Bool
}

struct LocationMatch {
    let matched: Bool
    let resolvedLocal: String?
    let label: String
    let status: MatchStatus
    let message: String
    let accuracyMeters: Double?
    let accuracyThresholdMeters: Int
    let minimumCheckoutDistanceMeters: Int
    let nearestWorkplaceDistanceMeters: Double?
}

struct LocationOptions {                               // fonte: /check/locations
    let items: [String]
    let accuracyThresholdMeters: Int
    let mixedZoneIntervalMinutes: Int
}

struct GeofenceCircle {                                // só para armar região nativa
    let id: Int
    let local: String
    let centerLat: Double
    let centerLng: Double
    let radiusMeters: Double
}
```

> **Fidelidade — literais byte-exact (UTF-8 com acentos/cedilha):** as três constantes de domínio abaixo e os nomes de zona são **carregados** (comparados após `normalizeLocationName`). Qualquer divergência de acento quebra a matriz.

```swift
let AUTOMATIC_CHECKOUT_LOCATION            = "Fora do Local de Trabalho"
let AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION = "Localização não Cadastrada"   // ç, ã, "não"
let MIXED_ZONE_LOCATION                    = "Zona Mista"
```

## 3. Funções puras de decisão (port de `AutoActivities.kt`)

Portar **1:1, preservando os nomes** (facilita auditoria lado a lado). Todas são funções livres, sem estado.

### 3.1 Normalização e leitura de estado

```swift
// trim → colapsa espaços internos → minúsculas. lowercased() SEM locale (não usar locale turco etc.).
func normalizeLocationName(_ value: String?) -> String {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return collapsed.lowercased()
}

func isCheckoutZoneLocationName(_ v: String?) -> Bool { normalizeLocationName(v) == "zona de checkout" }
func isMixedZoneLocationName(_ v: String?)   -> Bool { normalizeLocationName(v) == "zona mista" }

// Precedência: ambos nil → currentAction; só checkin → CHECKIN; só checkout → CHECKOUT;
// ambos → o mais novo vence; empate exato → currentAction; state nil → nil.
func resolveLastRecordedAction(_ state: HistoryState?) -> CheckAction? {
    let inAt = state?.lastCheckinAt, outAt = state?.lastCheckoutAt
    if inAt == nil && outAt == nil { return state?.currentAction }
    if inAt != nil && outAt == nil { return .checkIn }
    if inAt == nil && outAt != nil { return .checkOut }
    let i = inAt!, o = outAt!
    if i > o { return .checkIn }
    if o > i { return .checkOut }
    return state?.currentAction        // empate exato
}

func resolveRecordedCheckInLocation(_ s: HistoryState?) -> String? {
    s?.currentAction == .checkIn ? s?.currentLocal : nil
}
func resolveCurrentRecordedLocation(_ s: HistoryState?) -> String? { s?.currentLocal }

func resolveRecordedActionTimestamp(_ s: HistoryState?, _ a: CheckAction?) -> Date? {
    switch a {
    case .checkIn: return s?.lastCheckinAt
    case .checkOut: return s?.lastCheckoutAt
    case nil: return nil
    }
}
```

### 3.2 Cooldown da Zona Mista (DUAS variantes — não conflar)

```swift
struct MixedZoneActivity { let action: CheckAction; let local: String; let timestamp: Date }

func resolveLastRelevantMixedZoneActivity(_ state: HistoryState?) -> MixedZoneActivity? {
    let cur = resolveCurrentRecordedLocation(state)
    guard isMixedZoneLocationName(cur) else { return nil }         // exige currentLocal == Zona Mista
    guard let last = resolveLastRecordedAction(state),
          last == .checkIn || last == .checkOut,
          let ts = resolveRecordedActionTimestamp(state, last) else { return nil }
    return MixedZoneActivity(action: last, local: cur!, timestamp: ts)
}
func isLastRelevantActivityInMixedZone(_ s: HistoryState?) -> Bool { resolveLastRelevantMixedZoneActivity(s) != nil }

func resolveMixedZoneCooldownMilliseconds(_ minutes: Int) -> Int64 { minutes < 1 ? 0 : Int64(minutes) * 60 * 1000 }

func epochMillis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

// Variante A: exige que currentLocal JÁ seja "Zona Mista".
func isMixedZoneCooldownActive(_ state: HistoryState?, _ minutes: Int, _ referenceTime: Date? = nil) -> Bool {
    guard let last = resolveLastRelevantMixedZoneActivity(state) else { return false }
    let cd = resolveMixedZoneCooldownMilliseconds(minutes)
    if cd <= 0 { return false }
    let ref = referenceTime ?? Date()                              // fallback = agora (ambiente)
    return epochMillis(ref) - epochMillis(last.timestamp) < cd
}

// Variante B (temp006): última atividade em QUALQUER localização — guarda de drift de GPS no Branch B.
func isMixedZoneCooldownActiveForLastActivity(_ state: HistoryState?, _ minutes: Int, _ referenceTime: Date? = nil) -> Bool {
    guard let last = resolveLastRecordedAction(state), last == .checkIn || last == .checkOut,
          let ts = resolveRecordedActionTimestamp(state, last) else { return false }
    let cd = resolveMixedZoneCooldownMilliseconds(minutes)
    if cd <= 0 { return false }
    let ref = referenceTime ?? Date()
    return epochMillis(ref) - epochMillis(ts) < cd
}

struct MixedZoneDecisionSettings {
    let mixedZoneIntervalMinutes: Int
    let referenceTime: Date?
    init(mixedZoneIntervalMinutes: Int, referenceTime: Date? = nil) {
        self.mixedZoneIntervalMinutes = mixedZoneIntervalMinutes
        self.referenceTime = referenceTime
    }
}
```

### 3.3 Gates de evento e ação

```swift
func shouldAttemptAutomaticMixedZoneLocationEvent(_ match: LocationMatch?, _ remoteState: HistoryState?, _ settings: MixedZoneDecisionSettings) -> Bool {
    let resolved = match?.resolvedLocal
    guard isMixedZoneLocationName(resolved) else { return false }
    let lastAction = resolveLastRecordedAction(remoteState)
    let currentLoc = resolveCurrentRecordedLocation(remoteState)
    let lastCheckInLoc = resolveRecordedCheckInLocation(remoteState)
    let cd = resolveMixedZoneCooldownMilliseconds(settings.mixedZoneIntervalMinutes)

    // Branch A: estado já registrado na própria Zona Mista.
    if !normalizeLocationName(resolved).isEmpty,
       normalizeLocationName(resolved) == normalizeLocationName(currentLoc) {
        if !isLastRelevantActivityInMixedZone(remoteState) || cd <= 0 { return false }
        return !isMixedZoneCooldownActive(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime)
    }
    // Branch B: estado registrado em OUTRA localização — guarda de drift (temp006).
    if isMixedZoneCooldownActiveForLastActivity(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime) { return false }
    if lastAction != .checkIn { return true }
    return normalizeLocationName(resolved) != normalizeLocationName(lastCheckInLoc)
}

// Situações 1-4, 6-8 (localização MATCHED).
func shouldAttemptAutomaticLocationEvent(_ match: LocationMatch?, _ remoteState: HistoryState?, _ settings: MixedZoneDecisionSettings) -> Bool {
    let resolved = match?.resolvedLocal
    let lastAction = resolveLastRecordedAction(remoteState)
    if isCheckoutZoneLocationName(resolved) { return lastAction == .checkIn }
    if isMixedZoneLocationName(resolved)    { return shouldAttemptAutomaticMixedZoneLocationEvent(match, remoteState, settings) }
    if lastAction != .checkIn { return true }
    // Change A / P6.1: re-check-in numa área só dispara se o local mudou.
    let lastCheckInLoc = resolveRecordedCheckInLocation(remoteState)
    return !normalizeLocationName(resolved).isEmpty &&
           normalizeLocationName(resolved) != normalizeLocationName(lastCheckInLoc)
}

// Situação 1 (far) + 2: checkout quando OUTSIDE_WORKPLACE e último foi check-in.
func shouldAttemptAutomaticOutOfRangeCheckout(_ match: LocationMatch?, _ remoteState: HistoryState?) -> Bool {
    guard let m = match, m.status == .outsideWorkplace else { return false }
    return resolveLastRecordedAction(remoteState) == .checkIn
}

// Situação 5 (perto mas fora): nunca é alvo válido de check-in automático.
func shouldAttemptAutomaticNearbyWorkplaceCheckIn(_ match: LocationMatch?, _ remoteState: HistoryState?) -> Bool { false }

func resolveAutomaticLocationAction(_ match: LocationMatch?, _ remoteState: HistoryState?) -> CheckAction {
    let resolved = match?.resolvedLocal
    if isMixedZoneLocationName(resolved) {
        return resolveLastRecordedAction(remoteState) == .checkIn ? .checkOut : .checkIn
    }
    return isCheckoutZoneLocationName(resolved) ? .checkOut : .checkIn
}
```

### 3.4 A função-mestre (única fonte de verdade)

```swift
struct AutomaticActivity: Equatable { let action: CheckAction; let local: String? }

// Ordem de despacho por status: OUTSIDE_WORKPLACE → MATCHED → NOT_IN_KNOWN_LOCATION → else nil.
// SEM caso especial de primeiro registro (histórico vazio segue o fluxo normal).
func resolveAutomaticActivityForMatch(_ match: LocationMatch, _ currentState: HistoryState?, _ mixedZoneIntervalMinutes: Int) -> AutomaticActivity? {
    let settings = MixedZoneDecisionSettings(mixedZoneIntervalMinutes: mixedZoneIntervalMinutes)

    if match.status == .outsideWorkplace {
        return shouldAttemptAutomaticOutOfRangeCheckout(match, currentState)
            ? AutomaticActivity(action: .checkOut, local: AUTOMATIC_CHECKOUT_LOCATION)
            : nil
    }
    if match.status == .matched {
        guard shouldAttemptAutomaticLocationEvent(match, currentState, settings) else { return nil }
        return AutomaticActivity(action: resolveAutomaticLocationAction(match, currentState), local: match.resolvedLocal)
    }
    if match.status == .notInKnownLocation {
        // Change A continuation / P6.2: só como MUDANÇA, e só para usuário em check-in.
        let lastCheckInLoc = resolveRecordedCheckInLocation(currentState)
        if resolveLastRecordedAction(currentState) == .checkIn,
           normalizeLocationName(lastCheckInLoc) != normalizeLocationName(AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION) {
            return AutomaticActivity(action: .checkIn, local: AUTOMATIC_UNREGISTERED_CHECKIN_LOCATION)
        }
        return nil
    }
    return nil   // ACCURACY_TOO_LOW / NO_KNOWN_LOCATIONS
}
```

> **Blocker de backend (obrigatório):** o ramo `NOT_IN_KNOWN_LOCATION → "Localização não Cadastrada"` só funciona porque o backend concede relaxamento ao header `X-Client`. O web/qualquer outro cliente recebe **HTTP 422**. O iOS precisa de `X-Client: checking-ios` homologado com o mesmo tratamento do `checking-android` — senão este ramo quebra em produção (ver `conversion_plan.md` §8.1, `decision_log.md`).

## 4. Matriz canônica de decisão

| Caso | status | última ação | condição | resultado |
|------|--------|-------------|----------|-----------|
| S1a | MATCHED "Zona de CheckOut" | CHECKIN | — | **CHECKOUT** @ "Zona de CheckOut" |
| S1b | OUTSIDE_WORKPLACE | CHECKIN | — | **CHECKOUT** @ "Fora do Local de Trabalho" (resolvido pelo motor) |
| S2a/b | "Zona de CheckOut" ou OUTSIDE_WORKPLACE | CHECKOUT | — | **nil** (nunca 2 check-outs seguidos) |
| S3 | MATCHED (área) | CHECKOUT | — | **CHECKIN** @ resolvedLocal |
| S3n / S7B | NOT_IN_KNOWN_LOCATION | CHECKOUT | — | **nil** (checked-out nunca entra em não-cadastrada) |
| S4a | MATCHED (área) | CHECKIN | resolvedLocal == último local | **nil** (P6.1, suprime re-check-in mesmo local) |
| S4b | MATCHED (área) | CHECKIN | resolvedLocal ≠ último local | **CHECKIN** @ resolvedLocal |
| S5a | NOT_IN_KNOWN_LOCATION | CHECKIN | último ≠ "Localização não Cadastrada" | **CHECKIN** @ "Localização não Cadastrada" (P6.2) |
| S5b | NOT_IN_KNOWN_LOCATION | CHECKIN | já em "Localização não Cadastrada" | **nil** |
| S8 toggle | MATCHED "Zona Mista" | CHECKIN/CHECKOUT | cooldown expirado (elapsed ≥ intervalo) | **toggle** (CHECKIN↔CHECKOUT) @ "Zona Mista" |
| S8 cooldown | MATCHED "Zona Mista" | — | dentro do cooldown | **nil** |
| S8d | OUTSIDE_WORKPLACE / outra área | CHECKIN em Zona Mista | movimento genuíno | **dispara imediato** (cooldown só filtra reads que resolvem para a própria Zona Mista) |
| — | ACCURACY_TOO_LOW / NO_KNOWN_LOCATIONS | qualquer | — | **nil** |
| no-history | MATCHED área | nil | — | **CHECKIN**; far/CheckOut/near → **nil** |

## 5. Pausa programada (port de `ScheduledPause.kt`)

Função pura sobre data/hora **local do aparelho**. `ZonedDateTime` → `Date` + `Calendar`/`TimeZone` injetáveis. `DayOfWeek` → `Calendar.component(.weekday)`.

```swift
struct ScheduledPauseSettings {
    let scheduledPauseEnabled: Bool
    let scheduledPauseFrom: String   // "HH:mm" local
    let scheduledPauseTo: String     // "HH:mm" local
    let suspendSaturdays: Bool
    let suspendSundays: Bool
}

private func parseMinutesOfDay(_ hhmm: String) -> Int {
    let parts = hhmm.split(separator: ":")
    return Int(parts[0])! * 60 + Int(parts[1])!
}

// Ordem: (1) fim de semana (dia inteiro, INDEPENDENTE de scheduledPauseEnabled) → (2) janela.
func isScheduledPauseActiveNow(_ now: Date, _ calendar: Calendar, _ s: ScheduledPauseSettings) -> Bool {
    let weekday = calendar.component(.weekday, from: now)   // 1=domingo ... 7=sábado (Gregorian)
    if s.suspendSaturdays && weekday == 7 { return true }
    if s.suspendSundays   && weekday == 1 { return true }
    if s.scheduledPauseEnabled {
        let f = parseMinutesOfDay(s.scheduledPauseFrom)
        let t = parseMinutesOfDay(s.scheduledPauseTo)
        if f != t {                                        // f==t ⇒ janela DESABILITADA
            let n = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
            return f < t ? (n >= f && n < t)               // mesmo dia: início inclusivo, fim exclusivo
                         : (n >= f || n < t)               // wrap de meia-noite
        }
    }
    return false
}
```

- `nextResumeInstant(now)`: nil se não está pausado; senão enumera candidatos = (fins de janela `t` nos próximos **0..7** dias) + (00:00 dos próximos **1..7** dias), ordena por instante, retorna o primeiro que **não** está pausado. Trata sobreposição janela+fim-de-semana.
- `nextPauseStartInstant(now)`: nil se já pausado; enumera candidatos = (inícios `f` nos próximos **0..8** dias) + (00:00 de sábados/domingos suspensos nos próximos **0..8** dias), retorna o primeiro que **está** pausado.

> **Fronteira iOS:** essas duas funções alimentam **alarmes exatos** no Android (`setExactAndAllowWhileIdle`). O iOS **não** executa código em horário exato — a retomada/entrada de pausa vira `BGTaskScheduler` + `UNUserNotificationCenter` best-effort (ver `conversion_plan.md` §13). A **lógica de enumeração** é portada; a **garantia de execução no instante** não existe.

**Defaults de produção** (de `PersistedSettings.kt`, **não** dos testes): `enabled=true`, `from="20:00"`, `to="07:00"`, `suspendSaturdays=true`, `suspendSundays=true`.

## 6. Casos de uso (`RunAutomaticActivitiesUseCase` + `CaptureLocationUseCase`)

Ficam na borda do domínio; dependem de protocolos injetáveis. Port do fluxo exato:

```
invoke(chave, userProjects, currentState, mixedZoneIntervalMinutes, accuracyThresholdMeters):
  1. projeto = userProjects.activeProject (não-vazio) — senão log SYSTEM/WARNING "No active project — skipped." e retorna .notConfigured  (ANTES de qualquer GPS)
  2. capture = CaptureLocationUseCase(accuracyThresholdMeters)
       .matched(match) → segue
       .networkError(reading?) → se reading != nil: offlineQueue.enqueue(.raw(...clientEventId=novo UUID, capturedAtEpochMs=clock.now())); log LOCATION/WARNING; retorna .networkError
       (.timeout / .noPermission) → retorna .noAction
  3. activity = resolveAutomaticActivityForMatch(match, currentState, mixedZoneIntervalMinutes) — se nil → .noAction
  4. clientEventId = novo UUID; eventTime = clock.now()          // gerados ANTES do submit (exactly-once)
  5. checkRepository.submit(chave, projeto, action, local, .normal, eventTime, clientEventId):
       .success(newState) → log check-in/out SUCCESS (actor=SYS); retorna .submitted(action, local, newState)
       .failure(.network) → offlineQueue.enqueue(.decided(action, local, capturedAtEpochMs=eventTime, clientEventId=MESMO, informe="normal")); log SYNC/WARNING "queued (offline)"; retorna .networkError
       .failure(outro)    → log check-in/out FAILURE (actor=SYS); retorna .networkError
```

`CaptureLocationUseCase`: `locationProvider.capture(threshold)` → `.success(lat,lon,acc)` → `checkRepository.matchLocation(lat,lon,acc)` → `.success(match)` (log LOCATION `INFO` "Location fixed (±Xm) → …" ou `WARNING` "Location accuracy too low (±Xm).") → `.matched(match)`; `.failure` → `.networkError(reading: erro==.network ? LocationReading(...) : nil)`; `.timeout`/`.unavailable` mapeados.

**Protocolos a definir (Swift):**
```swift
protocol Clock { func now() -> Date }
protocol CheckRepository {
    func matchLocation(_ lat: Double, _ lon: Double, _ accuracyMeters: Double?) async -> AppResult<LocationMatch>
    func submit(chave: String, projeto: String, action: CheckAction, local: String?, informe: InformeType, eventTime: Date, clientEventId: String) async -> AppResult<HistoryState>
    // + getState / getHistory / getLocations / getGeofences (outras specs)
}
protocol LocationProvider { func capture(_ accuracyThresholdMeters: Int) async -> LocationCapture }   // .success/.timeout/.unavailable — camada de plataforma
protocol OfflineCheckQueue { func enqueue(_ event: PendingCheckEvent) async }
protocol ActivityLogger { /* logCheckIn/logCheckOut/logLocation/logQueuedOffline/logSystem — swallow-all */ }
enum AutoActivitiesResult { case submitted(CheckAction, String?, HistoryState), noAction, networkError, notConfigured }
```

### Invariantes obrigatórias (asseguradas por teste)

1. **Exactly-once:** `clientEventId`+`eventTime` gerados **uma vez** antes do submit e reusados no `.decided` em falha de rede (dedup no servidor por `client_event_id`). O `.raw` usa UUID novo + `clock.now()`.
2. **Enqueue só em `.network`:** falha HTTP/não-rede **nunca** enfileira (nem no match, nem no submit).
3. **Golden rule 2:** uma falha de log/persistência **nunca** altera o resultado (check-in ainda retorna `.submitted`, captura ainda retorna `.matched`; 0 linhas gravadas). O `ActivityLogger` engole todos os erros (duplo `runCatching` → no Swift, `try?` aninhado + escrita off-main que nunca propaga).
4. **Sem projeto ativo** curto-circuita **antes** de qualquer GPS → `.notConfigured`.
5. **Falha de submit não avança o estado** → um retry re-decide (não perde o evento).

## 7. Relógio e regimes de tempo (subtileza crítica)

Há **dois** regimes — não os unifique:

| Caminho | referência de tempo do cooldown | porte Swift |
|---------|--------------------------------|-------------|
| Motor puro `resolveAutomaticActivityForMatch(...)` | `Instant.now()` **ambiente** (o `referenceTime` interno é `nil` → cai em `now()`) | o motor lê `Date()`. Testes montam `lastCheckinAt = Date().addingTimeInterval(-20*60)` etc. |
| `shouldAttemptAutomaticMixedZoneLocationEvent(..., settings)` | `referenceTime` **injetado** em `MixedZoneDecisionSettings` | passar `referenceTime` explícito |
| `RunAutomaticActivitiesUseCase` (`eventTime`, `capturedAtEpochMs`) | `Clock` **injetado** | injetar `Clock` fixo |

⚠️ **Não conecte o cooldown da Zona Mista ao `Clock` injetado.** No e2e (`AutoActivitiesSituationTest.s8_*`) o `Clock` retorna `2026-06-16T12:00:00Z`, mas o cooldown usa `Instant.now()` — por isso esses testes montam `lastCheckinAt = Instant.now().minusSeconds(...)`, não o instante fixo.

## 8. Fixtures de teste a portar

Construtores que os testes usam (replicar como helpers Swift):

- `match(status, resolvedLocal=nil, nearest=nil)` → `LocationMatch(matched: status == .matched, resolvedLocal, label: resolvedLocal ?? "", status, message: "", accuracyMeters: 10.0, accuracyThresholdMeters: 50, minimumCheckoutDistanceMeters: 2000, nearestWorkplaceDistanceMeters: nearest)`. (Variante `AutoActivitiesTest`: `accuracyMeters:15.0, threshold:30, minCheckout:500`.)
- `history(last:)` / `checkedIn(local[,at])` / `checkedOut(local[,at])` / `firstRegistrationState()` → `HistoryState` com `found:true`, `projeto:"P80"`, `hasCurrentDayCheckin = last == .checkIn`, `lastCheckinAt/lastCheckoutAt` default `Date()` quando a ação bate (esse fallback é **load-bearing** nos testes s8 "within interval").
- `apply(prev, activity)` → modela o servidor gravando a atividade decidida (nil ⇒ inalterado; CHECKIN ⇒ `currentAction=.checkIn, currentLocal=activity.local, novo lastCheckinAt`; CHECKOUT ⇒ idem checkout). Testes de sequência encadeiam estado via `apply` entre `decide()`.
- `CapturingDao(throwOnInsert:)` — fake in-memory: `insert` lança `RuntimeException("boom")` se `throwOnInsert`, senão anexa e retorna `rows.count`. Port como fake com flag.
- **Clock fixo** injetado: `RunAutomaticActivities*` usam `2026-06-16T12:00:00Z`; `CaptureLocationLoggingTest` usa `2026-06-20T08:00:00Z`. O epoch exato **não** é asserido — só igualdade de campos.
- **Logging síncrono nos testes:** o Kotlin usa `UnconfinedTestDispatcher` para o log fire-and-forget virar síncrono. No Swift, injetar um escopo síncrono/inline (ou `await` na task) para a asserção enxergar a linha.

## 9. Mapa de testes Kotlin → Swift XCTest

**135 testes** (contagem por arquivo). Organizar em alvos Swift espelhando os arquivos Kotlin. Cada linha do §4 e das tabelas abaixo é um `func test…()`.

| Arquivo Kotlin | Alvo Swift sugerido | # | Camada |
|----------------|---------------------|---|--------|
| `checkrules/SituationMatrixTest.kt` | `DecisionMatrixTests` | 18 | motor puro |
| `checkrules/AutoActivitiesSituationTest.kt` | `AutoActivitiesUseCaseTests` | 24 | caso de uso (mock capture+repo) |
| `domain/checkrules/AutoActivitiesTest.kt` | `AutoActivitiesHelpersTests` | ~30 | funções puras (helpers) |
| `checkrules/LocationChangeContinuationTest.kt` | `LocationChangeContinuationTests` | 6 | motor puro (sequência) |
| `checkrules/CheckoutPreservationTest.kt` | `CheckoutPreservationTests` | 9 | motor puro (sequência) |
| `domain/checkrules/ScheduledPauseTest.kt` | `ScheduledPauseTests` | 32 | pausa pura |
| `domain/usecase/DuplicateEliminationTest.kt` | `DuplicateEliminationTests` | 4 | caso de uso (conta submits) |
| `domain/usecase/RunAutomaticActivitiesLoggingTest.kt` | `AutoActivitiesLoggingTests` | 6 | caso de uso (log rows) |
| `domain/usecase/RunAutomaticActivitiesOfflineTest.kt` | `AutoActivitiesOfflineTests` | 4 | caso de uso (enqueue) |
| `domain/usecase/CaptureLocationLoggingTest.kt` | `CaptureLocationLoggingTests` | 3 | caso de uso (log rows) |

### 9.1 `DecisionMatrixTests` (motor puro, `resolveAutomaticActivityForMatch`)

| test | given (status · última ação · locais) | → then |
|------|----------------------------------------|--------|
| 1a | MATCHED "Zona de CheckOut" · CHECKIN | CHECKOUT @ "Zona de CheckOut" |
| 1b | OUTSIDE_WORKPLACE · CHECKIN | CHECKOUT @ "Fora do Local de Trabalho" |
| 2a | MATCHED "Zona de CheckOut" · CHECKOUT | nil |
| 2b | OUTSIDE_WORKPLACE · CHECKOUT | nil |
| 3a | MATCHED "P80-Portaria" · CHECKOUT | CHECKIN @ "P80-Portaria" |
| 3b | NOT_IN_KNOWN_LOCATION · CHECKOUT | nil |
| 4a | MATCHED "P80-Portaria" · CHECKIN · current="P80-Portaria" | nil |
| 4b | MATCHED "P80-Refeitorio" · CHECKIN · current="P80-Portaria" | CHECKIN @ "P80-Refeitorio" |
| 5a | NOT_IN_KNOWN_LOCATION · CHECKIN · current="P80-Portaria" | CHECKIN @ "Localização não Cadastrada" |
| 5b | NOT_IN_KNOWN_LOCATION · CHECKIN · current="Localização não Cadastrada" | nil |
| 6a | MATCHED "P80-Portaria" · CHECKIN · current="P80-Portaria" | nil |
| 6b | MATCHED "P80-Refeitorio" · CHECKIN · current="P80-Portaria" | CHECKIN @ "P80-Refeitorio" |
| 7A | MATCHED "P80-Portaria" · CHECKOUT | CHECKIN @ "P80-Portaria" |
| 7B | NOT_IN_KNOWN_LOCATION · CHECKOUT | nil |
| 8a | MATCHED "Zona Mista" · CHECKIN · current="Zona Mista" · lastCheckin −20min | CHECKOUT @ "Zona Mista" |
| 8b | MATCHED "Zona Mista" · CHECKOUT · current="Zona Mista" · lastCheckout −20min | CHECKIN @ "Zona Mista" |
| 8c | MATCHED "Zona Mista" · CHECKIN · current="Zona Mista" · lastCheckin −5min | nil (dentro do cooldown) |
| 8d | OUTSIDE_WORKPLACE · CHECKIN · current="Zona Mista" | CHECKOUT @ "Fora do Local de Trabalho" |

`AutoActivitiesUseCaseTests` (24, `AutoActivitiesSituationTest`) espelha a mesma matriz **no nível do caso de uso** (locais "Unidade P80"/"Unidade P81"), asserindo `AutoActivitiesResult` + `submit` chamado 0/1 vez, mais 4 casos `no_history_*` (MATCHED→CHECKIN; far/CheckOut/near→NoAction), 4 puros `s8_mixed_zone_*` de `shouldAttemptAutomaticMixedZoneLocationEvent` com `referenceTime` injetado (5min→false, 20min→true), e `s8_drift_cooldown_does_not_block_other_locations`.

### 9.2 `AutoActivitiesHelpersTests` (`AutoActivitiesTest`)

Cobrem os helpers isolados: `resolveLastRecordedAction` (5 casos de precedência incl. `nullState→nil`), `shouldAttemptAutomaticOutOfRangeCheckout` (checkedIn→true; checkedOut/firstReg/matched/nullMatch→false), `shouldAttemptAutomaticLocationEvent` (checkoutZone×checkin/checkout; regular×checkedOut/firstReg/checkedIn-diferente; nullMatch×checkedIn→false/checkedOut→true), `resolveAutomaticLocationAction` (checkoutZone→CHECKOUT; regular→CHECKIN; mixed×checkin→CHECKOUT/checkout→CHECKIN), `isMixedZoneCooldownActive` (dentro/fora com `referenceTime` = checkin+20min/+40min, interval=30; notInMixedZone→false; zeroCooldown→false), `normalizeLocationName` ("  Zona  Mista  "→"zona mista"; nil→""), `isCheckoutZoneLocationName`/`isMixedZoneLocationName` (case-insensitive). ⚠️ nota: usa `"Zona de Checkout"` (grafia alternativa) — normaliza igual.

### 9.3 Sequências (`LocationChangeContinuationTests` 6 + `CheckoutPreservationTests` 9)

Threading de estado via `apply` entre decisões:
- **repeated_identical_matched_reads_check_in_only_once**: move→CHECKIN, depois 2 reads iguais → nil, nil.
- **only_the_move_to_a_new_area_checks_in**: mesma área→nil; nova área→CHECKIN.
- **not_in_known_location_continuation_cycle**: NOT_IN_KNOWN→CHECKIN "Localização não Cadastrada"; repetição→nil; volta a área MATCHED→CHECKIN.
- **checkout_then_not_in_known_location_no_action**, **accuracy_too_low_is_always_null**, **no_known_locations_is_always_null** (ambos ×checkedIn/checkedOut → nil).
- **never_two_consecutive_checkouts**: OUTSIDE→CHECKOUT; OUTSIDE de novo→nil; "Zona de CheckOut"→nil.
- **after_checkout_next_action_is_checkin_then_checkout_cycle**: CHECKOUT→…→CHECKIN→CHECKOUT.
- **mixed_zone_checkin_toggles_to_checkout** (−20min→CHECKOUT), **mixed_zone_checkin_then_far_immediate_checkout** (S8d), + os 5 de preservação de check-out do §4.

### 9.4 `ScheduledPauseTests` (32)

Booleanos de `isScheduledPauseActiveNow` (fixar UTC): mesmo-dia 09:00–17:00 (08:59→false, 09:00→true, 12:30→true, 16:59→true, **17:00→false**, 20:00→false); wrap 22:00–06:00 (21:59→false, 22:00→true, 23:59→true, 00:00→true, 05:59→true, **06:00→false**); `from==to`→sempre false; suspendSat (sáb→true 00:00/12:00/23:59, dom→false), suspendSun, ambos, e "suspendSat + enabled=false"→sáb true. `nextResumeInstant`: não-pausado→nil; mesmo-dia→hoje 17:00; wrap noite→amanhã 06:00, wrap manhã→hoje 06:00; sáb suspenso→dom 00:00; ambos→seg 00:00; sáb+wrap→dom 06:00; ambos+wrap→seg 06:00. **Datas âncora load-bearing:** 2024-01-13 sáb, -14 dom, -15 seg, -16 ter — o Swift precisa cair nos mesmos dias-da-semana (UTC).

### 9.5 Casos de uso (`DuplicateElimination` 4, `Logging` 6, `Offline` 4, `CaptureLogging` 3)

- **DuplicateElimination**: move A→B submete **1×**; 5 reads parados→0 submits; moves distintos→1 submit por local (echo do 4º arg = local); submit falho não avança estado (retry re-decide).
- **Logging**: sucesso→row `CHECK_IN`/`SUCCESS`/`SYS` desc "Check-in at Unidade P80."; falha rede→`SYNC`/`WARNING` contém "queued (offline)"; falha HTTP 500→`CHECK_IN`/`FAILURE` "Check-in failed at Unidade P80."; sem projeto→`SYSTEM`/`WARNING` "No active project — skipped." (em dash U+2014); rede na captura→`LOCATION`/`WARNING` "Location reading queued offline — will sync on reconnect." + enqueue Raw; **loggingFailure_neverChanges** → `.submitted` + 0 rows.
- **Offline**: match `.network` com fix → `.raw`(lat=1.5,lon=103.8,projeto="P80"); match HTTP → 0 enqueue; submit `.network` → `.decided`(action="checkin",local="Unidade P80",informe="normal"); submit HTTP → 0 enqueue.
- **CaptureLogging**: fix ok→`LOCATION`/`INFO` "Location fixed (±12m) → Unidade P80." (12.7→12, **truncado** por `Int()`, não arredondado; ± U+00B1, → U+2192); accuracy baixa→`WARNING` "Location accuracy too low (±80m)." (80.4→80); loggingFailure→`.matched`+0 rows.

## 10. Checklist de fidelidade (antes de dar por pronto)

- [ ] Literais byte-exact: `"Fora do Local de Trabalho"`, `"Localização não Cadastrada"` (ç, ã, "não"), `"Zona Mista"`, `"Zona de CheckOut"`/`"Zona de Checkout"`.
- [ ] `normalizeLocationName`: trim + colapso `\s+` + `lowercased()` **sem locale**.
- [ ] **Duas** variantes de cooldown da Zona Mista, com precondições distintas (currentLocal==Zona Mista vs. qualquer local).
- [ ] Ordem de despacho: OUTSIDE_WORKPLACE → MATCHED → NOT_IN_KNOWN_LOCATION → nil. **Sem** caso especial de primeiro registro.
- [ ] `resolveLastRecordedAction`: empate exato de timestamps → `currentAction`.
- [ ] Exactly-once: `clientEventId`+`eventTime` antes do submit; reuso no `.decided`.
- [ ] Enqueue só em `.network`; HTTP/outros nunca enfileiram.
- [ ] Golden rule: falha de log nunca altera o resultado.
- [ ] Dois regimes de tempo: cooldown lê `Date()` ambiente; `shouldAttempt*` recebe `referenceTime`; use case injeta `Clock`.
- [ ] Backend homologou `X-Client: checking-ios` (senão P6.2 quebra com 422).
- [ ] 135 testes portados e verdes (ou divergência aprovada no `decision_log.md`).

## 11. Constantes deste subsistema

`DEFAULT_ACCURACY_THRESHOLD_METERS = 30` (produção; testes usam 30 ou 50) · cooldown Zona Mista = `intervalMinutes × 60 × 1000` ms (0 se `< 1`) · `MIXED_INTERVAL` de teste = 15 · defaults de pausa produção = `enabled/20:00/07:00/Sat/Sun`. Fora do domínio (plataforma): filtro `max(50m, 2×precisão)` (só TIMER), captura `15s` melhor-fix-no-timeout, caches `45s/15min/1h`.
