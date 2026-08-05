# Spec de porte — Permissões & Diagnóstico

> Especificação para portar a escada de permissões e o diagnóstico do Android para iOS (Swift). É onde a **degradação honesta** do iOS é comunicada — e onde boa parte do modelo Android **colapsa** (isenção de bateria e OEM autostart não existem no iOS).
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta de `permissions/*` + `diagnostics/*` + `MainActivity`/`CheckingApp` (2026-07-15).
> Escopo: escada iOS (**D5**: notificações + localização precisa para iniciar; "Always" recomendado), painel de integridade, `EvaluationLog` (buffer volátil), canais de notificação, wiring do app, e as partes Android-only que somem.
> Cross-ref: gate de início ↔ decisão **D5** em [decision_log.md](decision_log.md) e [port_spec_background_orchestrator.md](port_spec_background_orchestrator.md) §9/§13; consentimento LGPD → auth §6/persistência §8.
> **Sem testes portáveis** (só `EvaluationLogDialogSmokeTest` de instrumentação) → os predicados puros viram **novos XCTests** (§9).

Fontes: [PermissionLadder.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/permissions/PermissionLadder.kt) · [PermissionsInspector.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/permissions/PermissionsInspector.kt) · [EvaluationLog.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/platform/background/diagnostics/EvaluationLog.kt) · [MainActivity.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/MainActivity.kt) · [CheckingApp.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/CheckingApp.kt)

---

## 0. Estado efetivo de permissões e diagnóstico — atualização de 2026-08-04

> **Regra de leitura.** As seções seguintes preservam o baseline Android e os slices históricos. Em conflito,
> este contrato atual prevalece. O perfil `candidate` só foi exercitado por injeção local; `Debug`, `Staging`
> e `Release` continuam em `legacyWithDiagnostics`. Não há telemetria remota, promoção de perfil ou prova
> física do candidato implícita nesta documentação.

### D5 e eligibility observacional

D5 não mudou: `minimumToStartGranted` continua sendo notificações + localização precisa. A nova
`BackgroundLocationEligibility` não substitui `PermissionLadder`, não pede permissões, não lê estado global e
não liga/desliga registros de região ou significant-change. É uma classificação pura, sem chave, projeto ou
coordenada, que expõe:

| Estado | Pré-condições | Avalia em foreground | Prontidão nativa |
|---|---|---:|---|
| `blocked` | falha de contexto, toggle, projeto, consentimento, serviços, autorização ou precisão | não | `notReady` |
| `foregroundOnly` | gates válidos + `When In Use` + precisão exata | sim | `notReady` |
| `operational` | gates válidos + `Always` + precisão exata | sim | `readyForCoreLocation` |

Background App Refresh é um sinal independente do timer (`available`, `degradedDenied` ou
`degradedRestricted`); ele não manda parar regiões. Low Power é aviso, não bloqueio novo. Nenhum desses
sinais promete wake, periodicidade, entrega pelo sistema ou recuperação após force-quit. A política foi
coberta por 1.536 combinações puras, mas ainda é observacional: aplicar start/stop é condicional a uma fase e
decisão posteriores.

### Journal técnico privado

Além do `EvaluationLog` legado, existe `DurableEvaluationJournal` v1, ator separado do ActivityLog/Core Data,
em `Application Support/BackgroundReliability/evaluation-journal-v1.json`. O arquivo usa escrita atômica,
proteção `completeUntilFirstUserAuthentication`, retenção de no máximo 500 records ou 30 dias e limite de
2 MiB. `begin`/`advance`/`coalesce`/`finish` são monotônicos/exatamente uma vez. Registros iniciados por outro
processo tornam-se `abandoned`; corrupção, schema desconhecido ou arquivo oversized são isolados, e arquivo
protegido/indisponível é preservado para retry seguro em vez de ser apagado por reflexo.

A allowlist comporta apenas enums fechados de trigger/estágio/terminal, buckets de precisão/idade/duração,
timestamp local, flags de monitor/cena/launch, contagens de wake/owner e classes sanitizadas de HTTP/CLError.
Ela proíbe coordenada, altitude, velocidade, local, projeto, usuário, chave, senha, cookie, token, body,
header, URL, `clientEventId`, `eventTime`, identifier/token de região e erro cru. `LocationSample` não é
serializável pelo journal. Os paths novos não usam `String(describing:)` nem `localizedDescription` para
diagnóstico.

