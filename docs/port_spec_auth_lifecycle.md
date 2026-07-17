# Spec de porte — Autenticação & ciclo de conta (CheckViewModel)

> Especificação executável para portar a máquina de estado de autenticação/conta do Android (Kotlin) para iOS (Swift), com fidelidade 1:1.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta do `CheckViewModel` (1545 linhas) + apoios + auditoria (2026-07-14).
> Escopo: chave, senha (criar/verificar/trocar), consulta de status, autocadastro + aprovação, auto-login, relogin silencioso, expiração de sessão, exclusão de conta, persistência multi-conta.
> Fora de escopo (cross-ref): decisão automática → [port_spec_decision_engine.md](port_spec_decision_engine.md); fila offline do `onSubmit` → [port_spec_offline_replay.md](port_spec_offline_replay.md); gate de permissões/engine → decisão **D5** em [decision_log.md](decision_log.md).

Fontes: [CheckViewModel.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/check/CheckViewModel.kt) · [CheckUiState.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/check/CheckUiState.kt) · [AuthRepositoryImpl.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/repository/AuthRepositoryImpl.kt) · [AuthApi.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/api/AuthApi.kt) · [AuthDtos.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/dto/AuthDtos.kt) · [AuthModels.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/model/AuthModels.kt) · [ClientStateFunctions.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/clientstate/ClientStateFunctions.kt) · [PasswordRules.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/clientstate/PasswordRules.kt) · [PersistedSettings.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/domain/clientstate/PersistedSettings.kt) · [SecurePasswordStore.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/data/local/SecurePasswordStore.kt)

---

## 1. Arquitetura alvo

| Kotlin | Swift | Nota |
|--------|-------|------|
| `CheckViewModel : ViewModel` + `StateFlow<CheckUiState>` | `@Observable @MainActor final class CheckViewModel` | estado imutável publicado no MainActor |
| `viewModelScope.launch` | `Task { }` (armazenadas para cancelar) | jobs: `passwordVerifyTask`, `checkSseTask`, `pendingApprovalPollTask` |
| funções puras (`clientstate`) | funções livres (Domain) | 1:1 |
| `AuthRepository` (interface) | `protocol AuthRepository` | injetável |
| `AppPreferencesDataSource` (DataStore) | store de preferências tipado (UserDefaults/arquivo) | chaves e defaults idênticos |
| `SecurePasswordStore` (EncryptedSharedPreferences) | Keychain (por-chave) | ver §5 |

O `CheckViewModel` é o **coração** e mistura auth + história + projetos + auto-atividades. Esta spec cobre a fatia **auth/conta**; as demais têm specs próprias.

## 2. Modelo

```swift
struct AuthStatus: Equatable {          // domínio (AuthModels.kt)
    let found: Bool
    let chave: String
    let hasPassword: Bool
    let authenticated: Bool
    let message: String
    var pendingApproval: Bool = false   // autocadastro aguardando aprovação (sem User ainda)
    var queueFull: Bool = false         // fila de aprovação cheia (transitório; só do selfRegister)
}

enum NotificationTone { case none, info, success, error, teal }
enum CheckDialog { case passwordChange, selfRegistration, settings, autoActivities, scheduledPause, notifications, evaluationLog, history, activities }
```

**Flags derivadas** (em `CheckUiState`): `isAuthenticated = authStatus?.authenticated == true`; `isFound`; `hasPassword`; `isAwaitingApproval = authStatus?.pendingApproval == true`. Todas `false` quando `authStatus == nil`.

**DTOs (Codable) — contrato snake_case pt** (`@SerialName` → `CodingKeys`):

