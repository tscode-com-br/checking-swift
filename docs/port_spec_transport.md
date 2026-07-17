# Spec de porte — Transporte

> Especificação executável para portar o subsistema de transporte do Android (Kotlin) para iOS (Swift), com fidelidade 1:1.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta de todo `presentation/transport` + repositório + estado local (2026-07-15).
> Escopo: máquina de estado de solicitações (tipos, estados), estado derivado, SSE + refresh de 30s, estado local de ocultar/realizar, editor de endereço, builder de solicitação, ciência, cancelamento, histórico.
> Cross-ref: contrato de rede/DTOs → [port_spec_network_contracts.md](port_spec_network_contracts.md) §7; SSE → §3; persistência per-chave → [port_spec_auth_lifecycle.md](port_spec_auth_lifecycle.md) §5.
> **Não há testes dedicados** no Kotlin (só o round-trip de `transportLocalJson` no `AppPreferencesDataSourceTest`, já mapeado na spec de auth) → a lógica derivada pura deve virar **novos XCTests** (§10).

Fontes: [TransportViewModel.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/transport/TransportViewModel.kt) · [TransportUiState.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/transport/TransportUiState.kt) · [TransportScreen.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/transport/TransportScreen.kt) · [TransportRepositoryImpl.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/repository/TransportRepositoryImpl.kt) · [TransportModels.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/model/TransportModels.kt) · [TransportLocalState.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/clientstate/TransportLocalState.kt)

---

## 1. Arquitetura alvo

`@Observable @MainActor final class TransportViewModel` sobre `protocol TransportRepository` + o store de preferências. Estado imutável publicado. Jobs canceláveis: `sseTask`, `autoRefreshTask`. Tela cheia (modal sobre o Check — ver spec de UI: mantida como overlay, não rota).

## 2. Modelo (domínio)

Enums (rawValue serializado — ver contrato §6): `TransportRequestKind{regular,weekend,extra}` · `TransportRequestStatus{pending,confirmed,rejected,cancelled,realized}` · `RouteKind{home_to_work,work_to_home}` · `VehicleType{carro,minivan,van,onibus}` · `TransportOverallStatus{available,pending,confirmed,realized}`.

```swift
struct TransportRequest: Equatable {
    let requestId: Int
    let requestKind: TransportRequestKind
    var status: TransportRequestStatus        // var: sobreposto localmente por realizedIds (§3)
    let isActive: Bool
    let serviceDate: Date?                     // LocalDate; ISO yyyy-MM-dd, parse fallback nil
    let requestedTime: String?                 // hora do dia (string)
    let selectedWeekdays: [Int]                // 0=segunda … 6=domingo (ver §8)
    let routeKind: RouteKind?
    let boardingTime: String?
    let confirmationDeadlineTime: String?
    let vehicleType: VehicleType?
    let vehiclePlate: String?
    let vehicleColor: String?
    let toleranceMinutes: Int?
    let awarenessRequired: Bool
    let awarenessConfirmed: Bool
    let responseMessage: String?
    let createdAt: Date                        // Instant; parse fallback EPOCH
}
struct TransportState: Equatable {
    let chave: String
    let endRua: String?; let zip: String?
    let status: TransportOverallStatus
    let requestId: Int?; let requestKind: TransportRequestKind?; let routeKind: RouteKind?
    let serviceDate: Date?; let requestedTime, boardingTime, confirmationDeadlineTime: String?
    let vehicleType: VehicleType?; let vehiclePlate, vehicleColor: String?; let toleranceMinutes: Int?
    let awarenessRequired, awarenessConfirmed: Bool
    let requests: [TransportRequest]
}
enum TransportNotificationTone { case neutral, success, error }
```

## 3. Estado derivado puro (o núcleo testável)

Portar **exatamente** — é aqui que mora a máquina de estado.

