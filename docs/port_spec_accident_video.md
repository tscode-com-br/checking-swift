# Spec de porte — Modo acidente + vídeo

> Especificação executável para portar o subsistema de acidente (a feature mais pesada) do Android para iOS (Swift), com fidelidade 1:1 **exceto** onde as decisões **D1–D4** ([decision_log.md](decision_log.md)) mandam corrigir.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta de todo `presentation/accident` + repositório + câmera + worker (2026-07-15).
> Escopo: wizard de abertura, fila de ciência, auto-checkin, relato de zona, chamada de emergência, vídeo (gravação + upload), tema vermelho, alerta em background.
> Cross-ref: dedup de notificação de acidente (`maybeNotifyAccident`) → [port_spec_background_orchestrator.md](port_spec_background_orchestrator.md) §6/§10; DTOs → [port_spec_network_contracts.md](port_spec_network_contracts.md) §7; SSE → §3.
> **Único teste**: `AccidentNotificationDecisionTest` (já mapeado na spec de background). A lógica da VM vira **novos XCTests** (§14).

Fontes: [AccidentViewModel.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/accident/AccidentViewModel.kt) · [AccidentUiState.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/accident/AccidentUiState.kt) · [AccidentScreen.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/accident/AccidentScreen.kt) · [VideoRecordScreen.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/accident/VideoRecordScreen.kt) · [AccidentRepositoryImpl.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/repository/AccidentRepositoryImpl.kt) · [VideoRecorder.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/camera/VideoRecorder.kt) · [AccidentWatchWorker.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/AccidentWatchWorker.kt)

---

## 0. As decisões D1–D4 aplicadas aqui (leia primeiro)

| # | Onde no código | Android (produção) | **Decisão iOS** |
|---|---|---|---|
| **D1** | `onDisableAutoActivities?.invoke()` (VM:274) → lambda vazio (`CheckScreen.kt:119`) | no-op (nunca desliga) | **Não desligar** (fiel). O hook existe mas não faz nada; pendência de produto. |
| **D2/D7** | `inquiryScenario(..., true)` hardcoded (VM:81) e `userProjects != null` (`CheckScreen.kt:257`) | trata auto como sempre-ligado | **Passar o flag real** `automaticActivitiesEnabled`. |
| **D3** | `triggerAutoCheckin` (VM:245) só faz `getState`+`refreshState` | detect-and-wait passivo, não submete | **Manter passivo** (fiel). |
| **D4** | `uploadVideo` descarta o `AppResult` (VM:539); `runCatching→DONE` (`VideoRecordScreen`) | falso "enviado" + vazamento do temp | **Inspecionar o Result**: DONE só em sucesso, ERROR em falha; deletar temp só em sucesso. |

## 1. Modelo

```swift
enum AccidentZone: String { case safety, accident }
enum AccidentSafetyStatus: String { case ok, help }

struct AccidentUserReport: Equatable { let zone: AccidentZone?; let status: AccidentSafetyStatus?; let reportedAt: Date? }
struct AccidentActiveItem: Equatable {
    let accidentId: Int, accidentNumberLabel: String, projectId: Int, projectName: String, locationName: String
    let description: String?; let awarenessStatus: String; let currentUserReport: AccidentUserReport?
}
struct AccidentState: Equatable {
    let isActive: Bool
    let accidentId: Int?; let accidentNumberLabel, projectName, locationName, description, awarenessStatus: String?
    let projectId: Int?; let currentUserReport: AccidentUserReport?
    let activeAccidents: [AccidentActiveItem]
}
struct VideoUploadResult { let videoId: Int; let publicUrl: String; let capturedAt: Date }
struct EmergencyCallResult { let callNumber: Int; let callNumberLabel: String; let callSid: String?; let callStatus, message: String }
```