```swift
struct WebPasswordStatusResponse: Codable {
    let found: Bool; let chave: String
    let hasPassword: Bool          // has_password
    let authenticated: Bool; let message: String
    var pendingApproval: Bool = false   // pending_approval
    enum CodingKeys: String, CodingKey { case found, chave, hasPassword = "has_password", authenticated, message, pendingApproval = "pending_approval" }
}
struct WebUserSelfRegistrationResponse: Codable {  // status é a fonte da verdade
    let ok, authenticated, hasPassword: Bool        // has_password
    let message: String
    var status: String = "registered"               // "registered" | "pending" | "queue_full"
    var pendingApproval: Bool = false               // pending_approval
    var queueFull: Bool = false                     // queue_full
    var projects: [String] = []
    var activeProject: String = ""                  // active_project
}
// Requests: senha, confirmar_senha, senha_antiga, nova_senha, projeto, projetos, nome, email.
```
> **Defaults obrigatórios:** `pending_approval`/`queue_full`/`status="registered"` têm default. O servidor pode omiti-los; o Swift `Codable` precisa de defaults (custom `init(from:)` ou `decodeIfPresent`). ⚠️ campos opcionais de request enviados como `null` explícito quando o backend exige (ver §8.1 do plano).

## 3. Funções puras (`ClientStateFunctions.kt` + `PasswordRules.kt`)

```swift
// chave: uppercase → remove tudo fora [A-Z0-9] → primeiros 4. null/"" → "". Resultado 0..4.
func sanitizeSettingsChave(_ value: String?) -> String {
    let up = (value ?? "").uppercased()
    let stripped = up.replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)
    return String(stripped.prefix(4))          // uppercase ANTES do regex
}

// CRIAR senha: 3..10 (inclusivo) E trim não-vazio.
func isPasswordLengthValid(_ pw: String?) -> Bool {
    let raw = pw ?? ""
    return (3...10).contains(raw.count) && !raw.trimmingCharacters(in: .whitespaces).isEmpty
}
// VERIFICAR senha (gate do debounce): 1..10. SEM mínimo 3, SEM trim. Mais frouxa de propósito.
func isPasswordVerificationInputValid(_ pw: String?) -> Bool { (1...10).contains((pw ?? "").count) }
```

**`splitNotificationMessage`** (usado no split de 62 chars das notificações — port cuidadoso do índice):

```swift
struct NotificationMessageSplit: Equatable { let primary: String; let secondary: String }

func splitNotificationMessage(_ message: String?, maxPrimaryLength: Int = 62) -> NotificationMessageSplit {
    let limit = maxPrimaryLength > 8 ? maxPrimaryLength : 62
    let rawText = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if rawText.isEmpty { return .init(primary: "", secondary: "") }

    // linhas explícitas: split \r?\n, trim, remove vazias
    let lines = rawText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if lines.count > 1 { return .init(primary: lines[0], secondary: lines.dropFirst().joined(separator: " ")) }

    let normalized = rawText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    if normalized.count <= limit { return .init(primary: normalized, secondary: "") }

    // splitIndex = último espaço em índice <= limit; se < floor(limit*0.55), primeiro espaço em índice >= limit; senão limit.
    var splitIndex = lastSpaceIndex(normalized, atMost: limit)        // Kotlin lastIndexOf(' ', limit)
    if splitIndex < Int(Double(limit) * 0.55) {                       // truncamento p/ zero (62→34)
        splitIndex = firstSpaceIndex(normalized, from: limit)         // Kotlin indexOf(' ', limit)
    }
    if splitIndex == -1 { splitIndex = limit }
    let primary = String(normalized.prefix(splitIndex)).trimmingCharacters(in: .whitespaces)
    let secondary = String(normalized.dropFirst(splitIndex)).trimmingCharacters(in: .whitespaces)
    return .init(primary: primary, secondary: secondary)
}
```
> ⚠️ **Índices por UTF-16:** o Kotlin `length`/`indexOf` operam em unidades UTF-16; para strings ASCII (todos os vetores de teste) `String.count`/offset de `Character` bastam, mas para textos com acento/emoji use offsets de `String.UTF16View` para casar exatamente. Nenhum caractere é perdido — só um espaço é consumido na fronteira.

