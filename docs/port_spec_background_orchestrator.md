# Spec de porte — Orquestrador de segundo plano

> Especificação para portar o motor de background do Android (Kotlin) para iOS (Swift). Este é o subsistema de **maior risco** e o único onde a paridade **não pode** ser total — o iOS não oferece equivalentes públicos a boa parte dos mecanismos Android. A spec separa o que é **portável 1:1** (a lógica do orquestrador) do que exige **estratégia em camadas** (os gatilhos), e marca cada fronteira.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta de toda a camada `platform/background` + `platform/location` (2026-07-15).
> Cross-ref: matriz de decisão → [port_spec_decision_engine.md](port_spec_decision_engine.md); fila offline → [port_spec_offline_replay.md](port_spec_offline_replay.md); gate de permissões → decisão **D5** em [decision_log.md](decision_log.md); estratégia iOS por camadas → `conversion_plan.md` §9.

Fontes: [BackgroundCheckOrchestrator.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/BackgroundCheckOrchestrator.kt) · [AutoActivityForegroundService.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/AutoActivityForegroundService.kt) · [AutoActivityController.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/AutoActivityController.kt) · [AutoActivityWatchdogWorker.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/AutoActivityWatchdogWorker.kt) · [GeofenceManager.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/GeofenceManager.kt) · [GeofenceBroadcastReceiver.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/GeofenceBroadcastReceiver.kt) · [BootReceiver.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/BootReceiver.kt) · [LocationProvider.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/location/LocationProvider.kt)

---

## 0. Estado iOS efetivamente implementado — atualização de 2026-08-04

> **Regra de leitura.** As seções históricas abaixo registram o baseline Kotlin e slices de julho. Quando
> divergirem desta seção, este é o contrato atual. Não se deve inferir que uma decisão do candidato já está
> habilitada em um build instalável ou validada em iPhone físico.

### Perfis e limite de rollout

`Debug`, `Staging` e `Release` persistem `legacyWithDiagnostics`. O perfil `candidate` é exercitado por
injeção em testes/validação local e seleciona um único motor; ele não roda ao lado do legado. O profile vem do
bundle, é uma decisão de build-time e **não** é um kill switch remoto. `candidateWithMovementExperiment` não é
selecionado por nenhum `.xcconfig`; o experimento permanece desligado. Promover Debug/Staging, produzir um
artefato físico Release-equivalente ou distribuir o candidato requerem aprovações humanas separadas.

O uso contínuo de `UIBackgroundModes=location`/`allowsBackgroundLocationUpdates` não faz parte do pipeline
automático candidato. Qualquer uso existente é restrito ao harness DEBUG preexistente, não prova periodicidade
nem deve ser descrito como estratégia distribuída.

### Pipeline candidato, amostra e coalescência

No candidato, a ordem aprovada é:

```text
gates/contexto + projeto + opções + pausa
  → captura
  → movimento
  → revalidação imediatamente antes do matcher
  → match
  → state, quando necessário
  → matriz
  → submit ou fila offline
```

- `LocationSample` permanece somente em memória e carrega timestamp, coordenada e precisão. A política
  `candidateTrial` aceita no máximo **10 s** de idade e **2 s** de tolerância futura; esses valores são
  aprovados apenas como ponto de partida de ensaio, não como SLO ou calibração final de rollout.
- Um `TIMER` candidato inicia no máximo **uma** captura física. A mesma amostra serve ao gate de movimento e,
  se ainda válida, ao matcher. Amostra stale, futura, inválida ou de precisão insuficiente não chega ao
  matcher e não abre uma segunda captura.
- Um wake significativo pode transportar seed opcional. Uma seed válida/suficiente evita iniciar o driver
  padrão; uma seed coarse pode solicitar no máximo uma melhoria. O legado descarta seed e preserva seu
  comportamento histórico.
- Há no máximo uma avaliação running e um pending normal bounded; wakes normais compatíveis são mesclados.
  O waiter recebe o ticket canônico e espera seu terminal — `coalesced`/`deferred` não são terminais nem
  concluem um BGTask por si. A ordem de drain é `pause transition → pause activation → foreground/pause
  reconciliation → pending normal → accuracy retry → acidente`.

Esse follow-up bounded é uma divergência deliberada do drop do Kotlin/legado: evita perder um wake normal
durante trabalho em voo, sem permitir duas avaliações do motor em paralelo.

### BGTask, UIKit e cancelamento

`BGAppRefresh` continua oportunista: não há promessa de cadência de 15 minutos, wake após force-quit,
relançamento por região ou entrega do daemon. No candidato, `BGAppRefreshExecutionController`,
`BGTaskCompletionGate`, `BackgroundWorkOwnership` e a lease de UIKit fazem completion, fim de lease e
reagendamento exatamente uma vez. A expiração síncrona só marca/libera seu owner; ela não faz `await`.

O contexto de cancelamento tem razão first-wins (`bgTaskExpired`, `uiBackgroundTimeExpired`,
`contextInvalidated`, `taskCancelled`). Expirar um owner BG/UIKit não cancela os demais: o trabalho canônico
só é cancelado quando não resta owner com orçamento válido. `contextInvalidated` cancela todos. Guards antes e
depois de awaits caros impedem iniciar capture, match, state ou submit depois do cancelamento.

| Terminal do trabalho coberto pelo request | Bool de `setTaskCompleted` | Sentido |
|---|---:|---|
| `submitted`, `noAction`, `skip`, `paused`, `toggleOff`, `notConfigured`, fila offline durável ou rejeição permanente processada | `true` | trabalho do sistema concluiu de forma conhecida; não significa sucesso de check-in |
| `expired`/`cancelled` sem handoff durável, `submissionOutcomeUnknown`, `internalFailure` ou request não admitido | `false` | não houve conclusão controlada dentro do orçamento |