O snapshot técnico de geofence contém somente geração e contagens `requested`, `confirmed`, `failed`/códigos
em whitelist, `omitted`, `pending`, `confirmationUncertain` e `inheritedUnknown`; nenhum ID físico/lógico,
token, local ou coordenada. A mensagem humana existente `Geofences registered (N).` continua byte-exact e
representa somente `requested`. Não houve aprovação para acrescentar mensagens humanas/localizadas por
callback; detalhes ficam no journal e na validação DEBUG.

### Retenção, wipe e exportação

`clear()` do journal/recorder é idempotente e tolera arquivo ausente/protegido. Wipe local primeiro invalida
e leva a automação à quiescência, depois limpa journal, recorder DEBUG, ActivityLog, EvaluationLog,
credenciais, preferências e a fila offline existente. Delete remoto repete a limpeza **somente depois** de
sucesso aceito; falha ou 409 preserva sessão e dados. Não há regra nova para remover um evento da fila por
uma resposta de submit indeterminada.

A decisão vigente de exportação é **DEBUG-only**: `PhysicalValidationScreen` oferece gesto explícito para um
snapshot bounded de até 500 records do journal e 500 eventos do recorder. O JSON sanitizado é criado em
diretório temporário controlado, com cleanup em conclusão/cancelamento do compartilhamento e ao sair da tela.
Não há exportação em launch/background/harness, botão ou share sheet em Staging/Release, upload ou telemetria.
Qualquer superfície de produção exige aprovação de produto, privacidade, localização e testes de
acessibilidade separados. O journal local, por si, não motivou alteração de `PrivacyInfo.xcprivacy`.

### Evidência e limite

Os testes locais cobrem retenção, corrupção, arquivo protegido/ausente, orphan, wipe, export explícito,
cleanup e sentinelas de privacidade. A regressão integrada mais recente teve 1.156 testes unitários Debug e
28 UI; o harness do Simulator terminou com 47 eventos sanitizados. Isso não é ensaio físico candidato nem
prova de BGTask, energia, localização em hardware ou entrega do SO.

## 1. A escada de autorização iOS (D5)

O Android tem 5 passos; no iOS **3** sobrevivem e **2 colapsam**:

| Passo Android | iOS | Status |
|---|---|---|
| 1. `POST_NOTIFICATIONS` | `UNUserNotificationCenter.requestAuthorization` — **obrigatório em toda versão** de iOS (sem atalho "pré-13 = true") | mantém |
| 2. `FINE_LOCATION` (precisa) | `CLLocationManager` **When In Use** + **precisão total** (`fullAccuracy`) | mantém |
| 3. `BACKGROUND_LOCATION` ("Allow all the time") | `CLLocationManager` **Always** (upgrade whenInUse→always em 2 etapas) | mantém (recomendado) |
| 4. `BATTERY_OPTIMIZATION` (isenção de Doze) | **NÃO existe** — Low Power Mode é read-only (`ProcessInfo.isLowPowerModeEnabled`), não há isenção | **colapsa** |
| 5. `OEM_GUIDANCE` (autostart Samsung/Xiaomi/…) | **NÃO existe** — sem OEM autostart no iOS | **colapsa** |

**Escada em contexto** (plano §12.1), nunca tudo no primeiro launch:
1. explicar privacidade + benefício interno;
2. notificações ao habilitar avisos/automático;
3. localização **"Durante o Uso"** no primeiro uso; validar em foreground;
4. ao habilitar automático, explicar segundo plano e pedir **"Always"** em etapa separada;
5. explicar precisão exata; tratar precisão reduzida;
6. câmera/microfone **só** ao iniciar gravação de acidente.

> **D5 — gate de início**: `minimumToStartGranted = notificações + localização precisa (When In Use fullAccuracy)`. "Always" e Low Power = **recomendados, não bloqueantes**. Ausência → aviso de "confiabilidade reduzida", **nunca** bloquear. **Ressalva iOS**: region monitoring / significant-change **exigem "Always"** — sem ela o motor roda em **modo degradado (foreground-only)**; a estrutura do gate espelha o Android, mas a capacidade real de background depende de "Always".

## 2. Estado da escada (`PermissionLadderStatus` → Swift)

