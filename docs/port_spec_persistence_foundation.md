# Spec de porte — Persistência & Fundação (camada Data)

> Especificação executável para portar a camada de dados/fundação do Android para iOS (Swift), com fidelidade 1:1. **Fecha a camada Data.**
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta de `data/local/*` + `platform/activitylog/*` + `core/time` + `privacy` (2026-07-15).
> Escopo: activity log (Room→Core Data, retenção 30d/5000, página 30, prune-on-write), `ActivityLogger` crash-proof (golden rule 2), `AppPreferencesDataSource`→store tipado, os 3 stores cifrados→Keychain/CryptoKit, `Clock` injetável, `PrivacyConfig`.
> Cross-ref: multi-conta/DataStore round-trip → [port_spec_auth_lifecycle.md](port_spec_auth_lifecycle.md) §5/§9.5; fila offline cifrada → [port_spec_offline_replay.md](port_spec_offline_replay.md) §4; senhas/cookies → auth §5 / rede §4.

Fontes: [ActivityLog.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/activitylog/ActivityLog.kt) · [ActivityLogDao.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/activitylog/ActivityLogDao.kt) · [ActivityLogRow.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/activitylog/ActivityLogRow.kt) · [CheckingActivityDatabase.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/activitylog/CheckingActivityDatabase.kt) · [ActivityLogger.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/activitylog/ActivityLogger.kt) · [ActivityLogEntry.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/model/ActivityLogEntry.kt) · [AppPreferencesDataSource.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/AppPreferencesDataSource.kt) · [Clock.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/core/time/Clock.kt) · [PrivacyConfig.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/privacy/PrivacyConfig.kt) · testes: [ActivityLogStoreTest.kt](../../kotlin/app/src/test/java/br/com/tscode/checking/data/local/activitylog/ActivityLogStoreTest.kt) · [ActivityLoggerTest.kt](../../kotlin/app/src/test/java/br/com/tscode/checking/platform/activitylog/ActivityLoggerTest.kt) · [ActivityLogDaoTest.kt](../../kotlin/app/src/androidTest/java/br/com/tscode/checking/data/local/activitylog/ActivityLogDaoTest.kt) · [ActivityLogStoreRoomTest.kt](../../kotlin/app/src/androidTest/java/br/com/tscode/checking/data/local/activitylog/ActivityLogStoreRoomTest.kt)

---

## 1. Modelo do log (`ActivityLogEntry`)

```swift
enum ActivityActor: String { case user = "USER", sys = "SYS" }                 // rawValue = .name Kotlin EXATO
enum ActivityKind: String { case checkIn="CHECK_IN", checkOut="CHECK_OUT", active="ACTIVE", inactive="INACTIVE",
                            error="ERROR", trigger="TRIGGER", location="LOCATION", sync="SYNC", auth="AUTH", system="SYSTEM" }
enum ActivitySeverity: String { case success="SUCCESS", failure="FAILURE", warning="WARNING", info="INFO" }
struct ActivityLogEntry { let at: Date; let actor: ActivityActor; let kind: ActivityKind; let severity: ActivitySeverity; let description: String; let location: String? }
```
> ⚠️ **rawValue = o `.name` Kotlin exato** (maiúsculo, snake). O Kotlin persiste `enum.name` e lê por `valueOf` (que **lança** em valor desconhecido). No Swift, `init(rawValue:)` deve **falhar alto** (não default silencioso) para espelhar.

## 2. `ActivityLog` store (Room → Core Data)

Fachada sobre o DAO. **Prune-on-write** a cada `record`:
```swift
func record(_ entry: ActivityLogEntry) async {
    await dao.insert(entry.toRow())
    await dao.deleteOlderThan(entry.atEpochMs - RETENTION_MS)   // corte = at do PRÓPRIO evento − 30d (NÃO um clock/now)
    await dao.trimToMax(MAX_ROWS)                               // ambos os prunes em TODA escrita
}
func page(offset: Int, limit: Int = PAGE_SIZE) async -> [ActivityLogEntry]   // newest-first, mapeia row→entry
func count() async -> Int
func clear() async
```
- **Corte de idade = `entry.at − 30d`** (o timestamp do próprio evento inserido, **não** o relógio). Dois registros a 31 dias de distância podam o mais antigo independentemente de "agora".
- Ordem: `insert → deleteOlderThan → trimToMax`. Mapeamento `at ↔ epoch millis Int64`.