```swift
// Sobreposição "realizado" LOCAL: só faz upgrade de CONFIRMED → REALIZED. Nenhum outro status é tocado.
var allRequests: [TransportRequest] {
    (transportState?.requests ?? []).map { req in
        (localState.realizedIds.contains(req.requestId) && req.status == .confirmed)
            ? { var r = req; r.status = .realized; return r }()
            : req
    }
}
// Cartões usam visibleRequests (dismissed removidos); o HISTÓRICO usa allRequests (dismissed NÃO removidos).
var visibleRequests: [TransportRequest] { allRequests.filter { !localState.dismissedIds.contains($0.requestId) } }
// Gate do auto-refresh de 30s: ativas = visíveis, isActive, e PENDING ou CONFIRMED.
var activeRequests: [TransportRequest] {
    visibleRequests.filter { $0.isActive && ($0.status == .pending || $0.status == .confirmed) }
}
var detailRequest: TransportRequest? { detailRequestId.flatMap { id in visibleRequests.first { $0.requestId == id } } }

var endRua: String { transportState?.endRua ?? "" }
var zip: String { transportState?.zip ?? "" }
var hasAddress: Bool { !endRua.isBlank && !zip.isBlank }
var canAddressSubmit: Bool { !isAddressSaving && endRuaInput.trimmed.count >= 3 && zipInput.trimmed.count == 6 }
var canCreateRequest: Bool { hasAddress && builderState != nil }
var canSubmitBuilder: Bool {
    guard let b = builderState, !isRequestSubmitting else { return false }
    switch b.kind {
    case .regular: return !b.selectedWeekdays.isEmpty && b.selectedWeekdays.count <= 5
    case .weekend: return !b.selectedWeekdays.isEmpty
    case .extra:   return !b.requestedDate.isBlank
    }
}
```

**Builder** (defaults por tipo):
```swift
struct TransportBuilderState {
    let kind: TransportRequestKind
    var selectedWeekdays: [Int]                // REGULAR: [0,1,2,3,4] (seg–sex); WEEKEND: [5,6] (sáb,dom); EXTRA: []
    var requestedDate: String = ""             // EXTRA default = hoje (ISO yyyy-MM-dd)
    var requestedTime: String = ""
}
```

## 4. Estado local per-chave (`TransportLocalState`) — puro

```swift
struct TransportLocalState: Equatable {        // JSON per-chave: {"HR70":{"dismissed_request_ids":[…],"realized_request_ids":[…]}}
    var dismissedIds: Set<Int> = []
    var realizedIds: Set<Int> = []
    func withDismissed(_ id: Int) -> Self { var s = self; s.dismissedIds.insert(id); return s }
    func withRealized(_ id: Int) -> Self { var s = self; s.realizedIds.insert(id); return s }
    var isEmpty: Bool { dismissedIds.isEmpty && realizedIds.isEmpty }
}
// load: gate chave.count==4 && json não-vazio; entry para a chave; senão vazio; decode falho → vazio.
// save: gate chave.count==4 (senão retorna currentJson INALTERADO); se state vazio → remove a chave; senão grava. encode.
```
> ⚠️ O gate é a **chave de 4 chars** (usuário), **não** o ZIP de 6 dígitos. Não confundir. Chaves JSON: `dismissed_request_ids`, `realized_request_ids`.

## 5. Ciclo de vida & timers do ViewModel

- **`onOpen(chave)`**: guarda `chave`; `loadState`; `startSseStream`; `scheduleAutoRefresh`.
- **`onClose`**: cancela `sseTask`/`autoRefreshTask`; **reseta** uiState.
- **`loadState`**: `isLoading=true`; carrega local (`transportLocalJson`); `getState(chave)` → `.success`: seta `transportState`+`localState`; `.failure`: seta `localState` + `inlineMessage = transport.messages.loadFailed` (`.error`).
- **`refreshState`**: `getState` → `.success` atualiza `transportState`; `.failure` **silencioso** (refresh de fundo).
- **SSE** (`startSseStream`): coleta `streamEvents(chave)` → **cada evento dispara `refreshState()`** (payload ignorado); erros engolidos (`retryWhen` no `sseFlow`).
- **Auto-refresh 30s** (`scheduleAutoRefresh`): `while true { sleep 30s; if activeRequests não-vazio { refreshState() } }`. **O timer tica sempre**; só faz a chamada de rede quando há ativas.

