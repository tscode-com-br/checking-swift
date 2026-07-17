# Spec de porte — Rede & contratos de API

> Inventário verificável do contrato de rede do Android (Kotlin) para reproduzir a integração de backend no iOS (Swift), com fidelidade de wire 1:1. É o **documento-referência central do Marco 0** (§8.4 do plano — "contratos verificáveis").
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta do cliente + auditoria de DTOs (2026-07-15).
> Backend: FastAPI/Pydantic v2 em `https://tscode.com.br/api/web/`. **Presença de campo importa** (Pydantic rejeita campo obrigatório ausente com 422).
> Cross-ref: exactly-once/idempotência → [port_spec_offline_replay.md](port_spec_offline_replay.md); auth DTOs → [port_spec_auth_lifecycle.md](port_spec_auth_lifecycle.md).

Fontes: [NetworkModule.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/di/NetworkModule.kt) · [ApiCallUtils.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/remote/ApiCallUtils.kt) · [ApiError.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/core/error/ApiError.kt) · [AppResult.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/core/result/AppResult.kt) · [PersistentCookieJar.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/PersistentCookieJar.kt) · [SseDataSource.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/remote/sse/SseDataSource.kt) · [CheckEventStream.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/remote/sse/CheckEventStream.kt) · `data/api/*.kt` · `data/dto/*.kt`

---

## 1. Cliente HTTP

| Aspecto | Android | iOS |
|---|---|---|
| Base URL | `BASE_URL + API_PREFIX + "/"` = `https://tscode.com.br/api/web/` (igual debug/release) | `URLSession` + base fixa; **ATS/TLS sem exceção** |
| Header em TODO request | `X-Client: checking-android` + `Accept: application/json` | `X-Client: checking-ios` (**blocker §11**) + `Accept` |
| Timeouts (regular) | connect 15s / read 30s / write 30s | `timeoutIntervalForRequest` ≈ diferenciar por operação |
| Timeouts (SSE) | connect 15s / read **0 (infinito)** | task de streaming sem timeout mid-stream |
| JSON | `ignoreUnknownKeys`, `coerceInputValues`, **`encodeDefaults=true`** | `Codable` tolerante + **encoder que emite `null` explícito** (§8) |
| Cookies | `PersistentCookieJar` (cifrado) | `SessionCookieStore` (Keychain — §4) |

## 2. Mapeamento de erro (`safeApiCall`)

```swift
enum ApiError: Error, Equatable {
    case http(status: Int, detail: String?)   // 4xx/5xx com o `detail` do FastAPI
    case unauthorized                         // 401/403 — sessão expirada, volta ao prompt silenciosamente
    case conflict                             // 409 — acidente já ativo / emergência já acionada
    case network                              // sem rede OU timeout (indistinguíveis)
    case unknown                              // erro inesperado
}
enum AppResult<T> { case success(T); case failure(ApiError) }   // + map/onSuccess/onFailure/getOrNil

// Envelopa toda chamada. Taxonomia EXATA a preservar:
func safeApiCall<T>(_ call: () async throws -> T) async -> AppResult<T> {
    do { return .success(try await call()) }
    catch let e as HTTPError {          // sua camada URLSession que carrega status + errorBody
        switch e.status {
        case 401, 403: return .failure(.unauthorized)
        case 409:      return .failure(.conflict)
        default:       return .failure(.http(status: e.status, detail: e.detail))
        }
    }
    catch is URLError /* .notConnectedToInternet, .timedOut, … */ { return .failure(.network) }
    catch { return .failure(.unknown) }
}
```
> ⚠️ **Timeout == sem-rede**: no Android `SocketTimeoutException` é `IOException` → `Network`. No iOS, mapeie `URLError.timedOut` **e** `.notConnectedToInternet`/`.cannotConnectToHost` todos para `.network` — a UI não os distingue. `detail` só existe em `.http`.

## 3. SSE (`sseFlow` + `CheckEventStream`)