**Multi-conta por chave** (`PersistedSettings.kt`): `resolvePersistedPassword`/`withPersistedPassword` (mapa `[chave: String]`, gate `sanitizeSettingsChave(chave).count == 4`, valida com `isPasswordLengthValid`) e `resolvePersistedUserSettings`/`withPersistedUserSettings` (mapa `[chave: UserSettings?]`, com `defaults` e normalização de projetos). Portar 1:1 — são a base do "trocar de chave restaura outro conjunto". `UserSettings` defaults: `scheduledPauseEnabled=true, from="20:00", to="07:00", suspendSaturdays/Sundays=true, notify*=true`.

Também puras: `normalizeProjectValue(value, allowed, fallback)` (trim+uppercase; retorna se em `allowed`, senão `fallback`); `autofillPetrobrasEmailDomain` (`x@` → `x@petrobras.com.br`).

## 4. Repositório e mapeamento DTO→domínio

```swift
protocol AuthRepository {
    func getStatus(_ chave: String) async -> AppResult<AuthStatus>
    func login(_ chave: String, _ password: String) async -> AppResult<AuthStatus>
    func logout() async -> AppResult<Void>
    func deleteAccount() async -> AppResult<Void>              // LGPD art. 18
    func registerPassword(_ chave: String, _ project: String?, _ password: String) async -> AppResult<AuthStatus>
    func changePassword(_ chave: String, _ oldPassword: String, _ newPassword: String) async -> AppResult<AuthStatus>
    func selfRegister(_ chave: String, _ nome: String, _ projetos: [String], _ email: String?, _ password: String, _ confirmPassword: String) async -> AppResult<AuthStatus>
    func getHistory(_ chave: String) async -> AppResult<HistoryState>
}
```

Regras de mapeamento (fidelidade):
- **`getStatus`**: mapeia 1:1; `queueFull` **não** é setado (fica default `false`).
- **`selfRegister`**: `found = (response.status == "registered")` — **não** de um campo `found`/`ok`. Só o literal `"registered"` dá `found=true`; `"pending"`/`"queue_full"` dão `found=false`. `chave` vem do **argumento**, não do DTO. Também mapeia `authenticated`, `hasPassword`, `pendingApproval`, `queueFull`.
- **`login`/`registerPassword`/`changePassword`**: `found = true` fixo; mapeiam `authenticated`/`hasPassword`/`message`.
- **`logout`**: engole exceção do POST, **sempre** limpa o cookie, **sempre** retorna `.success`.
- **`deleteAccount`**: limpa o cookie **só** em `.success` (um **409/Conflict** — admin/abridor de acidente — mantém a conta e a sessão). Retorna o resultado real (`.map { () }`).
- **`getHistory`**: parseia timestamps ISO-8601 com fallback `nil`.

Endpoints (`AuthApi`): `GET auth/status?chave=` · `POST auth/register-password` · `POST auth/register-user` · `POST auth/login` · `POST auth/logout` (sem body) · `POST auth/change-password` · `POST auth/delete-account` (sem body — auth via cookie).

## 5. Persistência

**Preferências** (`AppPreferencesDataSource`) — chaves e defaults **idênticos** (iOS: UserDefaults/arquivo tipado):

| chave DataStore | tipo | default | uso |
|-----------------|------|---------|-----|
| `pref_language` | String | `""` | idioma |
| `pref_chave` | String | `""` | chave persistida (verbatim, sem validação nesta camada) |
| `pref_user_settings_json` | String | `""` | JSON multi-conta `{"HR70":{…}}` (opaco aqui) |
| `pref_transport_local_json` | String | `""` | estado local de transporte |
| `pref_flag_<name>` | Bool | `false` | flags dinâmicas (ex.: `auto_activities_prompt_dismissed_<chave>`) |
| `pref_seen_accident_ids`, `pref_pending_checks_json`, `pref_bg_location_consent_at` | — | — | outras specs |