> **Concorrência (requisito do plano):** SSE + polling de 30s + ação do usuário podem competir. Todos convergem para `getState` → `transportState`. Testar que **não há regressão para um estado mais antigo** (o servidor é a autoridade; cada `getState` traz o estado corrente).

## 6. Fluxos

- **Editor de endereço**: `onZipChanged` filtra dígitos e `take(6)`; `canAddressSubmit` = `endRua>=3 && zip==6`; `updateAddress(chave, endRua.trim, zip.trim)` → `.success`: fecha + `transport.messages.addressUpdated`; `.failure`: `addressUpdateFailed`.
- **Builder → `createRequest`**: `requestedTime = requestedTime.ifBlank(nil)`; `requestedDate = kind==EXTRA ? date.ifBlank(nil) : nil`; `selectedWeekdays = kind != EXTRA ? weekdays : nil`. Falha → `transport.messages.requestFailed` com `{requestLabel: t("transport.kinds.<kind>")}`.
- **Cartão — ocultar/realizar (local, sem rede)**: `onRequestDismiss`/`onMarkRealized` → atualiza `localState` + **persiste** (`saveTransportLocalState`).
- **Cancelar (rede)**: `onCancelRequest` → adiciona a `cancellingIds`; `cancelRequest` → sucesso `cancelSuccess` / falha `cancelFailed`; remove de `cancellingIds`.
- **Ciência**: `onAcknowledgeConfirm` → `acknowledgeRequest(chave, requestId)` → atualiza `transportState`.
- **Detalhe / Histórico**: overlays por `detailRequestId` / `historyOpen`.
- **`clearInlineMessage`**.

## 7. Repositório + mapeamento

`safeApiCall { api.xxx().(.state).toDomain() }`. Endpoints (§5 do contrato): `GET transport/state?chave`, `POST transport/address`, `POST transport/vehicle-request` (alias `transport/request`), `POST transport/cancel`, `POST transport/acknowledge`, **SSE** `GET transport/stream?chave`. Mapeamento DTO→domínio: enums 1:1; `serviceDate = LocalDate.parse(...) ?? nil`; `createdAt = Instant.parse(...) ?? EPOCH` (**fallback EPOCH**, não nil). URL SSE montada manualmente (`BASE+PREFIX+/transport/stream?chave=`), consumida pelo `@SseClient` (não Retrofit).

## 8. Especificidades da UI (de `TransportScreen`, a preservar)

- **Cartões = 3 mais recentes**: `visibleRequests.sortedByDescending(requestId).take(3)`; o **painel de Histórico usa `allRequests`** (dismissed **não** removidos — reaparecem no histórico).
- **Swipe-to-dismiss** só habilitado para status **terminais** (`REALIZED`/`CANCELLED`/`REJECTED`); demais renderizam sem swipe. Qualquer valor de swipe não-Settled dispara `onDismiss` (adiciona a `dismissedIds`).
- **"Ciente"** (botão de ciência) é **hardcoded**, não vem do `t()`. Todo o resto usa chaves i18n.
- **Date pickers** convertem epoch↔data com `TimeZone(identifier:"UTC")` **explícito**; `requestedDate` = ISO `yyyy-MM-dd`.
- **Índice de dia da semana `0=segunda … 6=domingo`** (ISO/brasileiro, **não** domingo-first). `transport.weekdays.short/full` são chaveados por `"0".."6"`. No iOS, mapear o índice com segunda=0.
- **Mensagem inline auto-dispensa** por `LaunchedEffect(delay 4000ms) → clearInlineMessage` na **camada de UI**, não no ViewModel. No SwiftUI, replicar com um `task`/timer atrelado à view (re-disparado a cada mudança de mensagem) — **não** mover para um timer do ViewModel (mudaria o comportamento).
- **`TransportState` de topo** (campos escalares `requestId`/`vehicle*`) é parseado mas **a tela lê exclusivamente da lista `requests`** — os escalares de topo são amplamente não usados.