```swift
enum LadderStep { case notifications, preciseLocation, alwaysLocation }   // (bateria e OEM removidos)

struct PermissionLadderStatus {
    let notificationsGranted: Bool
    let preciseLocationGranted: Bool      // When In Use + fullAccuracy
    let alwaysLocationGranted: Bool       // Always

    // D5 — mínimo para INICIAR/manter o motor: notificações + precisa. Always = recomendado (não bloqueia).
    var minimumToStartGranted: Bool { notificationsGranted && preciseLocationGranted }
    // Todas as recomendadas → confiabilidade de background plena.
    var allRecommendedGranted: Bool { notificationsGranted && preciseLocationGranted && alwaysLocationGranted }
    // Primeiro passo não satisfeito, em ordem.
    var nextStep: LadderStep? {
        if !notificationsGranted { return .notifications }
        if !preciseLocationGranted { return .preciseLocation }
        if !alwaysLocationGranted { return .alwaysLocation }
        return nil
    }
}
```
> **Não portar**: `batteryOptExempt`, `oemGuidanceShown`, `detectOemType`, `oemAutostartIntent`, `canDeepLinkToOemAutostart`, `launchOemAutostartSettings`, `launchBatteryOptimizationRequest`, e o `allRequiredGranted` (alias depreciado). Launchers Android (`launchLocationSettings`/`launchAppNotificationSettings`) → `UIApplication.open(UIApplication.openSettingsURLString)` (o iOS só abre a página de Ajustes do app, sem deep-links por permissão). **Reintroduzir background exige ir a Ajustes** (como no Android 11+ para "Always").

## 3. Inspector → sinais de saúde (`PermissionsInspector` → iOS)

```swift
enum LocationStatus { case precise, imprecise, denied }   // iOS: fullAccuracy / reducedAccuracy / denied|restricted
struct PermissionsStatus {
    let location: LocationStatus
    let cameraMicGranted: Bool            // AVCaptureDevice camera + microfone
    let notificationsGranted: Bool
    let alwaysLocationGranted: Bool        // "backgroundGranted" Android
    let lowPowerMode: Bool                 // substitui "batteryRestricted" (read-only)
    // REMOVIDO: autoStartEnabled (sem OEM autostart no iOS → tratar como sempre-satisfeito/ausente)
}
```
- `location`: `precise` (`CLLocationManager.accuracyAuthorization == .fullAccuracy` + autorizado) / `imprecise` (`.reducedAccuracy`) / `denied`.
- `autoStartEnabled` do Android **some** — não mostrar linha fantasma no painel.
- `batteryRestricted` (não-isento) → **`lowPowerMode`** (só leitura; não há isenção a solicitar).

## 4. Painel de integridade (plano §12.3) — degradação observável

A tela de atividades automáticas mostra **separadamente** (verde/laranja/vermelho):
- consentimento interno (LGPD, `backgroundLocationConsentAt`);
- Localização habilitada no sistema; autorização **Durante o Uso / Sempre**; **precisão exata/reduzida**;
- notificações autorizadas; **Atualização em 2º Plano** disponível (`UIApplication.backgroundRefreshStatus`); **Modo Pouca Energia**;
- automático habilitado (servidor/local); **pausa ativa + próxima transição**;
- snapshot técnico de regiões: `requested`/`confirmed`/`failed`/`omitted`/`pending`/uncertain (contagens,
  sem IDs), além da mensagem humana histórica de requested;
- horário + resultado da última avaliação (`EvaluationLog`); **fila offline pendente**;
- necessidade de **abrir Ajustes**.

> **NUNCA** haverá instrução sobre "autostart" ou "ignorar otimização de bateria" — esses controles Android **não existem** no iOS (plano §12.3). O painel deve refletir só o que o iOS oferece.

## 5. `EvaluationLog` — ring buffer volátil legado

```swift
enum EvaluationOutcome { case submitted, noAction, skip, paused, networkError, toggleOff }
struct EvaluationEntry { let at: Date; let trigger: OrchestratorTrigger; let accuracyMeters: Double?; let resolvedLocal: String?; let decidedAction: String?; let outcome: EvaluationOutcome }

actor EvaluationLog {                    // @Synchronized → actor-isolado (thread-safe)
    static let shared = EvaluationLog()
    private var ring: [EvaluationEntry] = []
    private let max = 50
    func record(_ e: EvaluationEntry) { ring.append(e); if ring.count > max { ring.removeFirst() } }
    func snapshot() -> [EvaluationEntry] { ring.reversed() }   // newest-first
    var isEmpty: Bool { ring.isEmpty }
}
```
- **Volátil por design** (MAX=50, perdido na morte do processo) e thread-safe. Ele continua como buffer
  legado de UI; persistência técnica de avaliação é responsabilidade separada do `DurableEvaluationJournal`
  descrito em §0, não uma alteração deste buffer.
- `EvaluationOutcome`: `submitted`/`noAction`/`skip`/`paused`/`networkError`/`toggleOff` — gravado pelo orquestrador em cada run (background spec §2).

## 6. Canais de notificação → categorias iOS