## 3. DAO → Core Data (fetch/predicate/batch-delete)

`activity_log` (Room v1, `checking_activity.db`, isolado) → **entidade Core Data standalone** num store próprio (não misturar no modelo principal). Colunas: `id` (PK autoGenerate), `atEpochMs: Int64` (indexado), `actor/kind/severity: String`, `description: String`, `location: String?`.

| DAO Kotlin | Core Data |
|---|---|
| `insert` (`@PrimaryKey autoGenerate`) | Core Data **não tem autoincrement** → adicionar atributo **`seq: Int64` monotônico** atribuído no insert (não confiar em `objectID`). |
| `pageNewestFirst` = `ORDER BY atEpochMs DESC, id DESC LIMIT :limit OFFSET :offset` | `fetchRequest` sort `[atEpochMs DESC, seq DESC]`, `fetchLimit`, `fetchOffset` |
| `deleteOlderThan(t)` = `WHERE atEpochMs < :t` | `NSPredicate("atEpochMs < %lld", t)` + batch delete. **`<` estrito** (mantém `==`). |
| `trimToMax(N)` = deleta `id NOT IN (newest N by atEpochMs DESC, id DESC)` | buscar os `N` mais novos por `(atEpochMs DESC, seq DESC)` e deletar o resto |
| `count` / `clearAll` | `count(for:)` / batch delete tudo |

> **`seq` é load-bearing**: é o tiebreaker de timestamps iguais (paginação e cap). Sequência Int64 monotônica atribuída no insert.
> **Timestamp como Int64 epoch-MILLIS** (não `Date`): garante round-trip exato e o `<` inteiro do age-prune. `Instant.toEpochMilli() ↔ Int64`, `Instant.ofEpochMilli() ↔ Date(timeIntervalSince1970: ms/1000)`. Precisão de ms.

## 4. `ActivityLogger` — fachada CRASH-PROOF (golden rule 2)

```swift
// Toda helper: constrói a descrição inglesa EXATA + escolhe kind/severity/actor, persiste OFF a thread do caller.
// DUPLO guard: nunca lança no caminho de check-in/FGS/receiver.
private func log(_ actor: ActivityActor, _ kind: ActivityKind, _ severity: ActivitySeverity, _ description: String, _ location: String?) {
    do {                                                        // guard EXTERNO (build + agendar)
        let entry = ActivityLogEntry(at: clock.now(), actor: actor, kind: kind, severity: severity, description: description, location: location)
        appScope.run { try? await self.activityLog.record(entry) }   // guard INTERNO (persistência) — erro engolido
    } catch { /* engolido */ }
}
var verbose = true                                             // muta SÓ o logTrigger
```
- **Golden rule 2**: uma falha de persistência **nunca** propaga nem altera o resultado do caller. Duplo `try?`/do-catch. `verbose=false` muta **só** `logTrigger` (as demais sempre logam).
- **Off-thread**: escrita via `appScope` (SupervisorJob+IO no Android → um `Task`/executor de background no iOS). **Nos testes**, injetar um executor **síncrono** (equivalente ao `UnconfinedTestDispatcher`) para a linha ser observável logo após a chamada.

### Tabela helper → (kind, severity, actor, descrição) — EXATA