`BGProcessing` aplica a mesma disciplina ao drain; evento já persistido na fila é handoff durável e não é
removido por expiração/resposta desconhecida. Não existe marker ou handoff persistente novo para avaliações.
Se submit já foi despachado e o cancelamento torna a resposta indeterminada, o candidato termina
`submissionOutcomeUnknown`, journaliza contexto sanitizado e completa `false`: não cria
`PendingCheckEvent.Decided`, não muda schema/replayer e não faz retry/enqueue automático. Embora cliente e
fila conservem `clientEventId`/`eventTime`, falta contrato server-side e homologação aprovada demonstrando uma
única atividade lógica para repetição desse par; testes locais não suprem esse gate.

### Geofences candidatas por geração

O candidato mantém em memória um snapshot técnico com geração, `requested`, `confirmed`, `failed` (códigos
em whitelist), `omitted`, `pending` e `confirmationUncertain`, sem IDs, token, local ou coordenadas. Cada
mudança material usa identifiers físicos opacos versionados por geração (token aleatório + slot/índice opaco),
entregues somente ao Core Location. Resync idêntico no mesmo processo preserva a geração.

`didStartMonitoringFor` só confirma identifier **e** geometria do expected set atual e só então chama
`requestState`; callback antigo, duplicado ou de geometria divergente não confirma a geração nova.
`monitoringDidFailFor` só afeta região esperada; callback ambíguo vira `confirmationUncertain`. No relaunch,
identifiers herdados são `inheritedUnknown`: podem gerar wake-only enquanto o contexto atual for válido, mas
nunca contam como confirmados e são reconciliados de forma bounded. `removeAll`, logout, toggle off e troca de
projeto invalidam o conjunto antes de pará-lo/rearmá-lo.

Permanecem invariantes: cap 20, priorização tier/Haversine/id, lista vazia remove, falha de fetch preserva o
conjunto atual, dedup de 3 s por `(região, direção)`, ENTER/EXIT opostos distintos e matching no servidor. A
mensagem histórica byte-exact `Geofences registered (N).` significa apenas **requested**, nunca confirmação
técnica. Identifiers/tokens não são persistidos em journal, ActivityLog, export, UserDefaults ou UI.

### Evidência e limites

O candidato foi coberto localmente por testes de unidade/integração, inclusive 163 cenários integrados e a
regressão Debug de 1.156 testes; a UI Debug teve 28 testes. O harness do Simulator terminou com exit 0 e 47
eventos sanitizados, mas classificou execução de BGAppRefresh como indisponível e push silencioso como
inconclusivo. Isso não é validação física do candidato, nem prova de orçamento UIKit, geofence/significant,
rádio, bateria, thermal ou comportamento do daemon.

## 1. Princípio: paridade observável, não de mecanismo

A regra de ouro do plano (§2, §3.4) vale aqui: reproduzir os **resultados** que o usuário percebe (check-in/out automático ao se deslocar, alerta de acidente), não os mecanismos internos. A **lógica** do orquestrador (gate, single-flight, filtro de movimento, caches, dedup de acidente, relogin) porta 1:1. Os **gatilhos** (o que acorda o orquestrador) são reimaginados em camadas iOS, com degradação **explícita** na UX quando o iOS não permite.

## 2. O orquestrador (núcleo portável) — `BackgroundCheckOrchestrator`

`@Singleton` com `Mutex`. No Swift: **`actor`** com single-flight por flag (§3). Dependências (protocolos injetáveis): `appPrefs`, `checkRepository`, `runAutomaticActivitiesUseCase`, `locationProvider`, `clock`, `authRepository`, `securePasswordStore`, `accidentRepository`, `activityLogger`, `notifications`. (O `context`/wake lock some no iOS — §9.)

**Fluxo de 7 passos** (`runOnceLocked(trigger)`):
1. **Auth**: `chave` das prefs (vazia → return). `lang`. `logTrigger`.
2. **Toggle + pausa**: decodifica settings (tolerante → default). **`maybeNotifyAccident` roda ANTES do gate** (alerta de acidente independe do auto). Se `!automaticActivitiesEnabled` → registra `EvaluationOutcome.TOGGLE_OFF`, log, **return**. Pausa: `wasPaused` = flag **persistida** `scheduled_pause_active`; se `isScheduledPauseActiveNow` → transição-in (se `!wasPaused`: notifica se `notifyScheduledPause`, seta flag, log), `handleScheduledPause`, registra `PAUSED`, **return**. Se saiu da pausa (`wasPaused`) → transição-out (notifica, limpa flag, log). `scheduleStartAlarm(nextPauseStartInstant)`.
3. **Opções**: `getLocationOptions() ?: return` (TTL 15min; fallback offline embutido — §5).
4. **Skip-if-unchanged** (só `TIMER`): `shouldSkip(threshold)`; se `SKIP` → registra `SKIP`, log, **return** (§4).
5–6. **Estado + engine**: `getRemoteState(chave)` (TTL 45s); `userProjects` das settings; `runAutomaticActivitiesUseCase(...)` (a matriz — spec do motor). Atualiza `cachedState` em `Submitted`.
7. **Notificação**: se `Submitted && trigger != FOREGROUND && notifyActivities` → `postActivityNotification`. Restaura texto do serviço para "ativo".

**`runOnce(trigger)`** (entrada): single-flight; `wakeLock.acquire(60s)`; `isSessionExpired=false`; `runOnceLocked`; se `isSessionExpired` → `attemptSilentRelogin` → se ok, **`runOnceLocked` de novo (retry once)**. `finally`: libera wake lock + unlock.

