# Spec de porte — Fila offline + Replay (P8)

> Especificação executável para portar a resiliência offline do Android (Kotlin) para iOS (Swift), com fidelidade 1:1.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta + auditoria (2026-07-14).
> **Par da spec do motor de decisão** — o replayer reusa `resolveAutomaticActivityForMatch` (ver [port_spec_decision_engine.md](port_spec_decision_engine.md)).
> Escopo: modelo de eventos (`PendingCheckEvent`, domínio), a fila (`OfflineCheckQueue`), o replayer (`PendingCheckReplayer`) e a fronteira de persistência/agendamento.

Arquivos-fonte Kotlin:
- [PendingCheckEvent.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/offline/PendingCheckEvent.kt) (domínio, serializável)
- [OfflineCheckQueue.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/offline/OfflineCheckQueue.kt) · [OfflineQueueStore.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/offline/OfflineQueueStore.kt) · [EncryptedOfflineQueueStore.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/offline/EncryptedOfflineQueueStore.kt)
- [PendingCheckReplayer.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/offline/PendingCheckReplayer.kt) · [SyncPendingChecksWorker.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/offline/SyncPendingChecksWorker.kt)

---

## 1. Arquitetura e fronteira Domain ↔ Platform

| Peça | Camada | Portabilidade |
|------|--------|---------------|
| `PendingCheckEvent` (Raw/Decided) | **Domain** | 1:1, `Codable` |
| `OfflineCheckQueue` (cap/dedup/ordem/tolerância) | lógica pura sobre um **store protocolar** | 1:1 sobre protocolo síncrono |
| `PendingCheckReplayer` (drain/decide/taxonomia/24h) | lógica pura sobre **repository protocolar** | 1:1; reusa o motor de decisão |
| `OfflineQueueStore` cifrado | **Platform** | reescrever: `EncryptedSharedPreferences` → **Keychain + CryptoKit** |
| `SyncPendingChecksWorker` (WorkManager) | **Platform** | reescrever: → **BGTaskScheduler + NWPathMonitor** |

O núcleo (evento + fila + replayer) é testável em JVM puro no Android; no iOS deve ficar igualmente testável sobre fakes. Só o *store* e o *scheduler* são específicos de plataforma.

## 2. Modelo de eventos (port de `PendingCheckEvent.kt`)

Sealed class → enum Swift com valores associados. Discriminador polimórfico do kotlinx (`@SerialName`) = chave `"type"` com valores `"raw"`/`"decided"`, **achatado** no mesmo nível dos campos.

```swift
import Foundation

enum PendingCheckEvent: Codable, Equatable {
    case raw(Raw)
    case decided(Decided)

    struct Raw: Codable, Equatable {
        let chave: String
        let projeto: String
        let capturedAtEpochMs: Int64
        let clientEventId: String
        let latitude: Double
        let longitude: Double
        let accuracyMeters: Double?      // nullable
    }
    struct Decided: Codable, Equatable {
        let chave: String
        let projeto: String
        let capturedAtEpochMs: Int64
        let clientEventId: String
        let action: String               // "checkin" | "checkout"
        let local: String?               // nullable
        let informe: String              // "normal" | "retroativo"
    }

    // campos comuns (abstract no Kotlin)
    var chave: String { switch self { case .raw(let r): return r.chave; case .decided(let d): return d.chave } }
    var projeto: String { switch self { case .raw(let r): return r.projeto; case .decided(let d): return d.projeto } }
    var capturedAtEpochMs: Int64 { switch self { case .raw(let r): return r.capturedAtEpochMs; case .decided(let d): return d.capturedAtEpochMs } }
    var clientEventId: String { switch self { case .raw(let r): return r.clientEventId; case .decided(let d): return d.clientEventId } }
}

// Discriminador achatado {"type":"raw"/"decided", ...campos...} — espelha o formato kotlinx.
extension PendingCheckEvent {
    private enum TypeKey: String, CodingKey { case type }
    init(from decoder: Decoder) throws {
        let t = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch t {
        case "raw":     self = .raw(try Raw(from: decoder))
        case "decided": self = .decided(try Decided(from: decoder))
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown type \(t)"))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        switch self {
        case .raw(let r):     try c.encode("raw", forKey: .type);     try r.encode(to: encoder)
        case .decided(let d): try c.encode("decided", forKey: .type); try d.encode(to: encoder)
        }
    }
}
```