Não há cliente SSE first-party no iOS. Implementar um parser de streaming sobre `URLSession.bytes(for:)`:
- **Parse de linhas SSE**: `data:` (concatena multi-linha), `event:`, `id:`, comentários (`:` inicial), **linha em branco despacha o evento**. **Encaminhar só o payload `data`** (Android descarta `id`/`type`).
- **Reconexão**: erro não-rede **não** re-tenta; offline → espera `NetworkMonitor`/`NWPathMonitor` voltar online; backoff exponencial `min(1000 · 2^min(tentativa,5), 30000)` = **1,2,4,8,16 → cap 30s**. Sempre reinicia stream do zero — **sem `Last-Event-ID`, sem heartbeat**.
- **Conexão única compartilhada**: `CheckEventStream` mantém **uma** conexão `/check/stream?chave=` fanned-out para check **e** acidente, via `shareIn(WhileSubscribed(stopTimeoutMillis=5000), replay=0)`, re-chaveada quando a `chave` muda (relogin). iOS: multicast equivalente (um `AsyncStream` com contagem de assinantes + linger de 5s após o último sair).
- Request SSE: `Accept: text/event-stream`.

## 4. Cookies (`PersistentCookieJar` → `SessionCookieStore`)

Android: `EncryptedSharedPreferences "checking_cookies"`, **um blob JSON por `host`**, sobrescreve na resposta, filtra `expiresAt > now` na leitura, decode falho → vazio, `clear()` no logout.

```swift
struct CookieJson: Codable {   // campos exatos persistidos
    let name, value, domain, path: String
    let expiresAt: Int64       // epoch millis
    let secure, httpOnly, hostOnly: Bool
}
```
**iOS:** um `SessionCookieStore` que persiste cifrado (Keychain / arquivo cifrado — a `HTTPCookieStorage` padrão não persiste cifrado), honra `hostOnly` (host-only vs domain), `secure`, `httpOnly` na re-hidratação, filtra por expiração, e é **legível em background** após o primeiro desbloqueio. `clear()` invalida tudo em logout/troca de conta/exclusão. Interpretar `Set-Cookie` (domínio/caminho/expiração/flags) manualmente ou via `HTTPCookie` + persistência própria.

## 5. Inventário de endpoints (base `…/api/web/`)

Leitura/estado autenticam por `?chave=`; mutações (POST/PUT) via **cookie de sessão** (sem `chave` na query, exceto onde o body a carrega).

**Auth** — `AuthApi`
`GET auth/status?chave` → `WebPasswordStatusResponse` · `POST auth/register-password` → `WebPasswordActionResponse` · `POST auth/register-user` → `WebUserSelfRegistrationResponse` · `POST auth/login` → `WebPasswordActionResponse` · `POST auth/logout` (sem body) → `WebPasswordActionResponse` · `POST auth/change-password` → `WebPasswordActionResponse` · `POST auth/delete-account` (sem body, cookie) → `WebPasswordActionResponse`

**Check** — `CheckApi`
`GET check/state?chave` → `WebCheckHistoryResponse` · `GET check/history?chave` → `WebCheckHistoryListResponseDto` · `GET check/locations` → `WebLocationOptionsResponse` · `POST check/location` → `WebLocationMatchResponse` · `GET check/geofences?chave` → `WebGeofencesResponse` · `POST check` → `MobileSubmitResponse` · **SSE** `GET check/stream?chave`

**Projects** — `ProjectsApi`
`GET projects` → `[ProjectRow]` · `GET user-projects` → `WebUserProjectsResponse` · `PUT user-projects` → `WebUserProjectsUpdateResponse` · `PUT project` → `WebProjectUpdateResponse`

**Transport** — `TransportApi`
`GET transport/state?chave` → `WebTransportStateResponse` · `POST transport/address` → `WebTransportActionResponse` · `POST transport/vehicle-request` (alias `transport/request`) → `WebTransportActionResponse` · `POST transport/cancel` → `WebTransportActionResponse` · `POST transport/acknowledge` → `WebTransportActionResponse` · **SSE** `GET transport/stream?chave`