| Helper | kind | severity | actor | descrição |
|---|---|---|---|---|
| `logCheckIn(actor,loc,success)` | CHECK_IN | SUCCESS/FAILURE | arg | `Check-in at {loc}.` / `Check-in failed at {loc}.` |
| `logCheckOut(actor,loc,success)` | CHECK_OUT | SUCCESS/FAILURE | arg | `Check-out at {loc}.` / `Check-out failed at {loc}.` |
| `logActive(detail?)` | ACTIVE | INFO | SYS | `Checking is now active.` + ` ({detail})` |
| `logInactive(detail?)` | INACTIVE | INFO | SYS | `Checking is now inactive.` + ` ({detail})` |
| `logQueuedOffline(actor,kind,loc)` | **SYNC** | WARNING | arg | `{actText(kind)} queued (offline) at {loc}.` |
| `logSyncing(count)` | SYNC | INFO | SYS | `Syncing {count} queued event(s).` |
| `logSynced(kind,loc)` | SYNC | SUCCESS | SYS | `Queued {actText(kind).lowercased} synced at {loc}.` |
| `logSyncDropped(kind)` | SYNC | FAILURE | SYS | `Queued {actText(kind).lowercased} dropped (invalid).` |
| `logTrigger(name)` | TRIGGER | INFO | SYS | `Background evaluation ({name}).` (mutado se `!verbose`) |
| `logLocation(msg,loc?,sev=INFO)` | LOCATION | arg (default INFO) | SYS | msg **verbatim** |
| `logAuth(msg,sev=INFO)` | AUTH | arg (default INFO) | SYS | msg verbatim |
| `logSystem(msg,sev=INFO)` | SYSTEM | arg (default INFO) | SYS | msg verbatim |
| `logWarning(msg)` | **SYSTEM** | WARNING | SYS | msg verbatim (não há kind WARNING) |
| `logError(msg)` | ERROR | FAILURE | SYS | msg verbatim |

Helpers de texto: `locText(loc) = loc?.takeIf{ !isBlank } ?? "an unknown location"` (null OU só-espaço → fallback; **o valor cru ainda é gravado** na coluna `location`); `detailSuffix(d) = d.isBlank ? "" : " (\(d))"`; `actText(kind) = CHECK_IN→"Check-in", CHECK_OUT→"Check-out", else→"Activity"`.
> ⚠️ **`logQueuedOffline` grava `kind=SYNC`** (o argumento `ActivityKind` só alimenta a descrição via `actText`). Fácil de errar no port. Strings inglês **byte-exatas** (pontuação, `(offline)`, `event(s)`, `(invalid)`, em-dash `—`, e o literal pt `"Desconhecido"` passado sem traduzir).

## 5. `AppPreferencesDataSource` → store tipado

DataStore → store tipado (UserDefaults suite ou arquivo). Chaves e defaults **idênticos** (ver auth §5): `pref_language`/`pref_chave`/`pref_user_settings_json`/`pref_transport_local_json`/`pref_seen_accident_ids`/`pref_pending_checks_json` (legado)/`pref_bg_location_consent_at` (default `""`); `pref_flag_<name>` (Bool, default false). `seenAccidentIds`: parse tolerante (`split(",")`, `toIntOrNull` descarta lixo) ↔ `joinToString(",")`. `getFlag/setFlag` prefixo dinâmico `pref_flag_`. `clearAll()` = wipe total (LGPD art. 18). Round-trip **verbatim** (sem trim/normalização).

## 6. Cripto — 3 stores cifrados → Keychain / CryptoKit

Android usa `EncryptedSharedPreferences` (Keystore, chaves AES256-SIV / valores AES256-GCM, MasterKey AES256-GCM) em **três** arquivos:

| Arquivo Android | Conteúdo | iOS |
|---|---|---|
| `checking_passwords` | senhas por-chave (`SecurePasswordStore`) | Keychain (item por chave, `AfterFirstUnlockThisDeviceOnly`) — auth §5 |
| `checking_cookies` | cookies de sessão por host (`PersistentCookieJar`) | `SessionCookieStore` cifrado — rede §4 |
| `checking_offline_queue` | fila offline (GPS preciso) | Keychain + CryptoKit AES-GCM; **com `clear()`** (D6) — offline §4 |