Contrato: leitura de chave ausente → default; escrita = round-trip **verbatim** (sem trim/parse/normalização); último-write-vence; novo observador recebe o valor atual como 1ª emissão. Multi-conta é camada **superior** (o JSON tem a chave como chave de topo).

**Senhas** (`SecurePasswordStore`): Android `EncryptedSharedPreferences` "checking_passwords", por-chave, valida com `isPasswordLengthValid` na leitura/escrita, `clearAll()`. **iOS: Keychain** (um item por chave, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — legível em background pós-primeiro-desbloqueio; `ThisDeviceOnly` = não migra em backup). `getAllPasswords()` → enumerar itens do serviço.

## 6. A máquina de estado (fluxos do `CheckViewModel`)

Jobs canceláveis: `passwordVerifyTask`, `checkSseTask`, `pendingApprovalPollTask`.

**init**: restaura idioma; lê `pref_chave`; se `count==4` → carrega senha guardada + settings, popula uiState, `isInitializing=false`, `probeStatus`; senão só `isInitializing=false`. *(Só lê `userSettingsJson` quando a chave tem 4 chars — cuidado no port do init.)*

**onChaveChanged(raw)**: `sanitize`; cancela `passwordVerifyTask`; `stopPolling`; `stopStream`; reseta uiState (chave + limpa authStatus/prompt/notif/history/dialog/dismissed); persiste chave; se `count != 4` → `logout()` e retorna; senão carrega senha guardada (seta se não-vazia) + `probeStatus`.

**onPasswordChanged(raw)**: seta `password`; cancela `passwordVerifyTask`; **guarda**: `authStatus != nil && hasPassword && isPasswordVerificationInputValid(raw)`; senão retorna. Senão: `passwordVerifyTask = Task { sleep 800ms; attemptLogin(chave, raw) }` (cancelável a cada tecla).

**probeStatus(chave)** — ordem **crítica**:
1. `logout()` (limpa sessão obsoleta **antes**).
2. `isStatusLoading = true`; `getStatus(chave)`.
3. `.success`: seta `authStatus`+`prompt`. Se `pendingApproval` → barra vermelha `auth.awaitingApproval` (`.error`), **não** abre form, `startPendingApprovalPolling`. Senão → `stopPolling` + `maybeAutoOpenAssistanceDialog` + **auto-login** se `hasPassword && senha-guardada != ""`.
4. `.failure`: `isStatusLoading=false, statusErrored=true`.

**startPendingApprovalPolling(chave)**: no-op se já ativo; loop `while isAwaitingApproval && chave inalterada { sleep 10s; re-guarda; probeStatus }`. **10s** (o KDoc do teste diz 20s — obsoleto; use 10s da fonte).

**resolvePrompt(status)**: authenticated→`""`; hasPassword→`auth.enterPasswordPrompt`; else→`auth.createPasswordPrompt`.

**maybeAutoOpenAssistanceDialog(status)**: retorna se `pendingApproval`; retorna se `dismissedAssistanceForChave == status.chave`; `found && !hasPassword && !authenticated` → abre `passwordChange`; `!found` → abre `selfRegistration` (semeando `chave`).

**attemptLogin(chave, pw)**: guarda `count==4 && verify válido`; notif `status.passwordVerifying` (`.info`); `login` → `.success` authenticated: `setPassword`, `onAuthenticationSucceeded`, log "Signed in."; `.success` não-authenticated: notif = `localizeApiMessage(message)` (`.error`); `.failure` `Unauthorized` → limpa notif (`.none`); outro `.failure` → `status.apiCommunicationFailure` (`.error`).

**onAuthenticationSucceeded**: notif `status.authenticationCompleted` (`.teal`); `ensureEngineRunningIfEligible` (gate D5); carrega history/projects/catalog/locations; calcula nudge; `startCheckStream` (SSE → `refreshCheckState`).