**`runAccidentCheck()`** (independente do auto — §8): mesmo mutex; lê chave/settings; **se `!notifyAccident` → return ANTES de qualquer query**; `maybeNotifyAccident`; 401 → relogin → retry once.

## 3. Baseline Kotlin / single-flight do legado (`Mutex.tryLock` → actor + flag)

```swift
enum OrchestratorTrigger { case timer, geofence, foreground }

actor BackgroundCheckOrchestrator {
    private var isRunning = false                       // substitui Mutex.tryLock (NÃO-reentrante, não-bloqueante)

    func runOnce(_ trigger: OrchestratorTrigger) async {
        if isRunning { return }                         // prólogo síncrono (atômico até o 1º await): 2ª chamada CAI FORA
        isRunning = true
        let token = beginBackgroundTask()               // "wake lock" iOS (§9); prazo do sistema
        defer { endBackgroundTask(token); isRunning = false }
        isSessionExpired = false
        await runOnceLocked(trigger)
        if isSessionExpired {
            let chave = await appPrefs.chave(); if chave.isEmpty { return }
            if await attemptSilentRelogin(chave, lang: /* … */) { isSessionExpired = false; await runOnceLocked(trigger) }
        }
    }
}
```
> ⚠️ **Semântica discriminante:** a 2ª chamada concorrente **retorna imediatamente**, não enfileira. Um `actor` normal enfileira nos `await` — por isso o `isRunning` é checado e setado no **prólogo síncrono** (antes de qualquer `await`, portanto atômico no actor). **Não** use um lock que aguarda. Reset em `defer` (equivale ao `finally`), mesmo em return antecipado/erro.

## 4. Filtro de movimento (`shouldSkip`) — puro, só em TIMER

```swift
// Retorna .skip se o dispositivo NÃO se moveu além do limiar desde a última avaliação. Guarda o novo fix como baseline.
enum SkipDecision { case run, skip, noFix }

func shouldSkip(_ accuracyThresholdMeters: Int) async -> SkipDecision {
    guard case .success(let cap) = await locationProvider.capture(accuracyThresholdMeters) else { return .noFix }
    lastCaptureAccuracyMeters = cap.accuracyMeters
    defer { lastLat = cap.lat; lastLon = cap.lon }
    guard let pLat = lastLat, let pLon = lastLon else { return .run }   // 1ª vez → RUN
    let distance = CLLocation(latitude: pLat, longitude: pLon)
        .distance(from: CLLocation(latitude: cap.lat, longitude: cap.lon))   // ~ Android Location.distanceBetween
    let threshold = max(50.0, 2.0 * cap.accuracyMeters)                       // SKIP_THRESHOLD_METERS = 50
    return distance < threshold ? .skip : .run
}
```
> `GEOFENCE` e `FOREGROUND` **sempre** rodam o engine (não passam por `shouldSkip`). Só `TIMER` filtra.

## 5. Fallback offline de opções (`offlineFallbackLocationOptions`) — puro

```swift
let DEFAULT_ACCURACY_THRESHOLD_METERS = 30

// Só ApiError.network dá resultado usável; qualquer outro erro → nil (a run aborta).
func offlineFallbackLocationOptions(_ cached: LocationOptions?, _ error: ApiError) -> LocationOptions? {
    guard case .network = error else { return nil }
    return cached ?? LocationOptions(items: [], accuracyThresholdMeters: DEFAULT_ACCURACY_THRESHOLD_METERS, mixedZoneIntervalMinutes: 0)
}
```
Motivo: offline o engine só captura o GPS e enfileira um `Raw` — não precisa do limiar real (o servidor re-avalia no replay). Sem esse fallback, `getLocationOptions() ?: return` abortava quando o cache de 15min expirava → só a 1ª atividade offline sincronizava.

## 6. Dedup de notificação de acidente (`maybeNotifyAccident`) — decisão pura + set persistido

```swift
func maybeNotifyAccident(_ chave: String, notifyAccident: Bool, lang: String) async {
    guard notifyAccident else { return }
    switch await accidentRepository.getState(chave) {
    case .success(let state):
        let activeIds = Set(state.activeAccidents.map(\.accidentId))
        let seen = await appPrefs.seenAccidentIds()
        if !activeIds.subtracting(seen).isEmpty { notifications.postAccidentNotification(lang) }   // POST sse há id novo
        if activeIds != seen { await appPrefs.setSeenAccidentIds(activeIds) }                        // persiste sse mudou
    case .failure(let error):
        if case .unauthorized = error { isSessionExpired = true }                                    // network NÃO seta
    }
}
```
- Notifica **no máximo uma vez por id** (dedup por `seenAccidentIds` **persistido** — sobrevive à morte do processo). Persiste **só** quando `activeIds != seen`. Idioma via `resolveEffectiveLanguageCode`.

## 7. Caches e relogin

- **Estado remoto** ~45s (`STATE_CACHE_TTL`, chaveado por `chave`); **opções** ~15min (`LOCATION_OPTIONS_TTL`); **geofences** ~1h (no `CheckRepository`).
- ⚠️ **Fronteira iOS:** no Android são campos `@Volatile` num `@Singleton` — vivem enquanto o processo vive. No iOS o processo é **relançado** a cada acordar de background, então a vida do objeto difere: reavalie a frescura contra a vida real do processo (um cache in-memory pode estar sempre "frio" num relançamento). Persistir o `cachedState`/`cachedOptions` é opcional, mas o comportamento de TTL deve ser reproduzido dentro de uma sessão.
- **Relogin silencioso** (`attemptSilentRelogin`): `getPassword`; vazio → notif reauth coalescida + return false; `login` → sucesso true / falha → notif reauth + false.
- **Coalescing de reauth**: `postReauthNotificationCoalesced` posta **no máximo 1×/hora** (`REAUTH_NOTIFICATION_COOLDOWN = 1h`).