**Padrão iOS:** chave simétrica aleatória no **Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — legível em background pós-primeiro-desbloqueio, não migra em backup) cifrando o blob via **CryptoKit AES-GCM**; OU arquivo com Data Protection `.completeUntilFirstUserAuthentication`. Decodificação tolerante a erro → vazio (nunca crash).

## 7. `Clock` injetável + `ApplicationScope`

```swift
protocol Clock { func now() -> Date }                          // injetável (testes: instante fixo)
// Zona default do Clock = Asia/Singapore (usada no "dia atual" / resolveCalendarDayKey).
// ⚠️ A pausa programada usa o fuso do APARELHO (device local), NÃO Singapore. Manter a distinção.
```
`ApplicationScope` (SupervisorJob + Dispatchers.IO) → um executor/Task de vida-do-app para escritas best-effort (log). Nos testes, um executor síncrono.

## 8. `PrivacyConfig` — valores legais concretos

Fonte única dos fatos legais (resolve os `{token}` da spec de i18n §11): controlador **Tamer Salmem** (pessoa física, sem CNPJ; CPF **não** publicar), e-mail de privacidade **`tscode.com.br@gmail.com`**, política **`https://www.tscode.com.br/checking/privacidade`**, transferência internacional **true**, hospedagem **Singapura**, retenção de histórico/vídeo (descritiva) + log local **30 dias**, idade mínima **18**. `isConfigured` = nenhum campo com `"PREENCHER:"`. Confirmar o nome legal antes de publicar (§32).

## 9. Constantes
`RETENTION_DAYS = 30` · `RETENTION_MS = 2_592_000_000` (**Int64** — excede `Int32.max`; guardar) · `MAX_ROWS = 5_000` · `PAGE_SIZE = 30` · Room DB v1 `checking_activity.db` · prefixo flag `pref_flag_` · `Clock.SINGAPORE = Asia/Singapore` · retenção local privacidade `30 dias` · idade `18`.

## 10. Mapa de testes Kotlin → Swift XCTest (21 testes)

| Arquivo | Alvo Swift | # | Tipo |
|---|---|---|---|
| `ActivityLogDaoTest.kt` | `ActivityLogStoreTests` (Core Data in-memory) | 6 | integração |
| `ActivityLogStoreRoomTest.kt` | idem | 2 | integração |
| `ActivityLogStoreTest.kt` | `ActivityLogStoreUnitTests` (fake DAO spy) | 3 | unit |
| `ActivityLoggerTest.kt` | `ActivityLoggerTests` (fake DAO + throw) | 10 | unit |

**DAO (6):** `insert_and_count` (3 inserts → count 3); `pageNewestFirst` (65 rows → blocos disjuntos de 30, `page0.first.atEpochMs==65`, `page0.last==36`, `page1.first==35`); `deleteOlderThan` (100/200/300, corte 200 → mantém 200 e 300, remove 100 — **`<` estrito**); `trimToMax` (10 rows, cap 4 → mantém 10,9,8,7); `trimToMax_at5000` (5001 → count 5000, mais antigo sobrevivente `==2`, o `1` some); `clearAll` (→ count 0).
**StoreRoom (2):** `record_then_page_roundTrips` (2 entries, todos os campos preservados no mais novo: `Check-in at Gate 3.`/USER/CHECK_IN/SUCCESS/`Gate 3`/instant exato); `record_prunes>30d` (ancient 31d antes → podado, sobra "fresh").
**Store unit (3):** `record_inserts_and_prunes` (spy: `lastDeleteOlderThan == at.ms − RETENTION_MS`, `lastTrimMax == 5000`, ordem insert→delete→trim); `page_maps_newest_first` (enums re-parseados, "newer" primeiro); `constants_are_pinned` (RETENTION_DAYS 30, RETENTION_MS 2_592_000_000, MAX_ROWS 5000, PAGE_SIZE 30 — **guard de overflow**).
**Logger (10):** checkIn/checkOut descrições+campos exatos; active/inactive + detail em parênteses; `verbose_off` muta trigger / on restaura; **crashProof_persistThrows** (insert lança → não propaga, 0 rows); offline/sync helpers (todos kind SYNC); background suite (kind/severity/actor por helper; `logWarning`=SYSTEM+WARNING); unknownLocation fallback (`null`/`"   "` → "an unknown location"); `verboseOff_mutesOnlyTrigger` (trigger 0, core 3); manual submit → user rows (`Desconhecido`, em-dash); **crashProof_allHelpers** (10 helpers, insert lança → nenhum propaga, 0 rows).