**Autocadastro** (`submitSelfRegistration`): valida nome, email (se não-vazio, contém `@`), senha `3..10`, confirmação, ≥1 projeto; **sempre** `setPassword(chave, senha)` (para o auto-login pós-aprovação); então 3 saídas por `status`:
- `queueFull` → barra `auth.registrationQueueFull` (`.error`), fecha dialog, reseta fields, **não** awaiting/authenticated, **sem** poll.
- `pendingApproval` → barra `auth.awaitingApproval` (`.error`), fecha dialog, reseta fields, `startPendingApprovalPolling`.
- else (`registered`) → `resolvePrompt`, fecha dialog; se `authenticated` → `onAuthenticationSucceeded`.

**Trocar/criar senha** (`submitPasswordChange`): valida old (se `hasPassword`, `3..10`), new (`3..10`), confirm; `changePassword` (se hasPassword) senão `registerPassword`; `.success`: `setPassword`, fecha dialog+dismiss; se authenticated → `onAuthenticationSucceeded`.

**onForegroundResume** — precedência: (1) `isAwaitingApproval` → só re-`probeStatus`; senão (2) `isAuthenticated` → `refreshCheckState` + (se `automaticActivitiesEnabled`) `orchestrator.runOnce(.foreground)`; senão (3) nada.

**handleAuthExpiry** (401/403): `stopStream`; `authStatus.authenticated=false`; limpa flags/notif/userProjects/history/location; `showAutoActivitiesNudge=false`. **Mantém** chave/senha (permite re-entrar).

**deleteAccount** (LGPD art. 18): `deleteAccount()` → `.success`: `AutoActivityController.stop`, `activityLog.clear`, `securePasswordStore.clearAll`, `appPreferences.clearAll`, `stopStream`, `stopPolling`, reset uiState `CheckUiState(isInitializing:false)`; `.failure` `Conflict(409)` → `settings.deleteAccountBlocked`, else `settings.deleteAccountFailed` (`.error`).
> ⚠️ **Lacuna D6 também aqui:** este wipe **não** limpa a fila offline cifrada (nem o `PrivacyViewModel`). O port iOS deve incluir `offlineQueue.clear()` neste fluxo **e** no de privacidade.

## 7. Concorrência e tempo (Swift)

- `@MainActor` no ViewModel; estado publicado via `@Observable`.
- **Debounce** (`onPasswordChanged`): `passwordVerifyTask?.cancel(); passwordVerifyTask = Task { try? await Task.sleep(for: .milliseconds(800)); guard !Task.isCancelled …; await attemptLogin() }`.
- **Polling** (`startPendingApprovalPolling`): `Task` com `while` + `Task.sleep(for: .seconds(10))`, re-checando as guardas; guarda de reentrância (não iniciar se já ativo).
- **Testes** precisam de relógio/scheduler controlável (injetar `Clock`/scheduler) para: (a) não cruzar o `sleep(10s)` do poll, (b) o debounce de 800ms. Ver §9.

## 8. Notificações e i18n (chaves exatas)

Tons: `passwordVerifying`→`.info`; `authenticationCompleted`→`.teal`; sucessos de submit→`.success`; `awaitingApproval`/`registrationQueueFull`/falhas→`.error`; login-`Unauthorized`→`.none`.
Chaves: `auth.awaitingApproval` (pt: "Aguardando aprovação de cadastro."), `auth.registrationQueueFull` (pt: "Fila de cadastro cheia. Informe ao administrador do sistema."), `auth.enterPasswordPrompt`, `auth.createPasswordPrompt`, `status.passwordVerifying`, `status.apiCommunicationFailure`, `status.authenticationCompleted`, `settings.deleteAccountBlocked`, `settings.deleteAccountFailed`. Mensagens do servidor passam por `KnownApiMessages.localizeApiMessage(message, lang)` (ver spec de i18n).

## 9. Mapa de testes Kotlin → Swift XCTest (41 testes)