**UI state**:
```swift
enum WizardStep { case project, location, description, situation, confirm }
struct WizardProject { let id: Int; let name: String }
struct WizardLocation { let id: Int; let name: String; let registered: Bool }
enum AutoCheckinStatus { case pending, success, failed }
enum ZoneConfirmStep: Equatable {           // duas etapas de confirmação de relato
    case none, accidentExpanded              // 1º tap em "acidente" expande em ok/help
    case confirmSafety(Int), confirmAccidentOk(Int), confirmAccidentHelp(Int)   // diálogos antes do POST
}
enum InquiryScenario { case showZoneButtons, postReport, hideCard, checkedOutAutoOff, autoCheckinRunning, autoCheckinFailed, triggerAutoCheckin }
```
`WizardState{step, projects, selectedProjectId/Name, isLoadingProjects, locations, selectedLocationId/Name, customLocationName, useCustomLocation, isLoadingLocations, description, selectedZone, selectedStatus, isSubmitting, errorMessage}` com derivados: `effectiveLocationId = useCustom ? nil : selectedLocationId`; `effectiveCustomName = useCustom ? customLocationName.ifBlank(nil) : nil`; `effectiveLocationLabel`; `canProceedProject/Location/Situation`; `canSubmitConfirm`.
`AccidentUiState{accidentState, ackShownForAccidentIds:Set (sessão), ackDialogQueue:[Item], ackDialogShowing:Item?, hasCurrentDayCheckin, currentActionIsCheckin, autoCheckinStatus:[Int:AutoCheckinStatus], zoneConfirmStep, wizardOpen, wizardState?, reportSentForAccidentId:Int?, actionsDialogOpen, videoScreenOpen, emergencyMessage, isLoading, bannerMessage, needsDisableAutoActivities}` com derivados `isActive`, `activeAccidents`, `primaryActiveAccident`, `canReportAccident = hasCurrentDayCheckin && currentActionIsCheckin`.

## 2. `inquiryScenario` — a decisão de cartão por acidente (D2)

Porta 1:1, mas recebe o **flag real** de automático:
```swift
func inquiryScenario(_ accident: AccidentActiveItem, userActiveProject: String, automaticActivitiesEnabled: Bool) -> InquiryScenario {
    if accident.currentUserReport?.reportedAt != nil { return .postReport }                     // já relatou
    if currentActionIsCheckin && userActiveProject == accident.projectName { return .showZoneButtons }  // check-in no projeto do acidente
    if currentActionIsCheckin { return .hideCard }                                              // check-in em OUTRO projeto
    if !automaticActivitiesEnabled { return .checkedOutAutoOff }                                 // check-out + auto OFF (D2: usa o flag REAL)
    switch autoCheckinStatus[accident.accidentId] {                                             // check-out + auto ON
    case .pending: return .autoCheckinRunning
    case .success: return .showZoneButtons
    case .failed:  return .autoCheckinFailed
    case nil:      return .triggerAutoCheckin
    }
}
```
> **D2**: o Android chama isto com `true` hardcoded (VM:81) e com `userProjects != null` (`CheckScreen.kt:257`). O iOS **passa `automaticActivitiesEnabled` real** em todos os call-sites → um usuário check-out com auto **desligado** vê `checkedOutAutoOff` (sem sequência de auto-checkin).

## 3. Auto-checkin passivo (D3) + callback de disable (D1)

```swift
// D3: detect-and-wait — 3 tentativas (0s, depois 3s), só LÊ o estado; NUNCA submete check-in.
func triggerAutoCheckin(_ accidentId: Int) {
    guard autoCheckinStatus[accidentId] == nil else { return }        // guarda de reentrância
    autoCheckinStatus[accidentId] = .pending
    Task {
        var success = false
        for attempt in 0..<3 {                                        // AUTO_CHECKIN_RETRIES=3
            if success { break }
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) } // AUTO_CHECKIN_DELAY_MS=3000
            if case .success = await repository.getState(chave) {
                await refreshState()
                if currentActionIsCheckin { success = true }          // lê o estado do módulo Check
            }
        }
        autoCheckinStatus[accidentId] = success ? .success : .failed
        if !success { onAccidentAutoCheckinFailed() }                 // D1: no-op (fiel à produção)
    }
}
// D1: NÃO desligar o automático (produção é no-op). Hook existe p/ pendência de produto.
func onAccidentAutoCheckinFailed() { /* intencionalmente vazio — ver decision_log D1 */ }
```
> **D3**: o acidente **não** aciona o motor nem submete check-in — só espera o módulo Check virar o estado. Desacoplamento intencional (o `AccidentWatchWorker` roda mesmo com auto OFF). Combinado com **D2**, isto só roda para quem tem auto ligado → o motor tende a estar ativo → conclui com mais frequência que no Android.