> **Nota:** o iOS parte de um store vazio (sem blob Android para migrar), então o discriminador é um contrato **interno** — só precisa fazer round-trip dentro do app. Mantenha `"type":"raw"/"decided"` mesmo assim (custo zero, ajuda paridade/depuração). **Não** portar a migração legada do DataStore (é história do Android); só implemente migração se um build iOS anterior tiver deixado outro formato.

- `clientEventId` = chave de idempotência. `capturedAtEpochMs` = chave de **ordenação** E de **despejo** no cap. Ambos preservados no round-trip e na re-inserção (adota o valor mais novo).

## 3. A fila (port de `OfflineCheckQueue.kt`)

Serializada por Mutex no Kotlin. No Swift, use um **`actor`** com um **store síncrono** — assim não há ponto de suspensão dentro da seção crítica e a atomicidade read→mutate→write é preservada (ver §3.1).

```swift
protocol OfflineQueueStore {          // SÍNCRONO de propósito (ver §3.1)
    func read() -> String
    func write(_ json: String)
}
protocol SyncScheduler { func scheduleSync() }   // no-op em teste; BGTask em produção

actor OfflineCheckQueue {
    static let maxEvents = 200
    private let store: OfflineQueueStore
    private let scheduler: SyncScheduler
    init(store: OfflineQueueStore, scheduler: SyncScheduler) { self.store = store; self.scheduler = scheduler }

    func enqueue(_ event: PendingCheckEvent) {
        var list = readList()
        list.removeAll { $0.clientEventId == event.clientEventId }   // dedup: REPLACE por id
        list.append(event)
        // cap: mantém os 200 MAIS RECENTES por capturedAtEpochMs; descarta os mais antigos.
        let capped = Array(list.sorted { $0.capturedAtEpochMs < $1.capturedAtEpochMs }.suffix(Self.maxEvents))
        writeList(capped)
        scheduler.scheduleSync()                                     // FORA da seção crítica
    }

    func peekAll() -> [PendingCheckEvent] {                          // sempre em ordem de captura (mais antigo primeiro)
        readList().sorted { $0.capturedAtEpochMs < $1.capturedAtEpochMs }
    }
    func remove(_ clientEventId: String) { writeList(readList().filter { $0.clientEventId != clientEventId }) }
    func size() -> Int { readList().count }                          // contagem crua (não reordena)

    private func readList() -> [PendingCheckEvent] {
        let raw = store.read()
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PendingCheckEvent].self, from: data)) ?? []   // decode falho → vazio (tolerante)
    }
    private func writeList(_ list: [PendingCheckEvent]) {
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list),
              let s = String(data: data, encoding: .utf8) else { store.write(""); return }
        store.write(s)                                              // vazio → "" (contrato de persistência)
    }
}
```

### 3.1 Subtileza de atomicidade (actor vs Mutex)

O Kotlin segura o Mutex por **todo** `read → mutate → write` dentro de `enqueue`. Um `actor` Swift permite **reentrância nos pontos de `await`**: se o store fosse `async`, outro `enqueue` poderia intercalar entre o read e o write e perder um evento. **Por isso o `OfflineQueueStore` é síncrono** — a seção crítica não tem `await`, e o isolamento do actor garante atomicidade equivalente ao Mutex. O I/O real (Keychain) é síncrono, então isso é fiel. **Não** torne `store.read/write` `async`.

## 4. Store cifrado (fronteira de plataforma) — port de `EncryptedOfflineQueueStore.kt`

Android: `EncryptedSharedPreferences` (Keystore, chaves AES256-SIV / valores AES256-GCM), arquivo `checking_offline_queue`, key `pending_checks_json`.

**iOS:** guardar o blob JSON cifrado — **Keychain** (item `kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` para leitura em background pós-primeiro-desbloqueio) **+ CryptoKit AES-GCM** (chave simétrica aleatória guardada no Keychain que cifra o blob), OU um arquivo com Data Protection `.completeUntilFirstUserAuthentication`. Detalhes de ameaça na `conversion_plan.md` §14.2.

> **Ligação com a decisão D6 (`decision_log.md`):** este store **não tem** método `clear()` no Android — é exatamente por isso que o wipe LGPD deixa o GPS preciso para trás. **O port iOS DEVE expor `clear()`** e o fluxo "Apagar dados" deve chamá-lo (passo crash-guarded adicional).