| Arquivo Kotlin | Alvo Swift | # | Tipo |
|----------------|-----------|---|------|
| `domain/clientstate/ClientStateFunctionsTest.kt` | `ClientStateFunctionsTests` | 19 | puro |
| `data/repository/AuthMappingTest.kt` | `AuthMappingTests` | 6 | mapeamento (fake AuthApi) |
| `presentation/check/SelfRegistrationApprovalTest.kt` | `SelfRegistrationApprovalTests` | 8 | ViewModel (mocks + clock) |
| `presentation/check/CheckViewModelForegroundTest.kt` | `CheckViewModelForegroundTests` | 1 | ViewModel |
| `data/local/AppPreferencesDataSourceTest.kt` | `AppPreferencesStoreTests` | 7 | persistência (store real/temp) |

### 9.1 `ClientStateFunctionsTests` (puro)
- `sanitizeSettingsChave`: "ab12"→"AB12"; "AB-12!"→"AB12"; "ABCDEFGH"→"ABCD"; nil→""; ""→""; "a1-b2#"→"A1B2".
- `isPasswordLengthValid`: "abc"/"abcdefghij"→true; "ab"/nil/""→false; "abcdefghijk"(11)→false.
- `isPasswordVerificationInputValid`: "x"/"abcdefghij"→true; ""/nil→false.
- `normalizeProjectValue`: "alpha"∈["ALPHA","BETA"]→"ALPHA"; "GAMMA"→fallback "ALPHA"; nil→fallback.
- `splitNotificationMessage`: "Hello"→(primary="Hello",""); nil→("",""); "Line one\nLine two\nLine three"→("Line one","Line two Line three"); linha de 76 chars→primary.count≤62 & `(primary+" "+secondary).trim()==msg` (resultado concreto: primary len 60, secondary="character limit"); ""→("",""); "A"×62→(msg,"").

### 9.2 `AuthMappingTests` (fake `AuthApi`, casts `.success`)
- `getStatus` `pending_approval=true` → `found=false, pendingApproval=true` (`queueFull=false`).
- `getStatus` normal → `found=true, pendingApproval=false`.
- `selfRegister` `status="pending"` → `found=false, pendingApproval=true, queueFull=false`.
- `selfRegister` `status="queue_full"` → `found=false, queueFull=true, pendingApproval=false`.
- `selfRegister` `status="registered"` → `found=true, authenticated=true`.
- (args self-register fixos: chave="NEW1", nome="Nome Completo", projetos=["P80"], email=nil, password/confirm="abc123"; só a saída é asserida.)

### 9.3 `SelfRegistrationApprovalTests` (mocks + clock; `runCurrent` p/ não cruzar o poll)
| test | ação → resultado |
|------|------------------|
| `submit_pending_enters_awaiting_red_bar_password_stored_not_authenticated` | selfRegister→pending ⇒ `isAwaitingApproval`, notif `auth.awaitingApproval`/`.error`, `!isAuthenticated`, `canSubmit==false`; **`setPassword("NEW1","abc123")` chamado**; `getHistory`/`orchestrator.runOnce` **0×**; dialog fechado, `dismissed="NEW1"`, fields resetados |
| `submit_queue_full_red_message_not_awaiting_not_authenticated` | selfRegister→queue_full ⇒ notif `auth.registrationQueueFull`/`.error`, `!isAwaitingApproval`, `!isAuthenticated`; `setPassword` chamado; sem poll |
| `probe_pending_enters_awaiting_and_blocks_submit` | `onChaveChanged("PND1")`+`runCurrent` ⇒ `isAwaitingApproval`, notif awaiting, `canSubmit==false` |
| `approval_found_true_triggers_login_with_stored_password` | `getPassword("APR1")="pw1234"`; status found=true,hasPassword=true ⇒ `login("APR1","pw1234")` chamado; `!isAwaitingApproval` |
| `unknown_key_autoopens_registration_silently` | status !found, sem senha ⇒ `dialogOpen==selfRegistration` (chave semeada), `!isAwaitingApproval`, notif `.none`/"" |
| `dismiss_sets_guard_and_does_not_reopen_on_foreground` | `dismissDialog` ⇒ `dialogOpen=nil`+`dismissed="UNK2"`; `onForegroundResume` (não auth/não awaiting) ⇒ segue fechado |
| `restart_with_stored_pending_key_reconstructs_awaiting` | `pref_chave="RST1"`, status pending, init via `runCurrent` ⇒ `isAwaitingApproval` |
| `awaiting_foreground_resume_reprobes_without_running_orchestrator` | awaiting + `onForegroundResume` ⇒ `orchestrator.runOnce` **0×** (só re-probe) |