## 4. Fila de ciência (`reconcileAckQueue`) — dedup de sessão

```swift
// Chamada a cada refreshState/open bem-sucedido. Enfileira acidentes ativos ainda não vistos NESTA sessão.
func reconcileAckQueue(_ state: AccidentUiState) -> AccidentUiState {
    let activeIds = Set(state.activeAccidents.map(\.accidentId))
    let pruned = state.ackDialogQueue.filter { activeIds.contains($0.accidentId) }         // remove os não mais ativos
    let new = state.activeAccidents.filter {                                               // novos ainda não vistos/enfileirados/exibindo
        !state.ackShownForAccidentIds.contains($0.accidentId)
        && !pruned.contains(where: { p in p.accidentId == $0.accidentId })
        && state.ackDialogShowing?.accidentId != $0.accidentId
    }
    let queue = pruned + new
    let showing = (state.ackDialogShowing == nil && !queue.isEmpty) ? queue.first : state.ackDialogShowing
    let queueAfter = (state.ackDialogShowing == nil && !queue.isEmpty) ? Array(queue.dropFirst()) : queue
    let shownIds = state.ackShownForAccidentIds.union(showing.map { [$0.accidentId] } ?? [])
    return state.with(ackDialogQueue: queueAfter, ackDialogShowing: showing, ackShownForAccidentIds: shownIds)
}
```
- `onAckConfirm`: `acknowledge(chave, id)` (resultado não inspecionado — ver §13); drena a fila; **`triggerAutoCheckin(id)`** do acidente confirmado; `refreshState`.
- `onAckDismiss`: drena a fila **sem** chamar `acknowledge`.
> `ackShownForAccidentIds` é **de sessão** (reset no login/logout). O dedup **persistido entre processos** (`seenAccidentIds`) que dispara a *notificação* é do orquestrador (spec de background §6). Dois mecanismos distintos, ambos portados.

## 5. Wizard (5 passos)

`PROJECT → LOCATION → DESCRIPTION → SITUATION → CONFIRM`. `onReportButtonTap`: se `isActive` → `actionsDialog`; senão `openWizard` (carrega projetos). Navegação: `onWizardNextFrom*` valida `canProceed*` e avança; `onWizardBack` volta um passo (PROJECT→fecha). `onWizardDescriptionChanged` **limita 500 chars**. Localização: `onWizardLocationSelected` (limpa `useCustom`), `onWizardCustomLocationToggled`. `onWizardConfirmSubmit`: `open(chave, projectId, effectiveLocationId, effectiveCustomName, zone, status, description.ifBlank(nil))` → `.success`: `accidentState`+banner+fecha+`reconcileAckQueue`; `.failure` `.conflict` → `accident.wizard.conflictAlreadyActive`, senão `status.apiCommunicationFailure`.
> `open` no repositório envia `description = description.ifBlank ?? ""` — **string vazia, nunca null** (o servidor tipa `str=""` e dá 422 em null). Preservar.

## 6. Relato de zona + emergência

- `onZoneSafetyTap` → `confirmSafety`; `onZoneAccidentTap` → `accidentExpanded`; `onZoneAccidentOkTap` → `confirmAccidentOk`; `onZoneAccidentHelpTap` → `confirmAccidentHelp`. `onZoneConfirm` mapeia: safety→(SAFETY,OK), accidentOk→(ACCIDENT,OK), accidentHelp→(ACCIDENT,HELP) → `submitReport`.
- `submitReport(id, zone, status)`: `report(chave, zone, status)` → `.success`: `accidentState`+banner+`reportSentForAccidentId`; **se `status==.help` → `triggerEmergencyCall`**. `.failure` **silencioso** (ver §13).
- `triggerEmergencyCall`: `emergencyCall(chave)` → `.success`: `accident.emergency.callInitiated{label}`; `.failure` `.conflict` → `accident.emergency.alreadyCalled` (idempotência!), senão `callFailed`. **Manter o sinal de idempotência por `.conflict`.** A emergência real é acionada **pelo backend** (Twilio), não pelo app.

## 7. Vídeo — comportamento CORRIGIDO (D4) + AVFoundation