**Accident** — `AccidentApi`
`GET check/accident/state?chave` → `WebAccidentStateResponse` · `POST check/accident/open` → `WebAccidentStateResponse` · `POST check/accident/report` → `WebAccidentStateResponse` · `POST check/accident/acknowledge` → `WebAccidentStateResponse` · `POST check/accident/emergency-call` (`EmergencyCallChaveRequest{chave}`) → `EmergencyCallResponse` · **Multipart** `POST check/accident/video` (parts: `chave`, `idempotency_key`, `video`) → `AccidentVideoUploadResponse` · `GET check/accident/wizard/projects?chave` → `[AccidentProjectOption]` · `GET check/accident/wizard/locations?chave&project_id` → `[AccidentLocationOption]`

## 6. Enums (Swift `enum: String`, rawValue = valor serializado exato)

`CheckAction`: `checkin`/`checkout` · `InformeType`: `normal`/`retroativo` · `LocationMatchStatus`: `matched`/`accuracy_too_low`/`not_in_known_location`/`outside_workplace`/`no_known_locations` · `TransportRequestKind`: `regular`/`weekend`/`extra` · `TransportRequestStatus`: `pending`/`confirmed`/`rejected`/`cancelled`/`realized` · `TransportOverallStatus`: `available`/`pending`/`confirmed`/`realized` · `RouteKind`: `home_to_work`/`work_to_home` · `VehicleType`: `carro`/`minivan`/`van`/`onibus` · `AccidentZone`: `safety`/`accident` · `AccidentSafetyStatus`: `ok`/`help`.
> `awarenessStatus` (acidente) e `callStatus` (emergência) são **String pura**, NÃO enums.

## 7. Inventário de DTOs (campo `kotlinName: Tipo (json_name) [=default]`; `?` = nullable)

**Auth** (snake_case): `WebPasswordStatusResponse{found:Bool, chave:String, hasPassword:Bool(has_password), authenticated:Bool, message:String, pendingApproval:Bool(pending_approval)=false}` · `WebUserSelfRegistrationResponse{ok,authenticated,hasPassword(has_password):Bool, message:String, status:String="registered", pendingApproval(pending_approval)=false, queueFull(queue_full)=false, projects:[String]=[], activeProject:String(active_project)=""}` · `WebPasswordActionResponse{ok,authenticated,hasPassword(has_password):Bool, message:String}` · requests: `WebPasswordRegisterRequest{chave, projeto:String?=null, senha}` · `WebUserSelfRegistrationRequest{chave, nome, projetos:[String], email:String?=null, senha, confirmarSenha(confirmar_senha)}` · `WebPasswordLoginRequest{chave, senha}` · `WebPasswordChangeRequest{chave, senhaAntiga(senha_antiga), novaSenha(nova_senha)}`.

**Check**:
- `WebLocationMatchRequest`(req)`{latitude:Double, longitude:Double, accuracyMeters:Double?(accuracy_meters)=null}`
- `WebLocationMatchResponse{matched:Bool, resolvedLocal:String?(resolved_local)=null, label:String, status:LocationMatchStatus, message:String, accuracyMeters:Double?(accuracy_meters)=null, accuracyThresholdMeters:Int(accuracy_threshold_meters), minimumCheckoutDistanceMeters:Int(minimum_checkout_distance_meters), nearestWorkplaceDistanceMeters:Double?(nearest_workplace_distance_meters)=null}`
- `WebCheckHistoryResponse{found:Bool, chave:String, projeto:String?=null, currentAction:CheckAction?(current_action)=null, currentLocal:String?(current_local)=null, hasCurrentDayCheckin:Bool(has_current_day_checkin), lastCheckinAt:String?(last_checkin_at)=null, lastCheckoutAt:String?(last_checkout_at)=null, transportEnabled:Bool(transport_enabled)}`
- `WebCheckHistoryItemDto{action:CheckAction, projeto:String, local:String?=null, time:String, informe:InformeType}` · `WebCheckHistoryListResponseDto{items:[WebCheckHistoryItemDto]=[]}`
- `WebLocationOptionsResponse{items:[String], locationAccuracyThresholdMeters:Int(location_accuracy_threshold_meters), mixedZoneIntervalMinutes:Int(mixed_zone_interval_minutes)}`
- `WebCheckSubmitRequest`(req)`{chave, projeto, action:CheckAction, local:String?=null, informe:InformeType, eventTime:String(event_time), clientEventId:String(client_event_id), fillForms:Bool(fill_forms)=true}`
- `MobileSyncStateResponse{found:Bool, chave:String, nome:String?=null, projeto:String?=null, currentAction:CheckAction?(current_action)=null, currentEventTime:String?(current_event_time)=null, currentLocal:String?(current_local)=null, lastCheckinAt:String?(last_checkin_at)=null, lastCheckoutAt:String?(last_checkout_at)=null}`
- `MobileSubmitResponse{ok:Bool, duplicate:Bool=false, queuedForms:Bool(queued_forms)=true, workerHealthy:Bool(worker_healthy)=true, message:String="", state:MobileSyncStateResponse}` — **`typealias WebCheckSubmitResponse = MobileSubmitResponse`**.