## 8. Captura de localização (`LocationProvider`) → `CLLocationManager`

Android: `capture(threshold)`, `TIME_BUDGET_MS=15_000`, `PRIORITY_HIGH_ACCURACY` (1s/min 500ms), guarda o **melhor** fix (`isBetter`: menor `accuracy`; empate → `time` mais novo), fecha quando `accuracy <= threshold`. Timeout → melhor-fix-parcial se houver, senão `Timeout`. Erro → `Unavailable`.

**iOS:** `CLLocationManager` com `desiredAccuracy = kCLLocationAccuracyBest`, coletando por até **15s**, guardando o melhor `CLLocation` (menor `horizontalAccuracy`; empate → `timestamp` mais novo), encerrando cedo quando `horizontalAccuracy <= threshold`. **Semântica "melhor-so-far no timeout"** deve ser replicada. `LocationCapture { case success(lat,lon,accuracyMeters); case timeout; case unavailable }`.

## 9. Camada de gatilhos — mapa Android → iOS (o ponto crítico)

Todos os gatilhos Android convergem para `runOnce(trigger)`. No iOS, cada um vira uma **camada** (plano §9 A–H). Nível: **Alto** = paridade boa; **Parcial** = condicionada ao iOS; **Ausente** = sem equivalente público.

| Mecanismo Android | Onde | Estratégia iOS | Nível |
|---|---|---|---|
| **FGS `foregroundServiceType=location`** + `START_STICKY` | `AutoActivityForegroundService` | Não há equivalente distribuído no candidato; `allowsBackgroundLocationUpdates` fica fora do pipeline automático e só pode existir no harness DEBUG | Ausente no candidato |
| **Timer 15min** (imediato + `delay(15min)` loop) | FGS `timerJob` | **Sem tick garantido.** Eventos de localização + `BGAppRefreshTask` oportunista + reconciliação no foreground | Parcial (sem periodicidade) |
| **Geofences** `NEVER_EXPIRE`, `ENTER\|EXIT`, `INITIAL_TRIGGER_ENTER` (até 100) | `GeofenceManager` | `CLLocationManagerGeofenceMonitor` region monitoring — **cap 20** com `GeofenceRegionPrioritizer` (área atual → mais próximas → id); omitidas logadas + em `lastSummary`; INITIAL_TRIGGER via `didStartMonitoringFor`→`requestState`→`didDetermineState(.inside)` (§18) | Alta, com cap 20 |
| **Geofence → runOnce(GEOFENCE)** | `GeofenceBroadcastReceiver` | delegate encaminha wake ao orquestrador; relaunch/entrega são oportunidades do Core Location, não garantia nem prova física do candidato | Parcial |
| **Significant change** (implícito no FGS) | — | `startMonitoringSignificantLocationChanges` exige `Always`; é oportunidade de wake, sem promessa de entrega/relançamento | Parcial |
| **Watchdog 15min** (reinicia FGS + roda TIMER) | `AutoActivityWatchdogWorker` | `BGAppRefreshTask` / `BGProcessingTask` — **sem intervalo mínimo garantido**, throttled | Parcial |
| **Alarme exato** (pausa start/end, `setExactAndAllowWhileIdle`) | `scheduleExactWake` (1001/1002) | `BGTaskScheduler` (`earliestBeginDate` = preferência) + `UNUserNotificationCenter` best-effort — **sem execução no instante** | Parcial |
| **Boot / update** (`BOOT_COMPLETED`/`MY_PACKAGE_REPLACED`) | `BootReceiver` | **Ausente** — apps iOS não auto-iniciam no boot; só region/significant-change relançam (nunca num reboot sem evento de localização) | Ausente |
| **Restart pós-swipe** (`onTaskRemoved` + alarme 1s) | FGS | **Ausente** — não há `onTaskRemoved`; force-quit suspende tudo | Ausente |
| **Wake lock 60s** (`PARTIAL_WAKE_LOCK`) | orquestrador | `beginBackgroundTask` (prazo do sistema ~30s) para concluir a rajada; **sem loop** | Sem equivalente direto |

**Restauração no foreground (Camada D — controlável pelo app):** o fluxo histórico/legado pode reconciliar no
foreground. No candidato, o launch headless restaura somente estado local; restore remoto e qualquer trabalho
de cena só podem ocorrer após `.active` (ver spec de auth). Isso melhora a segurança de cold launch, mas não
promete entrega do iOS.

**Degradação explícita (obrigatória):** se o usuário força o encerramento, desliga Localização, desliga Atualização em 2º Plano, ou nega "Always"/precisão exata, o **painel de integridade** deve dizer que a automação está degradada/indisponível — **nunca prometer** o que a plataforma não garante.

## 10. Acidente em background (independente do auto)

`runAccidentCheck` roda mesmo com auto **desligado** (no Android via `AccidentWatchWorker`, WorkManager periódico 15min, agendado enquanto autenticado). **iOS:** como não há FGS sempre-ativo, o caminho de alerta de acidente precisa de **APNs** (push do backend para novos acidentes) + `BGAppRefreshTask` como reconciliação oportunista + consulta no foreground, todos com o **mesmo dedup** por `seenAccidentIds` persistido. O worker de 15min **não** pode ser prometido como periodicidade. → dependência de backend (APNs), plano §9.7/§19.2.