**D4 — o iOS inspeciona o resultado** (ao contrário do Android, que mostra "enviado" mesmo em falha e vaza o MP4):
```swift
enum VideoRecordPhase { case recording, uploading, done, error }

// VM: retorna o Result (NÃO descartar como o Android faz).
func uploadVideo(file: URL, contentType: String, onProgress: @escaping (Double) -> Void) async -> AppResult<VideoUploadResult> {
    await repository.uploadVideo(chave: chave, idempotencyKey: UUID().uuidString, videoFile: file, contentType: contentType, onProgress: onProgress)
}
// Tela: dirige a fase pelo Result — DONE só em .success, ERROR em .failure (espelha open/report/emergency que já fazem switch).
switch await onUpload(file, "video/mp4", { progress in state.uploadProgress = progress }) {
case .success: state.phase = .done; state.statusMessage = t("accident.video.sent")   // + temp deletado no repo (em sucesso)
case .failure: state.phase = .error; state.statusMessage = t("accident.video.error") // temp RETIDO p/ re-tentar
}
```
- **Câmera/microfone pedidos NO momento da gravação** (não pré-concedidos em Ajustes). Preview/gravação só bindam com ambos concedidos; senão mostra a justificativa.
- **AVFoundation**: `AVCaptureSession` preset `.hd1280x720` (equivalente ao `Quality.HD` do CameraX), **câmera traseira** + microfone, saída MP4 (`AVCaptureMovieFileOutput`) em arquivo temporário (`cacheDir`/`tmp`). Gravação **auto-inicia** ao entrar na tela (após bind). `VIDEO_CONTENT_TYPE = "video/mp4"`.
- **Upload em background**: `URLSessionConfiguration.background` a partir do arquivo, restauração do delegate após relançamento (o plano §19.3). **Idempotência**: `idempotency_key` é UUID gerado por-tentativa no Android (não persistido) — **enhancement em aberto** (persistir entre re-tentativas do usuário; parts exatos: `chave`, `idempotency_key`, `video`).
- **Exclusão do temp só em sucesso confirmado**; em falha, reter para re-tentar (D4).

## 8. Repositório + mapeamento

`safeApiCall { api.xxx(...).toDomain() }`. Endpoints (§5 do contrato): `getState`, `open`, `report`, `acknowledge`, `emergencyCall`, `wizardProjects/Locations`, multipart `uploadVideo`, SSE via `CheckEventStream` (a mesma conexão `/check/stream` compartilhada). Upload: multipart com corpo de progresso (contando bytes escritos / total); **delete do temp DENTRO do sucesso HTTP** (não prematuro — o defeito era a VM descartar o resultado). `capturedAt` parse fallback `now`. `reportedAt`/enums mapeados 1:1.

## 9. Tema vermelho

Troca global de tema (`ProvideAccidentTheme(active:)` → `CheckingTheme(accidentModeActive:)`). iOS: **environment-driven theme switch** ativado por `accidentState.isActive` (mais um `LocalAccidentModeActive` equivalente, default false). Paleta: `primary #C8222A`, `primaryContainer #FDE7E9`, `onPrimaryContainer #8C1A20`; botão de relato com pulse glow `#FF4D57` (sombra 18dp). (Ver spec de UI/design system.)

## 10. Alerta em background (independente do auto) — APNs

`AccidentWatchWorker`: WorkManager periódico **15min** (`KEEP`), chama `orchestrator.runAccidentCheck()`, **independente do toggle de auto** (roda mesmo em uso só-manual). **iOS não tem FGS sempre-ativo** → o alerta de acidente em background precisa de **APNs** (push do backend para novos acidentes) + `BGAppRefreshTask` (reconciliação oportunista) + consulta no foreground, todos com o **mesmo dedup** por `seenAccidentIds` persistido (spec de background §6/§10). O intervalo de 15min **não** pode ser prometido como periodicidade. → dependência de backend (APNs), Marco 0.

## 11. Ciclo de vida & timers

- `onLogin(chave)`: reset; `refreshState`; `startSseStream`; `startPolling`. `onLogout`: cancela jobs, reset.
- `onCheckWebState(historyState, activeProject)`: seta `hasCurrentDayCheckin` + `currentActionIsCheckin` (de `currentAction == .checkIn`); transição check-out→check-in → `refreshState`; para cada acidente ativo, `inquiryScenario(..., automaticActivitiesEnabled REAL)` == `.triggerAutoCheckin` → `triggerAutoCheckin` (**D2: passar o flag real, não `true`**).
- **SSE** (`startSseStream`): filtra `data` que começa com `"accident_"` **ou** contém `"accident"` → `refreshState`. (Payload textual filtrado, não JSON.)
- **Polling 30s** (`startPolling`): `while true { sleep 30s; if isActive { refreshState } }`.