**Geofence**: `GeofenceCircleDto{id:Int, local:String, centerLat:Double(center_lat), centerLng:Double(center_lng), radiusMeters:Double(radius_meters)}` · `WebGeofencesResponse{locations:[GeofenceCircleDto]}`.

**Projects**: `ProjectRow{id:Int, name, countryCode(country_code), countryName(country_name), timezoneName(timezone_name), timezoneLabel(timezone_label), address, zipCode(zip_code):String, formsEnabled(forms_enabled), transportEnabled(transport_enabled):Bool, emergencyPhone(emergency_phone):String, /* privados, defaults só p/ decode: */ twilioAccountSid="", twilioAuthToken="", twilioPhoneNumber="", mobileAdmin="", emailLocalEmergency="", emergencyCallMessage="":String, inactivityDaysThreshold(inactivity_days_threshold)=60, mixedZoneIntervalMinutes(mixed_zone_interval_minutes)=30:Int}` · `WebUserProjectsResponse{projects:[String], activeProject(active_project):String}` · `WebUserProjectsUpdateRequest{projects:[String]}` · `WebUserProjectsUpdateResponse{projects:[String], activeProject, ok:Bool, message}` · `WebProjectUpdateRequest{project:String}` · `WebProjectUpdateResponse{…UpdateResponse + project:String}`.

**Transport**: `WebTransportStateResponse{chave, endRua:String?(end_rua)=null, zip:String?=null, status:TransportOverallStatus, requestId:Int?(request_id)=null, requestKind:TransportRequestKind?(request_kind)=null, routeKind:RouteKind?(route_kind)=null, serviceDate:String?(service_date)=null, requestedTime:String?(requested_time)=null, boardingTime:String?(boarding_time)=null, confirmationDeadlineTime:String?(confirmation_deadline_time)=null, vehicleType:VehicleType?(vehicle_type)=null, vehiclePlate:String?(vehicle_plate)=null, vehicleColor:String?(vehicle_color)=null, toleranceMinutes:Int?(tolerance_minutes)=null, awarenessRequired:Bool(awareness_required), awarenessConfirmed:Bool(awareness_confirmed), requests:[WebTransportRequestItemResponse]}` · `WebTransportRequestItemResponse{requestId:Int(request_id), requestKind:TransportRequestKind(request_kind), status:TransportRequestStatus, isActive:Bool(is_active), serviceDate?(service_date), requestedTime?(requested_time), selectedWeekdays:[Int](selected_weekdays), routeKind?(route_kind), boardingTime?(boarding_time), confirmationDeadlineTime?(confirmation_deadline_time), vehicleType?(vehicle_type), vehiclePlate?(vehicle_plate), vehicleColor?(vehicle_color), toleranceMinutes:Int?(tolerance_minutes), awarenessRequired, awarenessConfirmed:Bool, responseMessage:String?(response_message)=null, createdAt:String(created_at)}` · `WebTransportActionResponse{ok:Bool, message:String, state:WebTransportStateResponse}` · requests: `WebTransportAddressUpdateRequest{chave, endRua(end_rua):String, zip:String}` (**não-null aqui**) · `WebTransportRequestCreate{chave, requestKind(request_kind):TransportRequestKind, requestedTime:String?(requested_time)=null, requestedDate:String?(requested_date)=null, selectedWeekdays:[Int]?(selected_weekdays)=null}` · `WebTransportRequestAction{chave, requestId:Int(request_id)}`.