## 11. Constantes
`WAKE_LOCK_TIMEOUT_MS=60_000` · `SKIP_THRESHOLD_METERS=50` · `STATE_CACHE_TTL=45s` · `LOCATION_OPTIONS_TTL=15min` · `REAUTH_NOTIFICATION_COOLDOWN=1h` · `DEFAULT_ACCURACY_THRESHOLD_METERS=30` · FGS `TIMER_INTERVAL_MS=15min`, `RESTART_DELAY_MS=1s` · watchdog `INTERVAL_MINUTES=15` (`KEEP`) · geofence TTL `1h` (repo), `NEVER_EXPIRE`, `ENTER\|EXIT`, `INITIAL_TRIGGER_ENTER`, **cap iOS 20** · `TIME_BUDGET_MS=15s` · request codes 1001/1002/3001 (irrelevantes no iOS).

## 12. Mapa de testes Kotlin → Swift XCTest (9 testes)

| Arquivo Kotlin | Alvo Swift | # | Tipo |
|---|---|---|---|
| `background/OfflineFallbackLocationOptionsTest.kt` | `OfflineFallbackLocationOptionsTests` | 4 | função pura |
| `background/AccidentNotificationDecisionTest.kt` | `AccidentNotificationDecisionTests` | 3 | orquestrador (async) |
| `background/OrchestratorToggleGateTest.kt` | `OrchestratorGateTests` | 1 | orquestrador |
| `background/OrchestratorSingleFlightTest.kt` | `OrchestratorSingleFlightTests` | 1 | orquestrador (concorrência) |

### `OfflineFallbackLocationOptionsTests` (puro, síncrono)
- `offline_reuses_last_cached`: `(cached{items:["Unidade P80"],threshold:45,interval:20}, .network)` → **mesma instância** (`===` / identidade).
- `offline_no_cache_defaults`: `(nil, .network)` → não-nil, `threshold==30`, `interval==0` (`items==[]`).
- `unauthorized_bails_nil`: `(cached, .unauthorized)` → **nil** (cache ignorado).
- `server_error_bails_nil`: `(cached, .http(500,"boom"))`, `(cached, .conflict)`, `(cached, .unknown)` → todos **nil**.

### `AccidentNotificationDecisionTests` (async; spy de notificação)
- `newAccident_postsOnce_andRemembersId`: settings default (notifyAccident=true), `seen={}`, `getState("STSM")→active[42]` ⇒ `postAccidentNotification(lang:"pt")` **1×**; `setSeenAccidentIds({42})` **1×**.
- `alreadySeen_doesNotPostAgain`: `seen={42}`, active `{42}` ⇒ `postAccidentNotification` **0×**.
- `notifyDisabled_doesNotPost_norQueriesState`: `notifyAccident=false` ⇒ `postAccidentNotification` **0×** **e** `accidentRepository.getState` **0×** (return antes da query).

### `OrchestratorGateTests` / `OrchestratorSingleFlightTests`
- `auto_off_records_toggle_off_and_never_submits`: `userSettingsJson=""` (→ default, auto OFF), chave="HR70", trigger `.foreground`, `clock` fixo `2026-06-18T09:09:09Z` ⇒ `EvaluationLog` tem entrada `(at, .foreground)` com `outcome==.toggleOff`; `useCase` **0×**; `submit` **0×**.
- `concurrent_runOnce_is_blocked_by_single_flight`: run1 `.timer` preso no 1º `await` (chave via gate suspenso) segurando o lock; run2 `.geofence` ⇒ **run2 completa imediatamente** (tryLock false) enquanto run1 não; libera gate com chave `""` ⇒ run1 completa (return por chave vazia); `submit` **0×** em ambos.

**Notas de teste:**
- `EvaluationLog` é um **ring buffer global** (MAX=50, `@Synchronized`). No Swift: **resetar por teste** (setUp/tearDown) ou marcar cada run com `clock` único e filtrar por `(at, trigger)`. Torná-lo `actor`/thread-safe.
- Single-flight: o Swift precisa de try-acquire **não-reentrante e não-bloqueante** — a 2ª chamada **retorna**, não aguarda. Portar o gate de suspensão do teste com uma `CheckedContinuation`/`AsyncStream` alimentada pelo teste + expectations (run2 termina enquanto run1 não).
- `clock` é o único mock não-relaxado (inject `Clock`/`Date` provider). Wake lock → no-op no iOS, mas preservar o "release no `defer`".

## 13. Checklist histórico de slices iniciais
- [x] Single-flight não-reentrante, não-bloqueante (2ª chamada retorna); release em `defer`.
- [x] Filtro `max(50, 2×precisão)` só em TIMER; geofence/foreground sempre avaliam.
- [x] `offlineFallbackLocationOptions`: só `.network` dá não-nil (cache ou default 30/0).
- [x] `maybeNotifyAccident`: dedup por set persistido; posta se há id novo; persiste se mudou; **antes** do gate de toggle; `notifyAccident=false` não consulta estado.
- [x] Ordem no `runOnceLocked`: auth → accident → toggle → pausa → opções → skip → engine → notif.
- [x] Pausa: flag `scheduled_pause_active` **persistida**; transições notificadas 1× cada.
- [x] Relogin silencioso retry-once; reauth coalescida 1h.
- [x] Captura 15s "melhor-fix-no-timeout" (`CLLocationManagerLocationProvider` — §17). O estado atual de
  geofence candidato é geracional e está definido na atualização §0; esta linha não é status atual.
- [x] Caches 45s/15min/1h; reavaliados contra a vida real do processo no iOS.
- [~] **Camadas de gatilho** iOS: NWPathMonitor/BGTask/foreground feitos (§14); `.timer` via BGAppRefreshTask agora de fato submetido e disparando o orquestrador (§16); geofence region-monitoring (cap 20 + priorização) feito (§18); painel de integridade no slice de permissões/diagnóstico; `.foreground`/`.geofence` sem call-site real (falta a UI/`checkViewModel` + o handler de launch-por-região).
- [~] Acidente em background: dedup + `runAccidentCheck` feitos; APNs (backend) pendente.
- [x] 9 testes portados e verdes; validação física do candidato continua um gate separado antes de promoção.