## 12. Constantes
`POLL_INTERVAL_MS = 30_000` · `AUTO_CHECKIN_RETRIES = 3` · `AUTO_CHECKIN_DELAY_MS = 3_000` (0 na 1ª) · descrição do wizard `≤500` chars · vídeo `HD (1280×720)` traseira + áudio, MP4 · watcher `15min` (`KEEP`) · tema `#C8222A/#FDE7E9/#8C1A20`, pulse `#FF4D57`.

## 13. Defeitos menores fora do conjunto D1–D6 (fiéis por ora)

Não são decisões registradas; **replicar** salvo decisão de produto:
- `submitReport` em falha é **silencioso** (sem mensagem de erro ao usuário).
- `onAckConfirm` **não inspeciona** o resultado de `acknowledge`.
- Se o motor de check estiver ocioso, o auto-checkin passivo (D3) falha de forma determinística após ~9s — por design.

## 14. Obrigações de teste (novos XCTests)
- **D2 — `inquiryScenario`**: check-out + `automaticActivitiesEnabled=false` ⇒ `.checkedOutAutoOff`; `=true` ⇒ ramo de auto-checkin. Check-in mesmo projeto ⇒ `.showZoneButtons`; outro projeto ⇒ `.hideCard`; já relatado ⇒ `.postReport`.
- **D3 — `triggerAutoCheckin`**: nunca chama endpoint de submissão de check-in; 3 polls; sucesso se `currentActionIsCheckin` vira true; senão `.failed`.
- **D1**: após falha do auto-checkin, o automático **permanece ligado** (nenhum stop/persistência).
- **D4 — vídeo**: `uploadVideo` `.failure` ⇒ fase `.error` (não `.done`) e temp **retido**; `.success` ⇒ `.done` + temp deletado.
- **`reconcileAckQueue`**: novo acidente ativo enfileira 1×; já-visto na sessão não re-enfileira; acidente não mais ativo é removido da fila.
- **Wizard**: `canProceed*`/`canSubmitConfirm`; descrição limita 500; `effectiveLocationId/CustomName` por `useCustomLocation`; `onWizardBack` de PROJECT fecha.
- **Zona/emergência**: `submitReport(HELP)` dispara `triggerEmergencyCall`; `emergencyCall` `.conflict` ⇒ `alreadyCalled`.
- **`open`**: descrição em branco vira `""` (nunca null).

## 15. Checklist de fidelidade
- [x] **D2**: flag real de auto em todos os call-sites de `inquiryScenario` (nada de `true`/`userProjects != null`).
- [x] **D3**: auto-checkin passivo (só polling, sem submeter check-in nem acionar motor).
- [x] **D1**: não desligar o automático após falha (fiel à produção); hook vazio documentado.
- [x] **D4**: vídeo inspeciona o Result; DONE só em sucesso; ERROR em falha; temp deletado só em sucesso, retido em falha.
- [x] Wizard 5 passos + `effective*` + descrição ≤500; `open` manda `description=""` nunca null.
- [x] Fila de ciência (sessão) + dedup persistido do orquestrador; ack não confirma → sem `acknowledge`.
- [x] Emergência via backend; idempotência por `.conflict` mantida.
- [x] Vídeo: câmera/mic solicitados em contexto; captura AVFoundation real HD 1280×720, câmera traseira,
  áudio, preview e finalização do MP4 aguardada antes do envio. Upload por
  `URLSessionConfiguration.background`, corpo multipart em arquivo protegido, progresso por bytes,
  restauração do delegate no relançamento, retenção para retry e idempotency key estável por gravação.
- [~] Tema/fluxo visual completos; cliente APNs reconhece acidente, reconcilia, categoriza a notificação e
  abre o app com segurança. **Pendente externo:** endpoint/backend para cadastrar e remover o device token.
- [x] SSE filtra "accident"; polling 30s só quando `isActive`.
- [x] Novos XCTests (D1–D4 + inquiryScenario + reconcileAckQueue + wizard) verdes — 81 testes.