**Accident**: `WebAccidentStateResponse{isActive:Bool(is_active), accidentId:Int?(accident_id)=null, accidentNumberLabel:String?(accident_number_label)=null, projectId:Int?(project_id)=null, projectName:String?(project_name)=null, locationName:String?(location_name)=null, description:String?=null, awarenessStatus:String?(awareness_status)=null, currentUserReport:WebAccidentUserReport?(current_user_report)=null, activeAccidents:[WebAccidentActiveItem]}` · `WebAccidentActiveItem{accidentId(accident_id):Int, accidentNumberLabel(accident_number_label), projectId(project_id):Int, projectName(project_name), locationName(location_name):String, description:String?=null, awarenessStatus(awareness_status):String, currentUserReport:WebAccidentUserReport?(current_user_report)=null}` · `WebAccidentUserReport{zone:AccidentZone?=null, status:AccidentSafetyStatus?=null, reportedAt:String?(reported_at)=null}` · requests: `WebAccidentOpenRequest{chave, projectId(project_id):Int, locationId:Int?(location_id)=null, customLocationName:String?(custom_location_name)=null, zone:AccidentZone, status:AccidentSafetyStatus, description:String?=null}` · `WebAccidentReportRequest{chave, zone:AccidentZone, status:AccidentSafetyStatus}` · `WebAccidentAcknowledgeRequest{chave, accidentId:Int?(accident_id)=null}` · `EmergencyCallChaveRequest{chave}` · responses: `AccidentVideoUploadResponse{videoId(video_id):Int, publicUrl(public_url), capturedAt(captured_at):String}` · `EmergencyCallResponse{callNumber(call_number):Int, callNumberLabel(call_number_label):String, callSid:String?(call_sid)=null, callStatus(call_status):String, message:String}` · wizard: `AccidentProjectOption{id:Int, name:String}` · `AccidentLocationOption{id:Int, name:String, registered:Bool}` (**sem @SerialName — JSON = camelCase**).

## 8. `encodeDefaults=true` → estratégia Swift Codable (a peça de fidelidade nº 1)

O cliente Kotlin serializa **todo** campo, inclusive nulos (emitidos como `null` explícito, não omitidos). O Pydantic tipa vários campos como `T | None` **sem default** → exige o campo **presente**. Swift `Codable` **omite** opcionais nil por padrão (`encodeIfPresent`). Para os **request DTOs**, force `null` explícito:

```swift
// Em cada request DTO com opcionais, custom encode que emite null (NÃO encodeIfPresent):
func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(chave, forKey: .chave)
    if let l = local { try c.encode(l, forKey: .local) } else { try c.encodeNil(forKey: .local) }  // sempre presente
    try c.encode(fillForms, forKey: .fillForms)                                                     // default true sempre enviado
}
```
Campos afetados (mínimo): `WebLocationMatchRequest.accuracy_meters`, `WebCheckSubmitRequest.local` + `fill_forms`, `WebAccidentOpenRequest.location_id`/`custom_location_name`/`description`, `WebAccidentAcknowledgeRequest.accident_id`, `WebTransportRequestCreate.requested_time`/`requested_date`/`selected_weekdays`. (Um wrapper `@ExplicitNull` ou um `KeyedEncodingContainer` helper evita repetir.)

## 9. Datas ISO-8601 = `String` na camada DTO

**Todos** os timestamps/datas trafegam como **String ISO-8601** e são parseados **no repositório**, não no decode automático. Modele-os como `String` no DTO (não `Date` com strategy) para preservar o round-trip exato. Parse no boundary: `ISO8601DateFormatter` (`.withInternetDateTime`; adicione `.withFractionalSeconds` só se o payload tiver frações), com **fallback `nil`** (`runCatching{Instant.parse}.getOrNull()` → `formatter.date(from:) ?? nil`). Campos: `last_checkin_at`, `last_checkout_at`, `current_event_time`, `time`, `event_time`, `service_date`, `requested_*`, `*_time`, `created_at`, `captured_at`, `reported_at`.