## 15. Implementação — núcleo do orquestrador (slice, 2026-07-16)

`BackgroundCheckOrchestrator` (actor) portado 1:1 sobre seams protocolares injetáveis (as impls concretas de auth/acidente/prefs/notificações/senha vêm nos slices delas):
- ✅ Single-flight por FLAG no prólogo síncrono (2ª chamada concorrente RETORNA); `runOnce` (7 passos + relogin retry-once) e `runAccidentCheck` (independente, gate `notifyAccident` antes da query, 401→relogin).
- ✅ Helpers 1:1: `shouldSkip` (só TIMER, `max(50, 2·acc)`), `maybeNotifyAccident` (dedup por set persistido), `getLocationOptions`/`getRemoteState` (TTL 15min/45s), `offlineFallbackLocationOptions`, `attemptSilentRelogin` + `postReauthNotificationCoalesced` (1h).
- ✅ `EvaluationLog` (ring buffer 50, thread-safe), `UserSettings` + `resolvePersistedUserSettings` (decode tolerante), `AccidentState`, seams (`AppPreferencesReading`, `AuthRepositoring`, `SecurePasswordReading`, `AccidentStateReading`, `AutoActivityNotifying`, `BackgroundTaskGuard`, `PauseAlarmScheduling`).
- Testes verdes (257 no total; 14 deste slice): os 9 do §12 + 5 de regressão de `UserSettings`.

**Revisão adversarial (7 agentes): 3 CONFIRMED, 1 refutado.**
- ✅ `sanitizeSettingsChave` agora faz strip `[^A-Z0-9]` + `take(4)` (chave ruidosa acha o record).
- ✅ Projetos normalizados na leitura (trim/uppercase/dedup); filtro `allowedProjects` fica no slice de settings.
- ↩️ `accuracyMeters` stale em trigger não-timer → **fiel ao Kotlin** (reset só no bloco TIMER); documentado, sem mudança.

**Adiado (não wired no `AppEnvironment` ainda):** o orquestrador precisa das impls concretas de auth/acidente/prefs/notificações/senha (seus slices) e do `LocationProvider` live + geofences para ser disparado de verdade. Pronto para plugar quando essas peças existirem.

## 16. Implementação — notificações + montagem final do orquestrador (slice, 2026-07-17)

`AutoActivityNotificationsLive` (port de platform/background/notifications/AutoActivityNotifications.kt, §23.9/T3B.6) — era a última peça faltando para montar o orquestrador de verdade:
- ✅ `postAccidentNotification`/`postActivityNotification`/`postReauthNotification`/`postScheduledPauseTransition` via `UNUserNotificationCenter.add(_:)` atrás de uma seam fina (`NotificationRequestPosting`, testável sem tocar o centro real). Sem `buildServiceNotification`/`updateServiceNotification` — sem equivalente à notificação ongoing de FGS no iOS (já documentado em `OrchestratorSeams.swift`).
- ✅ Textos PT (`brandTitle`/`checkinMessage`/`checkoutMessage`/`pauseStartMessage`/`pauseEndMessage`/`accidentMessage`/`reauthTitle`/`reauthBody`) adicionados ao stub de i18n (`Localization.swift`) — catálogo multi-idioma completo é do slice de i18n, ainda não feito.
- ✅ `local` (parâmetro de `postActivityNotification`) confirmado **não-usado** no Kotlin também (vestigial) — preservado assim na porta, não "corrigido".
- ✅ **Orquestrador montado de verdade em `AppEnvironment`**: `orchestrator: BackgroundCheckOrchestrator` com todas as deps reais (auth/acidente/prefs/senha/notificações), exceto localização — `UnavailableLocationProvider` (sempre `.unavailable`) é um placeholder deliberado até o slice de `CLLocationManager`, documentado no próprio arquivo. `backgroundTaskGuard`/`pauseAlarms` seguem nos defaults `Noop*`, agora com comentário explícito no ponto de construção.
- ✅ BGAppRefreshTask (`refreshTaskID`) agora é **de fato submetido** (`AppDelegate.scheduleAppRefresh()`, no launch e no fim de cada execução) e chama `orchestrator.runOnce(.timer)` — antes só tinha o handler registrado, sem nenhum `submit`, então nunca disparava (achado HIGH da revisão).
- 15 testes novos (`AutoActivityNotificationsLiveTests`) — port comportamental de `NotificationMechanismTest.kt` (título/corpo por tipo, mesmo `identifier` substitui, tipos diferentes não colidem); o teste de localização en/pt do Kotlin não foi portado (catálogo PT-only por ora, mesma lacuna do resto do i18n).
- **Ainda não montado**: `checkViewModel`/`accidentViewModel` (`@MainActor` — ficam para a camada de UI, que ainda não existe); com isso, `.foreground`/`.geofence` continuam sem call-site real hoje — só `.timer` roda em produção.

**Revisão adversarial (7 agentes): 3 CONFIRMED corrigidos, 1 refutado.**
- ✅ **HIGH** — `BGAppRefreshTaskRequest` nunca era submetido (só `register`, sem `submit`); o `.timer` recém-plugado era código morto em produção. Corrigido com submissão no launch + reagendamento no fim de cada execução (`conversion_plan.md §9.6`).
- ✅ Comentário adicionado documentando `backgroundTaskGuard`/`pauseAlarms` como `Noop` deliberado em produção (mesmo padrão do `UnavailableLocationProvider`).
- ✅ 3 testes que só checavam `.first` (sem `count==1`) agora também afirmam a contagem — fecha um ponto cego a posts duplicados.
- ↩️ Refutado: falta de teste para o branch de falha silenciosa (`try?` no `add`) — fiel ao Kotlin (`notify()` também não propaga erro sem `POST_NOTIFICATIONS`), e o próprio `NotificationMechanismTest.kt` também não testa esse branch.