## 16. Implementação (slice, 2026-07-16)

Implementado e verde (392 testes; 81 deste slice): `AccidentUiState`+`WizardState` (+`inquiryScenario` D2), `reconcileAckQueue`, DTOs de acidente (`AccidentDTOs.swift` — camelCase nos wizard options, snake_case no resto), `AccidentApi`/`AccidentApiLive` (+`MultipartFormBuilder`), `AccidentRepository`/`AccidentRepositoryLive` (D4 — delete do temp só em sucesso), `VideoRecording` (seam) + `AVFoundationVideoRecorder` (esqueleto fino — bind de câmera real fica p/ slice de UI), `VideoRecordController` (D4 — inspeciona o Result), `AccidentViewModel` (552 linhas do Kotlin portadas). Plugado em `AppEnvironment.live()` (`accidentRepository`, reusando a MESMA `CheckEventStream` compartilhada) — o `BackgroundCheckOrchestrator` agora só precisa de `notifications` p/ ser montado de verdade.

**Revisão adversarial (20 agentes): 13 CONFIRMED corrigidos, 2 refutados.**
- ✅ **[HIGH]** `onLogout`/troca de sessão não cancelava/invalidava Tasks em voo de `refreshState`/`triggerAutoCheckin`/`onAckConfirm`/`submitReport`/`onWizardConfirmSubmit`/`triggerEmergencyCall`/`loadWizard*` — uma resposta tardia da sessão anterior podia pisar no estado da sessão nova. Fix: `sessionToken` (mesmo padrão do slice de auth) validado antes de cada mutação; regressão com `AsyncGate` forçando a corrida.
- ✅ `startSseStream` sem `[weak self]` (retenção indefinida do VM) — alinhado ao padrão já usado em `startPolling`.
- ✅ `effectiveLocationLabel` não fazia trim do nome customizado (inconsistente com os campos irmãos).
- ✅ Faltavam `onWizardDismiss`/`onZoneConfirmDismiss`/`onEmergencyMessageDismiss` (métodos reais do Kotlin, necessários para a UI cancelar fluxos sem submeter).
- ✅ `openVideoScreen` não fechava `actionsDialogOpen` junto (Kotlin `onVideoRecordOpen` faz a transição combinada).
- ✅ `VideoRecordController.stopRecordingAndUpload` sem guarda de reentrância (duplo toque disparava upload duplicado).
- ✅ `MultipartFormBuilder` sem escapar `"`/CRLF nos headers (hardening — nenhum call-site atual é hostil, mas o builder é geral).
- ↩️ Refutados: 2 achados não confirmados na verificação adversarial.
- **Enhancements concluídos em 22/07/2026:** o progresso passou a ser medido por bytes na background
  URLSession e a idempotency key tornou-se estável durante as tentativas da mesma gravação. A limpeza
  best-effort continua silenciosa, como no Kotlin, mas ocorre apenas após sucesso HTTP com resposta válida.

## 17. Integração de UI, captura e upload restaurável (2026-07-22)

O módulo foi integrado como overlay da tela Check, preservando a navegação e o estado existentes. Foram
implementados banner, cartão de consulta, confirmações de zona, fila de ciência, ações de emergência, wizard
de cinco passos, estado visual de acidente, tela de câmera e retry explícito. A captura usa
`AVCaptureSession`/`AVCaptureMovieFileOutput`; o controlador só envia depois do callback de finalização.

O transporte do vídeo passou a usar uma background `URLSession` com `sessionSendsLaunchEvents`,
`uploadTask(fromFile:)`, multipart materializado em Application Support com proteção até o primeiro unlock e
metadados de limpeza em `taskDescription`. HTTP 2xx com JSON inválido não apaga a gravação. O arquivo original
só é removido após resposta válida; falhas conservam o vídeo e reutilizam a mesma idempotency key no retry.

Validação automatizada desta integração: build sem warnings do código do app, **550 testes unitários** no total,
11 direcionados de vídeo, 9 de notificações, 5 do orquestrador e 2 fluxos de UI de acidente aprovados. A câmera, o upload real, a chamada
de emergência e o push do backend ainda exigem ensaio controlado em iPhone/staging antes do gate.