Android cria 2 canais (`CheckingApp.createNotificationChannels`): `auto_activities_service` (IMPORTANCE_LOW, non-badging, notificação **ongoing** do FGS) e `auto_activities_events` (IMPORTANCE_DEFAULT). No iOS:
- `auto_activities_events` → `UNNotificationCategory` (interruption level `.active`/`.timeSensitive` conforme o caso; acidente pode justificar `.timeSensitive`).
- `auto_activities_service` → **não há equivalente** (iOS não tem notificação persistente de foreground-service). A semântica "ongoing enquanto rodando" **some**; o iOS usa o indicador de localização do sistema + Background Modes (background spec §9). Redesenhar em torno disso.
- Autorização de notificações pedida **em contexto** (não no launch); `UNNotificationCategory`/ações; deep-links autenticados/validados; dedup; cooldown de reauth 1h; conteúdo localizado; nada sensível na tela bloqueada.

## 7. Wiring do app (`MainActivity` / `CheckingApp` → iOS)

- `MainActivity` (single activity, splash via `installSplashScreen`, edge-to-edge, `CheckingTheme` + `CheckingNavHost`) → **`CheckingApp: App`** (SwiftUI) com o splash (spec de UI §10) e a navegação; edge-to-edge é o default no iOS (respeitar safe areas).
- `CheckingApp` (Hilt root, WorkManager config, `createNotificationChannels`, `logSystem("App started.")`) → **`AppDelegate`/`App`**: registrar identificadores `BGTaskScheduler` **antes do fim do launch** (background spec §E), registrar categorias de notificação, `activityLogger.logSystem("App started.")` (persistência spec §4), e a composição de dependências (`AppEnvironment` — plano §6, sem singleton mutável global).

## 8. O que NÃO tem equivalente iOS (comunicar como degradação, nunca prometer)

`START_STICKY`, boot irrestrito, restart pós-force-quit, wake lock, isenção de otimização de bateria, OEM autostart, timer garantido de 15min, alarme exato — **nenhum** tem equivalente público. Se o usuário força o encerramento, desliga Localização, desliga Atualização em 2º Plano, ou nega "Always"/precisão exata, o painel **deve** dizer que a automação está degradada/indisponível (plano §3.4/§9.10).

## 9. Obrigações de teste (novos XCTests — só predicados puros são portáveis)
- **`minimumToStartGranted` (D5)**: notif+precisa → true; falta qualquer → false; "Always" ausente não afeta.
- **`allRecommendedGranted`**: só true com notif+precisa+always.
- **`nextStep`**: ordem notifications → preciseLocation → alwaysLocation → nil.
- **`inspect` mapping**: fullAccuracy→`precise`, reducedAccuracy→`imprecise`, negado→`denied`; cameraMic; lowPowerMode; sem linha de autostart.
- **`EvaluationLog`**: ring cap 50 (o 51º empurra o mais antigo); `snapshot` newest-first; `isEmpty`. (Nos testes, resetar por teste — é singleton global.)

## 10. Checklist histórico de slices iniciais
- [x] **D5**: gate = notificações + localização precisa (When In Use fullAccuracy); "Always"/Low Power recomendados, não bloqueiam. (`PermissionLadderStatus.minimumToStartGranted`, `AutomationHealthLevel` — §12)
- [x] Escada iOS de 3 passos (notif, precisa, always); **remover** bateria e OEM autostart (e seus deep-links/alias). (§12)
- [x] `nextStep` na ordem; launchers → só `openSettingsURLString` (`UIKitSettingsOpener`); background exige ir a Ajustes.
- [x] Inspector: `precise/imprecise/denied` por `accuracyAuthorization`; `autoStartEnabled` removido; `batteryRestricted`→`lowPowerMode` (read-only). (§12)
- [~] Painel de integridade: a LÓGICA (sinais + severidades + degradação, `HealthReport`) está feita e testada; a **tela SwiftUI** e o coletor async ficam para o slice de UI (deve espelhar `AutoActivitiesDialog.kt`). **sem** linha de autostart/bateria (não existem no modelo). (§12)
- [x] `EvaluationLog` ring 50 newest-first, thread-safe (class+NSLock, equivalente ao `@Synchronized`); **volátil** por design, fiel ao Kotlin (persistência não adotada — decisão registrada). (slice do orquestrador)
- [~] Canais → categorias/interruption levels: `service` ongoing **some** (já documentado); `UNNotificationCategory`/interruption levels + requisição-em-contexto ficam para o slice de UI/notificações. (§12 — deferido explícito)
- [x] Wiring: `BGTaskScheduler` registrado no launch; `logSystem("App started.")`; `AppEnvironment` (sem singleton global mutável). (categorias de notificação deferidas, acima)
- [x] Não prometer o que o iOS não garante; `AutomationHealthLevel` (blocked/degradedForeground/operational) comunica cada fronteira. (§12)
- [x] Novos XCTests dos predicados puros verdes (37: escada, inspector, health level, severidades, needsOpenSettings).