## 17. Implementação — `LocationProvider` live (slice, 2026-07-17)

`CLLocationManagerLocationProvider` (port de platform/location/LocationProvider.kt, "15s melhor-fix") — troca o `UnavailableLocationProvider` no `orchestrator` real de `AppEnvironment.live()` (`.preview` continua com `UnavailableLocationProvider`, deliberadamente, sem tocar o CoreLocation real):
- ✅ Uma `CaptureSession` (`CLLocationManager`+delegate próprios) por chamada a `capture` — sem estado compartilhado entre chamadas concorrentes, já que `CaptureLocationUseCase` é o chokepoint único de check-in manual **e** automático (cenário real de concorrência, não hipotético).
- ✅ `isBetter`/`isValidAccuracy` (puros, testados diretamente): menor `horizontalAccuracy` vence, empate → `timestamp` mais novo; accuracy negativa também é inválida (convenção do CoreLocation sem equivalente Android, extensão natural do guard `isFinite` do Kotlin).
- ✅ Timeout 15s → melhor-fix-parcial se houver (`.success`), senão `.timeout`. Threshold batido → sai cedo com `.success`.
- ✅ Sem permissão do app (`authorizationStatus` não autorizado) → `.unavailable` **rápido**, sem esperar 15s — fiel ao `SecurityException` síncrono do Kotlin.
- ✅ `withTaskCancellationHandler` propaga cancelamento externo (ex.: `expirationHandler` do BGTask) para `finish(timedOut: true)` — sem isso, uma captura em voo ignoraria o cancelamento e rodaria os 15s inteiros, furando o prazo que o próprio app deu ao BGTask.
- 11 testes novos (`CLLocationManagerLocationProviderTests`, só a lógica pura). `CaptureSession`/integração CoreLocation real não é coberta por teste unitário (mesmo padrão de `NWPathMonitorNetworkMonitor`) — a lógica que consome `LocationProvider` já é testada com fake.
- **Divergência residual documentada, não escondida**: Android não lança exceção quando o toggle de Localização do sistema está desligado (só permissão do app lança) — o capture some silenciosamente e só resolve no timeout de 15s (`Timeout`). O iOS não separa "serviço desligado" de "permissão negada" no nível do delegate (`CLError.denied` cobre os dois); `didFailWithError(.denied)` pode disparar mais cedo que 15s nesse caso. Sem correção limpa possível — é uma diferença real de plataforma, documentada em código, não uma decisão D-numerada formal.

**Revisão adversarial (7 agentes): 3 CONFIRMED corrigidos, 1 refutado.**
- ✅ Removido o guard prévio `CLLocationManager.locationServicesEnabled()` — não tinha equivalente no Kotlin e convertia o cenário "serviço desligado" (que no Android vira `Timeout` após 15s) num `.unavailable` instantâneo errado.
- ✅ **`withTaskCancellationHandler` adicionado** — sem ele, cancelar a task ambiente (ex.: `work.cancel()` no `expirationHandler` do BGTask) não interrompia a captura em voo, que rodava até seus próprios 15s e furava o prazo do BGTask (undermina o próprio mecanismo de expiração que o app instalou).
- ✅ TODO desatualizado em `AppEnvironment.swift` (ainda listava "locationService real" como pendente) corrigido.
- ↩️ Refutado: falta de teste de seam para o ciclo de vida manual da `CheckedContinuation` (risco de double-resume) — hoje comprovadamente seguro (MainActor serializa, `finish` é síncrono sem `await` entre o guard e zerar `continuation`); crítica de estilo/precisão de comentário, não bug real.

## 18. Implementação — geofence region-monitoring (slice, 2026-07-17)

Port de GeofenceManager.kt + GeofenceBroadcastReceiver.kt. **Peça central e nova**: o Android permite 100 geofences e registra todas sem ranquear; o iOS limita a **20 regiões por app**, então a priorização determinística é lógica genuinamente nova exigida pelo plano §9.2 ("ranking determinístico e auditável", "não truncar em silêncio").
- ✅ **`GeofenceRegionPrioritizer`** (puro, 17 testes exaustivos): chave de ordenação `(tier, distância, id)`. Tier 0 = área do check-in atual (casa com `currentLocalName`, trim + case-insensitive; cobre a "zona de saída" porque uma `CLCircularRegion` observa entrada E saída); depois proximidade por **Haversine** (grau de longitude encolhe com a latitude — euclidiano ranquearia errado); desempate final por `id` (determinismo total, sem depender de sort estável). Tiers 2/3 do plano (projeto ativo / favoritas) **colapsam** — o `GET /check/geofences` já é escopo do usuário e o círculo não carrega esse sinal; documentado, não escondido.
- ✅ **`GeofenceRegionManager`** (actor, port de `GeofenceManager`, 8 testes com fake): fetch → prioriza → arma; engole erro e sai em lista vazia (fiel ao Kotlin); log `"Geofences registered (N)."` byte-exact; **omitidas nunca silenciosas** — WARNING dedicado + `lastSummary` (para o painel de integridade). `unregisterAll` port do estático do Kotlin.
- ✅ **`CLLocationManagerGeofenceMonitor`** (registro histórico do legado): reconciliava o conjunto usando
  `id = String(circle.id)`. O candidato substitui isso por identifiers opacos por geração, confirmação por
  identifier+geometria e snapshot sem IDs, conforme §0; não usar este parágrafo para implementar o candidato.