## 10. Gotchas obrigatórios (quebram o parse se ignorados)

- **`queued_forms` é `Bool`**, não `Int` (o servidor manda bool, default `true`). Decodar como Int lança e quebra **todo** o parse de submit.
- **`ProjectRow`**: os 11 primeiros campos vêm do `GET /projects` público; os **8 últimos** (twilio_*, mobile_admin, email_local_emergency, emergency_call_message, inactivity_days_threshold=60, mixed_zone_interval_minutes=30) **não** vêm — defaults só p/ decode; **não usar em lógica**.
- **Int vs Double**: manter distinto (Pydantic é estrito). Int: `*_threshold_meters`, `*_interval_minutes`, ids. Double: lat/lon/accuracy/nearest/center/radius.
- **Nullability varia req vs resp**: `end_rua`/`zip` nullable em `WebTransportStateResponse`, **não-null** em `WebTransportAddressUpdateRequest`. `selected_weekdays` non-null nas respostas, **nullable** em `WebTransportRequestCreate`.
- **Literais acentuados** (ex. `"Área X"`, `Á`=U+00C1): UTF-8 exato, sem normalizar.
- **`AccidentProjectOption`/`LocationOption`/`VideoLink`**: JSON = camelCase (sem @SerialName), ao contrário do resto (snake_case).

## 11. Blocker de backend — `X-Client: checking-ios` (Marco 0)

O Android envia `X-Client: checking-android` em **todo** request para que o servidor **conceda tratamento especial** (marca `device_id`, e crucialmente aceita o check-in em `"Localização não Cadastrada"` que o web recusa com 422 — ver spec do motor §3.4). **O iOS precisa de `X-Client: checking-ios` homologado com as mesmas regras** antes de qualquer integração real. Até isso, é bloqueador. → questão §32.5 do plano.

## 12. Mapa de testes Kotlin → Swift XCTest (2 testes)

Único teste dedicado à camada: `CheckHistoryMapperTest` (mapeamento `WebCheckHistoryItemDto → CheckHistoryEntry`). Alvo `CheckHistoryMapperTests` (async):
- `getHistory_mapsDtoToDomain_withLocationParsedTimeAndInforme`: `getHistory("U3RD")` → 2 itens `[{CHECKIN,"P80","Área X","2026-06-15T01:00:00Z",NORMAL},{CHECKOUT,"P80",null,"2026-06-15T03:00:00Z",RETROATIVO}]` ⇒ `.success`, size 2; item0 mapeia campo-a-campo (`time == Date` parseado do MESMO literal), item1 `local == nil` (passa nulo), `informe==.retroativo`. (Não asserir item1.projeto/time.)
- `getHistory_emptyList_mapsToEmptyDomainList`: `items=[]` ⇒ `.success`, `data.isEmpty()`.
> DTO-enum e domínio-enum são **tipos distintos** com os mesmos casos → manter dois enums + `toDomain()`. Parse de tempo com fallback `nil` (não exercitado por teste — não inventar teste extra). `local` nulo passa verbatim. Ordem 1:1.

## 13. Checklist de fidelidade / contratos verificáveis
- [ ] `X-Client: checking-ios` + `Accept` em todo request; homologado no backend (§11).
- [ ] `encodeDefaults`: requests emitem **todos** os campos, `null` explícito p/ opcionais ausentes.
- [ ] Taxonomia de erro exata (401/403→unauthorized, 409→conflict, timeout+sem-rede→network).
- [x] `queued_forms`=Bool; `ProjectRow` 8 campos privados opcionais; Int vs Double distintos. (`ProjectRow` — ver §15)
- [ ] Timestamps = String no DTO, parseados no boundary com fallback nil.
- [ ] Cookies cifrados por host, `hostOnly`/`secure`/`httpOnly`, filtro de expiração, legível em background, `clear()` no logout.
- [ ] SSE: 1 conexão `/check/stream` compartilhada, só `data`, backoff 1–30s, sem Last-Event-ID; re-chave em relogin; linger 5s.
- [ ] Idempotência: `client_event_id` (offline) e `idempotency_key` (form-part do vídeo) reusados em retry (specs offline/acidente).
- [ ] Gerar uma **ficha por endpoint** (método/caminho/req/resp/erros/fixture JSON anonimizada) e **contract tests** contra staging antes de publicar (§8.4).
- [x] 2 testes de mapeamento portados e verdes (`CheckRepositoryMappingTests`).