## 9. Concorrência e tempo (Swift)
- `sseTask` / `autoRefreshTask` como `Task` canceláveis em `onOpen`/`onClose`.
- Timer 30s: `Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); if !activeRequests.isEmpty { await refreshState() } } }`.
- Persistência local via o store de preferências (`transportLocalJson`), gate per-chave.

## 10. Obrigações de teste (novos XCTests — não há 1:1 no Kotlin)

A lógica derivada pura é o alvo natural. Casos mínimos:
- **`allRequests` realized override**: `realizedIds={7}`; request 7 `CONFIRMED` ⇒ vira `REALIZED`; request 7 `PENDING` (em `realizedIds`) ⇒ **inalterado** (só CONFIRMED faz upgrade).
- **`visibleRequests`**: `dismissedIds={3}` remove o 3 dos cartões mas **não** do histórico (`allRequests`).
- **`activeRequests`**: só `isActive && (PENDING||CONFIRMED)` e visíveis; usado como gate do refresh de 30s.
- **`canSubmitBuilder`**: REGULAR (weekdays não-vazio && ≤5), WEEKEND (não-vazio), EXTRA (data não-branca); `isRequestSubmitting` bloqueia.
- **`canAddressSubmit`**: `endRua≥3 && zip==6`; `onZipChanged` filtra dígitos e trunca em 6.
- **Builder defaults por tipo**: REGULAR `[0,1,2,3,4]`, WEEKEND `[5,6]`, EXTRA `[]` + data hoje.
- **`createRequest` param shaping**: EXTRA → `requestedDate` presente, `selectedWeekdays=nil`; não-EXTRA → `selectedWeekdays` presente, `requestedDate=nil`; `requestedTime.ifBlank→nil`.
- **`TransportLocalState` load/save**: per-chave; gate `count==4` (save com chave inválida retorna JSON inalterado); estado vazio remove a chave; chaves JSON exatas.
- **Não-regressão de estado**: SSE/polling/ação concorrentes convergem para `getState`; asserir que o estado nunca volta a um mais antigo.

## 11. Checklist de fidelidade
- [ ] Realized override só CONFIRMED→REALIZED (local); dismissed some dos cartões, fica no histórico.
- [ ] `activeRequests` gate do refresh; timer 30s tica sempre, só chama rede se houver ativas.
- [ ] Cartões = 3 mais recentes por `requestId`; histórico = todos (com dismissed).
- [ ] Swipe só em terminais; "Ciente" hardcoded; date pickers em UTC; weekday 0=segunda.
- [ ] Estado local per-chave (gate 4-char, não ZIP); ZIP = 6 dígitos.
- [ ] `createRequest` molda params por tipo; `requestedTime.ifBlank→nil`.
- [ ] Mapeamento: `serviceDate` parse→nil, `createdAt` parse→EPOCH; enums 1:1.
- [ ] SSE dispara `refreshState` (payload ignorado); erros engolidos; concorrência sem regressão.
- [ ] Mensagem inline auto-dispensa 4000ms na camada de UI, não no ViewModel.
- [ ] Novos XCTests da lógica derivada verdes.

## 12. Constantes
`AUTO_REFRESH_INTERVAL_MS = 30_000` · ZIP `6` dígitos · endereço `≥3` chars · REGULAR `≤5` dias · builder defaults `[0-4]/[5,6]/[]` · weekday `0=segunda…6=domingo` · inline auto-dispensa `4000ms` · cartões `take(3)`.