## 5. O replayer (port de `PendingCheckReplayer.kt`)

Lógica pura sobre `CheckRepository` + `ActivityLogger` + a fila. Reusa `resolveAutomaticActivityForMatch`.

```swift
enum DrainResult { case completed, retry }
private enum Outcome { case done, drop, retry }

final class PendingCheckReplayer {
    static let maxPasses = 5
    static let formsRecencyWindowMs: Int64 = 24 * 60 * 60 * 1000   // 24h
    private let queue: OfflineCheckQueue
    private let repo: CheckRepository
    private let logger: ActivityLogger

    func drain() async -> DrainResult {
        var pass = 0
        while pass < Self.maxPasses {
            let pending = await queue.peekAll()                     // snapshot em ordem de captura
            if pending.isEmpty { return .completed }
            let newest = pending.map(\.capturedAtEpochMs).max()!    // âncora da janela 24h (NÃO wall-clock)
            logger.logSyncing(pending.count)
            for event in pending {
                switch await replay(event, newest) {
                case .done, .drop: await queue.remove(event.clientEventId)
                case .retry:       return .retry                    // aborta o drain INTEIRO; reagenda depois
                }
            }
            pass += 1
        }
        return await queue.size() == 0 ? .completed : .retry
    }

    private func replay(_ e: PendingCheckEvent, _ newest: Int64) async -> Outcome {
        switch e {
        case .decided(let d): return await replayDecided(d, newest)
        case .raw(let r):     return await replayRaw(r, newest)
        }
    }

    private func replayDecided(_ e: PendingCheckEvent.Decided, _ newest: Int64) async -> Outcome {
        let action: CheckAction = e.action == "checkout" ? .checkOut : .checkIn
        let informe: InformeType = e.informe == "retroativo" ? .retroativo : .normal
        let outcome = outcomeOf(await repo.submit(
            chave: e.chave, projeto: e.projeto, action: action, local: e.local, informe: informe,
            eventTime: Date(timeIntervalSince1970: Double(e.capturedAtEpochMs) / 1000),
            clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest)))
        logReplayOutcome(outcome, action, e.local)
        return outcome
    }

    private func replayRaw(_ e: PendingCheckEvent.Raw, _ newest: Int64) async -> Outcome {
        guard case .success(let match) = await repo.matchLocation(e.latitude, e.longitude, e.accuracyMeters)
        else { return failureOutcome((/* .failure */ await repo.matchLocation(e.latitude, e.longitude, e.accuracyMeters)).errorOrNil) } // ver nota
        guard case .success(let state) = await repo.getState(e.chave) else { /* failureOutcome(err) */ }
        guard case .success(let options) = await repo.getLocations() else { /* failureOutcome(err) */ }
        guard let activity = resolveAutomaticActivityForMatch(match, state, options.mixedZoneIntervalMinutes)
        else { return .done }                                       // sem ação → consome o evento
        let outcome = outcomeOf(await repo.submit(
            chave: e.chave, projeto: e.projeto, action: activity.action, local: activity.local, informe: .normal,
            eventTime: Date(timeIntervalSince1970: Double(e.capturedAtEpochMs) / 1000),
            clientEventId: e.clientEventId,
            fillForms: fillFormsFor(e.capturedAtEpochMs, newest)))
        logReplayOutcome(outcome, activity.action, activity.local)
        return outcome
    }

    private func fillFormsFor(_ capturedAt: Int64, _ newest: Int64) -> Bool { (newest - capturedAt) <= Self.formsRecencyWindowMs }

    private func outcomeOf<T>(_ r: AppResult<T>) -> Outcome {
        switch r { case .success: return .done; case .failure(let e): return failureOutcome(e) }
    }
    // Transitório → RETRY (mantém): rede, sessão expirada, HTTP ≥500. Permanente → DROP (remove): HTTP 4xx, Conflict, Unknown.
    private func failureOutcome(_ error: ApiError) -> Outcome {
        switch error {
        case .network, .unauthorized: return .retry
        case .http(let status, _):    return status >= 500 ? .retry : .drop
        default:                      return .drop      // conflict, unknown
        }
    }
    private func logReplayOutcome(_ o: Outcome, _ action: CheckAction, _ local: String?) {
        let kind: ActivityKind = action == .checkOut ? .checkOut : .checkIn
        switch o {
        case .done: logger.logSynced(kind, local)
        case .drop: logger.logSyncDropped(kind)
        case .retry: break                               // RETRY não loga nada
        }
    }
}
```