## 14. Implementação — Marco 0 (slice de rede/contratos, 2026-07-15)

Camada implementada e verde (185 testes): `HTTPClient`/`URLSessionHTTPClient`, `safeApiCall`, `JSONCoding`, DTOs Check+Geofence (encode null-explícito, decode com defaults), `CheckApi`/`CheckApiLive`, `CheckRepositoryLive` (mappers 1:1 + cache TTL geofence), `SessionCookieStore` (in-memory; backend cifrado adiado p/ slice de segurança), `SSELineParser`+backoff, `ISOInstant`. Plugado em `AppEnvironment.live()`.

**Revisão adversarial (workflow, 16 agentes): 6 achados CONFIRMED corrigidos, 5 refutados.**
- ✅ Query: `+` era deixado literal pelo `URLQueryItem` (Starlette → espaço). Agora `percentEncodedQuery` escapa `+`→`%2B` (fiel ao OkHttp).
- ✅ `ISOInstant.string`: emite frações de segundo só quando não-zero (espelha `Instant.toString()`); antes truncava `event_time` para segundos inteiros.
- ✅ Cookie de sessão: `expiresAt` = `HttpDate.MAX_DATE` (253402300799999), não `Int64.max`; + clamp `>MAX→MAX`, `<=0→MIN` (fiel ao OkHttp).
- ✅ `ApiError.unknown(description:)` — retém a descrição textual da causa (Sendable-safe; o `cause: Throwable` do Kotlin não é portável 1:1). Igualdade por tipo.
- ✅ Cancelamento (`CancellationError`/`URLError.cancelled`) → `.unknown` (não `.network`) — espelha `CancellationException`→`Unknown` do Android e evita retry indevido no replayer.
- ↩️ Refutados (testados contra a Foundation real): deleção de cookie (Max-Age=0 é incluído no parse), inferência host-only por ponto no domínio, coalescência de múltiplos `Set-Cookie` — todos corretos no runtime Apple.

## 15. Implementação — slice ProjectListing (2026-07-17)

Camada implementada e verde (407 testes): `Domain/Repositories/ProjectRepository.swift` (refina `ProjectListing` já existente com `getUserProjects`/`updateUserProjects`/`updateActiveProject`), `Data/DTOs/ProjectDTOs.swift` (`ProjectRow` com decoder custom p/ os 8 campos privados com default fiel ao Kotlin; `WebUserProjectsResponse`/`WebUserProjectsUpdateRequest`/`WebUserProjectsUpdateResponse`/`WebProjectUpdateRequest`/`WebProjectUpdateResponse`), `Data/Repositories/ProjectsApi.swift` (`ProjectsApiLive`, 4 endpoints), `Data/Repositories/ProjectRepositoryLive.swift` (mapeamento DTO→domínio `safeApiCall`-wrapped; `listProjects()` só extrai id/name/transportEnabled, igual ao Kotlin). Plugado em `AppEnvironment.live()` (`ProjectsApiLive(http:)` → `ProjectRepositoryLive(api:)`) e `.preview` (`PreviewProjectRepository` inerte).

15 testes novos: `ProjectDTOCodingTests` (8, decode/encode snake_case + defaults dos 8 campos privados) e `ProjectRepositoryMappingTests` (7, mapeamento + propagação de erro via `FakeProjectsApi`).

**Revisão adversarial (workflow, 3 lentes — fidelidade de DTO, fidelidade de API/repository, wiring+cobertura de testes): 0 achados.** Slice pequeno (~138 linhas Kotlin, sem testes dedicados no Android) extraído por leitura direta em vez de workflow de extração; revisão adversarial confirmou fidelidade total sem necessidade de correções.

**Adiado (slices próprios):** conexão SSE ao vivo (multicast/backoff/NWPathMonitor — background); backend de cookie cifrado/Keychain (segurança); DTOs+APIs+repos de auth/transport/accident.