### 9.4 `CheckViewModelForegroundTests`
- `onForegroundResume_when_not_authenticated_does_not_run_orchestrator`: `authStatus=nil` ⇒ `orchestrator.runOnce` **0×**.

### 9.5 `AppPreferencesStoreTests` (store real/temp; observação assíncrona)
- `language`/`chave` default `""` e round-trip ("zh"/"en"; "HR70").
- `userSettingsJson`/`transportLocalJson` round-trip **verbatim** (comparar string, não objeto): `{"HR70":{"projects":["PROJ1"],"activeProject":"PROJ1","automaticActivitiesEnabled":true}}` e `{"HR70":{"dismissed":["req-1"],"realized":[]}}`.
- `flag` default `false` e round-trip; `flag_a`/`flag_b` independentes (`pref_flag_flag_a`/`_b`).
- `overwriting chave`: escreve "AA00" então "BB11", observa depois ⇒ vê só "BB11".

## 10. Fixtures / doubles
- Mocks relaxados para todos os repos/stores; **`getPassword(chave)` default `""`** (sem isso, auto-login dispara em probes inesperados — os testes dependem disso).
- `clock.now()` fixo (`Instant.EPOCH` no foreground test).
- Builders: `status(found,hasPassword,authenticated,pendingApproval,queueFull,chave="NEW1")`, `statusDto(...)`/`selfRegDto(...)` (self-reg: `hasPassword=authenticated`, `projects=["P80"]`, `activeProject = authenticated ? "P80" : ""`), `Project(id,name,transportEnabled)`.
- **Idiomas de tempo:** `advanceUntilIdle` (quiescência — só onde **não** há poll pendente) vs `runCurrent` (não cruza o `sleep(10s)` — para todo caso awaiting/pending). Teardown dos testes awaiting: `onChaveChanged("")` para cancelar o poll antes de drenar, senão o teste trava.

## 11. Checklist de fidelidade
- [x] `sanitizeSettingsChave`: uppercase **antes** do regex; `take(4)`; gate `count==4` em todo lugar.
- [x] Duas regras de senha (`3..10` criar / `1..10` verificar) — usar a correta em cada ponto (a verify gate do debounce).
- [x] Debounce 800ms cancelável; polling 10s com guardas; ambos canceláveis por troca de chave.
- [x] `probeStatus` faz `logout()` **primeiro**.
- [x] `selfRegister.found = (status == "registered")`; `chave` do argumento; 3 saídas (registered/pending/queue_full); senha **sempre** salva.
- [x] `logout` sempre `.success` + limpa cookie; `deleteAccount` limpa cookie **só** em sucesso; **409 mantém sessão**.
- [x] `handleAuthExpiry` mantém chave/senha; wipe do `deleteAccount` inclui **fila offline** — TODO(D6) marcado no código (`offlineQueue.clear()` ainda não ligado — falta plugar no `AppEnvironment`).
- [x] Multi-conta: senhas/settings por chave (JSON/mapa); trocar chave restaura outro conjunto. Keychain real fica p/ slice de segurança.
- [x] Chaves de preferência e defaults idênticos; round-trip verbatim.
- [x] Tons/i18n keys exatos; DTOs com defaults e snake_case.
- [x] 41 testes portados e verdes (+ 3 regressão de revisão + 5 `SecurePasswordStoreTests`).