> Nota de implementação: o pseudo-`guard case .success ... else { failureOutcome(err) }` acima é ilustrativo — no Swift real, faça `switch` em cada `await repo.xxx` e retorne `failureOutcome(error)` no ramo `.failure` (não chame o endpoint duas vezes). As três chamadas de leitura do `replayRaw` (`matchLocation` → `getState` → `getLocations`) falham **cada uma** pela mesma taxonomia.

**`submit` do `CheckRepository`** precisa do parâmetro `fillForms` (default `true`): o fluxo ao vivo (use case) chama **sem** `fillForms` (default true); o replayer chama **com** valor calculado. `fill_forms` só é transmitido quando `false` (o servidor assume true por omissão).

## 6. Worker / scheduler (fronteira de plataforma) — port de `SyncPendingChecksWorker.kt`

Android: `OneTimeWork`, `NetworkType.CONNECTED`, backoff `EXPONENTIAL 30s`, unique work `REPLACE`, delega tudo a `replayer.drain()` → `COMPLETED→success` / `RETRY→retry`.

**iOS:** delegador fino idêntico, mas o gatilho muda:
- **`BGProcessingTaskRequest`** (`requiresNetworkConnectivity = true`) agendado a cada `enqueue` e no login; `drain()` → `.completed` chama `setTaskCompleted(success: true)`, `.retry` reagenda.
- **`NWPathMonitor`** para disparar o drain quando a rede volta (equivalente ao `NetworkType.CONNECTED`), pois o iOS não garante execução do BGTask no momento.
- Backoff exponencial + de-dup de instância única **reimplementados manualmente** (não há `enqueueUniqueWork REPLACE`). Cancelar um drain no meio é seguro — replays são idempotentes (dedup por `client_event_id`).

> Ver `conversion_plan.md` §9.6/§14.3. **Não** prometer cadência garantida: BGTask é oportunista.

## 7. Invariantes obrigatórias

1. **Cap = 200**, descartando os **mais antigos** por `capturedAtEpochMs` (`sorted.suffix(200)`).
2. **Dedup = REPLACE por `clientEventId`** no enqueue (o mais novo vence, incl. seu `capturedAtEpochMs`).
3. **Ordem de replay = captura ascendente** (mais antigo primeiro) — o estado do servidor evolui certo (check-in antes do seu check-out).
4. **Exactly-once:** `capturedAtEpochMs` (→ `eventTime`) e `clientEventId` **originais** preservados em todo replay (servidor dedup por `client_event_id`).
5. **Taxonomia de erro:** `Network`/`Unauthorized`/`HTTP≥500` → **RETRY** (mantém); `HTTP 4xx`/`Conflict`/`Unknown` → **DROP** (remove). Um **RETRY aborta o drain inteiro** imediatamente.
6. **Janela `fill_forms` de 24h** ancorada no **evento mais novo da fila** (não no relógio): `(newest − captured) ≤ 24h`.
7. **Raw re-decide no servidor** via a MESMA `resolveAutomaticActivityForMatch`; ação nula → consome (DONE, sem submit). Decided → submit verbatim.
8. **Decode tolerante:** blob corrompido/desconhecido → lista vazia, nunca crash. `ignoreUnknownKeys` (Swift: ignorar chaves extras + `try?` no decode).
9. **Multi-passe** (máx 5): re-fotografa a fila a cada passe para pegar eventos enfileirados durante o drain.
10. **Log best-effort:** `logSyncing(count)` no início de cada passe; DONE→`logSynced(kind, local)`; DROP→`logSyncDropped(kind)`; RETRY→nada. Nunca altera o resultado do drain.

## 8. Fixtures de teste a portar