- ✅ Plugado em `AppEnvironment` (`geofenceRegionManager`), real na `.live()` e `NoopGeofenceRegionMonitor` na `.preview`.
- 25 testes novos (17 prioritizer + 8 manager). Total 451 verdes.

**Revisão adversarial (4 lentes, 2 céticos/achado; a mais rigorosa do port dada a importância): 3 CONFIRMED corrigidos, 8 refutados.** (Precisou re-executar 6 verificadores que bateram no limite de sessão — os 3 achados de completude afetados voltaram todos REFUTED após verificação real.)
- ✅ **HIGH** — `removeAll()` era no-op num processo recém-relançado (`guard let manager`): o region monitoring persiste no NÍVEL DO SISTEMA, então geofences de uma sessão anterior ficariam armadas após logout (correção **e** privacidade). Agora usa `ensureManager()` p/ acessar as `monitoredRegions` persistidas.
- ✅ **MEDIUM** — `requestState` movido de `sync()` para `didStartMonitoringFor`: chamado logo após `startMonitoring`, antes de a região ser confirmada, o CoreLocation retorna `.unknown` e o INITIAL_TRIGGER_ENTER (usuário já dentro no registro) se perdia.
- ✅ **LOW** — documentada a semântica de tempo do log `"registered"` = ENTREGUE ao CoreLocation (não sucesso confirmado, ao contrário do `.onSuccess` do Play Services); a falha por região vem depois via `monitoringDidFailFor`.
- ↩️ Refutados notáveis: NaN/∞ nas coordenadas (o clamp `min(1, sqrt(h))` sanitiza p/ distância finita determinística — premissa falsa); id "não versionado" (o Kotlin também usa o id cru, `igual ao Kotlin` procede); guard de background no-op no `.geofence` (deferido-e-documentado, igual ao LocationProvider).

**Obrigações DEFERIDAS para o slice do gatilho (call-site de `register`/`unregisterAll`) — refutadas como bug hoje (sem call-site de produção; o Kotlin arma incondicionalmente via `@SuppressLint("MissingPermission")`), mas exigidas pelo plano §9.2 e a rastrear para não caírem:**
1. **Renovar** o conjunto quando servidor/projeto/usuário mudar (`updateActiveProject`/`updateUserProjects` → re-`register`); **remover tudo** no logout/troca de conta/exclusão (`unregisterAll`, §15).
2. **Gate de pré-condição**: registrar só após autenticação + consentimento LGPD (`backgroundLocationConsentAt`) + permissão apropriada (§9.2).
3. **Degradação honesta de "Always"** (D5): region monitoring exige "Always" p/ entrega em background; sem ela o motor é foreground-only — o painel de integridade (slice de permissões) deve dizê-lo, nunca prometer em silêncio.
4. **Handler de launch-por-região**: p/ receber o evento que RELANÇOU o app terminado, um `CLLocationManager` com delegate precisa ser criado cedo no launch (hoje o monitor só nasce no 1º `sync`).

## 14. Implementação — camada de gatilhos (slice, 2026-07-16)

Escopo DESTE slice: a **camada de gatilhos** de resiliência offline + SSE (não o núcleo de 7 passos do orquestrador, que fica para um slice próprio com os 9 testes do §12).

- ✅ **`NetworkMonitoring`** (port de NetworkMonitor.isOnline) — `NWPathMonitorNetworkMonitor` (live) + `waitUntilOnline` (≈ `isOnline.first{it}`), distinctUntilChanged.
- ✅ **SSE ao vivo**: `SSELineParser` (já existia) + `URLSessionSSEConnection` (URLSession.bytes, split de bytes preservando linha em branco), `reconnectingSSE` (port de sseFlow: espera-online + backoff cumulativo, re-tenta URLError **e** HTTPError), `CheckEventStream` (multicast `shareIn WhileSubscribed` — 1 upstream, linger 5s, re-chave).
- ✅ **Disparo do drain**: `OfflineSyncCoordinator` (drena ao reconectar, single-flight) + `BGTaskSyncScheduler` (BGProcessingTask + drain imediato no enqueue-online). Plugado em `AppEnvironment.live()` + `AppDelegate` (registro do BGTask, start do coordenador, drain no foreground).
- Testes verdes (243 no total; 21 deste slice): `ReconnectingSSETests` 5, `SSEBytesTests` 6, `CheckEventStreamTests` 3, `OfflineSyncCoordinatorTests` 4, `NetworkMonitoringTests` 3.

**Revisão adversarial (13 agentes): 5 CONFIRMED corrigidos, 5 refutados.**
- ✅ **HIGH** — `URLSession.bytes.lines` DESCARTA linhas em branco → o SSE nunca despachava evento. Agora split de bytes manual preservando a linha em branco.
- ✅ SSE re-tenta HTTP não-2xx (fiel: no Kotlin todo `onFailure` vira `IOException`, retryWhen re-tenta tudo).
- ✅ Corrida add/remove no `CheckEventStream` (terminate-before-add vazava continuation) → set `terminated`.
- ✅ Re-chave encerra os assinantes antigos (invariante de chave única enforced, não só documentada).
- ✅ Enqueue-online drena na hora (paridade com WorkManager `NetworkType.CONNECTED`), não só no BGTask/transição.

**Fronteiras iOS (§9) — degradação explícita, a comunicar no painel de integridade:** sem tick de 15min garantido; BGTask oportunista; boot/force-quit **Ausentes**. A garantia forte é a **restauração no foreground** (drain no `scenePhase == .active`).