## 12. Constantes
chave `4` (uppercase alfanum.) · senha criar `3..10` / verificar `1..10` · debounce `800ms` · polling aprovação `10s` (não 20) · split de notificação `62` chars (threshold forward `floor(limit*0.55)=34`) · defaults de pausa `20:00/07:00/Sat/Sun` · `notify*` default on.

## 13. Implementação (slice, 2026-07-16)

Implementado e verde (305 testes): `ClientStateFunctions`/`UserSettings`/`resolveFallbackProjects`/`resolveFallbackActiveProject` (funções puras), `AuthStatus`, DTOs de auth, `AuthApi`/`AuthApiLive`, `AuthRepository`/`AuthRepositoryLive` (mapeamento 1:1), `UserDefaultsPreferencesStore`, `InMemorySecurePasswordStore` (backend cifrado real adiado), `CheckUiState`, `CheckViewModel` (`@Observable @MainActor`, fatia auth completa). Plugado em `AppEnvironment.live()` (`authRepository`, `appPreferences`, `securePasswordStore`) — o `BackgroundCheckOrchestrator` já aceita essas peças reais via seam, mas segue não instanciado no `AppEnvironment` (falta `accidentRepository` + `notifications`).

**Revisão adversarial (16 agentes, 2 rodadas — 1ª parcial por limite de sessão, retry completou): 10 CONFIRMED, 0 refutados.**
- ✅ `onRegEmailChanged` não aplicava `autofillPetrobrasEmailDomain` (helper existia, não era chamado).
- ✅ `loadProjectCatalogForRegistration` sem guard de catálogo-já-carregado (Kotlin evita re-fetch).
- ✅ **[HIGH]** corrida de chave: o `Task` de `onChaveChanged` não era rastreado/cancelado — uma resposta tardia de `probeStatus`/`attemptLogin`/`onAuthenticationSucceeded` para uma chave abandonada podia pisar no estado da chave atual. Fix: `chaveTask` cancelável + guard `uiState.chave == chave` após cada `await` nesses três fluxos (regressão: `test_stale_chave_probe_does_not_clobber_newer_chave_state`, usa `AsyncGate` p/ forçar a corrida).
- ✅ Guarda de reentrância do polling (`pollActive` Bool solto) não amarrada à identidade da task — cleanup tardio de um poller superseded podia apagar o estado de um poller mais novo. Fix: `pollGeneration` (token monotônico).
- ✅ Sem proteção contra retenção indefinida do VM por tasks longas (polling 10s, SSE) — `deinit` não serve em classe `@MainActor` (roda nonisolated, não pode ler propriedades isoladas); fix real foi `[weak self]` nos dois loops longos, lendo via `self?` ANTES do `sleep`/`await` para não reter durante a espera.
- ✅ `resolvePersistedUserSettings`: fallback de projetos não filtrava `defaults.projects` contra `defaults.allowedProjects` nem usava `defaults.project` (singular) — portados `resolveFallbackProjects`/`resolveFallbackProject`/`resolveFallbackActiveProject` 1:1 (bug dormente: nenhum call site real usa `UserSettingsDefaults` não-default hoje).
- ✅ `isPasswordLengthValid`/`normalizeProjectValue(s)`: trim usava `CharacterSet.whitespaces` (não inclui `\n`/`\r`), divergindo do `trim()` Kotlin (`Char.isWhitespace()`, mais amplo) → trocado para `.whitespacesAndNewlines`.
- ✅ `splitNotificationMessage`: split de linha explícita usava `CharacterSet.newlines` (mais amplo que o regex Kotlin `\r?\n` — incluía CR solto e separadores Unicode U+0085/U+2028/U+2029) → split fiel ao `\r?\n` via função dedicada.
- Nota de qualidade de teste (não é bug de produção): os testes originais rodam com fakes sem latência, então não exercitavam corridas reais — coberto agora pelo teste de `AsyncGate` acima.