- **Fake store:** classe com `var value = ""`; `read()` retorna, `write(_:)` seta. (Sem cripto no fake.)
- **Fake scheduler:** no-op (`scheduleSync()` vazio); nunca asserido.
- **Fake queue** (para os testes do replayer): back por `var pending: [PendingCheckEvent]`; `peekAll()` retorna cópia ordenada por `capturedAtEpochMs`; `remove(id)` filtra; `size()` conta.
- **Repository spy** (estrito): `submit`/`matchLocation`/`getState`/`getLocations` stubados por teste; capturar args **posicionalmente** no closure (não usar "último arg" — em suspend Kotlin o último é a Continuation; em Swift capture por posição). `activityLogger` relaxado (só chamadas verificadas importam).
- **Helpers de fábrica:** `raw(id, at, lat=1.0)` → `Raw(chave:"HR70", projeto:"P80", capturedAtEpochMs:at, clientEventId:id, latitude:lat, longitude:103.0, accuracyMeters:10.0)`; `decided(id, at, action:"checkout", local:"Zona Mista")` → `Decided(..., informe:"normal")`. (No replayer: `raw` usa `lat=1.3, lon=103.8`.)
- **`state(last:)`** → `HistoryState(found:true, currentAction:last, currentLocal:nil, hasCurrentDayCheckin: last == .checkIn, lastCheckinAt: last == .checkIn ? Date() : nil, lastCheckoutAt: last == .checkOut ? Date() : nil, transportEnabled:false)`. `match(status, local)` e `options(mixedZoneIntervalMinutes:15, threshold:50)` como na spec do motor.
- **Sem relógio:** `capturedAtEpochMs` são literais (100, 150, 200, 1..205, 0, 2·dia+1000). Passe `Int64` direto.
- **Async:** todos os testes são `runTest` (suspend) → XCTest `async`.

## 9. Mapa de testes Kotlin → Swift XCTest (16 testes)

| Arquivo Kotlin | Alvo Swift | # |
|----------------|-----------|---|
| `offline/OfflineCheckQueueTest.kt` | `OfflineCheckQueueTests` | 5 |
| `offline/PendingCheckReplayerTest.kt` | `PendingCheckReplayerTests` | 11 |

### 9.1 `OfflineCheckQueueTests` (mecânica da fila)

| test | given | → then |
|------|-------|--------|
| `enqueue_then_peek_returns_in_capture_order` | enfileira Raw(id="b",at=200) depois Raw(id="a",at=100) | `peekAll().ids == ["a","b"]` (ordem de captura, não inserção) |
| `enqueue_same_id_replaces_instead_of_duplicating` | Decided(id="x",at=100) depois Decided(id="x",at=150) | `size()==1`; `single().capturedAtEpochMs==150` (o novo vence) |
| `remove_drops_only_that_id` | Raw("a",100) + Decided("b",200); `remove("a")` | `peekAll().ids == ["b"]` |
| `survives_serialization_roundtrip_for_both_variants` | Raw("r",100,lat=1.2345) + Decided("d",200,action="checkout",local="Zona Mista"); reabre fila NOVA sobre o mesmo store | `size==2`; "r"→`.raw` lat==1.2345 (delta 0.0); "d"→`.decided` action=="checkout", local=="Zona Mista" |
| `caps_queue_dropping_oldest` | enfileira Raw "e1".."e205" com at=1..205 | `size==200`; descarta os 5 mais antigos; `first().id=="e6"`, `first().capturedAtEpochMs==6` |

### 9.2 `PendingCheckReplayerTests`

| test | given | → then |
|------|-------|--------|
| `decided_replays_verbatim_with_original_time_and_id` | 1 Decided("d",1000,checkout,"Zona Mista",normal); submit→Success | `.completed`; fila vazia; submit(chave,projeto,**CHECKOUT**,"Zona Mista",**NORMAL**,eventTime=1000ms,id="d",**fillForms=true**) |
| `raw_matches_decides_and_submits_with_original_time_and_id` | 1 Raw("r",2000,1.3,103.8); match→MATCHED "Unidade P80"; getState→CHECKOUT; getLocations→opts(interval=15); submit→Success | `.completed`; submit(**CHECKIN**,"Unidade P80",NORMAL,eventTime=2000ms,id="r",fillForms=true) |
| `raw_with_no_action_is_consumed_without_submitting` | 1 Raw("r",3000); match→NOT_IN_KNOWN_LOCATION; getState→CHECKOUT | `.completed`; fila vazia; **submit chamado 0×** |
| `raw_not_in_known_location_after_checkin_replays_unregistered_checkin` | 1 Raw("r",3000); match→NOT_IN_KNOWN_LOCATION; getState→CHECKIN+currentLocal="Unidade P80" | submit(CHECKIN,**"Localização não Cadastrada"**,NORMAL,eventTime=3000ms,id="r") |
| `network_failure_retries_and_keeps_event` | 1 Decided; submit→Failure(.network) | `.retry`; `pending.size==1` (mantido); nada logado |
| `http_4xx_drops_event` | 1 Decided; submit→Failure(.http(422)) | `.completed`; fila vazia (dropado) |
| `http_5xx_retries_and_keeps_event` | 1 Decided; submit→Failure(.http(503)) | `.retry`; `pending.size==1` (mantido) |
| `drain_logs_syncing_count_and_synced_on_success` | 1 Decided(checkout,"Zona Mista"); submit→Success | verifica `logSyncing(1)` + `logSynced(.checkOut,"Zona Mista")` |
| `drain_logs_dropped_on_permanent_4xx` | 1 Decided(checkin,"Unidade P80"); submit→Failure(.http(422)) | verifica `logSyncDropped(.checkIn)`; `logSynced` não chamado |
| `drains_in_capture_order_oldest_first` | Decided("late",2000) inserido antes de Decided("early",1000); submit registra ordem por id | ordem submetida == `["early","late"]` |
| `multi_day_backlog_fills_forms_only_within_24h_of_newest` | Decided("stale",at=0) + Decided("recent",at=2·dia+1000); submit registra fillForms por id | ambos submetidos; `fill["stale"]==false`, `fill["recent"]==true` |