> **Fakes a portar:** (a) DAO spy in-memory que grava `lastDeleteOlderThan`/`lastTrimMax` e atribui ids sequenciais desde 1 + ordena `(atEpochMs desc, id desc)`; (b) DAO `throwOnInsert` que lança em `insert`; (c) `Clock` fixo (`2026-06-19T10:00:00Z`); (d) executor síncrono para o `appScope`. Store Room = Core Data in-memory (`NSInMemoryStoreType`), fresh por teste.

## 11. Checklist de fidelidade
- [ ] Prune-on-write: `insert → deleteOlderThan(entry.at − 30d) → trimToMax(5000)`; corte pelo `at` do evento (não relógio); `<` estrito.
- [ ] Paginação `(atEpochMs DESC, seq DESC)`, LIMIT/OFFSET; **`seq` Int64 explícito** (Core Data não tem autoincrement).
- [ ] Timestamp Int64 epoch-**millis** (não Date); `RETENTION_MS` Int64 (guard de overflow).
- [ ] Enums como `.name` maiúsculo; `init(rawValue:)` falha alto em desconhecido.
- [ ] `ActivityLogger` duplo try/catch (golden rule 2); off-thread; `verbose` muta só `logTrigger`.
- [ ] Descrições inglês **byte-exatas**; `logQueuedOffline` grava **kind=SYNC**; `locText` fallback "an unknown location" (mas grava o valor cru).
- [ ] Store isolado (Core Data próprio), não misturar no modelo principal.
- [ ] `AppPreferences` chaves/defaults idênticos; `seenAccidentIds` tolerante; `pref_flag_`; `clearAll`.
- [ ] 3 stores cifrados → Keychain/CryptoKit `ThisDeviceOnly`; fila offline com `clear()` (D6).
- [ ] `Clock` injetável (Singapore p/ dia; aparelho p/ pausa); `PrivacyConfig` preenchido antes de publicar.
- [ ] 21 testes portados e verdes (8 integração Core Data + 13 unit).

## 12. Implementação — activity log Core Data (slice offline+persistência, 2026-07-16)

Parte de persistência DESTE slice (o resto — AppPreferences, cripto, PrivacyConfig — fica no slice de fundação dedicado):
- ✅ `CoreDataStack` (modelo programático, store isolado `checking_activity`, in-memory p/ testes) + `CoreDataActivityLogDao` (queries 1:1: `pageNewestFirst` = `atEpochMs DESC, seq DESC`; `deleteOlderThan` `<` estrito; `trimToMax` via `fetchOffset`; `seq` Int64 monotônico semeado do max, começa em 1).
- ✅ `ActivityLog` store: prune-on-write `insert → deleteOlderThan(at−30d) → trimToMax(5000)`; constantes fixadas (30d/5000/página 30/`RETENTION_MS` Int64).
- ✅ Enums persistidos por `.name`; `toEntry()/page()` **lançam** em rawValue desconhecido (espelha `valueOf` do Kotlin — capturável, não trap; revisão adversarial).
- Testes verdes: `ActivityLogCoreDataTests` (DAO 6 + StoreRoom 2), `ActivityLogStoreUnitTests` (3 + regressão do throw). Logger (10) coberto em parte por `AutoActivitiesLoggingTests` (6) — dedicados ficam p/ o slice de fundação.
- Adiado: `AppPreferencesDataSource` (extraído — keys/defaults prontos), 3 stores cifrados (Keychain/CryptoKit), `PrivacyConfig`.