## 11. Constantes
`EvaluationLog MAX = 50` · escada iOS 3 passos · `minimumToStartGranted = notif && precisa` (D5) · canais Android `auto_activities_service` (LOW, ongoing — some no iOS) / `auto_activities_events` (DEFAULT) · cap de regiões `20` (background spec).

## 12. Implementação — escada + lógica do painel (slice, 2026-07-17)

Port de PermissionLadder.kt + PermissionsInspector.kt. **Escopo:** toda a lógica auditável e testável; a **tela SwiftUI** do painel e o **fluxo de requisição em contexto** ficam para o slice de UI (não há camada SwiftUI ainda, e a tela deve espelhar o `AutoActivitiesDialog.kt` — fidelidade de layout).
- ✅ **`PermissionLadderStatus`** (Domain, puro): 3 passos iOS (`notifications`/`preciseLocation`/`alwaysLocation`); `minimumToStartGranted` (D5), `allRecommendedGranted`, `nextStep`. Bateria + OEM autostart + alias `allRequiredGranted` e todos os launchers de OEM/bateria **removidos** (colapsam no iOS).
- ✅ **`PermissionsStatus`** (Domain, puro): `LocationStatus` (precise/imprecise/denied) derivado de `LocationAuthorization` × `preciseAccuracy`; `NotificationAuthorization` como **enum** (não Bool — ver revisão); `lowPowerMode` (read-only, substitui `batteryRestricted`); **sem** `autoStartEnabled` (nada de linha-fantasma). Deriva a escada (fonte única).
- ✅ **`AutomationHealthLevel`** (peça central, puro): a degradação honesta — `blocked` (mínimo D5 não concedido) / `degradedForeground` (mínimo OK mas sem "Always" ou sem Atualização em 2º Plano) / `operational`. Low Power **não** rebaixa (recomendado-não-bloqueante), só vira aviso. + `HealthReport` (severidades por sinal + `needsOpenSettings`).
- ✅ **`PermissionsInspectorLive`** (Platform, integração — não testada por unidade): lê CoreLocation/UNUserNotificationCenter/AVFoundation/`ProcessInfo.isLowPowerModeEnabled`/`UIApplication.backgroundRefreshStatus`. `UIKitSettingsOpener` (só `openSettingsURLString` — o iOS não deep-linka por permissão). Plugados no `AppEnvironment` (`.live()` real, `.preview` inerte). Mapeamentos estáticos puros testados.
- 37 testes novos (`PermissionLadderTests` 11, `PermissionsStatusTests` 13, `AutomationHealthTests` 13). Total 488 verdes.

**Revisão adversarial (3 lentes): 1 CONFIRMED corrigido, 3 refutados.**
- ✅ **MEDIUM** — `needsOpenSettings` não roteava notificações **negadas** p/ Ajustes: modeladas como `Bool`, não distinguiam "negado" (só resolvível em Ajustes) de "não perguntado" (in-app). Um usuário que negou notificações ficava `blocked` com linha vermelha e **sem** remédio. Corrigido: `NotificationAuthorization` virou enum (igual à localização), `needsOpenSettings` roteia `.denied` p/ Ajustes; +2 testes de regressão.
- ↩️ Refutados: categorias de notificação/interruption levels não implementados (deferido ao slice de UI/notificações; item de checklist honestamente aberto, não falso-feito); `EvaluationLog` volátil (fiel ao Kotlin, que é explicitamente volátil); `EvaluationLog` como class+NSLock em vez de `actor` (funcionalmente equivalente e síncrono como o `@Synchronized` do Kotlin).

**Deferido para o slice de UI (honesto, a rastrear):** a tela SwiftUI do painel de integridade (fiel ao `AutoActivitiesDialog.kt`), o sequenciador de REQUISIÇÃO da escada (pedir permissões em contexto), o coletor async do `HealthReport` (assembla inspector + `GeofenceRegionManager.lastSummary` + `OfflineCheckQueue.size()` + prefs de consentimento/pausa + `EvaluationLog`), `UNNotificationCategory`/interruption levels, e a exposição da "próxima transição de pausa" (`nextPauseTransition` hoje nil — precisa de plumbing do `ScheduledPause`).