> **Sutileza `fillForms` (testes de evento único):** os `coVerify` de 7 args no Kotlin deixam `fillForms` no default `true` — isto **assere implicitamente `fillForms==true`**. Nos casos de evento único (newest==captured → dentro da janela), **assira `fillForms==true` explicitamente** no XCTest.

## 10. Checklist de fidelidade

- [x] Cap 200 descarta **mais antigos** por `capturedAtEpochMs`; dedup = **replace** por `clientEventId`.
- [x] `peekAll` sempre ordena por captura ascendente; decode falho → lista vazia (nunca crash).
- [x] Taxonomia: Network/Unauthorized/≥500 → RETRY; 4xx/Conflict/Unknown → DROP; **RETRY aborta o drain**.
- [x] `fill_forms` ancorado ao **evento mais novo** (não ao relógio); só transmitido quando `false`.
- [x] Raw reusa a **mesma** `resolveAutomaticActivityForMatch`; ação nula → consome sem submit.
- [x] `eventTime`+`clientEventId` originais preservados (exactly-once).
- [x] `actor` + store **síncrono** (sem `await` na seção crítica) para atomicidade equivalente ao Mutex.
- [x] `OfflineCheckQueue.clear()` (D6) — a fila expõe clear(); o backend cifrado (Keychain/CryptoKit) fica no slice de segurança.
- [ ] Scheduler = BGTask + NWPathMonitor, best-effort (sem promessa de cadência). **Adiado** (slice de background; hoje `NoopSyncScheduler`).
- [x] 16 testes portados e verdes (`OfflineCheckQueueTests` 5, `PendingCheckReplayerTests` 11) + Codable 8.

## 11.1 Implementação (slice, 2026-07-16)

Implementado e verde (222 testes): `PendingCheckEvent` (Codable, discriminador achatado), `OfflineQueueStore`/`SyncScheduler` (+ `InMemoryOfflineQueueStore` — backend cifrado adiado), `OfflineCheckQueue` (actor), `PendingCheckReplayer`. Plugado em `AppEnvironment.live()` (`offlineQueue`).

**Revisão adversarial: 3 CONFIRMED, 5 refutados.**
- ✅ `writeList` apagava a fila em falha de encode (não-finito) → agora **preserva o blob anterior** (fiel: o Kotlin lança antes do `store.write`).
- ✅ `ActivityLog.toEntry()/page()` passaram a **lançar** (não force-unwrap/trap) em rawValue de enum desconhecido — espelha o `valueOf` do Kotlin (capturável) e honra a spec §1 ("falha alto, sem default silencioso").
- ↩️ `readList` all-or-nothing decode → **fiel** (o Kotlin faz `runCatching{decode<List>}.getOrElse{emptyList()}`); nenhuma mudança.
- ↩️ Refutados: atomicidade do actor (correta), merge do discriminador achatado, `fetchOffset` do trim, `nextSeq` monotônico.

## 11. Constantes deste subsistema

`MAX_EVENTS = 200` · `MAX_PASSES = 5` · `FORMS_RECENCY_WINDOW_MS = 24h (86_400_000)` · backoff do worker = exponencial base `30s` · store: arquivo `checking_offline_queue` / key `pending_checks_json` (nomes internos; no iOS, service/account do Keychain à escolha).
