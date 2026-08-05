# Execução incremental — confiabilidade de localização em background

> Status geral: **baseline auditado; Prompts 02 a 20 implementados e validados localmente no perfil
> candidato quando aplicável; todos os configs
> distribuíveis permanecem no legado; o pipeline candidato do TIMER usa no máximo uma captura física e o
> wake por mudança significativa pode transportar uma seed opcional, sempre revalidada antes do matcher;
> o candidato mantém um único pending normal bounded e serial e isola cold launch/headless dos efeitos
> remotos da UI; a sessão é serializada e o retry de autenticação é limitado por estágio, sem retry de
> submit enquanto a idempotência server-side não for comprovada; P14 mantém a recuperação automática de
> resposta indeterminada desabilitada; P20 confirmou somente o que Simulator e builds locais permitem;
> não publicado**.
>
> Última atualização: 2026-08-04 — Prompt 20 verde no escopo local conservador, sem commit, instalação
> física, distribuição, credenciais ou upload; as validações server-side e físicas continuam explicitamente
> pendentes.
>
> Privacidade: este documento não deve receber coordenadas, altitude, nomes de locais ou projetos,
> credenciais, chaves, senhas, cookies, tokens APNs, corpos HTTP, URLs completas nem identificadores brutos
> de regiões. Os logs volumosos desta auditoria estão somente em `.build/`, que é ignorado pelo Git.

## 1. Escopo desta atualização

Este relatório preserva o preflight, a baseline e o inventário do Prompt 01, a seleção de perfil do Prompt
02, o journal do Prompt 03, os tipos puros do Prompt 04, o provider do Prompt 05, o seam do Prompt 06 e a
taxonomia operacional do Prompt 07, os terminais duráveis do Prompt 08, a captura única do Prompt 09 e
o transporte opcional da seed de mudança significativa no Prompt 10, o pending normal bounded, os tickets
canônicos e o drain serial do Prompt 11 e o guard mínimo de cold launch/headless do Prompt 12. Agora
registra também a sessão serial e o relogin tipado por estágio do Prompt 13, dentro do escopo parcial
aprovado, as leases/cancelamentos exactly-once do Prompt 14 e o diagnóstico de geofences por geração do
Prompt 15. O estado acumulado adicionou:

- modelos diagnósticos tipados, separados de coordenadas e dos modelos de negócio;
- um actor de journal JSON versionado, atômico, limitado e best-effort, separado do Core Data existente;
- uma implementação no-op para previews/fakes;
- uma única instância viva injetada pelo `AppEnvironment`;
- reconciliação assíncrona de órfãos no launch, sem bloquear callbacks nativos;
- limpeza no wipe local e somente após exclusão remota bem-sucedida;
- testes de lifecycle, idempotência, retenção, corrupção, I/O, concorrência, privacidade e integração;
- um valor de domínio imutável para amostras timestamped, sem dependência de Core Location;
- política pura e determinística de integridade, frescor e comparação de seeds;
- parâmetros de ensaio aprovados de 10 s para idade máxima e 2 s para tolerância futura.
- contrato de captura tipado que transporta `LocationSample` e separa timeout, indisponibilidade, permissão
  e cancelamento;
- máquina de estado pura para seed, batch de callbacks, melhor fix, timeout e first-terminal;
- adapter Core Location e scheduler de timeout confinados ao `MainActor` e injetáveis em teste;
- broker de coalescência com waiters independentes e propagação segura de cancelamento;
- seleção única entre comportamento legado e candidato pelo perfil de build;
- guards cooperativos que impedem matcher, matriz ou submit depois de cancelamento observado;
- orçamento explícito de aquisição `acquire`/`seedCandidate`/`finalSample`;
- etapas separadas e testáveis de aquisição e resolução, com revalidação imediatamente antes do matcher;
- compatibilidade do motor automático por overload que converte todas as chamadas atuais em `.acquire`;
- contexto imutável de submissão em memória, preservando a mesma identidade e o mesmo horário para
  submit e fila `Decided`.
- envelope operacional tipado com resultado legado, estágio máximo, origem/reuso/qualidade sanitizáveis,
  falha por estágio e contexto de submissão somente em memória;
- projeção sanitizada e fechada de `ApiError`, sem destino para `detail` ou `description`;
- efeito offline separado da causa de rede, distinguindo `queuedRaw` e `queuedDecided`;
- resolução tipada de options/state com origem `remote`, `cache` ou `offlineDefault` e eventual falha
  upstream preservada;
- consumo de `execute` pelo orquestrador uma única vez, sem novo retry, relogin, rede, captura, matriz ou
  submit;
- classificação precisa de coalescência: o consumidor adicional mantém a origem real da captura e recebe
  somente `reused = true`.
- um único `begin` e um único `finish` aguardados para toda avaliação admitida, com falha do journal
  estritamente best-effort;
- terminais duráveis e estágio máximo para settings, pausa, options, movimento, state, aquisição, match,
  decisão, submit e tentativa de notificação;
- `EvaluationCompletion` em memória para distinguir uma avaliação admitida de um wake rejeitado pelo
  single-flight existente;
- preservação explícita de efeitos irreversíveis na ordem
  `submitted > queued > submissionOutcomeUnknown > expired > staleContext > cancelled`;
- guards de geração/cancelamento antes do relogin, antes do retry e após os awaits, sem criar uma nova
  política de autenticação;
- adapter que mantém o `EvaluationLog` legado e todas as mensagens humanas existentes sem alteração;
- registro conservador de notificação: o seam fire-and-forget alcança o estágio `notification`, mas
  `notificationScheduled` permanece desconhecido até existir confirmação real do sistema.
- pipeline em fases para o TIMER candidato:
  `preflight → uma captura → movimento → revalidação/match → state quando necessário → matriz/submit`;
- política pura de movimento com limiar estrito
  `distance < max(50 m, 2 × horizontalAccuracyMeters)`;
- baseline candidato somente em memória, proposto durante o gate e confirmado apenas ao final de uma
  avaliação válida; invalidação/cancelamento não o adota e troca de contexto o limpa;
- bypass do skip durante episódio de accuracy retry sem retornar ao fluxo legado nem abrir outra captura;
- retomada do relogin existente por fase, sem recapturar, rematchear ou repetir submit;
- cancelamento cooperativo das operações candidatas de match/complete quando o contexto é invalidado;
- buckets de captura calculados no mesmo instante da revalidação e idade futura classificada como
  desconhecida, não como amostra recente.
- callback opcional de mudança significativa, em que `nil` ainda representa um wake válido sem amostra
  reutilizável;
- conversão de todos os `CLLocation` recebidos para valores `LocationSample` imutáveis antes da travessia
  de atores, com integridade, frescor e comparador aprovados aplicados na fronteira;
- entrada mínima `runOnce(_:seedCandidate:)`, preservando `runOnce(_:)` como wrapper com seed nula e
  mantendo ID, horário de recebimento e gerações sob ownership exclusivo do actor;
- descarte explícito da seed no perfil legado e uso como `seedCandidate` somente no perfil candidato e no
  trigger de mudança significativa;
- revalidação da seed na admissão, com o threshold remoto e novamente no provider/use case antes do
  matcher, sem deduzir local ou ação no delegate;
- driver start/stop/availability injetável apenas como seam determinístico de teste, com defaults
  equivalentes às mesmas APIs de produção;
- classificação por whitelist de erros Core Location e diagnósticos Debug estáticos/sanitizados, sem
  coordenadas, erro cru ou identificador de região.
- um `EvaluationRequest` somente em memória, com ID/horário criados pelo actor, máscara fechada de fontes,
  contadores saturados e seed opcional não persistida;
- uma avaliação running e, no perfil candidato, no máximo um pending normal coalescido para
  TIMER/GEOFENCE/SIGNIFICANT_LOCATION;
- merge puro que promove evento sobre TIMER, conserva seed significativa pelo comparador aprovado e nunca
  transporta region ID, direção, local ou coordenadas para o journal;
- ticket canônico compartilhado e aguardável, sem vetor ilimitado de continuations e sem cancelar trabalho
  comum quando um waiter é cancelado;
- drain serial aprovado na ordem
  `pause transition → pause activation → foreground/pause reconciliation → pending normal → accuracy retry → acidente`;
- geração unificada de contexto e barrier de transição para chave, projeto, auto OFF, consentimento,
  logout e wipe, com quiescência obrigatória antes de apagar stores;
- fresh state obrigatório no follow-up normal, mantendo no máximo uma captura física no TIMER e sem enviar
  amostra vencida ao matcher;
- proteção contra repetir a mesma ação irreversível dentro do ciclo, sem gerar novo ID/submit/fila
  `Decided`; uma ação oposta continua permitida e eventos `Raw` distintos permanecem por avaliação
  canônica;
- serialização por geração dos comandos de geofence, com no máximo um comando executando e um intent
  pending latest-wins;
- callbacks nativos sem lease que aguardam somente a admissão/coalescência; owners de orçamento continuam
  aguardando o terminal canônico.
- seleção coerente de lifecycle da UI pelo mesmo perfil de build: legado preserva o fluxo anterior e
  candidato usa o guard headless, sem executar os dois caminhos;
- restore local separado e sem efeitos remotos, limitado a idioma, chave, credencial somente em memória,
  settings e encerramento de inicialização;
- restore remoto candidato iniciado somente por evidência positiva de cena ativa, single-flight e cercado
  por geração de ativação, identidade e sessão autenticada;
- store coarse de estado da aplicação somente em memória, com revisões monotônicas para impedir que uma
  task antiga de cena sobrescreva uma transição mais nova;
- remoção do resume candidato em `onAppear`, preservando uma única fonte de verdade que cobre primeira
  apresentação já ativa, reativações reais e reconstruções repetidas;
- validação de permissões antes de captura/reconciliação automática no candidato, inclusive quando uma
  permissão é revogada fora do app;
- hidratação autenticada explícita que termina em background fica pendente somente em memória e recomeça
  no próximo active, sem repetir cadastro/troca de senha;
- notificação candidata baseada no estado real da cena no instante terminal; o legado conserva a regra
  anterior por trigger.

Alterações versionáveis acumuladas até esta atualização:

- `Checking/App/BackgroundReliabilityProfile.swift`;
- `Checking/App/AppDelegate.swift`;
- `Checking/App/AppEnvironment.swift`;
- `Checking/App/RootView.swift`;
- `Checking/Features/Check/CheckMainScreen.swift`;
- `Checking/Features/Check/CheckSceneActivationGate.swift`;
- `Checking/Features/Check/CheckViewModel.swift`;
- `Checking/Features/Check/CheckViewModelSeams.swift`;
- `Checking/Data/Persistence/DurableEvaluationJournal.swift`;
- `Checking/Domain/Models/AutomaticActivitiesExecution.swift`;
- `Checking/Domain/Models/LocationSample.swift`;
- `Checking/Domain/Repositories/LocationProvider.swift`;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/Domain/Repositories/SignificantLocationMonitoring.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Domain/UseCases/LocationSamplePolicy.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`;
- `Checking/Platform/Background/EvaluationApplicationStateProvider.swift`;
- `Checking/Platform/Background/EvaluationJournalModels.swift`;
- `Checking/Platform/Background/EvaluationJournaling.swift`;
- `Checking/Platform/Background/EvaluationRequest.swift`;
- `Checking/Platform/Background/MovementGatePolicy.swift`;
- `Checking/Platform/Location/CaptureSessionState.swift`;
- `Checking/Platform/Location/CLLocationManagerLocationProvider.swift`;
- `Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift`;
- `Checking/Platform/Location/GeofenceRegionManager.swift`;
- `Checking/Info.plist`;
- `Config/Debug.xcconfig`;
- `Config/Staging.xcconfig`;
- `Config/Release.xcconfig`;
- `CheckingTests/BackgroundReliabilityProfileTests.swift`;
- `CheckingTests/Auth/CheckMainViewModelTests.swift`;
- `CheckingTests/Auth/CheckSceneActivationGateTests.swift`;
- `CheckingTests/Auth/CheckViewModelHeadlessLifecycleTests.swift`;
- `CheckingTests/Auth/CheckViewModelFakes.swift`;
- `CheckingTests/Auth/SelfRegistrationApprovalTests.swift`;
- `CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift`;
- `CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift`;
- `CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift`;
- `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `CheckingTests/Location/CLLocationManagerLocationProviderTests.swift`;
- `CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift`;
- `CheckingTests/Location/GeofenceRegionManagerTests.swift`;
- `CheckingTests/Location/LocationSamplePolicyTests.swift`;
- `CheckingTests/Network/SafeApiCallTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/ActivityNotificationSceneStateTests.swift`;
- `CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift`;
- `CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift`;
- `CheckingTests/Orchestrator/ContextCallbackFenceTests.swift`;
- `CheckingTests/Orchestrator/EvaluationRequestMergeTests.swift`;
- `CheckingTests/Orchestrator/MovementGatePolicyTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`;
- `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift`;
- `CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift`;
- `CheckingTests/Orchestrator/PendingContextInvalidationTests.swift`;
- `CheckingTests/Orchestrator/PendingDrainBehaviorTests.swift`;
- `CheckingTests/Orchestrator/PendingNormalWakeTests.swift`;
- `CheckingTests/Orchestrator/PendingOfflineQueueTests.swift`;
- `CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift`;
- `CheckingTests/Orchestrator/SignificantLocationSeedTests.swift`;
- `CheckingTests/Orchestrator/TimerSingleCaptureTests.swift`;
- `CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift`;
- `CheckingTests/Persistence/DurableEvaluationJournalTests.swift`;
- `docs/plans/background_reliability_execution.md`.

O perfil seleciona coerentemente o comportamento do provider e do use case de localização. Como Debug,
Staging e Release continuam explicitamente em `legacyWithDiagnostics`, a filtragem candidata não está
ativa nos builds distribuíveis atuais. O journal não substitui `EvaluationLog.shared`: o Prompt 08 o
integra como fonte técnica adicional e reproduz somente as entradas legadas já existentes por adapter.
Somente o TIMER candidato fornece `finalSample`, depois de uma única aquisição física; ele nunca fornece
`seedCandidate` nem reabre orçamento de provider. O trigger candidato de mudança significativa pode
fornecer `seedCandidate`; GEOFENCE, FOREGROUND, TIMER, retries e todos os gatilhos legados continuam
encaminhando `.acquire`. Não há segunda matriz, captura comparativa ou mudança de frequência. O
perfil candidato mantém concorrência máxima do motor igual a um e substitui somente o drop de wakes
normais por um slot pending 0/1; o legado e o FOREGROUND comum preservam o drop histórico. Cada avaliação
canônica abre seu próprio record e chega a um terminal exatamente uma vez. Os Prompts 07 a 11 não mudaram
matriz, contratos HTTP, replay, mensagens humanas, UI, TTL, cache ou a política vigente de autenticação.
No caminho legado, seleção de `locations.last`, timeout e parâmetros enviados ao matcher permanecem
observavelmente compatíveis.

Operações deliberadamente não realizadas:

- pull, rebase, reset, checkout destrutivo ou limpeza do worktree;
- commit, push, tag, version bump, assinatura, upload ou deploy;
- atualização de dependências do aplicativo;
- chamada mutável ao backend;
- abertura ou alteração de estado de iPhone físico;
- alteração da matriz de negócio, contratos HTTP, DTOs, filas, replay, check manual ou acidente.

Não há `AGENTS.md` aplicável no repositório auditado.

Leituras obrigatórias concluídas antes da baseline:

- `temp/temp000.md` integral e o contrato operacional do `temp/exec000.md`;
- `README.md`, `project.yml` e os quatro arquivos em `Config/`;
- `AppEnvironment.swift`, `AppDelegate.swift`, `BackgroundCheckOrchestrator.swift` e
  `OrchestratorFakes.swift`;
- specs de background, auth lifecycle, permissões/diagnóstico, persistence e offline replay em `docs/`.

## 2. Baseline Git e origem

| Item | Valor auditado |
|---|---|
| Repositório | `https://github.com/tscode-com-br/checking-swift.git` |
| Branch | `main` |
| HEAD | `cc66dc131541cb66798e2de44a06d28a32b6df5a` |
| Upstream | `origin/main` |
| Hash do upstream após `git fetch --prune origin` | `cc66dc131541cb66798e2de44a06d28a32b6df5a` |
| Divergência HEAD/upstream | `0` atrás, `0` à frente |
| Mudanças preexistentes | nenhuma |
| Baseline esperado pelo plano | `cc66dc1`; confirmado |

Comandos de prova:

```sh
pwd
git status --short --branch
git rev-parse HEAD
git rev-parse '@{upstream}'
git rev-list --left-right --count HEAD...'@{upstream}'
git remote get-url origin
git fetch --prune origin
git diff --stat
git diff --check
```

O fetch foi apenas de leitura da origem. Não houve pull, merge, rebase ou reset.

## 3. Ambiente de build e teste

| Componente | Valor |
|---|---|
| Host | macOS 26.5.2, build 25F84, arm64 |
| Xcode | 26.6, build 17F113 |
| Developer directory | `/Applications/Xcode.app/Contents/Developer` |
| Swift | Apple Swift 6.3.3 |
| XcodeGen | 2.45.4 |
| Simulator | iPhone 17 Pro, iOS 26.5, arm64 |
| Simulator destination id | `45D57727-95E8-4C58-A15F-A0087891AFD7` |
| Configuração da suíte | Debug, scheme `Checking` |

O comando global `xcodegen` e o Homebrew não estavam disponíveis. Para não instalar ferramentas globais
nem tocar nas dependências do app, a tag oficial `2.45.4` do XcodeGen foi clonada e compilada somente em
`.build/tools/XcodeGen`, diretório ignorado. A tag resolveu para
`8d3d3476a69ae3e5d68e1adccc701c410c05eb36`. O harness já possuía uma cópia local também na versão 2.45.4.

Geração auditada:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

Resultado: `Checking.xcodeproj` foi regenerado a partir de `project.yml`, com os targets `Checking`,
`CheckingTests` e `CheckingUITests`. O projeto gerado é ignorado e não aparece no diff.

Uma tentativa inicial executada a partir do diretório da própria ferramenta encerrou sem escrever projeto
porque não encontrou `project.yml` naquele working directory. A geração foi então repetida a partir da raiz
do app, com sucesso. Esse incidente de invocação não alterou fonte, configuração ou dependência.

## 4. Baseline automatizada

### 4.1. Suíte unitária e UI

Comando shell exato:

```sh
set -o pipefail
/usr/bin/time -p xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/baseline/DerivedData \
  -resultBundlePath .build/baseline/prompt01.xcresult \
  test 2>&1 | tee .build/baseline/xcodebuild.log
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Duração interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 680 | 680 | 0 | 0 | 0 | 17,348 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 249,007 s |
| Total do `.xcresult` | 708 | 708 | 0 | 0 | 0 | — |

- Resultado do `.xcresult`: `Passed`.
- Tempo de parede do comando completo: 466,27 s.
- Evidência local ignorada:
  - `.build/baseline/prompt01.xcresult`;
  - `.build/baseline/xcodebuild.log`.
- Extração autoritativa:

```sh
xcrun xcresulttool get test-results summary \
  --path .build/baseline/prompt01.xcresult
```

Avisos de compilação já presentes na baseline, sem falha:

- dois bindings em `AuthenticationDialogs.swift` passam closure não marcada `@Sendable`;
- dois resultados de `withLock` em `KeychainStore.swift` não são consumidos;
- um `await` em `CheckEventStream.swift` não contém operação assíncrona;
- um resultado de `withLock` em `CheckViewModelFakes.swift` não é consumido;
- ferramentas de metadata de App Intents emitiram avisos ambientais.

Esses avisos foram somente registrados. Corrigi-los não faz parte desta fase read-only.

### 4.2. Harness de background no Simulator

Comando shell exato:

```sh
set -o pipefail
/usr/bin/time -p ./scripts/validate_background_simulator.sh \
  45D57727-95E8-4C58-A15F-A0087891AFD7 \
  2>&1 | tee .build/baseline/background-simulator.log
```

Tempo de parede: 123,34 s. Evidência textual local:
`.build/baseline/background-simulator.log`.

Resultados aplicáveis ao Simulator:

- PASS — o harness Debug recebeu ao menos uma atualização contínua enquanto o app estava em background;
- PASS — handlers de BGAppRefresh e BGProcessing foram registrados;
- PASS — o Simulator forneceu token APNs ao app;
- PASS — eventos simulados de entrada e saída de geofence foram recebidos;
- INCONCLUSIVO — `BGTaskSchedulerErrorDomain Code=1` impediu agendamento/execução real de BGAppRefresh;
- INCONCLUSIVO — o callback de push silencioso simulado não foi entregue nesta execução.

O relatório temporário do harness teve 48 eventos e permaneceu no container do Simulator. Nenhum payload,
coordenada ou identificador bruto foi copiado para este documento.

Esta execução não prova bateria, rádio, suspensão/cold relaunch real, oportunidade de BGTask, geofence em
campo ou comportamento Release em iPhone físico. A validação física continua obrigatória e bloqueada por
aprovação explícita.

## 5. Invariantes congelados

Os seguintes invariantes são gates de revisão para todas as fases posteriores:

1. `Checking/Domain/CheckRules/AutoActivities.swift` permanece autoritativo e não será alterado.
2. Contratos HTTP, DTOs, headers, endpoints e `X-Client` permanecem byte/semanticamente compatíveis.
3. A tentativa obrigatória de localização não cadastrada permanece; HTTP 422 continua rejeição do backend,
   nunca falha de GPS.
4. Check manual, acidente, histórico, notificações, projetos, pausa programada, accuracy retry, fila offline,
   replay, `clientEventId`, `eventTime` e idempotência devem permanecer funcionais.
5. Geofence e mudança significativa são apenas wakes. Nenhuma decisão será inferida por region ID, direção
   ou coordenada antiga; matcher do servidor e matriz existente continuam autoritativos.
6. Não haverá GPS contínuo, aumento global de raios, migração para `CLMonitor` ou
   `allowsBackgroundLocationUpdates` no caminho principal.
7. Os 15 minutos de BGAppRefresh são apenas `earliestBeginDate`, não promessa de periodicidade.
8. A decisão D5 permanece: falta de `Always` não bloqueia uso válido em foreground.
9. Novos diagnósticos não persistirão campos proibidos e não usarão descrições livres de erros externos.
10. Não será adicionada telemetria remota.
11. Mensagens existentes de `ActivityLogger` cobertas por testes permanecem byte-exact; novas mensagens serão
    apenas aditivas.
12. Perfis escolhem um caminho. Nunca haverá duas matrizes ou dois submits paralelos para comparação.
13. Testes não serão removidos, pulados, enfraquecidos ou regravados para mascarar regressão.
14. Tipos que cruzam atores continuarão genuinamente `Sendable`; `@unchecked Sendable` exige prova de
    sincronização.
15. Mudanças preexistentes do usuário serão preservadas e cada fase deverá manter diff focal e reversível.

## 6. Inventário de localização, wakes e concorrência

O inventário abaixo foi produzido com `rg`, por símbolo, no baseline atual. Caminhos e símbolos são um
snapshot auxiliar; fases posteriores devem redescobri-los, nunca confiar em line numbers antigos.

### 6.1. `LocationProvider`

Contrato:

- `Checking/Domain/Repositories/LocationProvider.swift`
  - `LocationCapture`;
  - `protocol LocationProvider`.

Conformers encontrados:

- produção/preview:
  - `UnavailableLocationProvider`;
  - `CLLocationManagerLocationProvider`;
- testes:
  - `FakeLocationProvider` em `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
  - `CountingLocationProvider` em
    `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`.

Todos os call sites de `capture`:

- `CaptureLocationUseCase.callAsFunction` — captura usada pelo match no servidor;
- `BackgroundCheckOrchestrator.shouldSkip` — captura direta do preflight de movimento do TIMER.

Composição:

- `AppEnvironment.live()` cria uma única instância de `CLLocationManagerLocationProvider`;
- essa mesma instância entra em `CaptureLocationUseCase` e diretamente no orquestrador;
- preview usa `UnavailableLocationProvider`;
- `makeOrchestrator` em `OrchestratorFakes.swift` injeta o seam nos testes.

Achado: no TIMER, `runOnceLocked` chama primeiro `shouldSkip`; se não houver skip,
`RunAutomaticActivitiesUseCase` chega a `CaptureLocationUseCase` e captura novamente. As duas capturas usam
o mesmo provider, mas são sequenciais e independentes.

### 6.2. `LocationCapturing` e `CoalescingLocationCapture`

Contrato e conformers:

- `LocationCapturing` — `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `CoalescingLocationCapture` — actor de produção;
- `CaptureLocationUseCase` — implementação base de produção;
- `FakeCaptureLocation` — `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `SlowCountingCapture` — fake actor em `CaptureLocationLoggingTests.swift`.

Call sites reais do seam:

- `RunAutomaticActivitiesUseCase.callAsFunction`;
- `CheckViewModel.captureLocation`, incluindo a recaptura acionada pela UI.

Wiring:

- `AppEnvironment.live()` envolve somente `CaptureLocationUseCase` com
  `CoalescingLocationCapture`;
- o coalescedor é injetado no motor automático e exposto à UI via `RootView`;
- o preview usa a base sem coalescedor.

Testes diretos:

- mesma accuracy concorrente compartilha uma captura;
- accuracies diferentes permanecem independentes.

Usuários dos fakes aparecem em:

- `CheckViewModelFakes.swift`;
- `AutoActivitiesLoggingTests.swift`;
- `AutoActivitiesOfflineTests.swift`;
- `AutoActivitiesUseCaseTests.swift`;
- `DuplicateEliminationTests.swift`;
- `CaptureLocationLoggingTests.swift`;
- `OrchestratorFakes.swift`;
- `AccuracyRetryEpisodeTests.swift`.

Achado: `CoalescingLocationCapture` não envolve a captura direta de `shouldSkip` e não une as duas capturas
sequenciais do TIMER.

### 6.3. `SignificantLocationMonitoring`

Contrato e conformers:

- `SignificantLocationMonitoring`;
- `NoopSignificantLocationMonitor`;
- `CLLocationManagerSignificantChangeMonitor`;
- `SpySignificantLocationMonitor` em `CheckViewModelFakes.swift`.

Construtores da implementação real:

- composição live em `AppEnvironment.live()`;
- dois cenários em `CLLocationManagerSignificantChangeMonitorTests.swift`.

Fluxo completo do callback:

1. `locationManager(_:didUpdateLocations:)` recebe `[CLLocation]`;
2. o monitor apenas verifica se o array não está vazio;
3. `handleSignificantLocation()` chama um callback `@Sendable () -> Void`;
4. `AppEnvironment` transforma o callback em `orchestrator.runOnce(.significantLocation)`.

A amostra que acordou o processo, seu timestamp e sua precisão não atravessam o seam atual.

Todos os call sites de lifecycle do monitor:

- `CheckViewModel`
  - `onChaveChanged` faz `stop`;
  - `handleAuthExpiry` faz `stop`;
  - `deleteAccount` faz `stop`;
  - `wipeLocalData` faz `stop`;
  - `reconcileAutomaticLocationServices` faz `stop` nos dois gates inválidos e `start` no gate elegível;
- `PhysicalValidationScreen`
  - `grantConsent` pode fazer `start`;
  - `startPhysicalValidation` faz `start`;
  - o diagnóstico Debug consulta `isActive`;
- testes
  - `AutomaticActivitiesActivationTests.swift` observa starts;
  - `CheckMainViewModelTests.swift` cobre consentimento, start/stop e wipe.

Testes diretamente associados ao callback/startup:

- `CLLocationManagerSignificantChangeMonitorTests.swift` cobre delegate/callback ativo e ausência de wake
  quando inativo;
- `SignificantLocationStartupPolicyTests.swift` cobre a decisão síncrona de início no cold launch;
- nenhum teste atual cobre transporte de amostra porque o seam é zero-argument.

Política de cold launch:

- `AppPreferencesStore.shouldStartSignificantLocationMonitoringAtLaunch()` lê de forma síncrona chave,
  toggle, projeto e consentimento persistidos;
- `AppEnvironment.live()` usa essa política em `startsImmediately`.

### 6.4. Call sites de `runOnce` e `runAccidentCheck`

Entradas externas de produção de `runOnce`:

- `AppDelegate` — handler compartilhado de BGAppRefresh;
- `AppEnvironment` — callback de geofence;
- `AppEnvironment` — callback de mudança significativa;
- `CheckViewModel`
  - após habilitar/desabilitar atividades automáticas;
  - em `onRefreshLocation`;
  - após carga autoritativa de memberships;
  - após sincronização serial de memberships;
  - após persistência de settings que não alterou a pausa programada.

Entradas internas do orquestrador:

- ativação de pausa;
- transição de pausa;
- mudança de settings;
- início e repetição de accuracy retry;
- drain de pendências de retry/pausa.

Seams relacionados:

- `CheckViewModelSeams.swift` define `CheckOrchestrating.runOnce`;
- o default de mudança de settings encaminha para `.foreground`;
- `CheckViewModelFakes.swift` implementa e registra o seam em testes.

Call sites de teste de `runOnce`:

- `AccuracyRetryEpisodeTests.swift` — 38 chamadas;
- `ScheduledPauseDeferralTests.swift` — 26 chamadas;
- `OrchestratorSingleFlightTests.swift` — 2 chamadas;
- `OrchestratorGateTests.swift` — 1 chamada;
- `CheckViewModelFakes.swift` — implementação e encaminhamento do seam.

`runAccidentCheck`:

- definição e fluxo interno em `BackgroundCheckOrchestrator`;
- entrada de produção no callback APNs de `AppDelegate`;
- três cenários em `AccidentNotificationDecisionTests.swift`.

### 6.5. `BackgroundTaskGuard`

Contrato e conformers:

- `BackgroundTaskGuard` em `OrchestratorSeams.swift`;
- `NoopBackgroundTaskGuard`;
- `UIKitBackgroundTaskGuard`.

Todos os usos:

- dependência armazenada e injetada em `BackgroundCheckOrchestrator`;
- `begin()` no início da avaliação admitida;
- `end(token)` no encerramento;
- implementação UIKit injetada em `AppEnvironment.live()`;
- testes e preview usam o no-op default.

Gaps confirmados:

- não existe fake/spy dedicado;
- não há teste direto de pareamento begin/end ou expiração;
- o guard UIKit usa `expirationHandler: nil`;
- `runAccidentCheck` não usa esse guard;
- testes do scheduler cobrem deadlines, não lifecycle/expiração de `BGTask`.

### 6.6. Owners de `CLLocationManager`

Produção:

- `CLLocationManagerLocationProvider.CaptureSession` — captura pontual;
- `CLLocationManagerSignificantChangeMonitor` — mudança significativa;
- `CLLocationManagerGeofenceMonitor` — region monitoring;
- `PermissionsInspectorLive` — inspeção transitória;
- `PermissionRequestCoordinator` — owner retido para solicitação de permissões.

Owners SwiftUI do coordenador de permissão:

- `CheckMainScreen`;
- `PhysicalValidationScreen`.

Somente Debug:

- `BackgroundValidationHarness` é protegido por `#if DEBUG`;
- é o único owner que habilita `allowsBackgroundLocationUpdates`;
- pode usar atualização contínua, mudança significativa e geofence apenas no ensaio.

O caminho normal de produção não configura `allowsBackgroundLocationUpdates`.

### 6.7. Single-flight e drop do segundo wake

Produção:

- `BackgroundCheckOrchestrator.runOnce` usa `isRunning`;
- enquanto ocupado, somente accuracy retry e ativação/transição de pausa deixam flags pendentes;
- triggers normais retornam imediatamente;
- `runAccidentCheck` também retorna se ocupado.

Teste que congela explicitamente o drop:

- `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift`;
- `test_concurrent_runOnce_is_blocked_by_single_flight` bloqueia o primeiro TIMER, chama GEOFENCE e prova
  que o segundo wake não executa trabalho nem submit.

Fakes/primitivas:

- `FakeAppPreferences.chaveGate` mantém o primeiro run ocupado;
- `SpyAutoActivities` conta execuções;
- `makeOrchestrator` faz o wiring;
- `PlatformFakes.swift` contém `waitUntil` e `AsyncGate`.

Testes correlatos que não devem ser confundidos com drop normal:

- `ScheduledPauseDeferralTests` protege pendência/reconciliação especial de pausa;
- `AccuracyRetryEpisodeTests` protege pendência especial de retry e invalidação.

A futura mudança para pending normal bounded deve substituir/expandir conscientemente o teste de drop, sem
remover ou enfraquecer as garantias especiais existentes.

## 7. Inventário de lifecycle, sessão e contexto

### 7.1. Fluxo `AppDelegate → AppEnvironment → RootView → CheckViewModel`

1. `CheckingApp` cria `AppDelegate` via `@UIApplicationDelegateAdaptor`.
2. `AppDelegate.environment` chama `AppEnvironment.live()` de forma eager.
3. O environment compartilha um `KeychainSessionCookieStore` entre HTTP, SSE e upload de acidente, monta o
   orquestrador e cria callbacks de geofence/mudança significativa.
4. No launch, `AppDelegate` registra BGTasks, agenda refresh regular e inicia o coordenador offline.
5. `AppSplashScreen` termina após atraso visual, sem gate de `scenePhase`.
6. `RootView` cria `CheckViewModel` e `AccidentViewModel` ao concluir o splash.
7. O initializer real de `CheckViewModel` inicia `restore()`.
8. Com chave persistida, `restore()` chama `probeStatus()`.
9. `probeStatus()` começa chamando `authRepository.logout()`.
10. `AuthRepositoryLive.logout()` limpa o cookie compartilhado mesmo se o POST falhar.

Achado: um cold launch acordado por localização/BGTask pode construir a máquina interativa e apagar o cookie
que o motor headless pretendia reutilizar.

Foreground:

- `CheckMainScreen.onAppear` chama `onForegroundResume()` sem provar cena ativa;
- a transição para `scenePhase == .active` chama novamente `onForegroundResume()` e
  `finishPermissionReview()`;
- há possibilidade de falso foreground e duplicação `onAppear` + `.active`.

### 7.2. Auth, login, logout e cookie

Todos os call sites de produção encontrados:

- `CheckViewModel`
  - chave incompleta após edição chama logout;
  - todo `probeStatus()` chama logout preventivo;
  - login interativo/automático chama login;
  - exclusão chama `deleteAccount`;
  - wipe local chama logout;
- `BackgroundCheckOrchestrator`
  - relogin silencioso chama login, no máximo uma tentativa no fluxo atual;
- `AuthRepositoryLive`
  - logout sempre chama `cookieStore.clear()`;
  - delete limpa cookie somente em sucesso.

Não existe fluxo de logout explícito independente na UI. O logout é consequência de troca/remoção de chave,
probes preventivos ou wipe.

Risco: cancelamento de `Task` e guards de geração protegem estado visual, mas não revertem uma mutação
HTTP/Keychain já iniciada. Um logout antigo pode limpar o cookie após um login mais novo.

### 7.3. Troca de chave

Fluxo principal em `CheckViewModel.onChaveChanged`:

1. sanitiza a chave;
2. se a identidade persistida válida mudou, invalida o contexto de automação;
3. cancela tasks de chave, senha, polling, SSE e sincronização de projetos;
4. limpa estado visual/contextual em memória;
5. para mudança significativa, remove geofences e persiste a chave;
6. chave incompleta faz logout;
7. chave completa recarrega settings/senha e executa `probeStatus`, que também faz logout preventivo.

`onRegChaveChanged` é um caminho separado do diálogo de autocadastro e altera a chave em memória sem repetir
todo o teardown.

### 7.4. Toggle automático e consentimento

Habilitação:

1. exige chave autenticada e projetos estáveis;
2. reconsulta memberships;
3. falha fechada sem projeto;
4. normaliza/persiste memberships, projeto ativo e toggle;
5. aguarda sincronização;
6. reconcilia serviços nativos;
7. executa `runOnce(.foreground)`.

Desabilitação:

1. persiste OFF;
2. invalida retry, pausa e contexto antigo;
3. para serviços;
4. executa foreground para limpeza derivada.

Consentimento:

- `recordBackgroundLocationConsent()` persiste timestamp global;
- registra mensagem humana existente e reconcilia serviços;
- não há revogação explícita na UI;
- wipe ou perda de elegibilidade/permissão efetivamente removem o uso;
- após troca de chave, o consentimento global persistido pode ser relido.

Gate atual dos serviços:

- exige chave, autenticação, automático, projeto ativo, consentimento e localização precisa;
- falha para monitor significativo e remove regiões;
- sucesso inicia monitor significativo e registra geofences.

`finishPermissionReview()` pode desligar o toggle quando o ladder mínimo não é atendido.

### 7.5. Projetos

- resposta do servidor é autoritativa;
- toques durante PUT são coalescidos e enviados serialmente;
- falha reverte ao último estado autoritativo;
- mudança de chave/auth invalida gerações e respostas antigas;
- mudança real de projeto ativo invalida contexto de automação;
- após confirmação, recarrega localizações, reconcilia geofences e executa foreground;
- `ProjectRepository.updateActiveProject()` existe, mas não tem call site no view model atual.

### 7.6. Exclusão de conta e wipe local

Exclusão bem-sucedida:

1. `AuthRepositoryLive.deleteAccount()` limpa o cookie;
2. o view model tenta desligar automático;
3. invalida contexto, para monitor e remove geofences;
4. limpa senhas, preferências e fila offline;
5. para SSE/polling/sync e reseta UI.

Conflito/falha preserva sessão e dados locais. A ordem é sensível porque o cookie é removido antes do
teardown local restante.

Wipe local:

1. desliga automático se autenticado;
2. invalida contexto;
3. para monitor e geofences;
4. faz logout;
5. limpa ActivityLog, fila offline, senhas, preferências e EvaluationLog;
6. cancela tasks e reseta UI/idioma.

Diferença de baseline: delete bem-sucedido não limpa explicitamente ActivityLog/EvaluationLog; wipe limpa.
Nenhuma semântica foi alterada nesta fase.

## 8. BGAppRefresh, retry e pausa

### 8.1. Handler atual

`AppDelegate`:

- registra `br.com.tscode.checking.refresh`;
- resolve o trigger em `triggerForPendingRefresh()`;
- chama `orchestrator.runOnce(trigger)`;
- reagenda o refresh regular;
- chama `setTaskCompleted(success: true)`;
- expiration handler apenas cancela a `Task`.

Gaps confirmados:

- não há gate exactly-once para completion;
- expiração não encerra explicitamente como falha;
- reagendamento não está protegido por uma garantia terminal/defer;
- cancelamento por toda a pilha ainda não está provado;
- uma corrida pode reportar sucesso após expiração.

### 8.2. Scheduler e deadlines

`BGTaskAppRefreshScheduler` possui um único request compartilhado por:

- regular;
- accuracy retry;
- ativação da pausa;
- transição da pausa.

Regular usa `now + 15 minutos` apenas como limite inferior. Nunca é periodicidade garantida.

Deadlines duráveis:

- `pref_bg_refresh_accuracy_retry_deadline_epoch_ms`;
- `pref_bg_refresh_pause_activation_deadline_epoch_ms`;
- `pref_bg_refresh_pause_transition_deadline_epoch_ms`.

Quando mais de um deadline está vencido, a prioridade é:

1. transição de pausa;
2. ativação de pausa;
3. accuracy retry;
4. timer.

O próximo request usa o mínimo entre os três deadlines duráveis e o regular. Para substituir, o scheduler
cancela o request anterior e submete outro. `submittedRequestDeadline` é cache somente do processo.

Accuracy retry:

- intervalo atual: 180 s;
- episódio durável é persistido antes de agendar;
- usa task em processo e deadline de BG como backstop;
- invalidação de contexto limpa o episódio/deadline.

Pausa programada:

- grace após checkout confirmado: 10 s;
- backoff após falhas repetidas: 180 s;
- runtime e deadlines são duráveis;
- invalidação de conta/projeto/toggle limpa flags e deadlines;
- mudança de settings reconcilia imediatamente.

Cobertura existente:

- `BGTaskAppRefreshSchedulerTests.swift` cobre regular, idempotência, restart, substituição, falha,
  persistência, mínimo, prioridade e limpeza seletiva;
- `ScheduledPauseDeferralTests.swift` cobre retry/backoff, autorização, reancoragem, cold restart, grace,
  terminais e invalidação;
- `AccuracyRetryEpisodeTests.swift` cobre episódio, retry, deadline, invalidação e concorrência especial.

## 9. Achados de baseline que orientam as próximas fases

Estes achados são inventário, não implementação nem conclusão causal definitiva:

1. TIMER pode adquirir duas localizações sequenciais na mesma avaliação.
2. O coalescedor atual não cobre o preflight de movimento.
3. A amostra entregue pela mudança significativa é descartada antes do matcher.
4. `LocationCapture` não carrega timestamp/frescor.
5. O provider considera a última amostra do callback e prioriza precisão; timestamp só desempata.
6. Um wake normal concorrente é descartado por desenho e por teste.
7. Cold launch pode criar a UI e executar logout/probe sem prova de foreground real.
8. Login/logout interativo e relogin headless não possuem coordenador serial compartilhado.
9. Completion/expiração de BGTask não é exactly-once.
10. O estado solicitado das geofences ainda não equivale a confirmação operacional.

Esses pontos são compatíveis com a lacuna observada, mas esta fase não atribui o incidente exclusivamente ao
GPS. Orçamento de execução, concorrência, sessão, frescor, disponibilidade de wake e comportamento oportunista
do iOS continuam hipóteses separadas a medir.

## 10. Hashes sentinela

Os hashes abaixo foram calculados com `git hash-object` depois da geração e de todos os testes. Eles servem
para revisão; não autorizam reverter mudanças futuras legítimas de seam.

### 10.1. Matriz e contratos DTO/wire de check — sentinelas estritos

| Arquivo | Hash |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Data/DTOs/CheckWireEnums.swift` | `e6c49aee2cb9daab0676f972116eb2fd1cb27061` |
| `Checking/Data/Repositories/CheckApi.swift` | `e852d0a24883128b738bf7a1fe8afd9eaabe2405` |
| `Checking/Data/Repositories/CheckApiLive.swift` | `4a09247a77653a1069f0f0c79f1159b6d9374845` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/CheckModels.swift` | `8493573989384c2fddaecbc1c3bd44372c5cda13` |

### 10.2. Offline, replay e idempotência — sentinelas estritos

| Arquivo | Hash |
|---|---|
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Domain/Repositories/OfflineCheckQueueing.swift` | `74f131e5193e8a8d193d7bbb5cb0cccd1baab29d` |
| `Checking/Data/Offline/OfflineQueueStore.swift` | `bc0a36885d0e60ad3c3ef2cccfb1aca7c672a334` |

### 10.3. Check manual — sentinelas de fluxo/revisão

| Arquivo | Hash |
|---|---|
| `Checking/Features/Check/RegistrationComponents.swift` | `2007868d3e980828c1071fb41b23e1b9735ca9a6` |
| `Checking/Features/Check/CheckUiState.swift` | `5cfb0aef4fe09a0c88c7568c35820065b07e13df` |
| `Checking/Features/Check/CheckMainScreen.swift` | `42955d7e0b3424715707adacbc88162936970f1b` |
| `Checking/Features/Check/CheckViewModel.swift` | `ef33eba9da0f001c0c3386f62058748a66c4af70` |

Os dois últimos são integrações compartilhadas que poderão receber seams legítimos em fases autorizadas.
Qualquer diff deverá preservar por símbolo os botões, submit manual, fila e idempotência.

### 10.4. Acidente — sentinelas estritos

| Arquivo | Hash |
|---|---|
| `Checking/Domain/Models/AccidentModels.swift` | `3d9eb1a34b31a8a71c80542cd53444de509fdc7a` |
| `Checking/Domain/Repositories/AccidentRepository.swift` | `e93eb83061bfcdeb771d6b8d35a4d15706211db2` |
| `Checking/Data/DTOs/AccidentDTOs.swift` | `f77484b8bd2c5fd4b75509338330f736e982c15f` |
| `Checking/Data/Repositories/AccidentApi.swift` | `92c61bef511e492ea79441b4df87167ec7a58db5` |
| `Checking/Data/Repositories/AccidentRepositoryLive.swift` | `a9ff63abb7538eb88d7002c54f23daa1a1acb9cf` |
| `Checking/Features/Accident/AccidentPureFunctions.swift` | `830f7fa039b269565279a2cf6e3ca9fa0888c9e5` |
| `Checking/Features/Accident/AccidentUiState.swift` | `548cd3e22b931112a087d1c38b5dbafe920ab456` |
| `Checking/Features/Accident/AccidentViewModel.swift` | `856f9d910b57784e2f5f860eed91fa0ae0d9cb38` |
| `Checking/Features/Accident/AccidentViews.swift` | `f591afe96477343664b66fca3f6b96f19833652c` |
| `Checking/Features/Accident/VideoRecordController.swift` | `14be51b0f3bcde83be6f97b4491f019953644975` |
| `Checking/Platform/Video/BackgroundAccidentVideoUploader.swift` | `117aa17dde9882cb116f06fe9adfeee836448389` |
| `Checking/Platform/Video/VideoRecording.swift` | `7af84a83815a78ace5b2dce05793aa2ab1af219c` |

Integração compartilhada a revisar por símbolo:

| Arquivo | Hash |
|---|---|
| `Checking/Platform/Background/BackgroundCheckOrchestrator.swift` | `f26cef045c2f8108be0a41ad23ac16550f3ff688` |

### 10.5. Single-flight, logs e notificações

| Arquivo | Hash | Natureza |
|---|---|---|
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `c500ceb009013bb00346f3118c84323d2084d1f7` | teste explícito do drop |
| `CheckingTests/Orchestrator/OrchestratorFakes.swift` | `8eb35f3dace2de7e3cac3e42bf18244a1aa0662a` | wiring/fakes |
| `CheckingTests/Platform/PlatformFakes.swift` | `a41c27d3d6b76dd9688ec9b4f91f63ea413b9c3d` | gates assíncronos |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` | mensagens byte-exact |
| `Checking/Domain/Repositories/ActivityLogging.swift` | `436ac2da92622bc933b57ea9931f0604c2598d0b` | contrato de log |
| `Checking/Platform/Notifications/AutoActivityNotificationsLive.swift` | `991a10105c5422ff0ee4e786a43e36fb0e1bf3c0` | notificações |
| `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift` | `a6edd62bfe57f5ed10c99cbd65e9b52f30d67f07` | integração compartilhada |

`RunAutomaticActivitiesUseCase` pode mudar legitimamente para receber/reutilizar amostra. A revisão deve
preservar `clientEventId`, `eventTime`, enqueue offline, replay e resultado do submit.

## 11. Situação dos prompts

| Prompt | Escopo | Status |
|---:|---|---|
| 00 | Contrato operacional obrigatório | concluído e vinculante |
| 01 | Preflight, baseline e inventário | concluído; somente relatório; não commitado |
| 02 | Perfis coerentes de build e injeção | concluído localmente; todos os configs legados; não publicado |
| 03 | Journal durável, bounded e privacy-safe | concluído localmente; storage/injeção/wipe; não publicado |
| 04 | `LocationSample` e política pura de frescor | concluído localmente; integrado somente ao candidato no Prompt 05; não publicado |
| 05 | Provider Core Location testável, seed, melhor-fix e cancelamento | concluído localmente; configs ainda legados; não publicado |
| 06 | Seam sample-aware entre aquisição e matcher | concluído localmente; gatilhos ainda usam `.acquire`; não publicado |
| 07 | Resultado operacional tipado sem alterar a matriz | concluído localmente; consumido pelo journal no Prompt 08; não publicado |
| 08 | Terminais duráveis em todos os caminhos do orquestrador | concluído localmente; single-flight preservado; não publicado |
| 09 | TIMER com exatamente uma captura | concluído localmente no perfil candidato; configs ainda legados; não publicado |
| 10 | Significant-change transporta seed opcional | concluído localmente no candidato; configs ainda legados; não publicado |
| 11 | Pending normal bounded, serial e sem perda silenciosa | concluído localmente no candidato; configs ainda legados; não publicado |
| 12 | Guard mínimo de cold launch/headless lifecycle | concluído localmente no candidato; configs ainda legados; não publicado |
| 13 | Sessão serial e relogin tipado por estágio | concluído localmente no escopo parcial aprovado; retry de submit bloqueado; configs ainda legados; não publicado |
| 14 | BGTask e UIKit lease exactly-once | verde localmente no candidato: controllers, owners, leases, completion, router por perfil e BGProcessing exercitados; recovery automático de submit indeterminado segue proibido sem prova server-side; validação física pendente; configs distribuíveis legados |
| 15 | Geofences requested/confirmed/failed/omitted por geração | verde localmente no candidato: geração, confirmação, reconciliação e privacidade exercitadas; validação operacional/P80 em hardware pendente; configs distribuíveis legados; não publicado |
| 16 | Wipe, retenção e apresentação/exportação segura | concluído localmente; exportação DEBUG-only, sem telemetria; configs distribuíveis legados |
| 17 | Política pura e observacional de elegibilidade | concluído localmente; observacional, D5/monitores intocados; configs distribuíveis legados |
| 18 | Auditoria integrada, regressão e perfis candidato/legado | concluído localmente; candidato injetado em testes, todos os configs legados |
| 19 | Atualização das specs e decision log | concluído; somente documentação, sem mudança de código/configuração |
| 20 | Simulator e build Release não assinado | concluído localmente; testes, harness e builds Debug/Staging/Release auditados; Release continua legado e não distribuído |
| 21 | Ensaio físico controlado | candidata Staging otimizada assinada e instalada somente como pré-ensaio; percurso formal e artefato Release-equivalente continuam pendentes |
| 22 | Aplicar elegibilidade e mover ownership nativo | condicional; não iniciado |
| 23 | Handoff durável de reconciliação | condicional à evidência; não iniciado |
| 24 | Episódio curto de movimento | experimento condicional; exige aprovação; não iniciado |
| 25 | Rollout e rollback | human-gated; não iniciado |
| 26 | Estabilização e remoção de compatibilidade legada | condicional; não iniciado |

## 12. Decisões humanas

### 12.1. Decisões aprovadas para o Prompt 03

O usuário aprovou explicitamente, antes da edição:

1. retenção máxima de 500 avaliações ou 30 dias, prevalecendo o limite que eliminar primeiro;
2. proteção `completeUntilFirstUserAuthentication`;
3. wipe do journal junto com dados locais e depois de exclusão remota bem-sucedida;
4. nenhuma apresentação/exportação em produção nesta fase.

Essas decisões foram implementadas sem ampliar o escopo para telemetria, backend ou UI.

### 12.2. Decisões aprovadas para o Prompt 04

O usuário aprovou explicitamente, antes da edição, os seguintes valores como ponto de partida para ensaio:

1. `maximumAge = 10 s`;
2. `futureTolerance = 2 s`.

Os valores estão centralizados em `LocationSamplePolicy.candidateTrial` e conectados somente ao caminho
`candidate`; nenhum config distribuível o seleciona nesta fase. A aprovação não os transforma em
thresholds definitivos de rollout: a adequação precisa ser medida no percurso e a mesma amostra deverá ser
revalidada imediatamente antes do matcher quando o seam sample-aware for integrado.

### 12.3. Decisões aprovadas para o Prompt 09

O usuário aprovou explicitamente, antes da edição comportamental:

1. a ordem candidata
   `gates/projeto/opções/pausa → captura → movimento → revalidação/match imediato → state se necessário → matriz → submit/fila`;
2. a manutenção dos parâmetros aprovados no Prompt 04: `maximumAge = 10 s` e
   `futureTolerance = 2 s`;
3. se a amostra envelhecer antes do matcher: nenhum match, nenhuma segunda captura e terminal
   `staleContext`; a próxima oportunidade deve vir de outro wake/retry.

Essas decisões afetam somente o pipeline `candidate`; Debug, Staging e Release continuam selecionando
`legacyWithDiagnostics`.

### 12.4. Decisões aprovadas para o Prompt 11

O usuário aprovou explicitamente, antes da edição:

1. carga máxima de uma avaliação normal adicional por ciclo running;
2. ordem de drain
   `pause transition → pause activation → foreground/pause reconciliation → pending normal → accuracy retry → acidente`;
3. FOREGROUND fora do pending normal inicial, preservando a reconciliação especial existente;
4. notificação baseada no estado real da cena no submit; nesta fase, sem inventar seam de lifecycle, foi
   preservada a semântica existente até o Prompt 12 fornecer o estado autoritativo;
5. o pending sempre executa follow-up na primeira versão, sem otimização `covered`.

O efeito operacional aprovado é bounded: pode haver uma captura/rede adicional depois de uma avaliação
running, mas nunca duas avaliações do motor em paralelo nem mais de um follow-up normal acumulado.

### 12.5. Decisões ainda pendentes

Estas decisões não foram tomadas por inferência:

1. SLO de chegada em cenário controlado; proposta do plano: até 5 minutos e antes da saída.
2. Dwell mínimo do ponto intermediário.
3. Meta separada para passagem sem dwell.
4. Amostra mínima de aparelhos e percursos.
5. Orçamento aceitável de energia e thermal.
6. Calibração definitiva de frescor e tolerância de relógio após medir os valores iniciais aprovados de
   10 s/2 s em percurso físico.
7. Aceite de eventual episódio curto de movimento, APIs permitidas e indicador do sistema.
8. Política de raio de wake, somente se virar experimento separado.
9. Dono e prazo da homologação do backend para a rejeição de localização não cadastrada.
10. Critérios de promoção entre perfis candidato/legado e responsáveis pelo rollback.
11. Aprovação no momento de qualquer teste em iPhone físico, TestFlight ou distribuição.

Até essas decisões serem resolvidas nos gates correspondentes, valores experimentais e rollout permanecem
desligados.

## 13. Gates e handoff do Prompt 01

| Gate | Resultado |
|---|---|
| Baseline verde | atendido: 708/708 |
| Nenhum arquivo de código/teste alterado | atendido |
| Inventário de conformers/call sites completo | atendido |
| Hashes sentinela registrados | atendido |
| Harness do Simulator executado | atendido dentro das limitações documentadas |
| `git diff --check` | limpo; arquivo untracked também verificado com `git diff --no-index --check` |
| Relatório incremental criado | atendido |
| Publicação/commit | não realizados |

Decisões tomadas nesta fase:

- usar o HEAD esperado e sincronizado como baseline;
- usar Simulator disponível descoberto, sem hardcode de device inexistente;
- isolar o XcodeGen em diretório ignorado;
- interpretar limitações do Simulator como inconclusivas;
- manter avisos preexistentes apenas documentados;
- não editar produção/testes nem antecipar solução.

Testes não executados e motivo:

- iPhone físico, Release/TestFlight, cold relaunch real, bateria, rádio, energia e thermal — exigem Prompt 21
  e aprovação explícita;
- execução real de BGAppRefresh — o Simulator devolveu a limitação conhecida;
- push silencioso físico — o callback simulado foi inconclusivo e não substitui APNs real;
- cenários das fases 02–26 — ainda não implementados.

Riscos/pendências para a próxima fase:

- preservar todos os invariantes e hashes estritos;
- não misturar perfis nem submeter em paralelo;
- manter alterações futuras focais e cobertas primeiro por testes direcionados;
- tratar `@unchecked Sendable` existente com cautela e não propagá-lo;
- não declarar a correção concluída antes dos gates físicos e humanos.

Estado Git esperado ao encerrar esta fase:

```text
## main...origin/main
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida, caso o usuário decida versionar este relatório:

```text
docs(ios): record background reliability baseline
```

## 14. Gates e handoff do Prompt 02

### 14.1. Resultado alcançado

Foi introduzido `BackgroundReliabilityProfile` como enum imutável e `Sendable`, com somente estes estados:

| Perfil | Pipeline operacional resolvido | Experimento de movimento |
|---|---|---|
| `legacyWithDiagnostics` | legado | desligado |
| `candidate` | candidato | desligado |
| `candidateWithMovementExperiment` | candidato | ligado |

Não existem seis booleanos combináveis nem construção de combinações inválidas. O parser é total, exato e
case-sensitive. Ausência, tipo incorreto, string vazia, placeholder não expandido ou valor desconhecido
resolvem para `legacyWithDiagnostics`; o experimento nunca é fallback.

A origem instalada do perfil é auditável:

1. cada `Config/*.xcconfig` define uma única vez
   `CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics`;
2. `Checking/Info.plist` referencia essa setting pela chave
   `CHECKINGBackgroundReliabilityProfile`;
3. `AppEnvironment.live()` lê somente o `Bundle` processado do build;
4. mudar Release exige gerar e distribuir outro build — isto não é kill switch remoto.

O `AppEnvironment` armazena o perfil, e a factory inerte de preview/teste permite injetar os três valores.
O perfil não cria outra stack, não escolhe dois motores e não inicia caminhos funcionais. O preview padrão
continua legado.

### 14.2. Arquivos modificados

| Arquivo | Alteração focal |
|---|---|
| `Checking/App/BackgroundReliabilityProfile.swift` | tipo, parsing conservador e capabilities coerentes |
| `Checking/App/AppEnvironment.swift` | armazenamento; leitura do Bundle na composição viva; injeção na factory inerte |
| `Checking/Info.plist` | ponte explícita entre build setting e Bundle |
| `Config/Debug.xcconfig` | perfil legado explícito |
| `Config/Staging.xcconfig` | perfil legado explícito |
| `Config/Release.xcconfig` | perfil legado explícito |
| `CheckingTests/BackgroundReliabilityProfileTests.swift` | oito testes direcionados |
| `docs/plans/background_reliability_execution.md` | este handoff incremental |

`project.yml`, `Config/Shared.xcconfig`, `PrivacyInfo.xcprivacy`, fakes existentes, motores, matriz, contratos,
DTOs, filas, replay, check manual e acidente não foram modificados. `Checking.xcodeproj` foi regenerado pelo
processo documentado e permanece ignorado pelo Git.

### 14.3. Decisões tomadas

- manter os nomes do plano como raw values exatos, sem aliases;
- derivar pipeline e experimento do enum, impedindo combinações arbitrárias;
- manter Debug, Staging e Release em `legacyWithDiagnostics`;
- fazer fallback de qualquer entrada inválida diretamente para o legado;
- limitar a composição viva à leitura do Bundle, sem override público, `UserDefaults`, argumento de
  processo, remote config ou ID de instalação;
- usar a composição in-memory/no-op de preview como factory de injeção para testes;
- não conectar o perfil a capture, orchestrator, auth, journal ou lifecycle nesta fase;
- exigir nos testes exatamente uma atribuição da setting em cada `xcconfig`;
- tratar o perfil como mecanismo de build/piloto que requer novo build para alteração;
- incorporar os endurecimentos apontados por três revisões read-only independentes antes da validação final.

### 14.4. Configuração e artefato Release

Comando usado para verificar a configuração efetiva dos três builds:

```sh
for config in Debug Staging Release; do
  xcodebuild -project Checking.xcodeproj -target Checking \
    -configuration "$config" -showBuildSettings
done
```

Resultado filtrado:

```text
Debug:   CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics
Staging: CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics
Release: CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics
```

Build Release final, sem assinatura:

```sh
set -o pipefail
/usr/bin/time -p xcodebuild \
  -project Checking.xcodeproj \
  -scheme 'Checking (Release)' \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt02/ReleaseDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee .build/prompt02/release-build-final.log
```

Resultado: `BUILD SUCCEEDED`; tempo de parede de 40,42 s. A extração abaixo retornou exatamente
`legacyWithDiagnostics` no produto final:

```sh
plutil -extract CHECKINGBackgroundReliabilityProfile raw \
  .build/prompt02/ReleaseDerivedData/Build/Products/Release-iphonesimulator/Checking.app/Info.plist
```

`Checking/Info.plist` e `Checking/PrivacyInfo.xcprivacy` também passaram em `plutil -lint`.

### 14.5. Testes direcionados finais

Comando:

```sh
set -o pipefail
/usr/bin/time -p xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt02/DirectedDerivedData \
  -resultBundlePath .build/prompt02/directed-final.xcresult \
  -only-testing:CheckingTests/BackgroundReliabilityProfileTests \
  test 2>&1 | tee .build/prompt02/directed-final.log
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures |
|---|---:|---:|---:|---:|---:|
| `BackgroundReliabilityProfileTests` | 8 | 8 | 0 | 0 | 0 |

Tempo de parede: 18,79 s. O `.xcresult` terminou como `Passed`.

Os testes cobrem:

- os três valores válidos;
- ausência, tipo incorreto, vazio, variação de caixa, whitespace, placeholder e desconhecido;
- `candidate` sem experimento e experimento nunca obtido por fallback;
- mapeamentos coerentes de pipeline/experimento;
- preview padrão legado;
- injeção dos três perfis na factory inerte;
- orquestrador parado, monitor significativo inativo, zero drains e log vazio após cada construção;
- exatamente uma definição legada em cada `xcconfig`;
- referência do `Info.plist` à setting auditável;
- bundle Debug processado e `fromBundle()` resolvendo legado.

### 14.6. Suíte completa final

Comando:

```sh
set -o pipefail
/usr/bin/time -p xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt02/DirectedDerivedData \
  -resultBundlePath .build/prompt02/full-final.xcresult \
  test 2>&1 | tee .build/prompt02/full-final.log
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Duração interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 688 | 688 | 0 | 0 | 0 | 13,489 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 194,498 s |
| Total do `.xcresult` | 716 | 716 | 0 | 0 | 0 | — |

Resultado do `.xcresult`: `Passed`. Tempo de parede: 220,21 s. A contagem foi confirmada por:

```sh
xcrun xcresulttool get test-results summary \
  --path .build/prompt02/full-final.xcresult --compact
```

Uma execução completa anterior ao último endurecimento também passou, mas somente o resultado final acima
é usado como gate autoritativo.

### 14.7. Auditorias estruturais e invariantes

Uma busca por símbolos confirmou referências ao perfil somente em:

- `Config/*.xcconfig`;
- `Checking/Info.plist`;
- `Checking/App/BackgroundReliabilityProfile.swift`;
- `Checking/App/AppEnvironment.swift`;
- `CheckingTests/BackgroundReliabilityProfileTests.swift`.

Não há referência em `Checking/Platform`, `Checking/Domain` ou `Checking/Data`. Assim, não houve conexão com
capture, orchestrator, auth, submit ou persistência, e construir qualquer perfil não seleciona nem executa
dois caminhos.

Os 37 hashes sentinela do Prompt 01 foram recalculados com `git hash-object`: 37 conferiram e zero
divergiram. Em particular, a matriz, DTOs/wire, offline/replay/idempotência, check manual, acidente,
mensagens byte-exact, notificações e teste de drop do segundo wake permanecem intactos.

Não foram introduzidos:

- GPS contínuo, novos raios, `CLMonitor` ou `allowsBackgroundLocationUpdates`;
- mudança de contratos HTTP, endpoints, headers ou `X-Client`;
- analytics/telemetria remota;
- mensagens novas no `ActivityLogger`;
- `@unchecked Sendable`;
- `UserDefaults` oculto, remote config ou seleção por instalação;
- promessa de periodicidade de BGAppRefresh;
- qualquer alteração de permissão, UI ou comportamento funcional.

Os warnings observados no build Release são os mesmos já presentes e registrados na baseline; não surgiu
warning atribuível aos arquivos do Prompt 02.

### 14.8. Gates

| Gate | Resultado |
|---|---|
| Nenhuma mudança observável no app | atendido estruturalmente e pela suíte completa 716/716 |
| Todos os configs ainda legados | atendido em fonte e `-showBuildSettings` |
| Release atual resolve legado | atendido no `Info.plist` do `.app` final |
| Nenhum motor duplo | atendido; perfil não é consumido por motor algum |
| Parsing/fallback seguro | atendido pelos oito testes direcionados |
| Injeção em environment/factory de fakes | atendido pela composição inerte in-memory/no-op |
| Tipos Swift 6 genuinamente `Sendable` | atendido; enum e valor derivado são `Sendable` |
| Arquivos protegidos preservados | atendido: 37/37 hashes, zero divergências |
| Testes direcionados | 8/8 |
| Suíte completa | 716/716 |
| Build Release sem assinatura | atendido |
| `git diff --check` | limpo; os três arquivos untracked também passaram em `--no-index --check` |
| Publicação/commit | não realizados |

### 14.9. Testes não executados e motivo

- iPhone físico, TestFlight, cold relaunch real, bateria, rádio, energia e thermal — não fazem parte desta
  fase e exigem aprovação explícita no Prompt 21;
- execução real de BGAppRefresh, APNs e wakes oportunistas — o Simulator não constitui prova física;
- pipelines candidatos — deliberadamente não estão conectados e todos os configs permanecem legados;
- journal, freshness/seed, captura única, pending bounded, headless lifecycle e expiração — pertencem às
  fases seguintes;
- episódio de movimento — continua bloqueado até o Prompt 24 e seus gates;
- backend — nenhuma chamada mutável foi autorizada ou realizada.

### 14.10. Riscos e pendências

- nesta fase, o tipo apenas torna a seleção futura explícita; não corrige ainda a confiabilidade de
  localização;
- promover `candidate` ou mudar Release exigirá novo build e somente poderá ocorrer após implementar e
  validar as fases correspondentes;
- `candidateWithMovementExperiment` permanece não selecionado em todos os configs e não pode ser promovido
  sem o Prompt 24 e aprovação;
- o Simulator não valida consumo de energia, rádio, cold relaunch real nem agendamento de BGTask;
- as decisões humanas então pendentes permaneciam registradas na seção 12 para os gates posteriores;
- os warnings preexistentes de concorrência e ferramentas do Simulator permanecem fora do escopo;
- os artefatos de teste e logs estão em `.build/`, ignorados pelo Git.

Estado Git final:

```text
## main...origin/main
 M Checking/App/AppEnvironment.swift
 M Checking/Info.plist
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? docs/plans/background_reliability_execution.md
```

O `git diff --check` ficou limpo. Os três arquivos ainda não rastreados também foram verificados
individualmente com `git diff --no-index --check`; nenhuma advertência de whitespace foi emitida.

Mensagem de commit sugerida:

```text
test(ios): add background reliability build profiles
```

## 15. Execução do Prompt 03 — journal durável, bounded e privacy-safe

### 15.1. Aprovações e limites aplicados

As quatro decisões humanas exigidas pelo prompt foram recebidas antes da edição e estão registradas na
seção 12.1. A implementação usa:

- cap de 500 avaliações;
- retenção de 30 dias com fronteira estrita: exatamente 30 dias permanece; mais antigo é removido;
- aplicação dos dois limites em conjunto, sem um ampliar o outro;
- proteção `completeUntilFirstUserAuthentication`;
- wipe local e wipe após exclusão remota bem-sucedida;
- nenhuma tela, exportação ou telemetria remota.

Foi adicionado também um limite defensivo de 2 MiB antes de carregar o JSON. O arquivo normal com 500
records cabe abaixo desse teto nos testes; uma representação maior é tratada como inválida e substituída
por um envelope vazio, sem guardar o blob bruto.

### 15.2. Arquitetura implementada

O journal é separado de `checking_activity.sqlite` e não exige migração do Core Data:

- `EvaluationJournalModels.swift` contém somente IDs aleatórios, enums fechados, buckets, contadores fixos
  de wake e records com `CodingKeys` explícitos;
- `EvaluationJournaling` é um protocolo `Sendable`, assíncrono e non-throwing;
- `NoopEvaluationJournal` mantém previews/fakes sem I/O;
- `DurableEvaluationJournal` é um actor com uma única instância na composição viva;
- o envelope JSON possui schema versionado e `next_sequence` monotônico;
- o initializer é lazy e não toca o disco;
- as escritas usam JSON ordenado, escrita atômica e a opção de proteção completa até a primeira
  autenticação, seguida de reaplicação best-effort do atributo no diretório e no arquivo;
- falha de diagnóstico nunca lança para o negócio, e uma escrita transitoriamente falha permanece marcada
  para retry em uma operação posterior;
- leitura temporariamente indisponível preserva o arquivo e deixa o mesmo actor tentar novamente;
- corrupção, schema futuro desconhecido e arquivo oversized são substituídos sem criar quarentena ou backups
  que escapem da retenção;
- erros e inconsistências usam somente mensagens estáticas e sanitizadas no `OSLog`.

O gatilho e o snapshot inicial de app/launch/permissão/precisão/refresh/energia/monitores são imutáveis.
Um `begin` repetido pode agregar um wake, avançar o estágio e preencher campos opcionais, mas não reescreve
o contexto primário. Estágio e terminal são eixos distintos: finalizar não apaga o último estágio útil.

### 15.3. Semântica e privacidade

Semântica coberta:

- `begin` cria ou atualiza um único record started;
- `finish` é first-wins e não reescreve o arquivo no segundo terminal;
- `coalesce` aceita somente tipos de wake conhecidos e contadores limitados;
- `reconcileOrphans` marca como `abandoned` somente started records de outro process ID;
- records do processo atual e records já terminados não são alterados;
- `recent` devolve newest-first e aplica retenção;
- `clear` é idempotente e limpa disco e memória best-effort;
- sequence continua monotônica após prune e reabertura;
- acesso concorrente é serializado pelo actor.

O schema não possui campos para coordenadas, altitude, velocidade, course, nome de local/projeto/usuário,
chave, senha, cookie, token, header, `clientEventId`, body HTTP, URL, erro cru ou region ID. A classificação
de Core Location recebe somente código whitelisted. A sanitização HTTP:

- conserva status HTTP exato válido e classe;
- conserva 422 como rejeição HTTP de cliente, sem detail/body;
- conserva 409 porque `ApiError.conflict` possui origem exata;
- não inventa 401 para `ApiError.unauthorized`, que representa tanto 401 quanto 403;
- descarta descrições de erros desconhecidos e falhas de rede.

`LocationSample` não recebeu `Codable`. Nenhuma mensagem existente do `ActivityLogger` foi alterada.

### 15.4. Integrações limitadas

`AppEnvironment.live()` cria uma única instância do actor na área de Application Support; a factory de
preview recebe um journal injetável e usa no-op por padrão. O `AppDelegate` agenda
`reconcileOrphans()` em uma `Task` de prioridade utility após registrar BGTasks, sem bloquear o callback
de launch e sem apresentar UI.

`RootView` injeta a mesma instância no `CheckViewModel`. O journal é limpo:

- depois de uma exclusão de conta confirmada pelo backend;
- no comando explícito de apagar dados locais.

Ele não é limpo em exclusão falha/conflitada, logout comum, troca de projeto, toggle, troca de chave ou
`clearActivities()`. Os testes de ViewModel verificam respectivamente contagens de clear `1`, `1` e `0`
para wipe local, exclusão bem-sucedida e exclusão conflitada.

Deliberadamente não realizados nesta fase:

- conexão do journal a todos os returns do orquestrador;
- substituição de `EvaluationLog.shared`;
- mudança em captura, geofence, mudança significativa, auth, matriz ou submit;
- execução de dois motores ou comparação por submits paralelos;
- exportação/apresentação do journal.

### 15.5. Testes direcionados

Comando integrado autoritativo da fase:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt03/DirectedDerivedData \
  -resultBundlePath .build/prompt03/directed-final.xcresult \
  -only-testing:CheckingTests/DurableEvaluationJournalTests \
  -only-testing:CheckingTests/ActivityLogCoreDataTests \
  -only-testing:CheckingTests/ActivityLogStoreUnitTests \
  -only-testing:CheckingTests/BackgroundValidationRecorderTests \
  -only-testing:CheckingTests/BackgroundReliabilityProfileTests \
  -only-testing:CheckingTests/CheckMainViewModelTests \
  test
```

Resultado: 81/81 testes passaram, zero falhas, zero skips e zero expected failures. A duração interna das
suítes foi 6,983 s; o `.xcresult` terminou como `Passed`.

Depois do último endurecimento de file protection, a suíte específica foi repetida:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt03/DirectedDerivedData \
  -resultBundlePath .build/prompt03/journal-protection-final.xcresult \
  -only-testing:CheckingTests/DurableEvaluationJournalTests \
  test
```

Resultado final do journal: 19/19, zero falhas, em 2,115 s internos.

A matriz de 19 testes cobre os seguintes aspectos, vários deles combinados no mesmo método:

1. begin/finish e reabertura;
2. proteção configurada e atributo real quando exposto pelo filesystem;
3. begin repetido sem duplicação, ressurreição ou perda do snapshot primário;
4. primeiro terminal vence;
5. coalescência tipada e imutabilidade pós-terminal;
6. ordenação e sequence após reabertura;
7. retenção exata por quantidade;
8. retenção por idade e fronteira de 30 dias;
9. orphan de outro processo, preservação do atual e idempotência;
10. arquivo ausente;
11. leitura indisponível preservada e retry no mesmo actor;
12. corrupção repetida sem backups;
13. arquivo acima do cap antes de `Data(contentsOf:)`;
14. schema futuro desconhecido;
15. falha de I/O e persistência posterior do terminal após recuperação;
16. clear;
17. 50 pares concorrentes serializados e reabertos;
18. buckets e sanitização HTTP/Core Location;
19. whitelist estrutural e sentinelas de privacidade;
20. no-op; e
21. benchmark sem limite temporal rígido.

O scanner valida conjuntos exatos de chaves e sentinelas únicas; não usa regex genérica de números
decimais.

Benchmark final anexado ao `.xcresult`:

```text
journal benchmark: 25 begin/finish pairs, 0.025621 s total, 1.025 ms/pair, 17192 bytes
```

O número é apenas ordem de grandeza desta máquina/Simulator e não é gate de performance.

Uma revisão adversarial read-only independente repetiu a suíte do journal: 19/19, zero falhas, 2,417 s.
Após as correções apontadas, a revisão não encontrou achado alto ou médio remanescente.

Uma execução intermediária foi cancelada na compilação porque um teste havia colocado `await` dentro do
autoclosure de `XCTAssertTrue`. O await foi movido para fora da asserção; nenhuma fonte de produção foi
alterada por esse incidente, e todas as execuções finais acima estão verdes.

### 15.6. Suíte completa final

Comando executado depois de todas as correções:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt03/FinalDerivedData \
  -resultBundlePath .build/prompt03/full-post-review.xcresult \
  test
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Duração interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 707 | 707 | 0 | 0 | 0 | 14,288 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 206,310 s |
| Total do `.xcresult` | 735 | 735 | 0 | 0 | 0 | — |

Resultado: `Passed`. A operação de teste observada pelo Xcode levou 233,140 s; o intervalo total registrado
pelo `.xcresult`, incluindo preparação/build, foi aproximadamente 263,882 s. A contagem foi confirmada por:

```sh
xcrun xcresulttool get test-results summary \
  --path .build/prompt03/full-post-review.xcresult --compact
```

### 15.7. Auditorias estruturais e sentinelas

Os 37 hashes do Prompt 01 foram recalculados:

- 36 continuam byte-exact;
- o único arquivo divergente é `Checking/Features/Check/CheckViewModel.swift`;
- essa divergência contém somente o seam autorizado do journal e dois `clear()` aguardados nos wipes;
- matriz, DTOs/wire, offline/replay/idempotência, acidente, orquestrador, mensagens byte-exact,
  notificações e testes de single-flight permanecem intactos.

Buscas estruturais confirmaram:

- todos os três `xcconfig` continuam em `legacyWithDiagnostics`;
- nenhum novo `@unchecked Sendable`;
- nenhum `String(describing:)` ou `localizedDescription` persistido;
- nenhum GPS contínuo, `CLMonitor`, raio novo ou `allowsBackgroundLocationUpdates`;
- nenhum contrato HTTP, endpoint, header ou `X-Client` alterado;
- nenhum analytics/remote config/export;
- nenhum arquivo do Core Data existente ou `EvaluationLog` alterado.

### 15.8. Gates

| Gate | Resultado |
|---|---|
| Aprovações humanas antes da edição | atendido; quatro decisões registradas |
| Journal separado e bounded | atendido; 500/30 dias e cap defensivo antes da leitura |
| Escrita atômica/protegida | atendido em código e Simulator quando o atributo é exposto |
| Primeiro terminal vence | atendido por teste byte-exact |
| Orphans reconciliados sem bloquear launch | atendido por actor + Task não bloqueante |
| Falha do journal não altera negócio | atendido por API non-throwing e testes de I/O/retry |
| Nenhum dado proibido serializado | atendido por schema fechado, whitelist e sentinelas |
| ActivityLog/Core Data preservados | atendido; testes direcionados e ausência de migração |
| Captura/orquestração inalteradas | atendido por hashes e diff |
| Wipes aprovados | atendido com contagens `1/1/0` |
| Testes direcionados | 81/81; journal final 19/19 |
| Suíte completa | 735/735 |
| `git diff --check` | limpo; sete untracked também verificados individualmente |
| Commit/publicação | não realizados |

### 15.9. Testes não executados e riscos pendentes

Não executados:

- iPhone físico, primeiro unlock real, cold relaunch físico, bateria, rádio, energia e thermal — exigem
  aprovação específica e pertencem aos prompts físicos posteriores;
- entrega real de geofence, significant change, BGAppRefresh e APNs — o Simulator não é prova desses
  comportamentos oportunistas;
- backend mutável, TestFlight, assinatura, upload ou deploy — não autorizados;
- exportação/apresentação do journal — explicitamente recusada nesta fase;
- build/pipeline candidato — todos os configs permanecem legados;
- instrumentação completa do orquestrador — pertence ao Prompt 08.

Riscos/pendências:

- o journal já é durável e reconciliável, mas ainda não explica cada retorno do orquestrador até o Prompt 08;
- file protection antes do primeiro unlock só pode ser comprovada integralmente em aparelho físico;
- corrupção/schema futuro/arquivo oversized perde somente diagnóstico local e nunca dados de negócio;
- I/O e proteção continuam best-effort para não bloquear o comportamento do app;
- as correções de freshness, captura única, pending e headless lifecycle ainda não foram iniciadas.

Estado Git final:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Info.plist
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida:

```text
feat(ios): add privacy-safe durable evaluation journal
```

## 16. Execução do Prompt 04 — `LocationSample` e política pura de frescor

### 16.1. Aprovação, objetivo e limite da fase

Antes de qualquer edição do Prompt 04, o usuário aprovou `maximumAge = 10 s` e
`futureTolerance = 2 s` como ponto de partida para ensaio. Os valores não são uma conclusão de campo nem
foram promovidos a comportamento vivo.

Esta fase foi mantida estritamente aditiva:

- introduziu tipos de domínio neutros de plataforma;
- introduziu uma política pura com relógio fornecido pelo chamador;
- adicionou somente testes puros;
- não alterou `LocationCapture`, `LocationProvider`, `CLLocationManagerLocationProvider`,
  `CaptureLocationUseCase` nem qualquer call site de produção;
- não conectou a política ao journal, provider, matcher, orquestrador ou perfil;
- não alterou quantidade de capturas, timeout existente, mensagens humanas ou decisão de negócio.

### 16.2. Tipos e política implementados

`LocationSample` é um valor imutável, `Sendable` e `Equatable`, com:

- latitude e longitude somente em memória;
- precisão horizontal em metros;
- instante de captura;
- origem fechada: captura standard ou mudança significativa.

O tipo não adota `Codable`, `CustomStringConvertible` nem protocolo de logging, não importa Core Location e
não aparece nos modelos persistidos do journal. A futura conversão de `CLLocation.timestamp` está
documentada para ocorrer somente na fronteira Platform.

Foram introduzidas também taxonomias `Sendable` de falha de aquisição e cancelamento de avaliação. Elas são
tipadas e não carregam `Error`, descrição localizada ou texto externo.

`LocationSamplePolicy.candidateTrial` é o único ponto de produção que contém os parâmetros 10 s/2 s. A
função de validade recebe `now` explicitamente e falha fechada quando encontra:

- configuração não finita ou negativa;
- threshold de precisão negativo;
- relógio ou timestamp não finito;
- latitude/longitude não finita ou fora das faixas inclusivas válidas;
- precisão negativa ou não finita.

A classificação aplica, nesta ordem:

1. integridade da configuração e da amostra;
2. futuro além da tolerância;
3. idade acima do limite;
4. precisão suficiente ou coarse.

Idade exatamente igual a 10 s é válida; 10 s + 1 ms é stale. Uma amostra exatamente 2 s no futuro é
aceita; 2 s + 1 ms é `fromFuture`.

A comparação total de duas seeds:

1. descarta amostras `invalid`, `stale` ou `fromFuture`;
2. prioriza `usable` sobre `freshButTooInaccurate`;
3. prioriza menor erro horizontal dentro da mesma classe;
4. usa o timestamp mais recente como desempate;
5. preserva `current` no empate completo.

Coordenadas e origem nunca participam do ranking. O ranking interno possui valores explícitos para impedir
que uma futura reordenação dos cases inverta a preferência silenciosamente. A documentação no código exige
nova validação no instante do matcher quando a política vier a ser integrada.

### 16.3. Arquivos da fase

Arquivos de código/teste adicionados exclusivamente pelo Prompt 04:

- `Checking/Domain/Models/LocationSample.swift`;
- `Checking/Domain/UseCases/LocationSamplePolicy.swift`;
- `CheckingTests/Location/LocationSamplePolicyTests.swift`.

Este relatório foi o único arquivo existente atualizado pela fase. Nenhum arquivo de produção ou teste
preexistente foi alterado pelo Prompt 04.

### 16.4. Geração e testes finais

O projeto foi regenerado pelo processo documentado, usando a cópia local já auditada do XcodeGen:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

Os testes puros finais foram executados com:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt04/DerivedData \
  -resultBundlePath .build/prompt04/pure-final.xcresult \
  -only-testing:CheckingTests/LocationSamplePolicyTests \
  test
```

Resultado: 20/20, zero falhas, zero skips e zero expected failures; 0,062 s internos e 17,35 s de parede.
Os testes cobrem:

- amostra atual, idade zero e threshold inclusivo;
- fronteiras exatas e +1 ms de 10 s e 2 s;
- precisão negativa, NaN, infinita, no threshold e coarse;
- coordenadas não finitas, fora da faixa e nos extremos inclusivos;
- configuração, clock e threshold inválidos;
- preservação de ambas as origens;
- ausência de `Encodable`, `Decodable` e `CustomStringConvertible`;
- seed precisa de 2 s contra seed coarse de 1 s, nas duas ordens;
- comparação entre duas seeds usable e entre duas coarse;
- prioridade de precisão antes do timestamp;
- descarte de stale/future/invalid;
- empate estável sem usar coordenada ou origem;
- revalidação da mesma amostra em dois instantes.

A regressão dirigida final foi executada com os seguintes seletores no mesmo projeto, scheme, Simulator e
DerivedData:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt04/DerivedData \
  -resultBundlePath .build/prompt04/directed-final.xcresult \
  -only-testing:CheckingTests/LocationSamplePolicyTests \
  -only-testing:CheckingTests/CaptureLocationLoggingTests \
  -only-testing:CheckingTests/AutoActivitiesHelpersTests \
  -only-testing:CheckingTests/AutoActivitiesLoggingTests \
  -only-testing:CheckingTests/AutoActivitiesOfflineTests \
  -only-testing:CheckingTests/AutoActivitiesUseCaseTests \
  -only-testing:CheckingTests/DecisionMatrixTests \
  -only-testing:CheckingTests/CheckoutPreservationTests \
  -only-testing:CheckingTests/DuplicateEliminationTests \
  -only-testing:CheckingTests/LocationChangeContinuationTests \
  -only-testing:CheckingTests/ScheduledPauseTests \
  -only-testing:CheckingTests/OfflineCheckQueueTests \
  -only-testing:CheckingTests/PendingCheckEventCodableTests \
  -only-testing:CheckingTests/PendingCheckReplayerTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests \
  -only-testing:CheckingTests/CheckRepositoryMappingTests \
  -only-testing:CheckingTests/DurableEvaluationJournalTests \
  test
```

Resultado: 249/249, zero falhas, zero skips e zero expected failures; 4,112 s internos e 13,27 s de
parede. Esse conjunto cobre captura e mensagens byte-exact, helpers/matriz, preservação de checkout,
eliminação de duplicidade, continuação por localização, pausa, raw enqueue, codificação e replay offline,
provider puro, accuracy retry, mapping do matcher e separação do journal.

A suíte completa final foi executada depois de todas as alterações:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt04/DerivedData \
  -resultBundlePath .build/prompt04/full-final.xcresult \
  test
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Duração interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 727 | 727 | 0 | 0 | 0 | 14,374 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 194,322 s |
| Total do `.xcresult` | 755 | 755 | 0 | 0 | 0 | — |

Resultado: `Passed`; tempo de parede 220,97 s. As contagens foram extraídas com
`xcresulttool get test-results summary`.

Antes do endurecimento final sugerido pela revisão read-only, também ficaram verdes execuções de 19/19,
248/248 e 754/754. Depois de tornar o ranking explícito e adicionar a cobertura coarse/coarse, todas as
três matrizes foram repetidas nos resultados finais acima. Na primeira execução pura, o `xcodebuild`
passou 19/19, mas o wrapper posterior de shell tentou usar a variável reservada `status` do zsh e encerrou
com erro operacional; o `.xcresult` e o log confirmaram que os testes haviam passado. O wrapper foi
corrigido para `test_status`, sem mudança no código.

Uma revisão independente read-only não encontrou achado alto ou médio. Os dois pontos baixos acionáveis —
ranking implícito e cobertura entre duas seeds coarse — foram endurecidos antes das execuções finais.

### 16.5. Auditorias estruturais e sentinelas

As seguintes buscas retornaram zero ocorrência:

```sh
rg -n '^import (CoreLocation|UIKit|SwiftUI|AVFoundation)\b' Checking/Domain
rg -n '\bLocationSample\b' \
  Checking/Platform/Background/EvaluationJournalModels.swift \
  Checking/Platform/Background/EvaluationJournaling.swift \
  Checking/Data/Persistence/DurableEvaluationJournal.swift
```

Sentinelas específicas registradas antes da edição e confirmadas ao final:

| Arquivo protegido | Hash final, idêntico ao inicial |
|---|---|
| `LocationProvider.swift` | `d91f6753c4d0e566750f227f8f4b316b0090f548` |
| `CaptureLocationUseCase.swift` | `feb41eb289103066095b7e215d0f6325482b5397` |
| `CLLocationManagerLocationProvider.swift` | `aa48dfab46ead5313f34043aac620b58be8053f9` |
| `UseCaseFakes.swift` | `b469fbfd562d2136cf89f565cd8571c409db5490` |
| `AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |

Esses hashes comprovam que os protocolos/providers/call sites existentes, parâmetros enviados ao matcher,
matriz, raw enqueue/replay e mensagens do `ActivityLogger` não mudaram nesta fase. O diff também não contém
`@unchecked Sendable`, integração ao journal, dependência de Core Location no Domain, coordenada persistida
ou mudança de configuração/perfil.

### 16.6. Gates

| Gate | Resultado |
|---|---|
| Aprovação humana de 10 s/2 s antes da edição | atendido e registrado |
| Domain sem Core Location/UIKit | atendido estruturalmente |
| Clock injetado e política determinística | atendido; `now` é argumento obrigatório |
| Limites temporais inclusivos | atendido por testes de fronteira e +1 ms |
| Seed precisa não perde para coarse só por timestamp | atendido nas duas ordens |
| Revalidação em instantes diferentes | atendido |
| Nenhuma coordenada persistida | atendido por tipo não Codable e separação estrutural do journal |
| Nenhum call site/protocolo/provider existente alterado | atendido por diff e hashes |
| Mesmos parâmetros do matcher e raw enqueue | atendido por hashes e regressão dirigida |
| Matriz e mensagens existentes intocadas | atendido por hashes e regressão dirigida |
| Swift 6/Sendable sem atalho unchecked | atendido |
| Testes puros | 20/20 |
| Regressão dirigida | 249/249 |
| Suíte completa | 755/755 |
| `git diff --check` | limpo; dez untracked também verificados individualmente |
| Commit/publicação | não realizados |

### 16.7. Testes não executados, riscos e pendências

Não executados:

- `validate_background_simulator.sh` — esta fase não altera callback, provider, captura, orquestração ou
  background; o harness não acrescentaria evidência sobre uma política ainda desconectada;
- build Release — nenhum config, `Info.plist`, profile ou caminho compilado condicionalmente por Release foi
  alterado pelo Prompt 04; o app Debug e todos os targets foram compilados pela suíte completa;
- iPhone físico, percurso, bateria, rádio, thermal, cold relaunch, TestFlight e wakes reais — exigem
  aprovação explícita e pertencem aos gates posteriores;
- backend mutável, assinatura, upload e deploy — não autorizados.

Riscos e pendências:

- 10 s/2 s são valores iniciais para ensaio, não thresholds definitivos de rollout;
- a 100 km/h, 10 s ainda representam aproximadamente 278 m de deslocamento, portanto a medição física e a
  revalidação imediatamente antes do matcher permanecem essenciais;
- esta fase deliberadamente não corrige ainda o comportamento observado: os novos tipos não são consumidos
  pelo pipeline até as fases posteriores;
- empate completo preserva a seed `current`; a integração futura deve manter explícitos os papéis
  current/incoming e testar estabilidade;
- o Simulator não prova qualidade de GPS, bateria, rádio ou entrega de wakes em background.

Estado Git final acumulado até o Prompt 04:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Info.plist
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

O `git diff --check` ficou limpo. Os dez arquivos não rastreados foram verificados individualmente com
`git diff --no-index --check`; nenhuma advertência de whitespace foi emitida.

Mensagem de commit sugerida:

```text
refactor(ios): introduce timestamped location samples
```

## 17. Execução do Prompt 05 — provider testável, seed, melhor fix e cancelamento

### 17.1. Objetivo, perfil e limite da fase

O Prompt 05 foi implementado sobre o mesmo baseline Git `cc66dc131541cb66798e2de44a06d28a32b6df5a`,
sem pull, rebase, reset, commit ou publicação. Os parâmetros aprovados no Prompt 04 foram mantidos:

- idade máxima de 10 segundos;
- tolerância futura de 2 segundos;
- timeout total da sessão de 15 segundos.

O perfil escolhe exatamente um comportamento:

- `legacyWithDiagnostics` usa `legacyCompatible`: ignora seed, não aplica freshness e preserva a seleção
  histórica de `locations.last`;
- `candidate` e `candidateWithMovementExperiment` usam `freshnessValidated`: validam seed, rejeitam cache
  antigo e avaliam todo o batch;
- nenhum caminho executa legado e candidato simultaneamente;
- os três `Config/*.xcconfig` continuam em `legacyWithDiagnostics`.

O experimento de movimento continua desligado. Nenhum call site vivo recebe seed nesta fase: os dois call
sites de produção chamam explicitamente `seed: nil`. Transporte de seed por mudança significativa e
reutilização entre movimento/matcher continuam reservados aos prompts posteriores.

### 17.2. Contrato e tipos operacionais

`LocationCapture.success` passou a transportar um único `LocationSample`, eliminando três valores soltos.
Falhas usam `LocationAcquisitionFailure`:

- `timeout`;
- `unavailable`;
- `permissionDenied`;
- `cancelled(EvaluationCancellationReason)`.

O novo contrato é:

```swift
func capture(
    _ accuracyThresholdMeters: Int,
    seed: LocationSample?
) async -> LocationCapture
```

A conveniência sem seed permanece e delega para `seed: nil`. `UnavailableLocationProvider` e todos os fakes
foram migrados. `CaptureLocationUseCase` preserva sua fachada observável:

- timeout e cancelamento viram `.timeout`;
- indisponibilidade e permissão viram `.noPermission`;
- sucesso envia latitude, longitude e precisão exatamente como recebidas ao matcher;
- os textos existentes do `ActivityLogger` foram preservados byte-exact.

### 17.3. Máquina de estado e semântica candidata

Foi criado `CaptureSessionState`, valor Foundation-only, `Sendable` e sem Core Location. A máquina recebe
admissão, batch, timeout, cancelamento e falha, e emite somente:

- iniciar driver;
- continuar aguardando;
- terminar com resultado tipado;
- ignorar evento posterior ao terminal.

No caminho candidato:

1. seed é validada no instante de admissão;
2. seed usable termina sem criar manager ou timer;
3. seed fresh/coarse torna-se best inicial;
4. seed stale, futura além da tolerância ou inválida é descartada;
5. callbacks anteriores a `captureStartedAt - 2 s` são rejeitados mesmo quando ainda seriam globalmente
   frescos;
6. todos os itens úteis do batch são comparados;
7. menor erro horizontal vence; empate usa timestamp mais novo;
8. threshold inclusivo encerra cedo;
9. no timeout, o best é revalidado e só retorna sucesso quando ainda está fresco;
10. best que envelheceu é removido antes de comparar um novo callback, permitindo que um fix recente,
    embora menos preciso, seja preservado;
11. cancelamento e permissão negada sempre vencem sobre best parcial;
12. primeiro terminal vence; callbacks, timeout, falha ou cancelamento tardios são no-op.

Com `maximumAge = 10 s` e orçamento de 15 s, uma seed capturada no início pode naturalmente envelhecer antes
do timeout. O best-partial de um timeout real precisa ser uma amostra ainda fresca, por exemplo um callback
recebido durante a sessão. Os testes avançam o relógio lógico e cobrem explicitamente seed stale, callback
recente e revalidação no instante terminal.

O caminho legado deliberadamente mantém `locations.last` e não aplica freshness. A infraestrutura comum
corrige apenas segurança terminal: cancelamento ou `.denied` não podem mais transformar best parcial em
sucesso.

### 17.4. Fronteira Core Location e classificação de erros

O objeto `CLLocationManager` pertence exclusivamente a `CoreLocationUpdateDriver`, confinado ao
`MainActor`. O provider `Sendable` guarda somente:

- comportamento e política imutáveis;
- clock `@Sendable`;
- factories `@MainActor @Sendable` de driver e scheduler.

O driver:

- converte cada `CLLocation.timestamp` em `LocationSample.capturedAt` na fronteira Platform;
- preserva todo o batch;
- nunca cruza atores com `CLLocationManager`;
- limpa delegate e callbacks em `stop`;
- não recebeu `@unchecked Sendable`.

O scheduler de produção mantém 15 segundos e é substituído nos testes por disparo explícito, sem sleep
real. Timer é instalado antes de `start`, cobrindo callback síncrono de fake. Todo terminal:

1. consome a continuation;
2. cancela e remove o timer;
3. para o driver, se iniciado;
4. limpa referências;
5. resume exatamente uma vez.

O erro do delegate é classificado por whitelist de `NSError.domain == kCLErrorDomain` e
`CLError.Code(rawValue:)`. Isso é necessário porque o callback expõe normalmente `NSError`; um cast direto
para `CLError` não reconhece de forma confiável `.denied`. A classificação cobre:

- `.denied`;
- `.locationUnknown`;
- demais códigos/domínios como `other`.

Para `.denied`, `authorizationStatus` é consultado somente no `MainActor`: permissão realmente
negada/restrita vira `permissionDenied`; serviço indisponível com autorização ainda nominal vira
`unavailable`. `.locationUnknown` e erros não terminais continuam aguardando.

### 17.5. Coalescência e barreiras de cancelamento

`CoalescingLocationCapture` deixou de fazer cada consumidor aguardar diretamente uma `Task` não estruturada.
O broker agora mantém uma continuation por waiter:

- pedidos simultâneos com mesmo threshold e sem seed continuam compartilhando uma captura;
- cancelar um waiter resolve somente esse waiter como timeout;
- os demais waiters permanecem;
- o task base é cancelado apenas quando sai o último waiter;
- completion e cancelamento são serializados pelo actor;
- uma checagem final de `Task.isCancelled` fecha a corrida entre completion e cancelamento.

A identidade ainda é somente o threshold porque `LocationCapturing` não aceita seed e todos os pedidos
desta fase são `seed: nil`. O comentário de contrato exige que um futuro caminho seeded bypass o broker ou
amplie sua identidade; duas seeds não podem ser unidas silenciosamente.

Barreiras adicionais foram colocadas:

- após o provider e imediatamente antes/depois do matcher;
- antes de matriz, raw enqueue e submit automático;
- no preflight TIMER do orquestrador.

Uma falha `.cancelled` no preflight TIMER termina a avaliação e não inicia a captura/matriz principal.
Esses guards não podem desfazer uma chamada que já começou; a propagação do expiration handler UIKit/BGTask
e o completion gate integral continuam pertencendo ao Prompt 14.

### 17.6. Arquivos alterados nesta fase

Produção:

- `Checking/App/BackgroundReliabilityProfile.swift`;
- `Checking/App/AppEnvironment.swift`;
- `Checking/Domain/Models/LocationSample.swift`;
- `Checking/Domain/Repositories/LocationProvider.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/UseCases/LocationSamplePolicy.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`;
- `Checking/Platform/Location/CaptureSessionState.swift` — novo;
- `Checking/Platform/Location/CLLocationManagerLocationProvider.swift`.

Testes:

- `CheckingTests/BackgroundReliabilityProfileTests.swift`;
- `CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift`;
- `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `CheckingTests/Location/CLLocationManagerLocationProviderTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`.

Documentação:

- `docs/plans/background_reliability_execution.md`.

Não foram alterados `UIKitBackgroundTaskGuard`, significant-change, geofences, matriz, DTOs/wire HTTP,
manual check, acidente, journal schema, fila, replay, notificações ou mensagens do `ActivityLogger`.

### 17.7. Testes focais

O projeto final foi regenerado pelo processo documentado:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

Comando focal final:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt05/DerivedData \
  -resultBundlePath .build/prompt05/targeted-final.xcresult \
  test \
  -only-testing:CheckingTests/CaptureSessionStateTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderComparisonTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderSessionTests \
  -only-testing:CheckingTests/CaptureLocationLoggingTests \
  -only-testing:CheckingTests/BackgroundReliabilityProfileTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests
```

Resultado autoritativo do `.xcresult`: 89/89, zero falhas, zero skips e zero expected failures; duração total
de 48,388 s. Distribuição:

| Classe | Testes |
|---|---:|
| `CaptureSessionStateTests` | 22 |
| `CLLocationManagerLocationProviderComparisonTests` | 14 |
| `CLLocationManagerLocationProviderSessionTests` | 16 |
| `CaptureLocationLoggingTests` | 11 |
| `BackgroundReliabilityProfileTests` | 8 |
| `AccuracyRetryEpisodeTests` | 18 |

Cobertura específica:

- seed usable/coarse/stale/futura/inválida;
- janela de sessão exata e +1 ms;
- batch misto, ordem, menor accuracy e empate por timestamp;
- best que envelhece e callback recente menos preciso;
- threshold, timeout com/sem best e revalidação;
- cancelamento prévio/em voo com/sem best;
- permissão inicial/runtime e `.locationUnknown`;
- callback síncrono, callbacks tardios e corridas nos dois sentidos;
- start, stop, timer e continuation exactly-once;
- duas sessões concorrentes independentes;
- `NSError` Core Location realista e domínio errado;
- coalescência por waiter e cancelamento do último;
- parâmetros exatos enviados ao matcher e seed nil;
- cancelamento não alcança matcher, matriz ou submit;
- preflight TIMER cancelado não abre motor principal;
- seleção coerente de perfil, com todos os configs ainda legados.

Uma execução intermediária foi interrompida porque o teste de duas sessões concorrentes assumia ordem de
agendamento entre tasks. O teste foi tornado determinístico iniciando a segunda sessão somente após o
primeiro driver estar ativo. Não houve sleep de 15 segundos nem mudança de produção para acomodar o teste.
Somente o resultado focal final acima é gate.

### 17.8. Regressão dirigida e suíte completa

A regressão dirigida incluiu os testes focais, política de freshness, matriz/helpers, logs, checkout,
duplicidade, pausa, raw enqueue, fila, codificação, replay, retry de precisão, mapping do matcher e journal:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt05/DerivedData \
  -resultBundlePath .build/prompt05/directed-final.xcresult \
  test \
  -only-testing:CheckingTests/BackgroundReliabilityProfileTests \
  -only-testing:CheckingTests/LocationSamplePolicyTests \
  -only-testing:CheckingTests/CaptureSessionStateTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderComparisonTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderSessionTests \
  -only-testing:CheckingTests/CaptureLocationLoggingTests \
  -only-testing:CheckingTests/AutoActivitiesHelpersTests \
  -only-testing:CheckingTests/AutoActivitiesLoggingTests \
  -only-testing:CheckingTests/AutoActivitiesOfflineTests \
  -only-testing:CheckingTests/AutoActivitiesUseCaseTests \
  -only-testing:CheckingTests/DecisionMatrixTests \
  -only-testing:CheckingTests/CheckoutPreservationTests \
  -only-testing:CheckingTests/DuplicateEliminationTests \
  -only-testing:CheckingTests/LocationChangeContinuationTests \
  -only-testing:CheckingTests/ScheduledPauseTests \
  -only-testing:CheckingTests/OfflineCheckQueueTests \
  -only-testing:CheckingTests/PendingCheckEventCodableTests \
  -only-testing:CheckingTests/PendingCheckReplayerTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests \
  -only-testing:CheckingTests/CheckRepositoryMappingTests \
  -only-testing:CheckingTests/DurableEvaluationJournalTests
```

Resultado: 305/305, zero falhas, zero skips e zero expected failures; 13,284 s totais no `.xcresult`.

Suíte final sobre o estado final exato:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt05/DerivedData \
  -resultBundlePath .build/prompt05/full-final.xcresult \
  test
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Duração interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 775 | 775 | 0 | 0 | 0 | 15,528 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 197,663 s |
| Total do `.xcresult` | 803 | 803 | 0 | 0 | 0 | 230,847 s |

O `.xcresult` final registra `Passed`. Os únicos warnings do log final foram duas mensagens ambientais do
processador de metadata informando ausência de AppIntents; não houve warning novo nos arquivos do Prompt
05.

Build Release final, sem assinatura e sem executar o app:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt05/ReleaseDerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED`. Os warnings de source exibidos nesse build já constavam da baseline:
closures não marcadas `@Sendable` em `AuthenticationDialogs`, dois resultados não consumidos em
`KeychainStore` e um `await` sem operação assíncrona em `CheckEventStream`.

### 17.9. Privacidade, invariantes e sentinelas

Não foi adicionado OSLog/ActivityLog no provider, na máquina ou no broker. Nenhuma coordenada, region ID,
nome humano, chave, credencial, token, URL, body, `clientEventId` ou `Error` cru é persistido. A
classificação de erro mantém somente enums fechados em memória.

Auditorias finais:

```sh
rg -n \
  'String\\(describing:|localizedDescription|AppLog|OSLog|Logger\\(' \
  Checking/Platform/Location/CaptureSessionState.swift \
  Checking/Platform/Location/CLLocationManagerLocationProvider.swift \
  Checking/Domain/Repositories/LocationProvider.swift \
  Checking/Domain/UseCases/CaptureLocationUseCase.swift

rg -n \
  'LocationSample' \
  Checking/Platform/Background/EvaluationJournalModels.swift \
  Checking/Data/Persistence/DurableEvaluationJournal.swift \
  Checking/Platform/Background/EvaluationJournaling.swift
```

Ambos produziram zero matches. Na suíte final,
`test_serializedJournal_hasExactWhitelistAndNoSensitiveSentinels` passou; o schema do journal não foi
alterado e `LocationSample` continua sem `Codable`, `CustomStringConvertible` ou conformance de logging.

Os 16 sentinelas estritos de matriz, DTO/wire, repositório de check, offline/replay, logs e notificações
foram recalculados e todos permaneceram iguais ao Prompt 01. Principais provas:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |

`AutoActivities.swift` não recebeu diff. HTTP, DTOs, headers, endpoints e `X-Client` permaneceram
inalterados. Os testes de offline/matriz confirmaram raw enqueue, replay, `clientEventId`, `eventTime` e
idempotência.

### 17.10. Gates, riscos e testes não executados

| Gate | Resultado |
|---|---|
| Testes determinísticos sem sleep real de 15 s | atendido |
| Core Location real confinado ao `MainActor` | atendido por tipos, build Swift 6 e revisão |
| Seed/freshness somente no candidato | atendido |
| Todos os configs distribuíveis ainda legados | atendido |
| Sem motor/captura dupla para comparação | atendido |
| Caminho legado normal sem seed preservado | atendido por regressão completa |
| Cancelamento não chega ao matcher/submit após observado | atendido por guards e testes |
| Best-partial fresco preservado no timeout | atendido |
| Matriz, HTTP, offline e mensagens protegidas | atendido por sentinelas/testes |
| Nenhuma coordenada persistida ou log novo | atendido |
| Swift 6 sem novo `@unchecked Sendable` em produção | atendido |
| Build Release não assinado | atendido |
| `git diff --check` | limpo |

Não executados:

- iPhone físico, percurso, bateria, rádio, thermal, cold relaunch real e wakes oportunistas — exigem
  autorização específica e pertencem aos prompts físicos;
- runtime candidato no app distribuível — exigiria selecionar outro perfil de build; nesta fase ele foi
  validado somente por injeção determinística;
- `validate_background_simulator.sh` — já passou no Prompt 01 e mede um harness Debug próprio de localização
  contínua, não a máquina de captura deste prompt; repeti-lo não provaria freshness, bateria ou Core
  Location físico;
- build Staging separado — Debug passou com todos os testes, Release compilou otimizado e os três valores
  de config foram verificados por teste;
- backend mutável, assinatura, upload, TestFlight, deploy, commit ou push — não autorizados.

Riscos e pendências explícitas:

- o caminho legacy mantém `locations.last` e sua tolerância histórica a uma primeira accuracy inválida no
  best; isso foi preservado para não corrigir silenciosamente builds ainda em produção;
- 10 s/2 s continuam parâmetros iniciais de ensaio, não conclusão de campo;
- todos os call sites ainda usam `seed: nil`; significant-change e uma captura por avaliação pertencem aos
  Prompts 06, 09 e 10;
- o lease UIKit existente ainda não possui propagation/completion integral de expiração; Prompt 14 é o
  gate end-to-end;
- um guard cooperativo não pode desfazer um matcher/submit que já começou antes do cancelamento;
- Simulator e testes unitários não provam energia, cache de rádio, relaunch do daemon, agendamento real de
  BGTask ou entrega física de geofence/significant-change.

Duas revisões read-only independentes foram realizadas. Elas encontraram e fizeram corrigir antes dos gates
finais:

1. best stale bloqueando callback recente menos preciso;
2. leitura de autorização fora do `MainActor`;
3. cast não confiável de `NSError` para `CLError`.

Após as correções, nenhuma revisão deixou achado alto ou médio pendente.

### 17.11. Estado Git e handoff

HEAD e upstream continuam idênticos:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

Estado Git acumulado:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Esse estado inclui legitimamente as mudanças não commitadas dos Prompts 02 a 04; nenhuma foi revertida ou
sobrescrita. Não houve commit, push ou publicação.

Mensagem de commit sugerida:

```text
fix(ios): reject stale Core Location samples
```

## 18. Execução do Prompt 06 — seam sample-aware entre aquisição e matcher

### 18.1. Objetivo, baseline e limite da fase

O Prompt 06 foi implementado sobre o mesmo baseline Git
`cc66dc131541cb66798e2de44a06d28a32b6df5a`, idêntico ao upstream. Não houve pull, rebase, reset,
commit, push ou publicação.

A fase separa aquisição física e resolução no matcher sem conectar amostras aos gatilhos. O comportamento
vivo continua deliberadamente equivalente:

- `BackgroundCheckOrchestrator` chama o overload histórico de `RunningAutomaticActivities`;
- o overload histórico encaminha explicitamente `.acquire`;
- nenhum call site de produção fornece `.seedCandidate` ou `.finalSample`;
- Debug, Staging e Release continuam em `legacyWithDiagnostics`;
- somente um caminho operacional é escolhido; não há motor, matriz, captura ou submit paralelo para
  comparação.

Os valores aprovados de frescor permanecem centralizados em `LocationSamplePolicy.candidateTrial`:
10 segundos de idade máxima e 2 segundos de tolerância futura. Eles não foram recalibrados nesta fase.

### 18.2. Contratos sample-aware e compatibilidade

Foram introduzidos valores `Sendable` e `Equatable`, somente em memória:

- `LocationAttemptInput.acquire`: ainda não existe amostra e há orçamento para uma captura;
- `LocationAttemptInput.seedCandidate`: a amostra pode alimentar ou refinar uma única captura;
- `LocationAttemptInput.finalSample`: a captura da avaliação já ocorreu e o provider não pode ser chamado;
- `LocationAcquisitionResult`: separa amostra, rejeição de validade e falha tipada de aquisição;
- `LocationResolutionResult`: separa match, erro de rede compatível, rejeição e cancelamento;
- `AutomaticSubmissionContext`: mantém o evento lógico decidido, incluindo identidade e horário, entre
  submit e eventual fila `Decided`.

`LocationCapturing.callAsFunction(_:)` foi preservado como fachada da UI/manual. O protocolo interno
`SampleAwareLocationCapturing` adiciona o overload com orçamento explícito. Da mesma forma,
`RunningAutomaticActivities` exige o overload sample-aware e fornece uma conveniência de cinco parâmetros
que encaminha `.acquire`.

O overload com `locationAttempt` é requisito real do protocolo, não somente extensão concreta. Um teste
invoca o motor por um existential `any RunningAutomaticActivities` e comprova que o default chega como
`.acquire`, evitando dispatch estático acidental.

### 18.3. Aquisição única e revalidação no ponto de uso

`CaptureLocationUseCase` agora expõe duas etapas internas:

1. `acquireSample` aplica o orçamento de aquisição;
2. `resolveSample` revalida imediatamente antes de chamar `matchLocation`.

Semântica implementada:

- `finalSample` válida chama o matcher com provider zero;
- `finalSample` stale, futura ou inválida termina sem provider e sem matcher;
- `seedCandidate` fresca/coarse é encaminhada sem alteração ao provider;
- seed rejeitada cai para exatamente uma captura com seed `nil`;
- `.acquire` e `.seedCandidate` chamam o provider no máximo uma vez;
- sucesso do provider que já envelheceu é rejeitado antes do matcher, sem reacquire;
- amostra fresh/coarse ainda chega ao matcher para preservar o episódio existente de baixa precisão;
- a mesma amostra é validada na admissão e novamente no instante de resolução;
- cancelamento observado antes do provider ou matcher impede a chamada seguinte;
- cancelamento enquanto o matcher está suspenso impede que o retorno tardio vire sucesso consumível.

O resultado externo continua sendo `LocationCaptureResult`. Rejeições de validade e cancelamentos ainda
mapeiam para `.timeout`; a taxonomia externa rica por estágio permanece reservada ao Prompt 07.

O perfil legado usa o caminho histórico de resolução, sem aplicar silenciosamente freshness a builds já
distribuídos. O candidato usa as etapas sample-aware. `AppEnvironment` injeta o mesmo clock e o mesmo
`LocationCaptureBehavior` no provider e no use case, inclusive no preview, evitando composição viva
divergente.

### 18.4. Coalescência e identidade da captura

`CoalescingLocationCapture` passou a depender do contrato sample-aware:

- `.acquire` continua compartilhando somente pedidos com o mesmo threshold;
- `.seedCandidate` e `.finalSample` bypassam o broker;
- duas seeds diferentes nunca recebem um resultado compartilhado indevidamente;
- cancelar um consumidor `.acquire` continua sem cancelar os demais;
- o último consumidor cancelado ainda cancela a captura base;
- cancelamento observado após o retorno do base continua mapeado para timeout.

Os testes concorrentes usam gates explícitos e determinísticos. O caminho `.acquire` usado pelo motor foi
testado diretamente com dois consumidores simultâneos, dois waiters e exatamente uma chamada ao base. As
duas seeds foram mantidas bloqueadas até as duas chamadas estarem registradas; não há `sleep` temporizado
capaz de produzir falso positivo.

### 18.5. Matriz, submit, fila offline e HTTP 422

`RunAutomaticActivitiesUseCase.callAsFunction(...) -> AutoActivitiesResult` foi preservado. O overload
histórico delega ao overload sample-aware e todos os retornos legados continuam iguais.

O contexto de submissão é criado uma única vez depois da matriz e antes do submit. Ele é reutilizado
integralmente quando uma falha de rede exige `PendingCheckEvent.Decided`:

- mesmo `clientEventId`;
- mesmo `eventTime`;
- mesma ação, local resolvido e informe;
- mesmo valor de `fillForms`;
- um submit e no máximo um enqueue.

No erro de rede durante match, `Raw` preserva a regra existente: horário derivado do clock da avaliação,
um novo `clientEventId`, a mesma leitura operacional e um único enqueue. Erro permanente 4xx não entra em
retry offline indevido.

O cenário HTTP 422 do local reservado não cadastrado foi testado de ponta a ponta:

- o submit obrigatório continua sendo feito;
- o backend continua sendo a origem da rejeição;
- não há enqueue;
- o resultado legado continua `.networkError`;
- a rejeição não é reclassificada como falta de GPS;
- as duas mensagens existentes do `ActivityLogger` permanecem byte-exact;
- detalhe do body de erro não entra no log.

`AutoActivities.swift`, DTOs, wire, APIs HTTP, headers, endpoints, `X-Client`, modelos e stores de fila,
replayer, check manual e acidente não foram alterados.

### 18.6. Cancelamento e limite deliberado

Há guards antes do match, antes da matriz e antes do submit. Os testes cobrem:

- task já cancelada antes de `finalSample`: provider zero e matcher zero;
- cancelamento durante match: retorno tardio não é consumível;
- cancelamento depois da decisão e geração da identidade, mas antes do submit: submit zero e enqueue zero.

Se o submit já foi despachado e a task é cancelada antes da resposta, ainda existe ambiguidade sobre
completion/enqueue. O novo `AutomaticSubmissionContext` preserva os dados necessários para resolver esse
caso sem gerar outra identidade, mas a política exactly-once pós-dispatch pertence explicitamente ao
Prompt 14 e não foi antecipada.

### 18.7. Arquivos alterados nesta fase

Produção:

- `Checking/App/AppEnvironment.swift`;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`.

Testes:

- `CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift`;
- `CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift` — novo;
- `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`.

Documentação:

- `docs/plans/background_reliability_execution.md`.

Não houve alteração em `project.yml`: o XcodeGen inclui recursivamente os novos fontes. O projeto gerado
permanece ignorado pelo Git.

### 18.8. Geração e testes focais

O projeto foi regenerado pelo processo documentado, sem atualização de dependências:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

O gate focal final executou a classe nova integralmente:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt06/DerivedData \
  -resultBundlePath .build/prompt06/pipeline-final.xcresult \
  test \
  -only-testing:CheckingTests/LocationAttemptPipelineTests
```

Resultado: 20/20, zero falhas, zero skips e zero expected failures; soma interna dos testes de
aproximadamente 0,060 s. Foram cobertos:

- default acquire legado/candidato;
- `finalSample` válida, coarse e stale;
- seed fresca, seed stale, falhas tipadas e sucesso stale;
- orçamento único e ausência de loop;
- duas revalidações da mesma amostra por clock sequencial;
- cancelamento pré-match, durante match e pré-submit;
- erros network, unauthorized, HTTP, conflict e unknown compatíveis;
- coalescência concorrente de `.acquire` e isolamento concorrente de seeds;
- dispatch por existential;
- payloads exatos de Raw e Decided;
- HTTP 422 obrigatório;
- caminho sem ação sem gerar identidade nem submit.

Uma primeira compilação dos testes novos detectou captura test-only de `XCTestCase` em closures
`@Sendable` do Swift 6. Os valores foram extraídos antes da criação das tasks, sem mudar produção ou
enfraquecer assertions. Um revisor também detectou que a primeira versão do teste de revalidação chamava as
etapas internas separadamente; o teste final usa uma única instância, clock sequencial e o overload público.
Somente os resultados finais acima são gate.

### 18.9. Regressão dirigida e suíte completa

A regressão dirigida executou integralmente DecisionMatrix, CaptureLocation, AutoActivities, offline e
replay, além de wire/DTO, SafeApiCall, repository mapping, provider, policy, orquestrador, perfil e journal:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt06/DerivedData \
  -resultBundlePath .build/prompt06/directed-final.xcresult \
  test \
  -only-testing:CheckingTests/AutoActivitiesHelpersTests \
  -only-testing:CheckingTests/AutoActivitiesLoggingTests \
  -only-testing:CheckingTests/AutoActivitiesOfflineTests \
  -only-testing:CheckingTests/AutoActivitiesUseCaseTests \
  -only-testing:CheckingTests/CaptureLocationLoggingTests \
  -only-testing:CheckingTests/CheckRepositoryMappingTests \
  -only-testing:CheckingTests/CheckoutPreservationTests \
  -only-testing:CheckingTests/CookieStoreTests \
  -only-testing:CheckingTests/DecisionMatrixTests \
  -only-testing:CheckingTests/DtoCodingTests \
  -only-testing:CheckingTests/DuplicateEliminationTests \
  -only-testing:CheckingTests/LocationAttemptPipelineTests \
  -only-testing:CheckingTests/LocationChangeContinuationTests \
  -only-testing:CheckingTests/OfflineCheckQueueTests \
  -only-testing:CheckingTests/PendingCheckEventCodableTests \
  -only-testing:CheckingTests/PendingCheckReplayerTests \
  -only-testing:CheckingTests/SSEParserTests \
  -only-testing:CheckingTests/SafeApiCallTests \
  -only-testing:CheckingTests/ScheduledPauseTests \
  -only-testing:CheckingTests/WireEncodingTests \
  -only-testing:CheckingTests/LocationSamplePolicyTests \
  -only-testing:CheckingTests/CaptureSessionStateTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderSessionTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderComparisonTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests \
  -only-testing:CheckingTests/OrchestratorGateTests \
  -only-testing:CheckingTests/OrchestratorSingleFlightTests \
  -only-testing:CheckingTests/BackgroundReliabilityProfileTests \
  -only-testing:CheckingTests/DurableEvaluationJournalTests
```

Resultado: 374/374, zero falhas, zero skips e zero expected failures; soma interna aproximada de 3,153 s.

Suíte completa sobre o estado final exato:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt06/DerivedData \
  -resultBundlePath .build/prompt06/full-final.xcresult \
  test
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Soma interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 795 | 795 | 0 | 0 | 0 | 15,432 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 185,000 s |
| Total do `.xcresult` | 823 | 823 | 0 | 0 | 0 | 227,386 s entre início/fim |

O `.xcresult` final registra `Passed`. O Xcode emitiu mensagens ambientais repetidas de ausência da versão
do debugger durante os relaunches de UI; elas não produziram falha, skip ou alteração no app.

Build Release otimizado, sem assinatura e sem executar o app:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt06/ReleaseDerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED`. Os warnings de source exibidos continuam sendo os já registrados na baseline:
closures sem `@Sendable` em `AuthenticationDialogs`, resultados não consumidos em `KeychainStore` e um
`await` sem operação assíncrona em `CheckEventStream`. Nenhum warning novo aponta para arquivo do Prompt
06.

### 18.10. Privacidade, invariantes e sentinelas

Os novos tipos sample-aware e o contexto de submissão:

- não são `Codable`;
- não adotam descrição customizada;
- não entram no journal;
- não geram OSLog, `ActivityLogger` ou telemetria nova;
- não persistem amostra, coordenada, identidade de evento ou conteúdo HTTP.

As buscas finais por `LocationSample`, `LocationAttemptInput`, resultados de aquisição/resolução e contexto
de submissão nos modelos/store/protocolo do journal produziram zero matches. As buscas por
`String(describing:)`, `localizedDescription`, OSLog e logger novo nos arquivos desta fase também
produziram zero matches. O teste de whitelist do journal passou dentro das suítes dirigida e completa.

Trinta e três sentinelas estritos de matriz, DTO/wire/API, modelos de check, offline/replay, check manual,
acidente, teste single-flight, logs e notificações foram recalculados; 33/33 permanecem byte-identical ao
Prompt 01 e todos apresentam diff vazio. Principais provas:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |

`RunAutomaticActivitiesUseCase.swift`, `OrchestratorSeams.swift` e os fakes mudaram legitimamente para
adicionar o seam. A revisão por símbolo e os testes exatos comprovaram a preservação da matriz, parâmetros
do matcher, payload/id/time, 422, Raw/Decided, replay e mensagens existentes.

### 18.11. Gates, revisões e testes não executados

| Gate | Resultado |
|---|---|
| `AutoActivities.swift` sem diff funcional | atendido; arquivo byte-identical |
| Fachadas e `AutoActivitiesResult` legados compatíveis | atendido |
| `finalSample` stale: provider zero/matcher zero | atendido |
| Seed stale: uma aquisição e nenhum loop | atendido |
| Revalidação imediatamente antes do matcher | atendido por duas leituras de clock no caminho público |
| Cancelamento observado não chama match/submit seguinte | atendido |
| Raw/Decided sem duplicidade e com payload/id/time preservados | atendido |
| HTTP 422 não vira falha de GPS | atendido |
| Fila, replay, wire, HTTP e mensagens existentes | atendido por testes e sentinelas |
| Nenhum gatilho fornece amostra nesta fase | atendido por `rg` e revisão do orquestrador |
| Todos os configs continuam legados | atendido |
| Nenhum motor ou submit duplo | atendido |
| Swift 6 sem novo `@unchecked Sendable` em produção | atendido |
| Nenhuma coordenada ou segredo em diagnóstico persistido | atendido |
| Suíte completa | 823/823 |
| Build Release não assinado | atendido |
| `git diff --check` | limpo após a atualização documental final, incluindo os arquivos untracked da fase |

Três revisões read-only independentes auditaram dispatch, perfis, concorrência, orçamento de aquisição,
cancelamento, payload, privacidade, sentinelas e cobertura. Elas identificaram apenas lacunas de teste, que
foram corrigidas antes dos gates finais: revalidação pelo caminho público, seed fresca, sucesso stale,
cancelamento tipado, coalescência pelo overload explícito, cancelamento pré-submit e remoção de `sleep`
temporal do teste de seeds. Depois das correções, nenhuma revisão deixou defeito alto ou médio pendente.

Não executados:

- iPhone físico, percurso, bateria, rádio, thermal, cold relaunch real e wakes oportunistas — exigem
  autorização específica e pertencem aos prompts físicos;
- runtime candidato em build distribuível — todos os configs permanecem no legado;
- integração de sample em TIMER/significant-change/geofence — pertence aos Prompts 09 e 10;
- taxonomia externa rica por estágio — pertence ao Prompt 07;
- completion exactly-once depois de submit já despachado — pertence ao Prompt 14;
- `validate_background_simulator.sh` — já passou no Prompt 01 e não prova este seam em hardware;
- build Staging separado — Debug executou a suíte completa, Release compilou otimizado e os configs foram
  cobertos por teste;
- backend mutável, assinatura, upload, TestFlight, deploy, commit ou push — não autorizados.

Riscos e pendências:

- o perfil legado mantém deliberadamente a resolução histórica sem freshness;
- os defaults do initializer poderiam ser combinados incorretamente por uma composição futura, embora
  live e preview atuais injetem comportamento explícito e coerente;
- cancelamento cooperativo não desfaz matcher/submit que já tenha começado;
- depois de submit despachado, a resposta indeterminada ainda precisa da política do Prompt 14;
- Simulator e testes não provam rádio, consumo, relaunch pelo daemon ou entrega física de wake;
- os parâmetros 10 s/2 s continuam ponto de partida de ensaio, não valor definitivo de rollout.

### 18.12. Estado Git e handoff

HEAD e upstream continuam idênticos:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

O worktree inclui as mudanças acumuladas e não commitadas dos Prompts 02 a 06. Mudanças anteriores do
usuário não foram revertidas nem reformatadas globalmente. Não houve commit, push ou publicação.

Estado Git acumulado ao fechar a fase:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida para esta fase:

```text
refactor(ios): support pre-acquired location samples
```

## 19. Execução do Prompt 07 — resultado operacional tipado sem alterar a matriz

### 19.1. Objetivo, baseline e limite da fase

O Prompt 07 foi implementado sobre o mesmo baseline Git
`cc66dc131541cb66798e2de44a06d28a32b6df5a`, que continua idêntico ao upstream. Não houve pull, rebase,
reset, commit, push, tag, assinatura, upload, deploy ou chamada mutável ao backend.

O objetivo desta fase foi impedir que a causa operacional se perdesse antes de chegar ao orquestrador,
sem alterar o resultado legado consumido pelo app. O limite foi mantido:

- `AutoActivitiesResult` continua sendo a fachada de negócio;
- `callAsFunction` continua disponível e delega uma única vez para `execute`;
- o orquestrador consome uma única execução e continua reconciliando somente `.result`;
- nenhuma falha tipada de match ou submit dispara relogin nesta fase;
- nenhum retorno foi ligado ao journal durável; essa integração pertence ao Prompt 08;
- nenhum trigger fornece seed ou amostra final;
- Debug, Staging e Release continuam explicitamente em `legacyWithDiagnostics`;
- não existe caminho paralelo de captura, matcher, matriz ou submit para comparação.

### 19.2. Envelope operacional e projeção sanitizada

Foi criado `AutomaticActivitiesExecution`, somente em memória, contendo:

- o `AutoActivitiesResult` legado;
- `AutomaticActivitiesTrace`, com estágio máximo, trace de captura, falha e disposição offline;
- `AutomaticSubmissionContext` somente quando a matriz já produziu uma decisão.

Os estágios são fechados e ordenados:

1. `started`;
2. `admitted`;
3. `captureStarted`;
4. `captured`;
5. `matched`;
6. `decisionCompleted`;
7. `submitStarted`;
8. `submitted`.

O trace de captura transporta somente metadados sanitizáveis:

- origem operacional `freshCapture`, `seed` ou `bestPartial`;
- origem física grosseira `standardCapture` ou `significantChange`;
- indicador de reaproveitamento;
- qualidade `usable`, `coarse` ou validade rejeitada tipada.

Uma revisão independente detectou que o segundo consumidor de uma captura coalescida era inicialmente
classificado como `seed`. Antes do gate final, a implementação foi ajustada para preservar a origem real da
captura e mudar somente o indicador de reaproveitamento. O teste concorrente correspondente foi atualizado
e todas as suítes foram repetidas sobre esse estado.

As causas operacionais ficam separadas por estágio:

- aquisição: timeout, indisponibilidade, permissão ou cancelamento;
- rejeição da amostra: validade tipada;
- match: `ApiError` integral em memória;
- submit: `ApiError` integral em memória;
- cancelamento cooperativo: razão tipada.

O efeito offline não substitui a causa. Uma falha `.network` pode coexistir com:

- `queuedRaw`, quando o match não pôde ser concluído e já existia leitura;
- `queuedDecided`, quando a matriz já havia produzido o evento lógico.

`SanitizedAutomaticActivitiesFailure` e `SanitizedAutomaticApiFailure` formam uma projeção fechada para
integração futura:

- `detail` de HTTP não possui campo de destino;
- `description` de erro desconhecido não possui campo de destino;
- somente status HTTP entre 100 e 599 pode sobreviver como número;
- nenhum `Error` cru é transportado;
- a projeção não possui coordenadas, identidade de evento, corpo, URL, header ou identificador de região.

Nenhum tipo operacional novo adota `Codable`, `CustomStringConvertible` ou descrição de debug. O contexto
de submissão conserva internamente os campos já necessários ao submit/fila, mas não entra no journal, em
OSLog, no histórico humano ou em telemetria.

### 19.3. Captura e match com falha tipada

`SampleAwareLocationCapturing.execute` agora retorna `LocationCaptureExecution`. A fachada
`LocationCapturing.callAsFunction` continua projetando somente `LocationCaptureResult`.

`CaptureLocationUseCase` preserva:

- falha de aquisição tipada sem mudar `.timeout`/`.noPermission` da fachada;
- `ApiError` exato do matcher, incluindo unauthorized, HTTP, conflict, network e unknown;
- leitura somente para `.network`, exclusivamente para o enqueue `Raw` já existente;
- rejeição de amostra e cancelamento sem permitir sucesso consumível;
- estágio máximo e trace de captura sem coordenadas.

`CoalescingLocationCapture` passou a compartilhar o envelope completo para pedidos `.acquire` do mesmo
threshold. A identidade e o cancelamento existentes permanecem:

- seed e amostra final continuam fora do broker;
- cancelar um consumidor não cancela os demais;
- o último consumidor cancelado cancela o trabalho base;
- cada waiter recebe exatamente um terminal;
- o consumidor que se juntou à captura recebe `reused = true`, sem falsificar sua origem.

Não foi adicionada captura, chamada de match ou retry. Os call sites vivos continuam enviando
`locationAttempt: .acquire`.

### 19.4. Motor automático e compatibilidade de efeitos

`RunAutomaticActivitiesUseCase` agora expõe:

```swift
func execute(...) async -> AutomaticActivitiesExecution
```

Os dois overloads de `callAsFunction(...) async -> AutoActivitiesResult` delegam para `execute` e retornam
`.result`. O corpo possui um único caminho de captura, decisão e submit.

Compatibilidade verificada por teste e revisão:

- ausência de projeto continua encerrando antes da captura e com a mesma mensagem;
- baixa precisão continua produzindo o mesmo episódio/ação esperada;
- sem decisão continua `.noAction`, sem gerar identidade ou submit;
- sucesso continua enviando exatamente um submit e a mesma notificação/log;
- erro de match `.network` continua gerando no máximo um `Raw`;
- erro de submit `.network` continua gerando no máximo um `Decided`;
- o evento `Decided` usa o mesmo ID, horário, ação, local lógico e informe do submit;
- erros permanentes não entram indevidamente na fila;
- HTTP 422 continua sendo rejeição do backend na etapa de submit;
- 422 não é remapeado para timeout, permissão ou falha de GPS;
- `AutoActivitiesResult` continua exatamente igual para todos os consumidores legados.

O `AutomaticSubmissionContext` é criado uma vez, depois da decisão e antes do submit. Ele fica disponível
no envelope quando já existe decisão, preparando o tratamento de resposta indeterminada do Prompt 14 sem
gerar um segundo ID ou horário.

### 19.5. Options/state tipados e autenticação preservada

Foi introduzido `BackgroundInputResolution<Value>`, também somente em memória:

- `.resolved(value, source, upstreamFailure)`;
- `.failed(ApiError)`.

As fontes fechadas são:

- `remote`;
- `cache`;
- `offlineDefault`.

Uma resolução pode transportar valor e falha simultaneamente. Isso preserva a causa `.network` quando o
comportamento histórico usa cache expirado ou defaults offline.

`getLocationOptions`, `getRemoteState` e `getFreshRemoteState` agora devolvem valor, fonte e falha sem
colapsar para `nil`. A semântica anterior foi mantida:

- TTL de options inalterado e limite exato coberto;
- TTL de state inalterado e limite exato coberto;
- cache de state continua isolado por conta;
- leitura fresh continua ignorando cache e atualizando o cache regular após sucesso;
- somente `.network` permite fallback de options;
- sem cache, o fallback continua com os mesmos valores existentes;
- unauthorized de options/state continua acionando apenas o fluxo de sessão que já existia;
- falha de state regular continua passando `nil` ao motor, como antes;
- falha de options sem fallback continua interrompendo a run antes de state/motor.

O orquestrador chama `runAutomaticActivities.execute` uma vez e usa somente `.result` nas regras de retry,
notificação e cache. Unauthorized de match/submit chega tipado ao orquestrador, mas não ativa relogin,
retry ou notificação nova. Essa separação foi coberta por spies de auth e notificação.

### 19.6. Arquivos alterados nesta fase

Produção:

- `Checking/Domain/Models/AutomaticActivitiesExecution.swift` — novo;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`.

Testes:

- `CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift` — novo;
- `CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift`;
- `CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift`;
- `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `CheckingTests/Network/SafeApiCallTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift` — novo;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`.

Documentação:

- `docs/plans/background_reliability_execution.md`.

Não houve alteração em `project.yml`; as pastas dos targets são recursivas. O projeto foi regenerado pelo
processo documentado:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

Nenhuma dependência foi instalada ou atualizada.

### 19.7. Testes novos

`AutomaticActivitiesExecutionTests` adicionou 7 métodos e 25 cenários tabelados:

- sucesso e contexto exato;
- quatro falhas de aquisição;
- seis falhas de match;
- enqueue `Raw` exato;
- seis falhas de submit;
- enqueue `Decided` exato;
- remoção de detail/description na projeção sanitizada.

`BackgroundDependencyResolutionTests` adicionou 14 métodos cobrindo:

- remoto/cache e limites exatos de TTL;
- fallback network com cache e sem cache;
- unauthorized, 422, outro 4xx, 500, conflict e unknown;
- origem e falha upstream;
- cache por conta e bypass fresh;
- comportamento vivo diante de falhas;
- ausência de relogin novo para unauthorized de match/submit.

`SafeApiCallTests` ganhou o caso de outro 4xx com preservação integral em memória. Os testes sample-aware do
Prompt 06 também passaram a verificar o envelope tipado, a origem/reuso da coalescência, cancelamento e
falha de match.

Uma primeira compilação focal detectou uma referência test-only a `Self` em valor armazenado de fake. Ela
foi substituída pelo tipo concreto; nenhum teste chegou a executar nessa tentativa e nenhum arquivo de
produção foi alterado por essa correção. Em seguida, `LocationAttemptPipelineTests` passou 20/20.

Antes da observação final de coalescência, os gates já haviam passado em 55/55, 347/347 e 845/845. Como o
trace foi corrigido, todos os gates abaixo foram repetidos; somente os resultados pós-correção são
considerados finais.

### 19.8. Gates automatizados finais

#### Testes focais

Comando final:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt07/final-targeted-derived \
  -resultBundlePath .build/prompt07/final-targeted.xcresult \
  -only-testing:CheckingTests/AutomaticActivitiesExecutionTests \
  -only-testing:CheckingTests/BackgroundDependencyResolutionTests \
  -only-testing:CheckingTests/LocationAttemptPipelineTests \
  -only-testing:CheckingTests/SafeApiCallTests \
  test
```

Resultado autoritativo do `.xcresult`: 55/55, zero falhas, zero skips e zero expected failures. A soma
interna foi aproximadamente 0,323 s; o resultado completo, incluindo build/boot, durou aproximadamente
65,238 s.

#### DecisionEngine, Offline, Orchestrator e Network

As 30 classes encontradas nessas quatro pastas foram executadas integralmente com o comando:

```sh
prompt07_final_selectors=()
while IFS= read -r prompt07_final_class; do
  prompt07_final_selectors+=("-only-testing:CheckingTests/${prompt07_final_class}")
done < <(
  rg -o '^final class [A-Za-z0-9_]+Tests' \
    CheckingTests/DecisionEngine \
    CheckingTests/Offline \
    CheckingTests/Orchestrator \
    CheckingTests/Network |
  sed -E 's/.*final class ([A-Za-z0-9_]+Tests)/\1/' |
  sort -u
)
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt07/final-targeted-derived \
  -resultBundlePath .build/prompt07/final-regression.xcresult \
  "${prompt07_final_selectors[@]}" \
  test
```

Resultado autoritativo do `.xcresult`: 347/347, zero falhas, zero skips e zero expected failures. A soma
interna foi aproximadamente 2,131 s; a execução completa durou aproximadamente 10,748 s.

#### Suíte completa

Comando final:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt07/full-derived \
  -resultBundlePath .build/prompt07/final-full.xcresult \
  test
```

| Escopo | Executados | Passaram | Falharam | Skips | Expected failures | Soma interna |
|---|---:|---:|---:|---:|---:|---:|
| `CheckingTests` | 817 | 817 | 0 | 0 | 0 | 18,970 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 0 | 215,913 s |
| Total do `.xcresult` | 845 | 845 | 0 | 0 | 0 | 259,709 s entre início/fim |

O `.xcresult` final registra `Passed`. Os relaunches dos testes de UI repetiram o aviso ambiental já
conhecido sobre a versão do debugger do Simulator; ele não gerou falha ou skip.

#### Build Release

Comando final, sem assinatura e sem executar o app:

```sh
xcodebuild \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt07/final-release-derived \
  build \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED` para arm64 e x86_64. Os warnings de fonte são os mesmos já presentes na
baseline:

- closures de Binding sem anotação `@Sendable` em `AuthenticationDialogs.swift`;
- resultados de `withLock` não consumidos em `KeychainStore.swift`;
- `await` sem operação assíncrona em `CheckEventStream.swift`;
- aviso ambiental da ferramenta de metadata sem dependência de App Intents.

Nenhum warning aponta para arquivo alterado no Prompt 07.

### 19.9. Privacidade, invariantes e sentinelas

As buscas e a revisão estrutural finais confirmaram:

- nenhum envelope operacional novo é `Codable`;
- nenhum envelope operacional é referenciado pelo schema/store/protocolo do journal;
- `detail` e `description` existem somente no `ApiError` em memória e são removidos pela projeção fechada;
- não foi criado OSLog, `ActivityLogger`, analytics ou telemetria para o envelope;
- não foi adicionada coordenada, identidade de evento, corpo HTTP, URL ou identificador de região a um
  tipo persistível;
- não há novo `String(describing:)` ou `localizedDescription` de erro externo na produção desta fase;
- não há novo `@unchecked Sendable` nos tipos de produção;
- o Domain continua sem importar Core Location ou UIKit para esses modelos;
- todos os configs continuam resolvendo `legacyWithDiagnostics`.

Os 33 arquivos-sentinela estritos foram recalculados; 33/33 continuam byte-identical ao Prompt 01, sem
diff. Provas principais:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Data/DTOs/CheckWireEnums.swift` | `e6c49aee2cb9daab0676f972116eb2fd1cb27061` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |

`RunAutomaticActivitiesUseCase.swift`, `CaptureLocationUseCase.swift`, `OrchestratorSeams.swift`,
`BackgroundCheckOrchestrator.swift` e os fakes mudaram legitimamente. A revisão por símbolo e os testes
comprovaram que matcher, payload, horários, IDs, filas, replay, mensagens, TTL, cache e autenticação
existente foram preservados.

### 19.10. Gates, revisão independente e riscos

| Gate | Resultado |
|---|---|
| Matriz e expectativas legadas sem alteração | atendido; sentinela e 347 testes dirigidos |
| `callAsFunction` e `AutoActivitiesResult` compatíveis | atendido |
| Unauthorized chega tipado até o orquestrador | atendido para options/state/match/submit |
| Nenhuma nova chamada de rede | atendido por spies e revisão de call sites |
| Nenhum relogin novo | atendido por spies de auth/notificação |
| HTTP 422 continua rejeição de submit | atendido |
| Raw/Decided, payload, ID e horário preservados | atendido |
| Detail/description ausentes da projeção sanitizada | atendido |
| Nenhuma coordenada no journal/envelope persistível | atendido |
| Sem motor, captura, matcher ou submit duplo | atendido |
| Todos os configs ainda legados | atendido |
| DecisionEngine/Offline/Orchestrator/Network | 347/347 |
| Suíte completa | 845/845 |
| Build Release não assinado | atendido |
| `git diff --check` | limpo antes da atualização documental; repetido no handoff final |

Uma auditoria read-only independente não encontrou defeito alto ou médio. Ela confirmou sentinelas,
dispatch único, preservação de `ApiError`, sanitização, filas, identidade/horário, TTL/cache e ausência de
relogin novo. A única ambiguidade diagnóstica encontrada — classificar coalescência como seed — foi
corrigida e retestada antes dos gates finais.

Testes existentes cobrem cancelamento enquanto o matcher está suspenso e impedem consumo do retorno
tardio. A situação posterior ao dispatch do submit continua deliberadamente pendente: cancelamento
cooperativo não desfaz uma requisição já enviada, e a resposta indeterminada exige o controller exactly-once
do Prompt 14.

Não executados:

- iPhone físico, percurso, rádio, bateria, energia, thermal, cold relaunch real ou wake do daemon — exigem
  autorização específica e pertencem aos prompts físicos;
- runtime de `candidate` em build distribuível — todos os configs permanecem no legado;
- persistência dos novos terminais — pertence ao Prompt 08;
- relogin por estágio — pertence ao Prompt 13;
- resolução exactly-once depois de submit despachado — pertence ao Prompt 14;
- `validate_background_simulator.sh` — já passou no Prompt 01 e não valida esta taxonomia;
- build Staging separado — Debug executou toda a suíte, Release compilou otimizado e os configs têm teste;
- backend mutável, assinatura, upload, TestFlight, deploy, commit ou push — não autorizados.

Riscos residuais:

- os novos envelopes ainda não geram observabilidade durável até o Prompt 08;
- match/submit já despachados dependem de cancelamento cooperativo; submit indeterminado fica para o Prompt
  14;
- o Simulator não prova comportamento de rádio, entrega real de wake, relaunch pelo daemon ou energia;
- o caminho candidato permanece inativo em builds distribuíveis;
- os valores 10 s/2 s continuam ponto de partida para ensaio, não calibração final.

### 19.11. Estado Git e handoff

HEAD e upstream continuam idênticos:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

O worktree contém legitimamente as mudanças acumuladas e não commitadas dos Prompts 02 a 07. Nenhuma
mudança anterior foi revertida, sobrescrita ou reformatada globalmente.

Estado Git acumulado ao fechar a fase:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida para esta fase:

```text
refactor(ios): preserve evaluation failures by stage
```

## 20. Execução do Prompt 08 — terminais duráveis em todos os caminhos do orquestrador

### 20.1. Objetivo, baseline e limite da fase

O Prompt 08 foi implementado sobre o mesmo baseline Git
`cc66dc131541cb66798e2de44a06d28a32b6df5a`, que continua idêntico a `origin/main`. A origem permanece
`https://github.com/tscode-com-br/checking-swift.git`. Não houve pull, merge, rebase, reset, commit,
push, tag, version bump, assinatura de distribuição, upload ou deploy.

O objetivo desta fase foi alcançado: toda chamada de `runOnce` que vence a admissão atual abre um único
record e o encerra uma única vez com terminal e estágio tipados. O journal continua best-effort e nunca
altera a decisão de negócio. O limite da fase também foi preservado:

- o single-flight existente continua rejeitando o segundo wake normal;
- TIMER continua com a mesma quantidade de capturas, inclusive seu preflight atual;
- nenhum trigger fornece seed ou amostra pré-adquirida;
- a matriz, matcher, submit, fila offline, replay, IDs e horários não mudaram;
- a política de relogin continua sendo a existente; nenhum relogin foi adicionado para match/submit;
- os três configs continuam selecionando `legacyWithDiagnostics`;
- não foi implementado controller de expiração de BGTask/lease, que pertence ao Prompt 14.

O Prompt 08 não adicionou UI, telemetria, analytics, exportação, log humano por terminal nem chamada de
rede. A instrumentação durável é local e usa o store separado criado no Prompt 03.

### 20.2. Admissão, `begin`/`finish` e conclusão exatamente uma vez

`BackgroundCheckOrchestrator.runOnce` agora retorna, de forma descartável, um `EvaluationCompletion` em
memória:

- `evaluationID`;
- `outcome`;
- `completedBeforeExpiration`;
- `admitted`.

A ordem implementada é:

1. aguardar eventual barrier de invalidação já existente;
2. criar um UUID aleatório para a invocação;
3. capturar as gerações de retry e pausa;
4. decidir a admissão dentro do actor do orquestrador;
5. para uma admissão, marcar `isRunning`, aguardar `journal.begin` no estágio `restore` e executar o fluxo;
6. receber um `AdmittedEvaluationResult` tipado, sem retornos que escapem do finalizador central;
7. aguardar exatamente um `journal.finish`;
8. reproduzir as entradas compatíveis no `EvaluationLog` legado;
9. encerrar o token de background, limpar `isRunning` e drenar somente os pendentes históricos permitidos;
10. retornar o mesmo ID e o terminal persistido no `EvaluationCompletion`.

Não foi usado `defer` assíncrono. Existe um único call site de `begin` e um único call site de `finish` no
fluxo admitido. `runOnceLocked` retorna `LockedEvaluationResult`, que carrega terminal e eventual entrada
legada, e `runAdmittedEvaluation` concentra restore, lease, relogin/retry e guards.

Uma chamada que encontra `isRunning == true` recebe `admitted == false` e `.notAdmitted`, sem `begin` nem
`finish`. Isso não viola exactly-once porque o wake não foi admitido. O drop do segundo wake normal e os
flags bounded já existentes para retry/pausa foram preservados sem coalescer ou enfileirar gatilhos novos;
essa política somente muda no Prompt 11.

O protocolo do journal é não lançável e as implementações reais isolam erro de I/O. Os testes exercitam
o no-op e uma implementação indisponível: ainda assim, o resultado de negócio e o encerramento do lease
permanecem os mesmos.

### 20.3. Taxonomia e estágios duráveis

O schema ganhou estágios aditivos para representar o pipeline real:

- `restore`;
- `settings`;
- `pause`;
- `options`;
- `movement`;
- `state`;
- `acquisition`;
- `match`;
- `decision`;
- `submit`;
- `notification`.

Os valores antigos do schema foram mantidos para compatibilidade de leitura. A função `furthest` usa uma
ordem total explícita; não depende da ordem textual nem de line numbers.

Mapeamentos centrais implementados:

| Caminho | Terminal | Estágio típico |
|---|---|---|
| chave ausente | `noKey` | `settings` |
| automático desligado | `toggleOff` | `settings` |
| pausa ativa | `paused` | `pause` |
| contexto incompleto | `notConfigured` | `settings` |
| TIMER sem movimento | `skippedNoMovement` | `movement` |
| timeout de aquisição | `locationTimeout` | `acquisition` |
| serviço/fix indisponível | `unavailable` | `acquisition` |
| permissão negada tipada | `permissionDenied` | `acquisition` |
| precisão insuficiente | `accuracyTooLow` | `acquisition` ou `match` |
| falha de rede sem enqueue | `networkFailure` | estágio da falha |
| 401/403 tipado | `unauthorized` | estágio da falha |
| relogin sem sucesso | `reloginFailed` | estágio que expirou a sessão |
| HTTP permanente, inclusive 422 | `httpRejected` | `options`, `state`, `match` ou `submit` |
| conflito | `conflict` | estágio da falha |
| nenhuma ação | `noAction` | `decision` |
| enqueue Raw | `queuedOfflineRaw` | `match` |
| enqueue Decided | `queuedOfflineDecided` | `submit` |
| check-in confirmado | `submittedCheckIn` | `submit` |
| check-out confirmado | `submittedCheckOut` | `submit` |
| geração invalidada | `staleContext` | estágio máximo observado |
| cancelamento cooperativo genérico | `cancelled` | estágio máximo observado |
| razão tipada de expiração | `expired` | estágio máximo observado |
| fallback impossível/inconsistente | `internalFailure` | estágio máximo observado |

`abandoned` continua sendo produzido pela reconciliação de órfãos do journal no launch, implementada no
Prompt 03. `submissionOutcomeUnknown` foi adicionado ao vocabulário e à precedência, mas não é inventado
sem evidência: sua emissão real fica para o controller de submit/expiração do Prompt 14.

HTTP 422 continua sendo uma rejeição do backend no estágio de submit. O journal recebe somente status e
classe HTTP; ele nunca reclassifica 422 como falha de GPS.

### 20.4. Precedência, cancelamento e efeitos irreversíveis

Quando uma geração muda ou a `Task` é cancelada depois que o motor retorna, o orquestrador não pode apagar
um efeito já confirmado. A precedência fechada é:

```text
submitted
  > queued Raw/Decided
  > submissionOutcomeUnknown
  > expired
  > staleContext
  > cancelled
  > demais resultados reversíveis
```

Para prioridades protegidas equivalentes, a primeira evidência vence. Para resultados comuns, a tentativa
mais recente descreve o desfecho final. O estágio persistido é sempre o estágio mais avançado entre as duas
evidências.

Testes com gates controlados provam:

- check-in submetido vence cancelamento genérico posterior;
- enqueue Raw vence cancelamento genérico posterior;
- enqueue Decided vence invalidação de geração posterior;
- expiração tipada vence invalidação e cancelamento genérico;
- contexto stale tipado vence cancelamento genérico;
- exatamente um finish permanece mesmo nessas corridas;
- a entrada legada é preservada somente quando houve efeito irreversível.

O cancelamento observado antes do motor/matcher impede a chamada seguinte, como já comprovado desde os
Prompts 05–07. Esta fase não tenta cancelar retroativamente uma requisição de submit já despachada.

### 20.5. Auth, dependências e compatibilidade legada

Options e state continuam usando TTL, cache e fallback existentes. Seus envelopes tipados preservam
origem e `ApiError`, mas o Prompt 08 apenas os converte para terminal quando o fluxo realmente encerra.
Uma falha de state que historicamente permite seguir com `currentState == nil` continua permitindo o mesmo
motor e, portanto, pode terminar em `noAction`/submit em vez de ser forçada a `networkFailure`.

O relogin existente continua no máximo uma vez. Foram adicionados guards de geração e cancelamento:

- depois de aguardar a chave;
- depois de aguardar o idioma e imediatamente antes de despachar login;
- depois do retorno do login;
- antes de repetir `runOnceLocked`;
- no caminho de falha do login.

Um teste focal bloqueia especificamente a segunda leitura de chave, após um unauthorized de options,
invalida o contexto e prova `auth.login == 0`, `engine retry == 0`, um begin e um finish stale. Outro caso
prova que um segundo unauthorized depois de relogin bem-sucedido encerra como `unauthorized`, sem loop.

Unauthorized de match/submit chega tipado ao journal, mas não ativa relogin novo. A política de acidente em
background não foi instrumentada nem modificada; `runAccidentCheck` continua independente conforme o
contrato.

As descrições existentes do `ActivityLogger` não foram editadas. O adapter só grava no `EvaluationLog`
volátil os mesmos outcomes/accuracy/local/ação que o fluxo antigo já produzia. Testes verificam as strings
byte-exact para toggle, skip e no-action, além da compatibilidade do histórico em todos os casos tabelados.

### 20.6. Notificações e semântica conservadora

O seam vivo de atividade é síncrono e fire-and-forget: internamente ele abre uma `Task` para
`UNUserNotificationCenter.add` e não devolve sucesso/falha. Por isso:

- quando o pedido alcança o seam, o terminal avança para `notification`;
- `notificationScheduled` permanece `nil`, significando confirmação desconhecida;
- quando nenhuma notificação deve ser pedida, o terminal submetido registra `false`;
- nenhum valor afirma entrega ou exibição pelo iOS.

Essa decisão evita persistir um fato falso e mantém o contrato de notificação intacto. Evoluir o seam para
confirmar agendamento seria uma mudança separada.

### 20.7. Privacidade e concorrência Swift 6

O mapper durável consome somente:

- estágio fechado;
- `trace.failure.sanitized`;
- source/reused sanitizados;
- status/classe HTTP em whitelist;
- terminal fechado.

Ele deliberadamente não lê nem transfere `AutomaticSubmissionContext`. O record não recebe:

- latitude, longitude, altitude, velocidade, course ou amostra;
- chave, senha, cookie, token, header ou body;
- nome de usuário, local ou projeto;
- `clientEventId` ou `eventTime` de negócio;
- URL ou region ID;
- `ApiError.detail`, `unknown.description`, `Error` cru ou `localizedDescription`.

Os testes usam sentinelas distintas para chave, projeto, local, ID, detail e description e inspecionam a
representação terminal. O scanner por whitelist do journal continuou verde. Não foi adicionado
`String(describing:)`, analytics, telemetria remota nem OSLog com dados livres.

`EvaluationCompletion`, terminais e fakes que cruzam atores são `Sendable`. O journal e o fake de execução
com gate são actors; os fakes mutáveis existentes usam seus locks históricos. Não foi introduzido
`@unchecked Sendable` em produção nesta fase.

### 20.8. Arquivos alterados nesta fase

Produção:

- `Checking/App/AppEnvironment.swift` — injeta no orquestrador a mesma instância viva/preview do journal;
- `Checking/Features/Check/CheckViewModelSeams.swift` — seam acompanha o retorno descartável;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift` — admissão, finalização central,
  terminais, precedência, adapter legado e guards;
- `Checking/Platform/Background/EvaluationJournalModels.swift` — estágios/terminais aditivos e
  `EvaluationCompletion`.

Testes:

- `CheckingTests/Auth/CheckViewModelFakes.swift` — fake compatível com a conclusão tipada;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift` — journal recorder, guard, gates/contadores e injeção;
- `CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift` — novo, com 18 métodos e matrizes
  internas.

Documentação:

- `docs/plans/background_reliability_execution.md`.

Nenhum arquivo de matriz, DTO/wire, fila, replay, check manual, acidente ou mensagem humana foi alterado.
`project.yml` não mudou; o projeto ignorado foi regenerado pela ferramenta documentada:

```sh
.build/tools/XcodeGen/.build/arm64-apple-macosx/release/xcodegen generate --spec project.yml
```

Resultado: projeto criado com sucesso. Nenhuma dependência foi atualizada.

### 20.9. Cobertura nova

`DurableEvaluationTerminalTests` possui 18 métodos, além de casos tabelados, cobrindo:

- noKey;
- toggle off com log humano byte-exact;
- paused e grace/no-action;
- trigger de retry obsoleto e ativação de pausa obsoleta;
- options 422, outro 4xx, 500, conflict, unknown e unauthorized;
- state com falha e fallback legado;
- timeout, indisponibilidade e permissão;
- baixa precisão;
- match/submit network;
- filas Raw e Decided;
- submit 422 e unknown;
- noAction, notConfigured, check-in e check-out;
- notificação pedida/desabilitada e trace sanitizado;
- stale context, cancelamento e expiração tipada;
- precedência de efeitos irreversíveis;
- invalidação durante await normal e durante preparação do relogin;
- relogin success, failure e segundo unauthorized;
- Task cancellation;
- TIMER skip;
- drop da segunda chamada sem novo record;
- journal no-op/indisponível sem impacto no negócio.

Cada caminho admitido asserta um begin, um finish, mesmo UUID, trigger, estágio, terminal e ausência de
coalescência indevida. Os testes também verificam quantidade de chamadas ao motor/auth/repository,
encerramento do background token, `EvaluationLog` e side effects.

### 20.10. Gates automatizados finais

#### Journal persistente existente

Comando:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/DerivedData-prompt08-persistence \
  -only-testing:CheckingTests/DurableEvaluationJournalTests \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: 19/19, zero falhas. Soma interna 3,607 s; sessão 3,619 s. Isso inclui I/O indisponível,
corrupção, schema, retenção, concorrência, idempotência, órfãos e scanner de privacidade.

#### Terminais duráveis

Comando final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt08/final-terminal-v2-derived \
  -resultBundlePath .build/prompt08/final-terminal-v5.xcresult \
  -only-testing:CheckingTests/DurableEvaluationTerminalTests
```

Resultado: 18/18, zero falhas, zero skips. Soma interna 0,145 s; operação de teste 14,650 s.

#### DecisionEngine e Orchestrator

As 22 classes encontradas nas duas pastas foram executadas integralmente:

```sh
only_testing=()
while IFS= read -r test_class; do
  only_testing+=("-only-testing:CheckingTests/$test_class")
done < <(
  rg --no-filename -o 'final class [A-Za-z0-9_]+Tests' \
    CheckingTests/DecisionEngine \
    CheckingTests/Orchestrator |
  sed 's/final class //' |
  sort -u
)
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt08/targeted-derived \
  -resultBundlePath .build/prompt08/targeted-v2.xcresult \
  "${only_testing[@]}"
```

Resultado: 279/279, zero falhas, zero skips. Soma interna 1,830 s; operação de teste 9,877 s.

#### Suíte completa e repetição unitária final

Comando da suíte assinada completa:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt08/full-derived \
  -resultBundlePath .build/prompt08/full.xcresult
```

| Escopo | Executados | Passaram | Falharam | Skips | Soma interna |
|---|---:|---:|---:|---:|---:|
| `CheckingTests` | 832 | 832 | 0 | 0 | 19,549 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 223,216 s |
| Total | 860 | 860 | 0 | 0 | operação completa 257,780 s |

Depois dessa suíte, a revisão independente pediu três provas adicionais exclusivamente em arquivos de
teste. A produção e a UI não mudaram. A suíte unitária completa foi então repetida no estado final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt08/unit-final-derived \
  -resultBundlePath .build/prompt08/unit-final.xcresult \
  -only-testing:CheckingTests
```

Resultado final unitário: 835/835, zero falhas, zero skips. Soma interna 18,335 s; operação de teste
28,452 s. Os 28 testes de UI já haviam passado contra a mesma produção e não foram repetidos depois de
alterações exclusivamente test-only.

#### Build Release

Comando:

```sh
xcodebuild build \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt08/release-derived \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED` para arm64 e x86_64. Os warnings de produção são os mesmos da baseline:
bindings sem `@Sendable` em `AuthenticationDialogs`, `withLock` não consumido em `KeychainStore`, `await`
sem operação assíncrona em `CheckEventStream` e metadata de App Intents ausente.

A assinatura padrão foi mantida nos testes para permitir os casos de Keychain. Uma tentativa diagnóstica
anterior com `CODE_SIGNING_ALLOWED=NO` falhou somente em seis asserções dos três testes de Keychain; a
repetição assinada passou. Isso foi tratado como limitação ambiental do comando sem assinatura, não como
sucesso nem como regressão mascarada.

Uma primeira versão de dois testes concorrentes usava apenas uma quantidade fixa de `Task.yield`, o que
expôs uma corrida ambiental numa repetição. O helper passou a aguardar uma condição observável com prazo
de parede; a suíte focal, a regressão agregada e todos os unitários foram repetidos verdes. Nenhuma
asserção foi enfraquecida e nenhum `XCTSkip` foi usado.

### 20.11. Sentinelas e auditorias estruturais

Os arquivos protegidos principais continuam byte-identical ao Prompt 01:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Data/DTOs/CheckWireEnums.swift` | `e6c49aee2cb9daab0676f972116eb2fd1cb27061` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `c500ceb009013bb00346f3118c84323d2084d1f7` |

A sentinela do teste histórico de drop confirma que ele não foi editado. O warning test-only de expressão
`EvaluationCompletion` não consumida nesse teste foi deliberadamente aceito para cumprir a proibição de
alterá-lo antes do Prompt 11.

Revisões read-only independentes confirmaram:

- um begin e um finish estruturais para toda admissão;
- nenhuma escrita para wake rejeitado;
- mesma instância de journal no ambiente e orquestrador;
- ausência de coordenadas, nomes, submission context e detalhes HTTP no record;
- tipos Sendable/actors/locks coerentes;
- nenhum relogin novo para match/submit;
- precedência correta de efeitos irreversíveis.

As lacunas de cobertura inicialmente apontadas pela revisão — precedência e invalidação durante o relogin
— foram cobertas e retestadas antes dos gates finais. A semântica falsa de
`notificationScheduled == true` também foi removida.

### 20.12. Gates, riscos e testes não executados

| Gate | Resultado |
|---|---|
| Toda avaliação admitida tem terminal | atendido estruturalmente e por testes |
| `finish` exactly-once | atendido |
| Falha do journal não muda negócio | atendido |
| `EvaluationLog` legado compatível | atendido |
| `ActivityLogger` byte-exact | atendido; sentinela intacta |
| Single-flight/drop existente | atendido; sentinela intacta |
| Quantidade de capturas inalterada | atendido |
| Matriz/HTTP/offline/replay intactos | atendido; sentinelas e regressões |
| 422 permanece rejeição HTTP | atendido |
| Sem motor/submit duplo | atendido |
| Privacidade do journal | atendido |
| Swift 6 concurrency | compilação Debug/Release e revisão atendidas |
| DecisionEngine + Orchestrator | 279/279 |
| Unitários finais | 835/835 |
| UI contra a produção final | 28/28 |
| Build Release não assinado | atendido |
| Publicação | não realizada |

Riscos/pendências deliberados:

- uma expiração real de `BGAppRefreshTask` ainda chega como cancelamento genérico porque o AppDelegate não
  propaga uma razão de lease e `UIKitBackgroundTaskGuard` ainda não possui expiration handler. A
  taxonomia `.expired` e sua precedência estão prontas e testadas quando a razão tipada existe, mas a
  atribuição física correta e `completedBeforeExpiration` real pertencem ao Prompt 14;
- `submissionOutcomeUnknown` não é emitido até existir o controller exatamente uma vez do Prompt 14;
- `notificationScheduled == nil` significa que o seam fire-and-forget não confirma o sistema operacional;
- wakes concorrentes normais continuam descartados até o Prompt 11, conforme exigido nesta fase;
- o caminho candidato permanece inativo em todos os configs distribuíveis;
- Simulator não prova rádio, bateria, thermal, cold relaunch pelo daemon, oportunidade de BGTask,
  geofence em campo nem entrega de notificação.

Não executados:

- iPhone físico, percurso, bateria, energia, thermal, rádio ou cold relaunch real — não autorizados e
  pertencem aos prompts físicos;
- runtime candidate em build distribuível — configs continuam legados;
- `validate_background_simulator.sh` — já auditado no Prompt 01 e não valida exactly-once do journal;
- build Staging separado — os configs são testados por parsing, Debug executou testes e Release compilou;
- mutação de backend, commit, push, tag, assinatura de distribuição, upload, TestFlight ou deploy — não
  autorizados.

### 20.13. Estado Git e handoff

HEAD e upstream continuam:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

O worktree preserva as mudanças acumuladas e não commitadas dos Prompts 02 a 08. Estado ao encerrar a
fase, antes somente desta atualização documental final:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida:

```text
feat(ios): persist terminal background evaluation outcomes
```

## 21. Execução do Prompt 09 — `TIMER` com exatamente uma captura

### 21.1. Decisão aprovada e limite da fase

Foram registradas e aplicadas as seguintes decisões humanas:

- ordem candidata:
  `gates/projeto/opções/pausa → captura → movimento → revalidação/match imediato → state remoto quando
  necessário → matriz → submit/fila`;
- `maximumAge = 10 s`;
- `futureTolerance = 2 s`;
- amostra que envelhece antes do matcher encerra como `staleContext`, com zero match e zero recaptura; um
  wake posterior inicia uma avaliação nova;
- nenhuma alteração em `GEOFENCE`, `SIGNIFICANT_LOCATION`, `FOREGROUND`, single-flight, intervalos de
  accuracy retry, matriz, contratos HTTP ou fila/replay.

O objetivo da fase foi atingido somente no pipeline `candidate`. Todos os configs distribuíveis continuam
explicitamente em `legacyWithDiagnostics`; portanto a seleção do caminho candidato ainda exige outro build
e não constitui kill switch remoto.

### 21.2. Arquitetura final e orçamento de aquisição

O TIMER candidato ficou dividido em fases explícitas:

```text
TIMER candidate admitido
  │
  ├─ gates de chave/toggle/pausa/projeto/opções
  │
  ├─ LocationProvider.capture(seed: nil) × 1
  │
  ├─ política de movimento
  │    ├─ estacionário → skippedNoMovement
  │    ├─ falha/sem amostra → terminal tipado
  │    └─ prosseguir → mesma LocationSample
  │
  ├─ finalSample → revalidação → match × 0 ou 1
  │
  ├─ state remoto somente se o match precisar da matriz
  │
  └─ matriz existente → submit/fila existente
```

`finalSample` fecha o orçamento físico da avaliação. A fase `complete` recebe apenas um match já resolvido e
não possui acesso ao provider nem à amostra, de forma que nenhum branch posterior pode abrir uma captura
oculta. O matcher recebe os mesmos três valores da amostra avaliada pelo gate de movimento. A amostra é
revalidada no chokepoint imediatamente anterior ao matcher; se estiver vencida, o provider e o matcher não
são chamados novamente.

O state remoto foi deliberadamente movido para depois do match no caminho candidato. Assim, uma chamada de
state lenta não envelhece uma amostra antes de seu primeiro envio ao matcher. Quando a decisão não precisa
de state, essa chamada é evitada. A fachada legada continua com a ordem anterior.

### 21.3. Movimento, baseline e invalidação

A política pura `MovementGatePolicy` implementa:

```text
threshold = max(50 m, 2 × horizontalAccuracyMeters)
skip somente quando distance < threshold
```

Consequências verificadas:

- a primeira amostra válida e suficientemente precisa propõe baseline e prossegue;
- distância exatamente igual ao threshold prossegue;
- amostra grosseira não prova imobilidade, não propõe baseline e prossegue para o mesmo match;
- amostra inválida, vencida ou além da tolerância futura não chega ao matcher;
- timeout, indisponibilidade, permissão ou cancelamento sem amostra não alteram baseline;
- o episódio de accuracy retry continua ignorando o skip de movimento, mas ainda usa o pipeline candidato
  de uma captura;
- baseline e coordenadas permanecem somente em memória.

O baseline candidato não é gravado durante o gate. A avaliação carrega uma proposta em memória e somente a
confirma, de forma síncrona, depois de todos os awaits, se as gerações de automação e pausa ainda forem as
mesmas, a task não estiver cancelada e o terminal não for `cancelled`, `expired`, `staleContext` ou
`abandoned`. A invalidação cancela a operação candidata viva e limpa o baseline antes de seu primeiro
await.

Uma revisão independente encontrou também a possibilidade de uma captura legada antiga terminar depois de
uma invalidação e restaurar o baseline recém-limpo. O helper legado passou a validar as duas gerações e o
cancelamento imediatamente após sua única captura de movimento e antes de tocar precisão ou baseline. Um
teste determinístico prova que a avaliação antiga termina `staleContext` e que o TIMER seguinte não é
classificado incorretamente como estacionário.

### 21.4. Contadores observáveis por caminho

Os contadores abaixo representam avaliações admitidas que já passaram pelos gates anteriores:

| Caminho | Provider | Match | State | Submit/fila |
|---|---:|---:|---:|---:|
| candidate TIMER, primeira amostra ou movimento | 1 | 1 | 0 ou 1, depois do match | 0 ou 1 |
| candidate TIMER, estacionário | 1 | 0 | 0 | 0 |
| candidate TIMER, amostra grosseira | 1 | 1 com a mesma amostra | conforme decisão | 0 ou 1 |
| candidate TIMER, amostra vencida antes do match | 1 | 0 | 0 | 0 |
| candidate TIMER, falha sem amostra | 1 | 0 | 0 | 0 |
| candidate TIMER durante episódio de precisão | 1 | 1 | conforme decisão | 0 ou 1 |
| candidate accuracy retry | 1 | 1 | fluxo existente | 0 ou 1 |
| candidate GEOFENCE/SIGNIFICANT/FOREGROUND | 1 no motor existente | 1 | fluxo existente | 0 ou 1 |
| legado TIMER que prossegue | 2, como antes | 1 | ordem legada | 0 ou 1 |
| legado TIMER estacionário | 1, como antes | 0 | 0 | 0 |

Não há execução paralela de pipeline legado e candidato para comparação. O perfil resolve um único
`BackgroundAutomaticEvaluationPipeline`, uma única política de captura e uma única instância do motor.

### 21.5. Arquivos da fase

Arquivos de produção diretamente ajustados ou introduzidos para o Prompt 09:

- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`;
- `Checking/Platform/Background/MovementGatePolicy.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/Models/AutomaticActivitiesExecution.swift`;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/App/AppEnvironment.swift`.

Arquivos de teste diretamente ajustados ou introduzidos:

- `CheckingTests/Orchestrator/TimerSingleCaptureTests.swift`;
- `CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift`;
- `CheckingTests/Orchestrator/MovementGatePolicyTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`;
- `CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift`;
- `CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift`.

O conjunto versionável acumulado dos Prompts 02 a 09 continua listado na seção 1. Nenhum arquivo protegido
de matriz, DTO/wire, fila/replay, check manual, acidente, mensagens humanas ou teste histórico de
single-flight recebeu diff nesta fase. O diff acumulado de `CheckViewModel.swift` permanece restrito ao
wiring e ao wipe do journal autorizados no Prompt 03; submit manual, identidade, horário e fila não foram
alterados.

### 21.6. Cobertura determinística nova

`MovementGatePolicyTests` fixa:

- threshold mínimo de 50 m;
- threshold derivado de duas vezes a precisão;
- comportamento estrito abaixo/igual/acima do limite;
- fail-open para entradas inválidas.

`TimerSingleCaptureTests` cobre 15 cenários:

- primeira avaliação, estacionário e movimento;
- amostra grosseira e baseline intocado;
- timeout, indisponibilidade e cancelamento;
- amostra que vence antes do matcher;
- ausência de projeto antes de ligar localização;
- Raw por falha de match e Decided por falha de submit;
- rejeição HTTP 422 sem remapeamento para GPS nem enqueue;
- episódio e retry de precisão sem recaptura;
- relogin de state retomando a fase preparada sem recaptura, rematch ou submit duplicado;
- match antes de state lento;
- GEOFENCE, SIGNIFICANT e FOREGROUND sem mudança de contagem;
- perfil legado mantendo o fluxo de duas capturas.

`CandidateTimerContextRaceTests` usa gates assíncronos com prazo limitado, sem sleep real, para provar:

- invalidação durante match suspenso: zero Raw, state e submit;
- invalidação durante state suspenso: zero complete e submit;
- invalidação durante complete antes da intenção de submit: cancelamento propagado e zero submit;
- invalidação legada durante captura: zero contaminação do próximo baseline.

Uma expectativa preliminar de teste ainda descrevia `finalSample` como captura não reutilizada. Ela foi
corrigida para a semântica real: a amostra foi fisicamente capturada uma vez pelo orquestrador e reutilizada
pelo matcher. Em outra iteração preliminar, uma fixture de chave não sobrevivia ao sanitizador existente e
levava o teste ao fallback; apenas a fixture foi corrigida. Nenhuma asserção foi enfraquecida, nenhum
`XCTSkip` foi usado e nenhum código de produção foi alterado para acomodar essas duas falhas de teste.

### 21.7. Geração, testes finais e build Release

Projeto regenerado pelo XcodeGen local já auditado:

```sh
.tools/xcodegen/xcodegen/bin/xcodegen generate
```

Ambiente final:

| Item | Valor |
|---|---|
| Xcode | 26.6, build 17F113 |
| SDK/Simulator | iOS 26.5 |
| Destination | iPhone 17 Pro disponível, arm64 |
| HEAD/upstream | `cc66dc131541cb66798e2de44a06d28a32b6df5a` |

Teste focal final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt09/focal-final-derived \
  -resultBundlePath .build/prompt09/focal-final-20260731.xcresult \
  -only-testing:CheckingTests/TimerSingleCaptureTests \
  -only-testing:CheckingTests/CandidateTimerContextRaceTests \
  -only-testing:CheckingTests/MovementGatePolicyTests \
  -only-testing:CheckingTests/AutomaticActivitiesExecutionTests \
  -only-testing:CheckingTests/LocationAttemptPipelineTests \
  -only-testing:CheckingTests/LocationSamplePolicyTests
```

Resultado: 76/76, zero falhas, zero skips. Duração do bundle, incluindo build isolado: 55,293 s; soma
interna dos testes: 0,355 s.

Regressão integral de todas as 25 classes descobertas em `DecisionEngine` e `Orchestrator`:

```sh
only_testing=()
while IFS= read -r test_class; do
  only_testing+=("-only-testing:CheckingTests/$test_class")
done < <(
  rg --no-filename -o 'final class [A-Za-z0-9_]+Tests' \
    CheckingTests/DecisionEngine \
    CheckingTests/Orchestrator |
  sed 's/final class //' |
  sort -u
)
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt09/focal-final-derived \
  -resultBundlePath .build/prompt09/broad-final-20260731.xcresult \
  "${only_testing[@]}"
```

Resultado: 308/308, zero falhas, zero skips. Duração do bundle: 11,194 s; soma interna: 1,653 s.

Suíte assinada completa, em DerivedData isolado:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt09/full-final-derived \
  -resultBundlePath .build/prompt09/full-final-20260731.xcresult
```

| Escopo | Executados | Passaram | Falharam | Skips | Soma interna |
|---|---:|---:|---:|---:|---:|
| `CheckingTests` | 864 | 864 | 0 | 0 | 20,236 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 221,079 s |
| Total | 892 | 892 | 0 | 0 | bundle completo 314,637 s |

Build Release final:

```sh
xcodebuild build \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt09/release-final-derived \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED` para arm64 e x86_64. Permanecem apenas os warnings já observados na baseline:
bindings sem anotação Sendable, retornos de lock não consumidos, um await redundante e ausência de metadata
de App Intents. Nenhum warning novo foi atribuído ao pipeline do Prompt 09.

### 21.8. Privacidade, sentinelas e auditorias

As verificações finais confirmaram:

- `LocationSample` continua `Sendable`/`Equatable`, sem `Codable`, descrição textual ou persistência;
- a amostra não foi adicionada ao envelope do journal;
- o journal recebe somente source/reused, buckets, estágios, terminais e classes sanitizadas;
- coordenadas, nomes, contexto de submissão, region ID e detalhes de erro permanecem sem campo serializável;
- idade negativa acima da tolerância é bucket desconhecido, não uma leitura recente;
- nenhum log humano existente foi editado;
- nenhum GPS contínuo, `CLMonitor`, raio ampliado, telemetria remota ou novo background mode foi
  introduzido;
- `allowsBackgroundLocationUpdates` continua restrito ao harness Debug preexistente e não foi usado pelo
  provider/pipeline candidato;
- `git diff --check` está limpo tanto para arquivos rastreados quanto para todos os novos arquivos.

Todos os 31 arquivos protegidos revalidados permaneceram byte-identical aos hashes da seção 10. Entre os
principais:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Data/DTOs/CheckWireEnums.swift` | `e6c49aee2cb9daab0676f972116eb2fd1cb27061` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |
| `Checking/Platform/Notifications/AutoActivityNotificationsLive.swift` | `991a10105c5422ff0ee4e786a43e36fb0e1bf3c0` |
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `c500ceb009013bb00346f3118c84323d2084d1f7` |

Revisões read-only independentes confirmaram a aquisição única candidata, a ordem match antes de state, a
ausência de recaptura por `finalSample`, a correção da corrida de baseline legada e o isolamento actor/Swift
6. As observações encontradas durante a revisão foram corrigidas antes dos três gates automatizados finais.

### 21.9. Gates

| Gate | Resultado |
|---|---|
| candidate TIMER chama provider no máximo uma vez | atendido por arquitetura e testes |
| zero amostra vencida enviada ao matcher | atendido |
| match usa a mesma amostra do movimento | atendido |
| state lento não causa reenvio/recaptura | atendido |
| baseline grosseiro/cancelado/inválido não é adotado | atendido |
| accuracy retry mantém comportamento | atendido |
| GEOFENCE/SIGNIFICANT/FOREGROUND inalterados | atendido |
| legado preserva contagens e ordem | atendido |
| matriz/payload/IDs/tempo/fila/notificação | atendido por sentinelas e regressão |
| HTTP 422 permanece rejeição de backend | atendido |
| sem duplicate enqueue/submit nos cenários cobertos | atendido |
| journal sem coordenadas/dados proibidos | atendido |
| todos os configs permanecem legados | atendido |
| testes focais | 76/76 |
| DecisionEngine + Orchestrator | 308/308 |
| suíte completa | 892/892 |
| build Release | atendido |
| `git diff --check` | limpo |
| publicação | não realizada |

### 21.10. Riscos, limites e testes não executados

Limites deliberadamente preservados para fases posteriores:

- cancelamento cooperativo impede efeitos depois que é observado, mas não pode desfazer um enqueue que já
  entrou no actor da fila no intervalo mínimo posterior ao último guard. Um token de geração revalidado no
  próprio boundary da fila pertence ao Prompt 11; até essa coordenação existir, invalidação/wipe e um
  enqueue antigo já despachado também podem competir no boundary da fila;
- submit já despachado não pode ser cancelado com segurança nem classificado como sucesso/falha
  determinística sem o controller submission-aware do Prompt 14;
- a identidade e o horário de submissão já permanecem estáveis em memória para o Prompt 14;
- wakes normais concorrentes ainda são descartados pelo single-flight histórico até o Prompt 11;
- o pipeline candidato continua desligado em Debug, Staging e Release e foi exercitado somente por injeção
  explícita nos testes;
- Simulator não comprova bateria, rádio, thermal, cold relaunch pelo daemon, entrega real de geofence,
  oportunidade de BGTask ou comportamento em percurso.

Não executados:

- iPhone físico, percurso, bateria, energia, thermal, rádio e cold relaunch real — não autorizados nesta
  ação;
- build distribuível com `candidate` selecionado — todos os configs devem permanecer legados nesta fase;
- alteração mutável de backend, commit, push, tag, version bump, assinatura de distribuição, upload,
  TestFlight ou deploy — não autorizados;
- migração para `CLMonitor`, GPS contínuo ou experimento de movimento do Prompt 24 — fora do escopo.

### 21.11. Estado Git e handoff

HEAD e upstream permanecem:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

Estado final, preservando o conjunto acumulado e não commitado dos Prompts 02 a 09:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Background/MovementGatePolicy.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Orchestrator/MovementGatePolicyTests.swift
?? CheckingTests/Orchestrator/TimerSingleCaptureTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida:

```text
fix(ios): reuse timer location sample for matching
```

## 22. Execução do Prompt 10 — significant-change transporta seed opcional

### 22.1. Resultado e limites da fase

O wake de `CLLocationManagerSignificantChangeMonitor` deixou de descartar a leitura entregue pelo sistema.
No pipeline candidato, uma amostra íntegra e fresca pode agora servir como seed de uma única aquisição:
uma seed já suficiente evita iniciar o manager; uma seed grosseira inicia uma sessão curta para melhorar;
uma seed inválida, futura ou vencida é descartada e mantém a aquisição normal. Em todos os casos, o
matcher do servidor e a matriz existente continuam autoritativos.

Esta fase não mudou:

- elegibilidade, início ou parada do monitor;
- registro de geofences, region mapping ou raios;
- frequência de wakes ou agendamento de BGTask;
- fluxo TIMER de captura única do Prompt 09;
- single-flight e drop do segundo wake;
- matriz, contratos HTTP, DTOs, headers, endpoints ou `X-Client`;
- fila offline, replay, IDs/horários idempotentes, check manual, acidente, notificações ou UI;
- perfil efetivo de Debug, Staging ou Release.

Nenhum `EvaluationRequest`, pending normal ou política de merge foi antecipado do Prompt 11. Nenhum GPS
contínuo, `CLMonitor`, `allowsBackgroundLocationUpdates` no caminho normal ou telemetria foi introduzido.

### 22.2. Fluxo implementado

```text
Core Location: [CLLocation]
    │ converte todos na fronteira Platform
    ▼
[LocationSample] somente em memória
    │
    ├─ lote vazio ──► ignora + diagnóstico Debug estático
    │
    └─ lote não vazio
         │ filtra integridade/frescor + precisão, timestamp como desempate
         ▼
callback @Sendable (LocationSample?)
         │ amostra não reutilizável ainda produz wake com nil
         ▼
AppEnvironment ──► actor BackgroundCheckOrchestrator
         │ actor carimba receivedAt, evaluation ID e gerações
         ▼
candidate + SIGNIFICANT_LOCATION?
    ├─ não ──► acquire legado/normal
    └─ sim ──► revalida seed na admissão e com threshold remoto
                  │
                  ▼
             seedCandidate
                  │ provider/use case revalidam com clock vivo
                  ▼
             match somente com amostra ainda fresca
                  ▼
             matriz existente ──► submit/fila existente
```

O delegate não conhece chave, projeto, estado, local, direção, ação ou region ID. Ele nunca executa match,
matriz ou submit. `CLLocation` e `Error` cru não atravessam atores: o delegate cria primeiro o valor
`LocationSample` imutável e reduz o erro Core Location a um enum por whitelist.

O monitor ainda não conhece o threshold remoto. Para escolher somente o melhor valor transportável entre
os itens de um callback, ele:

1. rejeita coordenadas/precisão não finitas ou fora de faixa;
2. rejeita amostras vencidas ou além da tolerância futura aprovada;
3. prefere menor erro horizontal;
4. usa timestamp mais novo apenas como desempate;
5. preserva `nil` se nenhum candidato for reutilizável.

O threshold real é aplicado novamente no orquestrador e no provider/use case. A seed é revalidada com o
clock vivo imediatamente antes do matcher; uma leitura que envelheça nesse intervalo não chega à rede.

### 22.3. Perfis e orçamento de aquisição

O overload existente permanece:

```swift
runOnce(_ trigger)
```

e delega para a entrada mínima:

```swift
runOnce(_ trigger, seedCandidate: LocationSample?)
```

Somente `candidate + significantLocation` admite a seed. O perfil `legacyWithDiagnostics` a descarta antes
do pipeline e conserva `.acquire`, mesmo que o callback tenha transportado uma leitura. GEOFENCE,
FOREGROUND, TIMER, accuracy retry e os gatilhos de pausa também permanecem sem seed.

No candidato:

- seed suficiente: o provider é consultado uma vez, mas o manager e o timer não iniciam;
- seed fresca e grosseira: o provider inicia no máximo uma sessão para melhorar;
- seed inválida, vencida ou futura: o provider recebe `nil` e faz a captura normal;
- seed que vence depois da aquisição: terminal `staleContext`, zero match e zero recaptura escondida;
- o journal recebe somente `source`, `reused` e buckets, nunca a amostra ou suas coordenadas.

O `receivedAt`, o ID da avaliação e as gerações são definidos dentro do actor. A callback externa não
cria contexto de avaliação. A mesma seed admitida é passada por parâmetro também no retry de autenticação
vigente; ela não fica armazenada em propriedade global do actor.

### 22.4. Lifecycle, testabilidade e erros

`AppDelegate` continua criando `AppEnvironment.live()` de forma eager. O environment monta o
`CLLocationManagerSignificantChangeMonitor`, instala seu delegate e avalia a mesma policy persistida de
startup antes de a UI ser criada ou o sync do launch começar. A fase não moveu ownership nem alterou os
gates de consentimento/permissão/toggle/projeto.

Para testes determinísticos, disponibilidade, start e stop do manager ganharam ações injetáveis confinadas
ao `MainActor`. Os defaults chamam exatamente:

- `CLLocationManager.significantLocationChangeMonitoringAvailable()`;
- `startMonitoringSignificantLocationChanges()`;
- `stopMonitoringSignificantLocationChanges()`.

Isso evita que um callback real oportunista do Simulator contamine um unit test, sem criar outro motor nem
mudar o caminho vivo. Revisão concorrencial independente confirmou que `CLLocationManager` não cruza
atores, os defaults não criam ciclo de retenção e os recorders de teste chamam expectations fora dos locks.

`didFailWithError`:

- aceita o código somente quando o domínio é o de Core Location;
- projeta o código por `EvaluationCoreLocationErrorCategory`;
- usa `.unknown` para domínio/código não permitido;
- mantém a mensagem humana genérica existente;
- não usa `localizedDescription`, `String(describing:)`, domínio, código cru ou detalhe externo nos
  diagnósticos.

### 22.5. Arquivos alterados nesta fase

Produção:

- `Checking/Domain/Repositories/SignificantLocationMonitoring.swift`;
- `Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift`;
- `Checking/App/AppEnvironment.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`.

Testes:

- `CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift`;
- `CheckingTests/Location/CLLocationManagerLocationProviderTests.swift`;
- `CheckingTests/Orchestrator/SignificantLocationSeedTests.swift` (novo).

Documentação:

- `docs/plans/background_reliability_execution.md`.

Nenhum outro arquivo acumulado dos Prompts 02 a 09 foi revertido ou reformatado.

### 22.6. Cobertura adicionada

Os testes novos/expandidos cobrem:

1. delegate instalado e amostra válida convertida pela callback real;
2. `startsImmediately: true` com delegate já instalado;
3. lote vazio ignorado, com expectation invertida;
4. lote não vazio somente com itens inválidos/vencidos produzindo um wake com `nil`;
5. comparador que prefere uma leitura mais precisa a uma leitura grosseira apenas mais nova;
6. callback depois de stop ignorada;
7. erro Core Location reduzido por whitelist e warning humano genérico;
8. seed suficiente no candidato sem start físico do manager;
9. seed grosseira alimentando uma única sessão de melhoria;
10. seeds vencida, futura e inválida descartadas antes do match;
11. seed envelhecendo entre aquisição e match sem recaptura;
12. perfil legado descartando seed;
13. wrapper sem seed e triggers não significativos preservando `.acquire`;
14. trigger/log byte-exact `SIGNIFICANT_LOCATION`;
15. journal contendo somente origem/reuso/buckets;
16. segundo wake concorrente ainda `notAdmitted`, congelando conscientemente o comportamento até o
    Prompt 11.

Uma primeira tentativa de fortalecer o teste de lote vazio, ainda acionando o manager real do Simulator,
recebeu um callback oportunista do próprio ambiente e falhou. Isso revelou isolamento insuficiente do
teste, não uma falha do guard de lote vazio. As ações de start/stop/availability foram então injetadas com
defaults de produção idênticos, o teste passou a usar driver no-op e todas as baterias abaixo foram
reexecutadas no estado final.

### 22.7. Testes e builds finais

Ambiente:

- Xcode 26.6, build 17F113;
- iPhone 17 Pro Simulator;
- iOS 26.5, build 23F77;
- Swift 6;
- projeto regenerado com XcodeGen 2.45.4 pelo binário local documentado.

Foco final de monitor, policy, provider, state machine, seam sample-aware e orquestrador:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt10/focal-derived \
  -resultBundlePath .build/prompt10/focal-final-20260731.xcresult \
  -only-testing:CheckingTests/CLLocationManagerSignificantChangeMonitorTests \
  -only-testing:CheckingTests/SignificantLocationSeedTests \
  -only-testing:CheckingTests/SignificantLocationStartupPolicyTests \
  -only-testing:CheckingTests/LocationSamplePolicyTests \
  -only-testing:CheckingTests/CaptureSessionStateTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderComparisonTests \
  -only-testing:CheckingTests/CLLocationManagerLocationProviderSessionTests \
  -only-testing:CheckingTests/LocationAttemptPipelineTests
```

Resultado: 109/109, zero falhas, zero skips; bundle 15,966 s, soma interna 0,482 s.

Todas as 24 classes em `CheckingTests/Location` e `CheckingTests/Orchestrator`:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt10/regression-derived \
  -resultBundlePath .build/prompt10/location-orchestrator-20260731.xcresult \
  <24 seletores -only-testing de Location e Orchestrator>
```

Resultado: 242/242, zero falhas, zero skips; bundle 52,293 s, soma interna 1,364 s.

Suíte completa assinada:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt10/full-derived \
  -resultBundlePath .build/prompt10/full-20260731.xcresult
```

| Escopo | Executados | Passaram | Falharam | Skips | Soma interna |
|---|---:|---:|---:|---:|---:|
| `CheckingTests` | 877 | 877 | 0 | 0 | 19,359 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 226,657 s |
| Total | 905 | 905 | 0 | 0 | bundle completo 315,563 s |

Build Release:

```sh
xcodebuild build \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt10/release-derived \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED`, binário universal x86_64/arm64. O `Info.plist` do produto final resolve
`legacyWithDiagnostics`. `xcodebuild -showBuildSettings` confirmou o mesmo valor em Debug, Staging e
Release.

Permanecem somente warnings já registrados na baseline: closures de Binding sem `@Sendable`, retornos de
lock não consumidos, um `await` redundante e ausência de metadata de App Intents. Nenhum warning novo foi
atribuído aos arquivos do Prompt 10.

### 22.8. Privacidade, sentinelas e auditorias

As buscas estruturais e os testes confirmaram:

- `LocationSample` continua sem `Codable`, descrição customizada ou persistência;
- os modelos/store/protocolo do journal não referenciam `LocationSample`;
- não existe campo durável para coordenada, altitude, velocidade, course, region ID, identidade de evento
  ou conteúdo HTTP;
- o novo OSLog do lote vazio é estático;
- os diagnósticos Debug do monitor guardam somente categorias permitidas;
- o warning de falha e a linha de mudança significativa existentes permanecem byte-exact;
- nenhum erro externo é persistido ou logado por descrição;
- Domain continua sem importar Core Location ou UIKit nesses tipos;
- `allowsBackgroundLocationUpdates` continua somente no harness Debug preexistente;
- não há `CLMonitor`, GPS contínuo, analytics ou telemetria remota;
- `git diff --check` está limpo para rastreados e todos os arquivos novos.

Dos 37 hashes da seção 10, 33 sentinelas estritas continuam byte-identical ao Prompt 01. As quatro
diferenças são seams acumulados e autorizados em fases anteriores/atuais:
`CheckViewModel`, `BackgroundCheckOrchestrator`, `OrchestratorFakes` e
`RunAutomaticActivitiesUseCase`. Os principais invariantes permanecem:

| Arquivo | Hash final |
|---|---|
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Data/DTOs/CheckWireEnums.swift` | `e6c49aee2cb9daab0676f972116eb2fd1cb27061` |
| `Checking/Domain/Repositories/CheckRepository.swift` | `0a2f4540e6a016beb92bc2195e188b6471e39657` |
| `Checking/Data/Repositories/CheckRepositoryLive.swift` | `b0cffd7c3b32a60e8ab49f088887262d8d6807eb` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |
| `Checking/Platform/Notifications/AutoActivityNotificationsLive.swift` | `991a10105c5422ff0ee4e786a43e36fb0e1bf3c0` |
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `c500ceb009013bb00346f3118c84323d2084d1f7` |

Três revisões independentes, read-only, não encontraram blocker de lógica, concorrência, lifecycle,
privacidade ou testes. As lacunas médias de teste apontadas — fronteira real do delegate e espera baseada
somente em `Task.yield()` — foram corrigidas antes dos gates finais.

### 22.9. Gates

| Gate | Resultado |
|---|---|
| callback opcional e wake `nil` para lote não reutilizável | atendido |
| lote vazio ignorado sem crash | atendido |
| todos os candidatos convertidos e comparados | atendido |
| seed útil evita start redundante do manager | atendido |
| seed grosseira usa uma sessão curta | atendido |
| amostra inválida/futura/vencida nunca chega ao matcher | atendido |
| revalidação na admissão e imediatamente antes do matcher | atendido |
| delegate não faz match/matriz/region mapping | atendido |
| monitor precoce; start/stop/elegibilidade preservados | atendido |
| perfil legado descarta seed | atendido |
| TIMER/geofence/foreground/retries preservados | atendido |
| single-flight sem fila nova | atendido |
| zero coordenadas/erro cru/region ID em log ou journal | atendido |
| todos os configs permanecem legados | atendido |
| testes focais | 109/109 |
| Location + Orchestrator | 242/242 |
| suíte completa | 905/905 |
| build Release universal | atendido |
| sentinelas estritas | 33/33 |
| `git diff --check` | limpo |
| publicação | não realizada |

### 22.10. Riscos, limites e testes não executados

Riscos deliberadamente deixados para as fases correspondentes:

- wakes normais concorrentes ainda são descartados pelo single-flight histórico; pending bounded pertence
  ao Prompt 11;
- hoje, falhas unauthorized que acionam relogin no fluxo significativo ocorrem em options/state antes da
  aquisição, portanto não abrem duas sessões. Se uma fase futura habilitar relogin depois de match/submit,
  deverá existir resume submission-aware para não recapturar, rematchear ou repetir submit;
- cancelamento depois de um enqueue/submit já despachado conserva os limites registrados nos Prompts
  09/14;
- não há teste unitário único que construa toda a stack `AppEnvironment.live`, pois isso armaria
  persistence, rede e serviços nativos. A callback real do delegate, o wiring por compilação/inspeção e o
  pipeline do actor foram testados separadamente;
- o perfil candidato continua desligado nos configs distribuíveis e foi exercitado por injeção explícita.

Não executados:

- iPhone físico, wake real entregue pelo daemon, percurso, rádio, bateria, energia, thermal e cold relaunch
  real — não autorizados nesta ação e não comprováveis no Simulator;
- build distribuível com `candidate` selecionado;
- chamada mutável ao backend;
- commit, push, tag, version bump, assinatura de distribuição, upload, TestFlight ou deploy;
- GPS contínuo, `CLMonitor`, mudança de raio ou experimento do Prompt 24.

### 22.11. Estado Git e handoff

HEAD e upstream permanecem:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

Origem confirmada:

```text
https://github.com/tscode-com-br/checking-swift.git
```

Estado final, preservando o conjunto acumulado e não commitado dos Prompts 02 a 10:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/Repositories/SignificantLocationMonitoring.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Background/MovementGatePolicy.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Orchestrator/MovementGatePolicyTests.swift
?? CheckingTests/Orchestrator/SignificantLocationSeedTests.swift
?? CheckingTests/Orchestrator/TimerSingleCaptureTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida:

```text
fix(ios): reuse significant location change samples
```

## 23. Execução do Prompt 11 — pending normal bounded, serial e sem perda silenciosa

### 23.1. Resultado

O Prompt 11 foi implementado e validado localmente somente no perfil `candidate`. A admissão candidata
continua permitindo no máximo uma avaliação no motor e agora conserva no máximo um único wake normal
pending para TIMER, GEOFENCE e SIGNIFICANT_LOCATION. Qualquer quantidade adicional desses wakes é
coalescida nesse mesmo slot bounded; não existe fila crescente nem segunda execução em paralelo.

O perfil `legacyWithDiagnostics` preserva o drop histórico do segundo wake. Debug, Staging e Release
continuam selecionando explicitamente esse perfil legado, portanto esta fase não altera o comportamento de
um build distribuível atual. Não foram executados dois motores, duas matrizes, duas capturas comparativas ou
dois submits em paralelo.

As cinco decisões humanas da seção 12.4 foram aplicadas:

1. no máximo uma avaliação normal adicional por ciclo running;
2. drain na ordem aprovada;
3. FOREGROUND fora do pending normal;
4. decisão de notificação existente preservada no ponto de submit, sem inventar estado de cena na
   recepção;
5. todo pending admitido faz follow-up; não existe otimização `covered`.

### 23.2. Modelo de admissão, merge e completion

`EvaluationRequest` é um valor `Sendable` somente em memória. ID e horário são criados na fronteira
controlada do actor; a geração de automação é carimbada somente na admissão. O request pode transportar
trigger, seed opcional, estado grosseiro da aplicação, máscara fechada de fontes e contadores fixos
saturados. Ele não adota `Codable`, não possui descrição textual e não transporta região, direção, local,
identidade de usuário ou qualquer dado de coordenada para o journal.

`EvaluationAdmission` foi separado de `EvaluationCompletion`. `deferred`/`coalesced` descrevem apenas a
admissão; não são terminais de negócio. Cada avaliação canônica possui uma única task compartilhada e um
one-shot com no máximo uma continuation interna. Todos os callers que possuem orçamento podem aguardar o
mesmo ticket; cancelar um waiter não cancela o trabalho comum nem os demais waiters. O ticket pending só
completa depois do terminal real do follow-up.

O valor histórico `coalescedCovered` permanece apenas no enum versionado do journal para compatibilidade
de schema; não existe uso no caminho operacional nem supressão de follow-up por cobertura.

Tabela de merge puro:

| Slot atual | Novo wake | Resultado efetivo |
|---|---|---|
| TIMER | TIMER | TIMER; permanece elegível ao gate de movimento |
| TIMER | GEOFENCE | GEOFENCE; evento não passa por movement skip |
| TIMER | SIGNIFICANT_LOCATION | SIGNIFICANT_LOCATION; seed elegível é preservada |
| GEOFENCE | SIGNIFICANT_LOCATION | SIGNIFICANT_LOCATION; ambas as fontes ficam na máscara |
| SIGNIFICANT_LOCATION | GEOFENCE | SIGNIFICANT_LOCATION; seed não é descartada |
| qualquer normal | múltiplas seeds | comparador total do Prompt 04, seguido de revalidação no drain |

O ID/ticket da primeira admissão no slot permanece canônico. `receivedAt` usa o instante mais recente
somente para diagnóstico, as fontes são unidas, os contadores usam saturação em `UInt16.max` e a escolha
entre seeds aplica integridade, frescor, qualidade suficiente, precisão e timestamp, nessa ordem. Nenhum
region mapping ou decisão de negócio foi movido para o merge.

### 23.3. Drain, limites e fairness

O loop é serial e não usa recursão pela API pública. A ordem final, igual à aprovação, é:

```text
avaliação running
  → pause transition
  → pause activation
  → foreground/pause reconciliation
  → pending normal
  → accuracy retry
  → acidente pending
```

Limites observados:

| Recurso | Limite |
|---|---:|
| motor executando | 1 |
| pending normal | 0 ou 1 |
| follow-up normal por ciclo running | no máximo 1 |
| pending especial por classe | bounded pelos slots já existentes |
| concorrência medida do motor | 1 |

`servedInDrainCycle` impede que wakes normais continuamente repostos executem duas vezes antes de retry e
acidente pendentes serem considerados. Um normal que já começou continua até seu terminal, como exige a
serialização; um retry que chegue durante essa execução entra no mesmo ciclo e não sofre starvation.

O follow-up normal revalida contexto e configuração, força leitura remota fresca de state em vez de
reutilizar o cache anterior ao submit e só permite movement skip quando a máscara é exclusivamente TIMER.
Seed coalescida é revalidada ao drenar. O teto de uma captura física por avaliação TIMER candidata e a
proibição de enviar amostra vencida ao matcher permanecem intactos.

FOREGROUND continua fora do pending normal e usa o ticket especial de reconciliação já existente. O código
não tratou `.onAppear` como foreground e não inventou um novo provider de lifecycle. A decisão vigente de
notificação continua no ponto real de submit; tornar `scenePhase` autoritativo em cold launch permanece
escopo explícito do Prompt 12.

### 23.4. Invalidação de contexto e fences assíncronos

Foi unificada a geração de contexto para troca de chave/projeto, auto OFF, revogação de consentimento,
logout e wipe. A transição é aberta antes do primeiro `await`; avaliações antigas cancelam
cooperativamente, pendings antigos recebem `staleContext` e nenhuma identidade anterior é adotada pelo
novo ciclo.

Existem guards antes/depois dos awaits de options, aquisição, match, state, decisão, enqueue/submit, cache
e notificação. Callbacks antigos de check aceito, state confirmado e alteração de pausa também verificam a
geração antes de recriar estado local, timers ou reconciliações. O wipe aguarda quiescência dos writers
locais. Na exclusão de conta, a barreira destrutiva só abre depois do sucesso remoto; conflito/falha mantém
sessão e dados locais.

Os comandos derivados de geofence ganharam geração própria e execução serial latest-wins: no máximo um
comando está executando e um intent substituível aguarda. Um fetch antigo não pode repovoar monitores,
resumos ou logs depois de unregister/troca de contexto.

### 23.5. Proteção contra efeitos irreversíveis duplicados

Dentro de um mesmo ciclo de drain, repetir exatamente a mesma ação irreversível não cria novo
`clientEventId`, submit, fila `Decided` ou notificação. Uma ação oposta continua permitida, pois pode
representar uma transição legítima. Eventos `Raw` continuam pertencendo à avaliação canônica que realmente
falhou no match e não são colapsados entre avaliações diferentes.

O guard final também exige que a geração da avaliação coincida com a geração de automação atual. Isso
impede uma ação protegida de uma identidade antiga de reaparecer em um ciclo novo. Matriz, payload,
`eventTime`, idempotência, HTTP 422, fila/replay e mensagens humanas existentes não foram alterados.

### 23.6. Arquivos modificados nesta fase

Produção:

- `Checking/App/AppEnvironment.swift`;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Features/Check/CheckViewModel.swift`;
- `Checking/Features/Check/CheckViewModelSeams.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`;
- `Checking/Platform/Background/EvaluationRequest.swift` (novo);
- `Checking/Platform/Location/GeofenceRegionManager.swift`.

Testes:

- `CheckingTests/Auth/CheckMainViewModelTests.swift`;
- `CheckingTests/Auth/CheckViewModelFakes.swift`;
- `CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift`;
- `CheckingTests/Location/GeofenceRegionManagerTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`;
- `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift`;
- `CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift`;
- `CheckingTests/Orchestrator/ContextCallbackFenceTests.swift` (novo);
- `CheckingTests/Orchestrator/EvaluationRequestMergeTests.swift` (novo);
- `CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift` (novo);
- `CheckingTests/Orchestrator/PendingContextInvalidationTests.swift` (novo);
- `CheckingTests/Orchestrator/PendingDrainBehaviorTests.swift` (novo);
- `CheckingTests/Orchestrator/PendingNormalWakeTests.swift` (novo);
- `CheckingTests/Orchestrator/PendingOfflineQueueTests.swift` (novo).

Os sete arquivos novos contêm 38 testes. O teste histórico de single-flight não foi removido: foi
renomeado/comentado para documentar explicitamente que o drop continua sendo o contrato do perfil legado.

### 23.7. Testes executados

Simulator descoberto no ambiente:

```text
platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7
```

Regressão dirigida de 17 classes relacionadas:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/DerivedData/prompt11-targeted \
  -resultBundlePath .build/prompt11/final-targeted-02-20260731.xcresult \
  -only-testing:CheckingTests/EvaluationRequestMergeTests \
  -only-testing:CheckingTests/PendingNormalWakeTests \
  -only-testing:CheckingTests/PendingDrainBehaviorTests \
  -only-testing:CheckingTests/PendingAccidentFairnessTests \
  -only-testing:CheckingTests/PendingContextInvalidationTests \
  -only-testing:CheckingTests/PendingOfflineQueueTests \
  -only-testing:CheckingTests/ContextCallbackFenceTests \
  -only-testing:CheckingTests/GeofenceRegionManagerTests \
  -only-testing:CheckingTests/OrchestratorSingleFlightTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests \
  -only-testing:CheckingTests/CheckMainViewModelTests \
  -only-testing:CheckingTests/TimerSingleCaptureTests \
  -only-testing:CheckingTests/AutomaticActivitiesExecutionTests \
  -only-testing:CheckingTests/BackgroundDependencyResolutionTests \
  -only-testing:CheckingTests/ScheduledPauseDeferralTests \
  -only-testing:CheckingTests/CandidateTimerContextRaceTests \
  -only-testing:CheckingTests/SignificantLocationSeedTests
```

Resultado: 191/191, zero falhas, zero skips. Depois do ajuste final que alinhou a posição de
`accuracyRetry` à ordem humana aprovada, as quatro classes afetadas foram repetidas:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/DerivedData/prompt11-targeted \
  -resultBundlePath .build/prompt11/drain-order-targeted-02-20260731.xcresult \
  -only-testing:CheckingTests/PendingNormalWakeTests \
  -only-testing:CheckingTests/PendingAccidentFairnessTests \
  -only-testing:CheckingTests/AccuracyRetryEpisodeTests \
  -only-testing:CheckingTests/ScheduledPauseDeferralTests
```

Resultado final dirigido: 53/53, zero falhas, zero skips. A classe focal de efeitos/filas também foi
executada isoladamente em
`.build/prompt11/review-targeted-04-20260731.xcresult`: 9/9, zero falhas.

Suíte completa sobre o código final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/DerivedData/prompt11-full-final-02 \
  -resultBundlePath .build/prompt11/full-final-03-20260731.xcresult
```

| Escopo | Executados | Passaram | Falharam | Skips | Duração interna |
|---|---:|---:|---:|---:|---:|
| `CheckingTests` | 923 | 923 | 0 | 0 | 24,060 s |
| `CheckingUITests` | 28 | 28 | 0 | 0 | 262,244 s |
| Total | 951 | 951 | 0 | 0 | sessão Xcode 305,430 s |

Build Release final:

```sh
xcodebuild build \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData/prompt11-release-final-03 \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED`; produto universal `x86_64 arm64`. O `Info.plist` do produto final resolve
`CHECKINGBackgroundReliabilityProfile = legacyWithDiagnostics`. Debug, Staging e Release têm o mesmo valor.
Os warnings são os mesmos já registrados na baseline: closures de Binding sem `@Sendable`, retornos de
lock não consumidos, um `await` redundante e ausência de metadata de App Intents.

O Simulator registrou a limitação conhecida de submissão de BGAppRefresh. Isso não foi tratado como falha
da suíte nem como prova de agendamento real em aparelho.

### 23.8. Privacidade, sentinelas e auditoria independente

Auditorias estruturais confirmaram:

- `LocationSample` continua sem `Codable`, `CustomStringConvertible` ou persistência;
- journal/store não referenciam `LocationSample` nem possuem campos para coordenada, altitude, movimento,
  identidade de evento, conteúdo HTTP, credencial ou identificador de região;
- nenhum `String(describing:)`/`localizedDescription` externo foi adicionado à persistência;
- não foi adicionado `CLMonitor`, GPS contínuo ou `allowsBackgroundLocationUpdates`;
- `startUpdatingLocation` continua somente na captura one-shot do provider e no harness Debug
  preexistente, com stop/terminal cobertos por testes;
- a matriz, DTOs/wire, APIs HTTP, fila Raw/Decided, replay, `ActivityLogger` e notificação protegida
  permanecem byte-identical;
- `git diff --check` está limpo.

Dos 37 hashes da seção 10, 32 continuam byte-identical. As cinco diferenças são seams autorizados e
revisados dos Prompts anteriores/atual:

| Arquivo | Hash atual | Motivo |
|---|---|---|
| `Checking/Features/Check/CheckViewModel.swift` | `6b5a6f4c20a06bd98bd6fcddfc3f59159ba0ed7f` | fences de transição/wipe |
| `Checking/Platform/Background/BackgroundCheckOrchestrator.swift` | `700b46e4737e008c07d86ef010b83891e7de415d` | pending/tickets/drain |
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `e2d20d761d7426a2d5aed82437d142f8fedc8123` | contrato legado documentado |
| `CheckingTests/Orchestrator/OrchestratorFakes.swift` | `313a057aa2fbe9e2738604d67eb419390b3d713f` | seams/fakes da fase |
| `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift` | `bedd30ef266504a033b415882c9d93201a68bf79` | proteção de efeitos |

Os invariantes principais permanecem nos hashes da seção 22.8, incluindo matriz, DTO/wire, repository,
evento pending offline, fila, replay, logger e notificações.

Revisões independentes read-only verificaram as fences de callbacks, a geração serial de geofence, a ordem
final do drain, fairness e ausência de blocker. A revisão final confirmou
`normal → accuracyRetry → acidente`, completion compartilhada e concorrência máxima igual a um.

### 23.9. Gates

| Gate | Resultado |
|---|---|
| cinco decisões humanas registradas antes da mudança | atendido |
| motor concorrente máximo igual a 1 | atendido |
| pending normal limitado a 0/1 | atendido |
| no máximo um follow-up normal por ciclo | atendido |
| falha do primeiro não apaga o segundo | atendido |
| merge de triggers/seeds puro e bounded | atendido |
| evento nunca passa por movement skip | atendido |
| follow-up força state fresco | atendido |
| seed revalidada ao drenar e antes do matcher | atendido |
| ticket pending só completa no terminal | atendido |
| cancelamento de waiter não cancela trabalho comum | atendido |
| FOREGROUND permanece especial | atendido |
| prioridades de pausa/reconciliação/retry/acidente | atendido |
| acidente sem starvation | atendido |
| contexto antigo não cruza chave/projeto/toggle/consentimento/logout/wipe | atendido |
| callbacks/cache/timers/geofence não repovoam contexto antigo | atendido |
| zero submit/fila `Decided`/notificação duplicada | atendido |
| Raw continua por avaliação canônica | atendido |
| journal admitted/coalesced/drained/stale/terminal | atendido |
| legado preserva drop e candidato permanece desligado | atendido |
| matriz/HTTP/422/offline/replay/logs preservados | atendido |
| testes dirigidos finais | 53/53 |
| suíte completa final | 951/951 |
| build Release universal | atendido |
| sentinelas não autorizadas | 32/32 intactas |
| `git diff --check` | limpo |
| publicação | não realizada |

### 23.10. Riscos, pendências e testes não executados

Riscos deliberados:

- o pending pode acrescentar uma avaliação, captura e rede depois da running; a carga é a consequência
  aprovada e permanece bounded;
- estado autoritativo de cena em cold launch/headless pertence ao Prompt 12; esta fase apenas não degrada a
  decisão existente de notificação;
- owners reais de BGTask/UIKit lease e expiração exactly-once pertencem ao Prompt 14;
- geofence requested/confirmed/failed/omitted por geração persistida pertence ao Prompt 15;
- o candidato continua desligado em todos os configs distribuíveis e foi exercitado somente por injeção
  em testes.

Não executados:

- iPhone físico, wake real do daemon, percurso, rádio, bateria, energia, thermal e cold relaunch real;
- build distribuível com perfil candidato;
- chamada mutável ao backend;
- commit, push, tag, version bump, assinatura de distribuição, upload, TestFlight ou deploy;
- GPS contínuo, `CLMonitor`, alteração de raio ou experimento de movimento do Prompt 24.

### 23.11. Estado Git e handoff

HEAD e upstream continuam em:

```text
cc66dc131541cb66798e2de44a06d28a32b6df5a
```

Origem:

```text
https://github.com/tscode-com-br/checking-swift.git
```

`git status --short --branch` contém 30 arquivos rastreados modificados e 29 novos, todos pertencentes ao
conjunto acumulado, não commitado, dos Prompts 02 a 11. Nenhuma alteração preexistente foi descartada:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/Repositories/SignificantLocationMonitoring.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift
 M Checking/Platform/Location/GeofenceRegionManager.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift
 M CheckingTests/Location/GeofenceRegionManagerTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift
 M CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Background/EvaluationRequest.swift
?? Checking/Platform/Background/MovementGatePolicy.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift
?? CheckingTests/Orchestrator/ContextCallbackFenceTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Orchestrator/EvaluationRequestMergeTests.swift
?? CheckingTests/Orchestrator/MovementGatePolicyTests.swift
?? CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift
?? CheckingTests/Orchestrator/PendingContextInvalidationTests.swift
?? CheckingTests/Orchestrator/PendingDrainBehaviorTests.swift
?? CheckingTests/Orchestrator/PendingNormalWakeTests.swift
?? CheckingTests/Orchestrator/PendingOfflineQueueTests.swift
?? CheckingTests/Orchestrator/SignificantLocationSeedTests.swift
?? CheckingTests/Orchestrator/TimerSingleCaptureTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida:

```text
fix(ios): retain one bounded pending location wake
```

## 24. Prompt 12 — guard mínimo de cold launch/headless lifecycle

### 24.1. Resultado da revisão final

O Prompt 12 está concluído no seu escopo mínimo. A revisão de 2026-08-03 confirmou que a implementação e
os testes já estavam presentes, mas o handoff detalhado desta seção não havia sido escrito quando a sessão
anterior foi interrompida. Essa era a inconsistência que fazia a fase parecer incompleta.

O resultado implementado é deliberadamente selecionado por perfil:

- `candidate` e `candidateWithMovementExperiment` usam o lifecycle `headlessGuarded`;
- `legacyWithDiagnostics` conserva o lifecycle publicado anterior;
- Debug, Staging e Release continuam resolvendo `legacyWithDiagnostics`;
- nenhum build distribuível foi alterado para o candidato e os dois caminhos nunca executam em paralelo.

Assim, esta fase introduz o guard testável e reversível sem mudar o comportamento do aplicativo atualmente
distribuído.

### 24.2. Sequência de chamadas antes/depois

Sequência legada preservada no perfil publicado:

```text
CheckViewModel.init
  -> restore local
  -> restore remoto legado
  -> probeStatus(replaceIdentity)
  -> logout preventivo
  -> getStatus / eventual login / hidratação autenticada

CheckMainScreen.onAppear ou scenePhase.active
  -> onForegroundResume
```

Sequência candidata implementada:

```text
AppDelegate / AppEnvironment
  -> constroem cedo orquestrador e delegates nativos

CheckViewModel.init
  -> restoreLocalState
       -> idioma / chave / senha somente em memória / settings / isInitializing
       -> zero API, logout, login, history, projects, capture, stream ou FOREGROUND

RootView.task(id: scene state + disponibilidade do view model)
  -> reserva revisão monotônica
  -> publica estado coarse no EvaluationApplicationStateStore
  -> scene != active
       -> cancela restore remoto, polling e stream
  -> primeira scene active ou reativação real
       -> CheckSceneActivationGate
       -> restoreRemoteStateWhenActive single-flight
       -> aguarda restore local e fences explícitas
       -> getStatus preservando a sessão da mesma identidade
       -> login salvo somente se necessário
       -> history / projects / permissions / reconciliação / stream
       -> respostas só são adotadas se cena, chave e gerações continuarem atuais
```

`CheckingApp` continua drenando a fila offline na transição `.active`; essa responsabilidade não foi
duplicada no view model.

### 24.3. Lifecycle, estado de cena e cold launch

A fronteira SwiftUI usa uma única `.task(id:)` em `RootView`, cobrindo tanto uma tela criada já ativa quanto
transições posteriores. O identificador inclui o estado coarse da cena e a disponibilidade do view model,
de modo que uma cena inicialmente ativa ainda seja encaminhada quando o view model terminar de ser criado.

O `EvaluationApplicationStateStore` é um actor somente em memória. Cada task da cena reserva uma revisão
monotônica antes de atravessar o actor; uma task antiga que retome tarde não consegue sobrescrever uma
transição mais recente. O estado `.unknown` nunca equivale a foreground.

O `CheckSceneActivationGate` é puro e determinístico:

- primeira `.active` a partir de `.unknown`, `.inactive` ou `.background` produz uma ativação;
- `.active` repetido é deduplicado;
- `.inactive`, `.background` e `.unknown` encerram conservadoramente uma ativação;
- uma nova ativação só ocorre depois de uma saída real do estado ativo.

No candidato, `CheckMainScreen.onAppear` configura apenas o requester de permissões e não chama
`onForegroundResume`. O `onChange` legado também fica inativo. O método legado permanece disponível e é
explicitamente no-op quando o perfil usa o guard headless.

Em cold launch/headless, `AppEnvironment` e os delegates de geofence/mudança significativa continuam sendo
criados antes da UI. A eventual construção do view model executa apenas `restoreLocalState`; sem evidência
positiva de `.active`, não há probe, logout, login, prompt, captura visual, stream ou trigger `FOREGROUND`.

### 24.4. Restore remoto, identidade e limites de sessão desta fase

`restoreRemoteStateWhenActive` é cercado por:

- geração da ativação;
- geração de mutação da chave;
- chave esperada;
- estado atual da cena;
- cancelamento da task;
- epoch da sessão candidata autenticada.

Esses guards são reavaliados após awaits relevantes. Uma resposta de uma ativação ou chave abandonada não
atualiza a UI, não reabre polling/stream e não inicia captura/reconciliação.

O probe candidato da mesma chave usa `preserveCurrentSession`: testa primeiro o cookie existente e não
começa por logout. Login salvo só ocorre se o status disser que a sessão não está autenticada e houver senha
local válida. Um status já autenticado hidrata a UI sem login.

Troca explícita de chave, logout implícito por expiração e exclusão continuam com a semântica existente. Um
tail privado do view model serializa as mutações explícitas de autenticação que podem gravar ou limpar cookie,
sem criar nesta fase o coordenador amplo e environment-owned reservado ao Prompt 13.

Esse tail não deve ser confundido com uma solução global de sessão. Permanecem deliberadamente para o
Prompt 13:

- coalescer relogin entre UI e orquestrador;
- proteger `Set-Cookie` de qualquer resposta HTTP por geração efêmera;
- serializar também a adoção pós-resposta e retries tipados por estágio.

### 24.5. Estado real da cena no submit

O store coarse de cena também é injetado no orquestrador candidato. O request registra apenas o estado
sanitizado no recebimento e, imediatamente antes da notificação de uma atividade submetida, o candidato relê
o estado atual:

- `.active` suprime a notificação local;
- `.inactive`, `.background` e `.unknown` preservam a decisão conservadora de notificar;
- o perfil legado continua decidindo exclusivamente pelo trigger, sem consultar o provider.

Nenhum nome de local, coordenada ou identificador de região é adicionado por esse seam. A semântica do
submit, da matriz e do `ActivityLogger` não foi alterada.

### 24.6. Arquivos revisados/modificados nesta fase

Produção e seams diretamente envolvidos:

- `Checking/App/BackgroundReliabilityProfile.swift`;
- `Checking/App/AppEnvironment.swift`;
- `Checking/App/RootView.swift`;
- `Checking/Features/Check/CheckMainScreen.swift`;
- `Checking/Features/Check/CheckSceneActivationGate.swift`;
- `Checking/Features/Check/CheckViewModel.swift`;
- `Checking/Platform/Background/EvaluationApplicationStateProvider.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`.

Testes/fakes diretamente envolvidos:

- `CheckingTests/BackgroundReliabilityProfileTests.swift`;
- `CheckingTests/Auth/CheckSceneActivationGateTests.swift`;
- `CheckingTests/Auth/CheckViewModelHeadlessLifecycleTests.swift`;
- `CheckingTests/Auth/CheckMainViewModelTests.swift`;
- `CheckingTests/Auth/CheckViewModelFakes.swift`;
- `CheckingTests/Auth/SelfRegistrationApprovalTests.swift`;
- `CheckingTests/Orchestrator/ActivityNotificationSceneStateTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`.

`CheckingApp.swift`, `AppDelegate.swift`, `AppLifecycleCoordinator.swift`, `AuthRepositoryLive.swift` e os
contratos do journal foram relidos integralmente na revisão. Não foi criado um coordenador amplo de sessão e
`AuthRepositoryLive.logout` não foi redesenhado.

### 24.7. Testes e builds finais

Ambiente final:

```text
Xcode 26.6 (17F113)
iPhone 17 Pro Simulator — iOS 26.5
destination id: 45D57727-95E8-4C58-A15F-A0087891AFD7
```

Revisão focal sobre os três contratos novos:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt12-review-targeted \
  -only-testing:CheckingTests/CheckSceneActivationGateTests \
  -only-testing:CheckingTests/CheckViewModelHeadlessLifecycleTests \
  -only-testing:CheckingTests/ActivityNotificationSceneStateTests
```

Resultado: 36/36, zero falhas e zero skips; duração interna 1,031 s e operação de testes informada pelo
Xcode 10,674 s.

Suíte unitária completa sobre o código final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt12-full-final3 \
  -only-testing:CheckingTests
```

Resultado: 960/960, zero falhas e zero skips; duração interna 23,628 s e operação de testes informada pelo
Xcode 46,800 s. O log está em `.build/prompt12-unit-full-final3.log`.

Suíte completa de UI sobre o mesmo código final:

```sh
xcodebuild test \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt12-ui-final3 \
  -only-testing:CheckingUITests
```

Resultado: 28/28, zero falhas e zero skips; duração interna 342,977 s e operação de testes informada pelo
Xcode 353,360 s. O log está em `.build/prompt12-ui-full-final3.log`.

Build Release não assinado:

```sh
xcodebuild build \
  -project Checking.xcodeproj \
  -scheme Checking \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt12-release-final3 \
  CODE_SIGNING_ALLOWED=NO
```

Resultado: `BUILD SUCCEEDED`; binário universal `x86_64 arm64`. O `Info.plist` do produto resolve
`CHECKINGBackgroundReliabilityProfile = legacyWithDiagnostics`. Debug, Staging e Release continuam com o
mesmo valor.

Os warnings observados são os já presentes nas fases anteriores: closures de `Binding` sem `@Sendable`,
retornos de lock não consumidos, um `await` redundante e ausência de metadata de App Intents. Nenhum deles é
erro de build ou regressão específica do Prompt 12.

### 24.8. Privacidade, sentinelas e revisão estrutural

As auditorias confirmaram:

- estado de cena é um enum coarse somente em memória;
- nenhum dado de localização, identidade de região, credencial ou conteúdo HTTP foi adicionado ao seam;
- nenhum `String(describing:)` ou `localizedDescription` externo foi adicionado à persistência;
- nenhum analytics/telemetria remota foi criado;
- `LocationSample` continua fora dos modelos `Codable` do journal;
- nenhum `CLMonitor`, GPS contínuo ou novo `allowsBackgroundLocationUpdates` foi adicionado;
- matriz, DTO/wire, endpoints, fila offline, replay, `clientEventId`, `eventTime`, logger e notificações
  permanecem semanticamente preservados;
- `git diff --check` está limpo.

Dos 37 hashes sentinela da seção 10, 31 continuam byte-identical. As seis diferenças são seams autorizados
dos Prompts 06 a 12:

| Arquivo | Hash atual | Motivo revisado |
|---|---|---|
| `Checking/Features/Check/CheckMainScreen.swift` | `42da0f902d3f326a9a5bc8c75aeeb5ad867f3f1a` | seleção de lifecycle por perfil |
| `Checking/Features/Check/CheckViewModel.swift` | `c4000aabe4f25d52cc6decdd82b224028cd92f11` | restore local/remoto, gerações e fences explícitas |
| `Checking/Platform/Background/BackgroundCheckOrchestrator.swift` | `0996867dbbabae17ecfc43d59f646630a3b81d02` | pending anterior e estado de cena candidato |
| `CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift` | `e2d20d761d7426a2d5aed82437d142f8fedc8123` | divergência legado/candidato documentada no Prompt 11 |
| `CheckingTests/Orchestrator/OrchestratorFakes.swift` | `7d4bbd6f0165cc89159b68f8ff2b659d13d30bbc` | seams de request e application state |
| `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift` | `bedd30ef266504a033b415882c9d93201a68bf79` | seam sample-aware e proteção de efeitos anteriores |

Os sentinelas estritos de matriz, wire, fila/replay, acidente, `ActivityLogger` e implementação de
notificações permanecem intactos.

### 24.9. Gates

| Gate | Resultado |
|---|---|
| Prompt 11 previamente verde | atendido |
| `init` candidato executa somente restore local | atendido |
| background/onAppear candidato produz zero efeito remoto | atendido |
| primeira cena já ativa restaura uma vez | atendido |
| re-render/active repetido não duplica restore | atendido |
| cada reativação real reconcilia uma vez | atendido |
| mesma identidade não começa por logout | atendido |
| resposta de ativação/chave antiga não altera UI | atendido |
| polling de aprovação existe somente em active | atendido |
| stream encerra ao sair de active e reabre de forma cercada | atendido |
| permissões são revistas antes de captura/reconciliação | atendido |
| foreground real mantém history/projects/permissions/stream | atendido |
| monitor nativo continua independente da UI | atendido |
| lifecycle legado preservado por perfil | atendido |
| nenhum coordenador amplo de sessão foi introduzido | atendido |
| testes focais | 36/36 |
| suíte unitária final | 960/960 |
| suíte de UI final | 28/28 |
| build Release universal e perfil legado | atendido |
| sentinelas não autorizadas | 31/31 intactas |
| `git diff --check` | limpo |
| publicação | não realizada |

### 24.10. Riscos, pendências e testes não executados

Pendências deliberadamente fora do Prompt 12:

- **Prompt 13:** o tail do view model não é autoridade global. `URLSessionHTTPClient` aceita `Set-Cookie`
  de qualquer resposta, inclusive probes e requisições não incluídas nesse tail. Uma geração efêmera no
  store/request ou coordenação equivalente ainda é necessária;
- **Prompt 13:** a requisição de login/cadastro/troca de senha é serializada, mas a adoção de estado após a
  resposta ocorre fora do tail. A corrida determinística com `unauthorized` simultâneo deve ser coberta antes
  do coordenador environment-owned;
- **Prompt 16:** `loadProjectCatalogForRegistration` ainda cria uma task não rastreada; wipe completo de
  todos os producers deve cancelar/cercar esse retorno tardio;
- o candidato continua desligado nos configs distribuíveis; a efetividade operacional será validada apenas
  quando um build piloto for explicitamente selecionado;
- Simulator não prova wake real do daemon, relaunch frio físico, rádio, energia, thermal ou comportamento de
  bateria.

Não executados:

- instalação, abertura ou alteração de estado de iPhone físico;
- cold launch real por evento de localização em aparelho;
- chamada mutável ao backend;
- build distribuível com perfil candidato;
- assinatura, commit, push, tag, version bump, upload, TestFlight ou deploy;
- GPS contínuo, alteração de raio, `CLMonitor` ou experimento de movimento.

### 24.11. Estado Git e handoff

HEAD, upstream e origem permanecem:

```text
HEAD:     cc66dc131541cb66798e2de44a06d28a32b6df5a
upstream: cc66dc131541cb66798e2de44a06d28a32b6df5a
origin:   https://github.com/tscode-com-br/checking-swift.git
```

`git status --short --branch` contém 32 arquivos rastreados modificados e 34 novos, todos pertencentes ao
conjunto acumulado, não commitado, dos Prompts 02 a 12. Nenhuma alteração foi descartada:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/Repositories/SignificantLocationMonitoring.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckMainScreen.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift
 M Checking/Platform/Location/GeofenceRegionManager.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/Auth/SelfRegistrationApprovalTests.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift
 M CheckingTests/Location/GeofenceRegionManagerTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift
 M CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Features/Check/CheckSceneActivationGate.swift
?? Checking/Platform/Background/EvaluationApplicationStateProvider.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Background/EvaluationRequest.swift
?? Checking/Platform/Background/MovementGatePolicy.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/Auth/CheckSceneActivationGateTests.swift
?? CheckingTests/Auth/CheckViewModelHeadlessLifecycleTests.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/ActivityNotificationSceneStateTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift
?? CheckingTests/Orchestrator/ContextCallbackFenceTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Orchestrator/EvaluationRequestMergeTests.swift
?? CheckingTests/Orchestrator/MovementGatePolicyTests.swift
?? CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift
?? CheckingTests/Orchestrator/PendingContextInvalidationTests.swift
?? CheckingTests/Orchestrator/PendingDrainBehaviorTests.swift
?? CheckingTests/Orchestrator/PendingNormalWakeTests.swift
?? CheckingTests/Orchestrator/PendingOfflineQueueTests.swift
?? CheckingTests/Orchestrator/SignificantLocationSeedTests.swift
?? CheckingTests/Orchestrator/TimerSingleCaptureTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
fix(ios): isolate headless launch from UI auth restore
```

## 25. Prompt 13 — concluído localmente no escopo parcial aprovado

### 25.1. Estado da fase

O preflight do Prompt 13 foi executado após o Prompt 12 ficar verde. Em 2026-08-03, o owner aprovou
explicitamente o escopo parcial seguro: coordenação serial da sessão e retry tipado de
options/state/match, sem retry de submit enquanto a idempotência server-side não estiver comprovada em
homologação. A implementação começou somente depois desse registro e foi concluída localmente sem mudar o
perfil de nenhum config distribuível.

O blocker específico do retry de submit permanece: o workspace comprova que o cliente preserva a identidade
do evento, mas não contém evidência de homologação aprovada pelo owner do backend mostrando que duas
requisições com o mesmo `clientEventId` e `eventTime` produzem uma única atividade lógica. `unauthorized` em
submit deve, portanto, continuar terminal, sem retry e sem enqueue automático.

### 25.2. Evidência disponível por decisão

| Gate | Evidência local | Situação humana |
|---|---|---|
| 401 e 403 mapeiam para `unauthorized` | `SafeApiCall.swift` e testes cobrem ambos | **aprovado em 2026-08-03** |
| repetição do mesmo evento é idempotente no backend/replayer | cliente/replayer preserva ID/tempo; DTO possui `client_event_id` e resposta `duplicate`; specs afirmam dedup server-side | **homologação ausente; escopo parcial sem retry de submit aprovado em 2026-08-03** |
| match só pode repetir a mesma amostra enquanto fresca | policy 10 s/2 s e revalidação antes do matcher já existem | **aprovado em 2026-08-03** |
| segundo `unauthorized` encerra | comportamento atual possui orçamento único em caminhos já cobertos | **aprovado em 2026-08-03** |
| HTTP 422 nunca reloga | 422 permanece `.http`, não `.unauthorized`, e a rejeição real está documentada | **aprovado em 2026-08-03; também invariável do Prompt 00** |

Provas do lado cliente:

- `Checking/Core/API/SafeApiCall.swift`: 401/403 → `.unauthorized`; 422 → `.http`;
- `CheckingTests/Network/SafeApiCallTests.swift`: casos dedicados para 401, 403 e 422;
- `Checking/Data/Offline/PendingCheckReplayer.swift`: replay reutiliza `eventTime` e `clientEventId`;
- `CheckingTests/Offline/PendingCheckReplayerTests.swift`: preservação verbatim do payload lógico;
- `Checking/Data/DTOs/CheckDTOs.swift`: wire `client_event_id` e campo de resposta `duplicate`;
- `docs/port_spec_decision_engine.md` e `docs/port_spec_offline_replay.md`: declaram deduplicação server-side.

Limite dessas provas: as specs foram derivadas/auditadas a partir do cliente e os testes locais não enviam
duas requisições iguais a um ambiente de homologação. Não há no workspace artefato demonstrando a resposta
duplicada, uma única atividade resultante, ambiente/data do ensaio e aceite identificável do owner do
backend. Portanto, elas não satisfazem o gate expresso do Prompt 13 para retry de submit.

### 25.3. Escopo autorizado

- serializar as mutações reais de sessão e coalescer refresh silencioso por geração de identidade;
- repetir uma vez somente options, state ou match que retornou `unauthorized`;
- no retry de match, reutilizar a mesma amostra apenas depois de nova revalidação de frescor, sem nova
  captura;
- encerrar no segundo `unauthorized`;
- nunca relogar ou recapturar em HTTP 422;
- manter submit `unauthorized` terminal, sem retry e sem enqueue automático.

Também ficaram pré-aprovados para a execução futura do Prompt 14 o mapping terminal → Bool proposto e o
tratamento conservador de resposta de submit indeterminada: `submissionOutcomeUnknown`, Bool `false` e
nenhum enqueue automático enquanto a idempotência server-side não for comprovada. Esta anotação não autoriza
implementar o Prompt 14 durante a fase atual.

### 25.4. Resultado alcançado

O Prompt 13 foi concluído localmente no escopo parcial aprovado. A fase adicionou uma autoridade de sessão
compartilhada pelo `AppEnvironment`, eliminou o rerun integral da avaliação após `unauthorized` e restringiu
o retry à dependência que efetivamente falhou. O comportamento final é:

- `AuthSessionCoordinator` serializa mutações reais de autenticação em ordem total também através de
  pontos de suspensão. O actor protege o estado e um task-chain explícito preserva a ordem durante `await`;
- `useCurrentSession` reutiliza a sessão vigente sem logout preventivo;
- refresh silencioso simultâneo da mesma identidade é coalescido e executa no máximo um login;
- a senha é lida do secure store somente quando o refresh admitido chega ao início da operação;
- replace identity e logout explícito invalidam a geração de identidade sincronamente antes do primeiro
  `await`; delete preserva a sessão durante a chamada remota e só invalida/limpa depois de uma resposta de
  sucesso aceita na geração corrente;
- a UI e o orquestrador recebem a mesma instância environment-owned; não há dois coordenadores ou dois
  motores concorrentes;
- requests carregam um snapshot efêmero da geração de cookie. Uma resposta tardia só pode adotar
  `Set-Cookie` enquanto a geração observada ainda é a corrente;
- options e state podem repetir somente a própria dependência uma vez depois de um refresh silencioso;
- match pode repetir somente o matcher, com a mesma `LocationSample`, se a política 10 s/2 s ainda a
  considerar fresca imediatamente antes da repetição;
- o orçamento `EvaluationAuthRetryBudget` é único por avaliação: um segundo `unauthorized`, mesmo em outro
  estágio, encerra a avaliação;
- submit `unauthorized` é terminal. Não há refresh, segundo submit, enqueue compensatório ou novo
  `clientEventId`/`eventTime`;
- 401 e 403 continuam `.unauthorized`; 422 continua `.http`, os demais mapeamentos HTTP permanecem
  inalterados e nenhuma resposta não-auth provoca relogin ou recaptura;
- o caminho TIMER candidato continua limitado a uma captura física. Retry de match usa `.finalSample` e
  nunca reabre orçamento do provider;
- match, submit e enqueue offline usam um fence revogável que combina geração de sessão e validade da
  avaliação. A invalidação vencedora impede o efeito irreversível;
- no transporte live, a autorização e `URLSessionDataTask.resume()` são linearizados. Se a invalidação
  vence, o request retorna `notDispatched` e o protocol handler não observa início de rede;
- na fila live, a validação e a persistência ocorrem atomicamente dentro do actor por
  `enqueueIfCurrent`;
- se `resume()` vence legitimamente antes da invalidação, o request já foi despachado e pode terminar, mas
  cache, log de atividade, notificação e demais efeitos locais da identidade antiga permanecem cercados;
- um submit confirmado pelo servidor antes de uma invalidação tardia continua sendo reportado como
  submitted; a invalidação não converte sucesso conhecido em retry ou falha artificial.

O retry antigo que reiniciava `runOnceLocked` inteiro deixou de ser o mecanismo de autenticação. Não há
segunda captura, reaplicação do movement gate, segunda matriz, nova identidade de evento ou notificação
duplicada para recuperar options/state/match.

### 25.5. Fluxo final de sessão e retry

```text
UI ou avaliação background
  │
  ├─ obtém snapshot da geração de sessão corrente
  │
  ├─ executa options / state / match
  │    │
  │    └─ unauthorized?
  │         ├─ reserva o único orçamento de auth da avaliação
  │         ├─ entra no refresh silencioso compartilhado da identidade
  │         ├─ valida novamente sessão + contexto da avaliação
  │         └─ repete somente a dependência que falhou
  │
  ├─ match retry
  │    └─ mesma amostra → revalidação 10 s/2 s → zero nova captura
  │
  └─ submit unauthorized
       └─ terminal; zero refresh, zero retry e zero enqueue automático
```

Troca de identidade e logout explícito seguem a barreira abaixo:

```text
ação explícita de troca/logout
  → invalidação síncrona da geração e das avaliações antigas
  → invalidação das respostas HTTP/cookies em voo
  → espera da cadeia de mutações anterior
  → mutação remota/local autorizada
  → publicação atômica da nova geração
  → liberação dos waiters
```

Delete preserva a regra existente de não limpar a sessão antes do sucesso remoto:

```text
delete solicitado na geração corrente
  → entra na cadeia serial
  → confirma que a geração ainda é corrente
  → executa DELETE remoto
  ├─ falha: mantém sessão/geração
  └─ sucesso ainda corrente: invalida geração → limpa localmente → libera a transição
```

Um waiter cancelado não cancela o refresh compartilhado nem os demais waiters. Respostas de uma geração
antiga não podem reativar cookie ou estado depois da troca.

### 25.6. Limites e contadores comprovados

| Propriedade | Limite final no escopo do Prompt 13 |
|---|---:|
| captura física por avaliação TIMER candidata | no máximo 1 |
| refresh silencioso por avaliação | no máximo 1 |
| login simultâneo por geração de identidade | no máximo 1 |
| request de options após primeiro `unauthorized` | no máximo 1 repetição |
| request de state após primeiro `unauthorized` | no máximo 1 repetição |
| match | no máximo 1 repetição, com a mesma amostra ainda fresca |
| nova captura durante retry de match | 0 |
| retry de submit | 0 |
| submit por evento lógico nesta fase | no máximo 1 |
| relogin/recaptura para HTTP 422 | 0 |
| dispatch/enqueue quando a invalidação vence o commit | 0 |
| mudança na matriz `AutoActivities` | 0 |

Os testes de corrida medem concorrência e efeitos, não apenas o resultado final: nos commits de match e
submit, invalidação de identidade ou automação vencedora conserva uma captura TIMER, inicia zero request
inválido, faz zero enqueue e não duplica submit.

### 25.7. Testes e builds

O projeto foi regenerado pelo processo documentado, sem atualização de dependências:

```text
./.tools/xcodegen/xcodegen/bin/xcodegen generate
```

Antes do fix, dois testes determinísticos de caracterização provaram a corrida residual que justificou o
coordenador environment-owned: uma resposta auth antiga e uma resposta não-auth antiga conseguiam repor o
cookie depois de `clear()`. O comando pré-fix executou os dois casos, obteve **2/2 falhas esperadas** e exit
65; depois da implementação, ambos integram a suíte verde:

```text
xcodebuild test -project Checking.xcodeproj -scheme Checking -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt13-cookie-red \
  -only-testing:CheckingTests/CookieStoreTests/test_authResponseFromPreviousIdentityCannotRestoreCookieAfterClear \
  -only-testing:CheckingTests/CookieStoreTests/test_nonAuthResponseFromPreviousIdentityCannotRestoreCookieAfterClear
```

Validações focais, executadas antes das suítes completas:

- coordenação, retries por estágio, transporte e integração: **96/96**, zero falhas;
- suíte Network isolada: **72/72**, zero falhas;
- guards de validade, fila e corridas TIMER: **20/20**, zero falhas;
- corridas integradas de identidade/automação nos commits de match/submit: **8/8**, zero falhas.

Esses conjuntos têm sobreposição e não devem ser somados como se fossem testes distintos.

Uma primeira execução diagnóstica sem assinatura executou 1.028 testes e encontrou oito asserções em quatro
testes de Keychain porque aquele produto de teste não possuía o entitlement/assinatura necessários. Esse
resultado foi tratado como limitação da invocação, não como baseline verde. A execução assinada seguinte
encontrou duas asserções em um único teste de accuracy retry. A investigação mostrou que a fixture aguardava
`isRunning`, mas não comprovava que a leitura bloqueada do restore já tinha começado. O teste foi tornado
determinístico por um sinal lock-backed do início real da leitura; nenhuma regra de produção foi relaxada.
O caso isolado passou **1/1** e, em seguida, **10/10** iterações consecutivas.

Suíte unitária final assinada:

```text
xcodebuild test -project Checking.xcodeproj -scheme Checking -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt13-full-unit-signed \
  -only-testing:CheckingTests
```

- **1.041/1.041**, zero falhas e zero unexpected;
- tempo interno dos testes: 25,979 s; suíte: 26,738 s;
- log ignorado: `.build/prompt13-full-unit-signed-rerun.log`.

Suíte UI final assinada:

```text
xcodebuild test -project Checking.xcodeproj -scheme Checking -configuration Debug \
  -destination 'platform=iOS Simulator,id=45D57727-95E8-4C58-A15F-A0087891AFD7' \
  -derivedDataPath .build/prompt13-full-ui-signed \
  -only-testing:CheckingUITests
```

- **28/28**, zero falhas e zero unexpected;
- tempo interno dos testes: 244,723 s; suíte: 244,748 s;
- log ignorado: `.build/prompt13-full-ui-signed.log`.

Build Release final, sem assinatura e sem instalar/abrir o app:

```text
xcodebuild build -project Checking.xcodeproj -scheme Checking -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/prompt13-release-final CODE_SIGNING_ALLOWED=NO
```

- `BUILD SUCCEEDED`;
- executável universal do Simulator: `x86_64 arm64`;
- `Info.plist` final: `CHECKINGBackgroundReliabilityProfile = legacyWithDiagnostics`;
- log ignorado: `.build/prompt13-release-final.log`.

O build emitiu warnings já visíveis em `AuthenticationDialogs`, `CheckEventStream` e `KeychainStore`; não
houve erro de Swift 6 nem falha de gate. Eles não foram alterados de forma oportunista fora do escopo desta
fase. Avisos ambientais do Simulator/runner não foram interpretados como prova de aparelho físico.

### 25.8. Arquivos modificados pelo Prompt 13

Produção/seams:

- `Checking/App/AppEnvironment.swift`;
- `Checking/App/RootView.swift`;
- `Checking/Core/API/HTTPClient.swift`;
- `Checking/Data/Network/SessionCookieStore.swift`;
- `Checking/Data/Offline/OfflineCheckQueue+EffectGuard.swift` (novo);
- `Checking/Data/Persistence/AppPreferencesStore.swift`;
- `Checking/Data/Repositories/AuthApi.swift`;
- `Checking/Data/Repositories/AuthSessionCoordinator.swift` (novo);
- `Checking/Data/Repositories/CheckApi.swift`;
- `Checking/Data/Repositories/CheckApiLive.swift`;
- `Checking/Data/Repositories/CheckRepositoryLive.swift`;
- `Checking/Domain/Models/AutomaticActivitiesExecution.swift`;
- `Checking/Domain/Repositories/AuthSessionCoordinating.swift` (novo);
- `Checking/Domain/Repositories/CheckRepository.swift`;
- `Checking/Domain/Repositories/OfflineCheckQueueing.swift`;
- `Checking/Domain/Repositories/OrchestratorSeams.swift`;
- `Checking/Domain/UseCases/CaptureLocationUseCase.swift`;
- `Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift`;
- `Checking/Features/Check/CheckViewModel.swift`;
- `Checking/Platform/Background/BackgroundCheckOrchestrator.swift`;
- `Checking/Platform/Video/BackgroundAccidentVideoUploader.swift`.

Testes/fakes:

- `CheckingTests/Accident/VideoUploadTests.swift`;
- `CheckingTests/Auth/AuthSessionCoordinatorTests.swift` (novo);
- `CheckingTests/Auth/CheckMainViewModelTests.swift`;
- `CheckingTests/Auth/CheckViewModelFakes.swift`;
- `CheckingTests/Auth/CheckViewModelHeadlessLifecycleTests.swift`;
- `CheckingTests/Auth/SelfRegistrationApprovalTests.swift`;
- `CheckingTests/DecisionEngine/AutomaticActivitiesEffectGuardValidityTests.swift` (novo);
- `CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift`;
- `CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift`;
- `CheckingTests/DecisionEngine/UseCaseFakes.swift`;
- `CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift`;
- `CheckingTests/Network/CookieStoreTests.swift`;
- `CheckingTests/Network/SafeApiCallTests.swift`;
- `CheckingTests/Offline/OfflineCheckQueueTests.swift`;
- `CheckingTests/Orchestrator/AccidentNotificationDecisionTests.swift`;
- `CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift`;
- `CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift`;
- `CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift`;
- `CheckingTests/Orchestrator/ContextCallbackFenceTests.swift`;
- `CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift`;
- `CheckingTests/Orchestrator/OrchestratorFakes.swift`;
- `CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift`;
- `CheckingTests/Orchestrator/PendingNormalWakeTests.swift`;
- `CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift`;
- `CheckingTests/Orchestrator/TimerSingleCaptureTests.swift`;
- `CheckingTests/Persistence/KeychainStoreTests.swift`.

Documentação:

- `docs/plans/background_reliability_execution.md`.

O status Git abaixo é acumulado desde o Prompt 02; portanto inclui também arquivos de fases anteriores.

### 25.9. Decisões de implementação e invariantes

- foi criado somente o menor coordenador environment-owned necessário para a corrida residual comprovada;
- o task-chain é intencional: a reentrância de um actor isolado não garante, sozinha, ordem total através
  de `await`;
- os poucos `@unchecked Sendable` novos encapsulam estado acessível somente sob `NSLock`; não foram usados
  para tornar `CLLocationManager`, `URLSessionDataTask` ou estado mutável arbitrário artificialmente
  Sendable;
- a adoção de cookie de resposta é condicionada à geração efêmera. A geração não é persistida e não altera
  headers, endpoints, DTOs ou o valor de `X-Client`;
- chamadas manuais mantêm as fachadas legadas. O fence de efeito é injetado somente no pipeline automático;
- o matcher do servidor e `AutoActivities.swift` permanecem autoridades da resolução e da decisão;
- não foi criado fallback de retry de submit, marker persistente, analytics, telemetria remota ou remote
  kill switch;
- `ApiError.detail`, `unknown(description:)`, cookies, credenciais e payloads não foram adicionados ao
  journal;
- as mensagens existentes do `ActivityLogger` não foram alteradas;
- a decisão futura do Prompt 14 já está registrada, mas nenhum BGTask controller, lease ou completion Bool
  foi implementado nesta fase.

### 25.10. Sentinelas protegidas

Os hashes permanecem idênticos aos registrados no Prompt 01:

| Arquivo protegido | `git hash-object` atual |
|---|---|
| `Checking/Core/Logging/ActivityLogger.swift` | `1eb84101ad37650c1fd348c5dbac2aff1af72c96` |
| `Checking/Domain/CheckRules/AutoActivities.swift` | `0a504f5e1eef835009de77bfbf530c374d9f265b` |
| `Checking/Data/DTOs/CheckDTOs.swift` | `35f436a6a62a573249d60bafdc6bbb860ceba040` |
| `Checking/Domain/Models/PendingCheckEvent.swift` | `ba94c01abb63103333f761d19ea22d54c7c3a06d` |
| `Checking/Data/Offline/OfflineCheckQueue.swift` | `6d7602926385da53bdf6ae14d303302129268b17` |
| `Checking/Data/Offline/PendingCheckReplayer.swift` | `e28b0e08229960b652dee1e0f71114471e6840b3` |

`git diff --check` está limpo.

### 25.11. Riscos, pendências e validações não executadas

Risco/bloqueio deliberado:

- não existe evidência de homologação aprovada pelo owner do backend para idempotência de duas requisições
  de submit com o mesmo `clientEventId`/`eventTime`. Por isso, retry de submit continua proibido;
- se um submit já despachado perder uma corrida futura com expiração/cancelamento e sua resposta ficar
  indeterminada, a política pré-aprovada do Prompt 14 é `submissionOutcomeUnknown`, Bool `false` e zero
  enqueue automático;
- a disputa específica entre cancelamento de `Task`/expiração e `URLSessionDataTask.resume()` pertence ao
  Prompt 14. A invalidação de identidade/automação do Prompt 13 está linearizada;
- se `resume()` vence antes da invalidação, o request pode chegar ao servidor; efeitos locais posteriores
  continuam bloqueados. Isso é diferente de tentar cancelar um request ainda não despachado;
- todos os configs continuam no perfil legado; admissão/captura/pending/lifecycle candidatos não foram
  ativados em Release. O coordenador de sessão e os fences de transporte são infraestrutura de segurança
  compartilhada, compilada para qualquer perfil, e não representam execução paralela de dois motores.

Não executados nesta fase:

- homologação server-side de idempotência;
- chamada mutável ao backend;
- instalação, abertura ou alteração de estado de iPhone físico;
- wake real de localização, cold relaunch físico, rádio, bateria ou thermal;
- TestFlight, assinatura de distribuição, upload, deploy ou publicação;
- commit, push, tag ou version bump;
- Prompt 14, simulator harness específico dessa fase ou qualquer marker persistente.

### 25.12. Estado Git e handoff

Baseline e origem permanecem:

```text
HEAD:     cc66dc131541cb66798e2de44a06d28a32b6df5a
upstream: cc66dc131541cb66798e2de44a06d28a32b6df5a
origin:   https://github.com/tscode-com-br/checking-swift.git
```

O worktree contém 47 arquivos rastreados modificados e 39 novos, 86 entradas no total, acumuladas dos
Prompts 02 a 13. Nenhuma mudança preexistente ou de fase anterior foi descartada:

```text
## main...origin/main
 M Checking/App/AppDelegate.swift
 M Checking/App/AppEnvironment.swift
 M Checking/App/RootView.swift
 M Checking/Core/API/HTTPClient.swift
 M Checking/Data/Network/SessionCookieStore.swift
 M Checking/Data/Persistence/AppPreferencesStore.swift
 M Checking/Data/Repositories/AuthApi.swift
 M Checking/Data/Repositories/CheckApi.swift
 M Checking/Data/Repositories/CheckApiLive.swift
 M Checking/Data/Repositories/CheckRepositoryLive.swift
 M Checking/Domain/Repositories/CheckRepository.swift
 M Checking/Domain/Repositories/LocationProvider.swift
 M Checking/Domain/Repositories/OfflineCheckQueueing.swift
 M Checking/Domain/Repositories/OrchestratorSeams.swift
 M Checking/Domain/Repositories/SignificantLocationMonitoring.swift
 M Checking/Domain/UseCases/CaptureLocationUseCase.swift
 M Checking/Domain/UseCases/RunAutomaticActivitiesUseCase.swift
 M Checking/Features/Check/CheckMainScreen.swift
 M Checking/Features/Check/CheckViewModel.swift
 M Checking/Features/Check/CheckViewModelSeams.swift
 M Checking/Info.plist
 M Checking/Platform/Background/BackgroundCheckOrchestrator.swift
 M Checking/Platform/Location/CLLocationManagerLocationProvider.swift
 M Checking/Platform/Location/CLLocationManagerSignificantChangeMonitor.swift
 M Checking/Platform/Location/GeofenceRegionManager.swift
 M Checking/Platform/Video/BackgroundAccidentVideoUploader.swift
 M CheckingTests/Accident/VideoUploadTests.swift
 M CheckingTests/Auth/CheckMainViewModelTests.swift
 M CheckingTests/Auth/CheckViewModelFakes.swift
 M CheckingTests/Auth/SelfRegistrationApprovalTests.swift
 M CheckingTests/DecisionEngine/CaptureLocationLoggingTests.swift
 M CheckingTests/DecisionEngine/UseCaseFakes.swift
 M CheckingTests/Location/CLLocationManagerLocationProviderTests.swift
 M CheckingTests/Location/CLLocationManagerSignificantChangeMonitorTests.swift
 M CheckingTests/Location/GeofenceRegionManagerTests.swift
 M CheckingTests/Network/CookieStoreTests.swift
 M CheckingTests/Network/SafeApiCallTests.swift
 M CheckingTests/Offline/OfflineCheckQueueTests.swift
 M CheckingTests/Orchestrator/AccidentNotificationDecisionTests.swift
 M CheckingTests/Orchestrator/AccuracyRetryEpisodeTests.swift
 M CheckingTests/Orchestrator/OrchestratorFakes.swift
 M CheckingTests/Orchestrator/OrchestratorSingleFlightTests.swift
 M CheckingTests/Orchestrator/ScheduledPauseDeferralTests.swift
 M CheckingTests/Persistence/KeychainStoreTests.swift
 M Config/Debug.xcconfig
 M Config/Release.xcconfig
 M Config/Staging.xcconfig
?? Checking/App/BackgroundReliabilityProfile.swift
?? Checking/Data/Offline/OfflineCheckQueue+EffectGuard.swift
?? Checking/Data/Persistence/DurableEvaluationJournal.swift
?? Checking/Data/Repositories/AuthSessionCoordinator.swift
?? Checking/Domain/Models/AutomaticActivitiesExecution.swift
?? Checking/Domain/Models/LocationSample.swift
?? Checking/Domain/Repositories/AuthSessionCoordinating.swift
?? Checking/Domain/UseCases/LocationSamplePolicy.swift
?? Checking/Features/Check/CheckSceneActivationGate.swift
?? Checking/Platform/Background/EvaluationApplicationStateProvider.swift
?? Checking/Platform/Background/EvaluationJournalModels.swift
?? Checking/Platform/Background/EvaluationJournaling.swift
?? Checking/Platform/Background/EvaluationRequest.swift
?? Checking/Platform/Background/MovementGatePolicy.swift
?? Checking/Platform/Location/CaptureSessionState.swift
?? CheckingTests/Auth/AuthSessionCoordinatorTests.swift
?? CheckingTests/Auth/CheckSceneActivationGateTests.swift
?? CheckingTests/Auth/CheckViewModelHeadlessLifecycleTests.swift
?? CheckingTests/BackgroundReliabilityProfileTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesEffectGuardValidityTests.swift
?? CheckingTests/DecisionEngine/AutomaticActivitiesExecutionTests.swift
?? CheckingTests/DecisionEngine/LocationAttemptPipelineTests.swift
?? CheckingTests/Location/LocationSamplePolicyTests.swift
?? CheckingTests/Orchestrator/ActivityNotificationSceneStateTests.swift
?? CheckingTests/Orchestrator/BackgroundDependencyResolutionTests.swift
?? CheckingTests/Orchestrator/CandidateTimerContextRaceTests.swift
?? CheckingTests/Orchestrator/ContextCallbackFenceTests.swift
?? CheckingTests/Orchestrator/DurableEvaluationTerminalTests.swift
?? CheckingTests/Orchestrator/EvaluationRequestMergeTests.swift
?? CheckingTests/Orchestrator/MovementGatePolicyTests.swift
?? CheckingTests/Orchestrator/PendingAccidentFairnessTests.swift
?? CheckingTests/Orchestrator/PendingContextInvalidationTests.swift
?? CheckingTests/Orchestrator/PendingDrainBehaviorTests.swift
?? CheckingTests/Orchestrator/PendingNormalWakeTests.swift
?? CheckingTests/Orchestrator/PendingOfflineQueueTests.swift
?? CheckingTests/Orchestrator/SignificantLocationSeedTests.swift
?? CheckingTests/Orchestrator/TimerSingleCaptureTests.swift
?? CheckingTests/Persistence/DurableEvaluationJournalTests.swift
?? docs/plans/background_reliability_execution.md
```

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
fix(ios): serialize auth refresh for background evaluation
```

## 26. Prompt 14 — verde localmente no candidato; validações externas pendentes

### 26.1. Gate humano e limite de autoridade

O mapping terminal → Bool e a política conservadora para submit indeterminado foram pré-aprovados no
handoff do Prompt 13. O Bool é a conclusão controlada do trabalho do sistema, não o sucesso de um
check-in.

O segundo gate continua **não comprovado**: o workspace não contém contrato server-side e evidência de
homologação aprovada pelo owner do backend demonstrando idempotência para repetição do mesmo
`clientEventId`/`eventTime`. Testes locais, DTOs e o replayer não substituem essa prova. Portanto, quando
um submit já despachado perde a resposta por cancelamento, o candidato grava
`submissionOutcomeUnknown`, completa o BGTask com `false` e não cria `PendingCheckEvent.Decided`, retry
automático, marker ou schema novo.

As lacunas de integração encontradas na auditoria foram fechadas por testes candidatos reais: expiração
BG/UIKit durante acquisition, state e match; submit já despachado antes do journal; journal indisponível;
ticket pending/coalescido; e expiração do BGProcessing com fila real preservada. O router do AppDelegate
prova, para cada perfil, que instala exatamente um caminho — controller candidato ou handler legado —
nunca ambos. Os gates determinísticos locais do Prompt 14 estão verdes; os limites externos abaixo não são
alegados como satisfeitos.

### 26.2. Implementação entregue

- `EvaluationCancellationContext` guarda a primeira razão vencedora (`bgTaskExpired`,
  `uiBackgroundTimeExpired`, `contextInvalidated` ou `taskCancelled`); `BackgroundWorkOwnership` limita
  owners aos slots conhecidos e só cancela o trabalho canônico quando o último orçamento expira.
- `BGAppRefreshExecutionController`, `BGTaskCompletionGate` e seu finalizador unem reagendamento regular
  e completion em caminho exactly-once. O handler nativo apenas marca/expira o owner; nunca faz `await`.
  O ticket canônico é aguardado inclusive para admissão `pending`/coalescida.
- `UIKitBackgroundTaskGuard` implementa `BackgroundExecutionLeasing`; a lease física tem expiration
  handler não nulo e termina uma vez. O no-op de teste é determinístico.
- O orquestrador faz guard de cancelamento antes de `.drained`/restore e antes/depois dos awaits caros.
  Um pending já expirado encerra `.expired` sem iniciar aquisição, match, state ou submit. Uma invalidação
  de contexto não pode sobrescrever uma expiração que já venceu first-wins.
- Expiração tardia entre o fim lógico e `journal.finish` é ligada ao mesmo record canônico de modo
  monotônico antes de `setTaskCompleted(false)`; não reabre nem altera o terminal de negócio já conhecido.
- `BGProcessingExecutionController` aplica o mesmo gate ao drain. `.retry` mantém a fila existente e
  reagenda somente o request oportunista; drain completo não cria wake vazio. Cancelamento não remove
  evento durável e não cria marker.
- `AppDelegate` instancia somente os controllers no perfil `candidate`; o perfil
  `legacyWithDiagnostics` conserva os handlers históricos. Debug, Staging e Release continuam com
  `CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics`.
- `AppDelegateBackgroundTaskHandlerRouter` é a fronteira testável dos dois registros UIKit. Ele instala
  exatamente um expiration handler e seleciona somente candidate ou legacy. Sob expiração repetida, o teste
  percorre router → BGProcessing controller → coordinator → replayer → fila real, preserva o evento
  durável e completa `false` uma vez.

Não foi criado handoff persistente de avaliação, marker de retomada, migração, alteração de schema ou
replayer. O marker que aparece como hipótese no texto antigo da Fase 6/§13.8 não foi implementado: o
Prompt 14 o substitui expressamente pelo caminho sem marker até eventual aprovação do Prompt 23.

### 26.3. Tabela terminal → Bool

Esta é a matriz pré-aprovada no handoff do Prompt 13 e mantida pelo `BGTaskCompletionPolicy`: o Bool relata
conclusão controlada da tarefa do sistema, não sucesso de check-in. Terminais conhecidos, admitidos e
concluídos dentro do orçamento permanecem `true`, inclusive falhas de negócio observadas; expiração,
cancelamento, resultado indeterminado, falha interna e admissão não canônica permanecem `false`.

| Terminal admitido e concluído antes da expiração | Bool | Justificativa |
|---|---:|---|
| `submittedCheckIn`, `submittedCheckOut` | `true` | submit teve resposta terminal conhecida |
| `noAction`, `skippedNoMovement` | `true` | wake foi processado controladamente |
| `noKey`, `toggleOff`, `paused`, `notConfigured`, `staleContext` | `true` | gate/contexto conhecido foi processado |
| `captured`, `bestPartial`, `locationTimeout`, `timeout`, `unavailable`, `permissionDenied`, `accuracyTooLow` | `true` | aquisição controlada chegou a terminal conhecido |
| `queuedOfflineRaw`, `queuedOfflineDecided`, `queuedOffline` | `true` | existe handoff durável na fila existente |
| `httpRejected`, `conflict` | `true` | rejeição permanente conhecida foi processada |
| `networkFailure`, `unauthorized`, `reloginFailed` | `true` | terminal observado; não indica sucesso de negócio |
| `expired`, `cancelled`, `submissionOutcomeUnknown`, `internalFailure` | `false` | orçamento/resultado não concluído de forma confiável |
| `abandoned`, `notAdmitted`, `coalescedCovered`, ou `admitted == false` | `false` | este BGTask não concluiu trabalho canônico admitido |
| qualquer linha com `completedBeforeExpiration == false` | `false` | expiração prevalece até sobre terminal de negócio controlado |

### 26.4. Diagrama de cancelamento

```text
BGTask expiration ─┐
UIKit lease expiry ├─> owner token expira ─> resta owner válido?
context invalidated ┘                          │
                                               ├─ sim: só o waiter expirado completa false;
                                               │       ticket canônico continua
                                               └─ não: cancellation context first-wins
                                                        ↓
                                             cancela avaliação/replayer cooperativamente
                                                        ↓
                                      journal terminal + owner expiration sanitizado
                                                        ↓
                                    end lease uma vez → reagenda → completion gate uma vez
```

### 26.5. Evidência de validação

- `BGAppRefreshExecutionIntegrationTests`: **9 aprovados**, incluindo expiração UIKit+BG em acquisition,
  state e match, submit confirmado antes do journal e journal indisponível;
- router + BGProcessing: **13 aprovados**; refresh controller, perfis, OfflineSync e replayer: **40
  aprovados**;
- `AuthSessionCoordinatorTests.test_cancelledWaiterDoesNotCancelSharedSilentRelogin`: **20 repetições
  aprovadas** após a sincronização explícita do waiter que já capturou o task compartilhado;
- suíte completa Debug final: **1.165 aprovados, 0 falhos, 0 ignorados** em
  `.build/prompt14p15-final-results.xcresult`;
- build Release final para simulador (`Checking (Release)`): aprovado, mantendo
  `legacyWithDiagnostics` como perfil distribuível;
- `./scripts/validate_background_simulator.sh 45D57727-95E8-4C58-A15F-A0087891AFD7` terminou com exit
  0: handlers refresh/processing registrados, atualização de localização em background, APNs e geofence
  enter/exit observados. O simulador classificou `refreshSubmission = unavailable`, portanto execução real
  de BGTask permanece inconclusiva e requer iPhone físico; push silencioso também ficou inconclusivo nesta
  rodada;
- `git diff --check` está limpo.

### 26.6. Pendências deliberadas e handoff

- falta a prova de idempotência server-side/homologação aceita pelo owner do backend; até ela existir,
  recuperação automática de submit indeterminado continua proibida;
- falta validação em iPhone físico para execução real de `BGAppRefresh`/`BGProcessing`, push silencioso,
  budget UIKit, rádio, bateria, thermal, cold relaunch e comportamento do daemon;
- nenhum config distribuível foi alterado, nenhum deploy, TestFlight, commit, push ou mudança de backend foi
  feito.

O worktree continua acumulado desde os Prompts 02–15: o `git status --short` final desta rodada contém 113
entradas (modificadas e não rastreadas), todas preservadas; não houve commit. HEAD e upstream permanecem
`cc66dc131541cb66798e2de44a06d28a32b6df5a`.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
fix(ios): complete and cancel background tasks exactly once
```

## 27. Prompt 15 — geofences por geração no candidato; verde localmente

### 27.1. Estado e escopo seguro

Foi implementado localmente, apenas no caminho `candidate`, um snapshot técnico em memória com geração,
`requested`, `confirmed`, `failed`/códigos fechados, `omitted`, `pending` e
`confirmationUncertain`. Ele não contém ID lógico, identifier físico, token, local, coordenada ou `Error`
bruto. A mensagem histórica byte-exact `Geofences registered (N).` foi mantida e significa somente
**requested**, nunca confirmação técnica.

Debug, Staging e Release continuam em `legacyWithDiagnostics`; consequentemente, o monitor legado permanece
o único caminho distribuível e não houve publicação, migração persistente, alteração de raio, de cap 20, de
priorização tier/Haversine/id, de deduplicação de 3 s ou de wake-only/server-side matching.

### 27.2. Geração, callbacks e reconciliação

- O candidato cria identifier físico `gfr1.<token aleatório da geração>.<slot aleatório>.<índice opaco>`.
  Ele é entregue apenas ao Core Location e nunca vai a journal, ActivityLog, export, UserDefaults ou UI.
- `didStartMonitoringFor` só confirma a região física atual quando identifier **e** geometria casam; então,
  e somente então, chama `requestState`. Callback antigo, geometria divergente e callback duplicado são
  ignorados. `monitoringDidFailFor` só falha uma região física atual; ausência de região torna a geração
  explicitamente `confirmationUncertain`, sem confirmação/falha atribuída indevidamente.
- Resync idêntico no mesmo processo preserva a geração e as confirmações. Mudança material recria um set
  físico novo. Remoção, logout, toggle ou troca de projeto invalidam o set e os aliases wake antes de parar
  os registros conhecidos; uma troca de projeto também faz `unregisterAll()` antes da nova reconciliação.
- No relaunch, `gfr1.*` herdado e o formato canônico legado `String(Int)` entram como
  `inheritedUnknown`: podem ser wake-only enquanto ainda não houve reconciliação, nunca contam como
  confirmados e são parados/rearmados bounded no primeiro sync. Identifiers externos, inclusive o harness
  Debug e strings numéricas não canônicas, não são tomados como propriedade do candidato.

```text
                ┌────────────── inheritedUnknown ───────────────┐
idle ── sync ──> requested / pending ── didStart atual ──> confirmed
 │                    │                     │                    │
 │                    ├── didFail atual ───> failed              │
 │                    ├── callback sem região ─> confirmationUncertain
 │                    └── mistura de estados ─> partiallyConfirmed
 │
 └── removeAll / logout / troca de projeto ─> invalidated ─> idle

callback antigo, geometria divergente ou identifier externo ─> ignorado
```

O alias de deduplicação é efêmero e privado por região lógica: ele mantém o par `(região, direção)` mesmo
se a identidade física mudar de geração, sem expor a correlação fora do processo.

### 27.3. Diagnóstico e privacidade

`PhysicalValidationScreen` consulta o snapshot candidato e mostra somente contagens técnicas. O relatório
Debug passou para schema 2 e tem allowlist de nomes de evento, chaves **e** valores (booleanos, contagens e
enumerações fechadas); reports antigos são saneados e regravados no relaunch. Assim, ID/token de região, local,
coordenadas e descrições/códigos brutos de erro não podem ser exportados pelo harness. `CLError` é reduzido
à whitelist `denied`, `regionMonitoringDenied`, `regionMonitoringFailure` ou `other`.

### 27.4. Evidência local e pendências externas

- `GeofenceGenerationAdapterTests`, `GeofenceRegionManagerTests` e
  `BackgroundValidationRecorderTests`: **41 aprovados, 0 falhas** no Simulator, cobrindo gerações
  atual/antiga, resync, inherited, migração legada bounded, cap/omitidas, dedup, troca de projeto e
  sentinelas de privacidade;
- regressão Debug final: **1.165 testes, 0 falhas, 0 ignorados**, em DerivedData isolado e preservada em
  `.build/prompt14p15-final-results.xcresult`; build `Checking (Release)` para simulador também passou e
  confirmou `CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics`;
- `./scripts/validate_background_simulator.sh 45D57727-95E8-4C58-A15F-A0087891AFD7` terminou com exit 0,
  gravando schema 2 sem identifier, coordenada, local ou erro bruto. Os handlers BG foram registrados;
  `refreshSubmission = unavailable` e o push silencioso permaneceram inconclusivos no Simulator, como
  esperado. O harness ainda valida somente o caminho sintético/legado, não confirma tecnicamente o set
  candidato em hardware;
- o predecessor Prompt 14 está verde no escopo local conservador e não bloqueia este fechamento local. A
  confirmação `confirmed` significa callback técnico do Core Location para a geração atual, não uma
  confirmação operacional em aparelho físico;
- o ensaio da Fase 7 que exige `Always` nominal em background e P80 confirmado em hardware permanece
  pendente de autorização própria do Prompt 21. Nenhum perfil distribuível foi promovido.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
feat(ios): track confirmed geofence monitoring state
```

---

## 28. Prompt 16 — lifecycle privado do diagnóstico

### 28.1. Decisão de exportação

Permanece vigente a decisão humana conservadora já registrada em §12.1: **não há exportação nem
apresentação de diagnóstico em produção**. A única superfície adicionada é o botão explícito
`Exportar diagnóstico` da `PhysicalValidationScreen`, compilado integralmente sob `#if DEBUG`; Staging e
Release não possuem botão, share sheet, tipo exportador ou símbolo correspondente no binário. Não houve
aprovação de produto para uma ação de usuário em produção, upload ou telemetria remota.

Também não houve aprovação/localização para novas mensagens humanas em `ActivityLogger`/Activities. As
strings byte-exact existentes foram preservadas. O texto técnico novo fica somente na tela de validação
Debug, que já é a superfície de ensaio controlada.

### 28.2. Implementação e fronteiras de privacidade

- `EvaluationDiagnosticsExporter` é um `actor` Debug-only sem dependência de rede. Ele é chamado somente
  pelo gesto explícito da tela, lê no máximo 500 records do journal e no máximo 500 eventos do recorder,
  e grava um JSON protegido em subdiretório aleatório de `temporaryDirectory`.
- O schema de exportação é distinto do envelope persistente e copia uma allowlist de enums, buckets,
  contagens, terminais, códigos HTTP/CLError sanitizados e timestamps locais. Ele omite
  `evaluationID`, `processID` e `sequence`, além de não ter campo para coordenada, local, projeto, chave,
  senha, cookie, token, body, URL, `clientEventId`, identificador de região ou erro cru.
- O `UIActivityViewController` Debug remove o arquivo tanto em conclusão quanto em cancelamento; a tela
  também o remove ao desaparecer. A remoção é idempotente e limitada ao diretório/nome que o exportador
  controla. Não há exportação em launch, refresh, background ou harness e não há upload.
- O `BackgroundValidationRecorder` agora aplica a mesma retenção de 500 eventos/30 dias, usa
  `completeUntilFirstUserAuthentication`, reindexa o snapshot bounded e possui `clear()` tolerante a
  arquivo ausente/falha. Após `clear`, callbacks Debug já enfileirados são descartados até um novo
  `reset()` explícito do ensaio, impedindo que recriem o report após um wipe.
- `deleteLocalData()` e exclusão remota bem-sucedida param/inativam o harness antes de limpar o recorder
  Debug, journal, `ActivityLog` e `EvaluationLog`; a fila offline continua seguindo exatamente suas regras
  anteriores. A exclusão remota com falha não executa qualquer wipe. A tarefa assíncrona do catálogo de
  auto-registro também passou a ter token/cancelamento, para que uma resposta tardia não repovoe a UI após
  o wipe.

### 28.3. Auditoria e testes

- `EvaluationDiagnosticsExporterTests` serializa sentinelas únicas de latitude, longitude, chave, senha,
  cookie, token, body, URL, local e região através do recorder e prova que não surgem no JSON exportado;
  também cobre schema fechado, cap, IDs omitidos, criação somente pela ação explícita, falha de I/O e
  cleanup idempotente sem apagar arquivo externo.
- `BackgroundValidationRecorderTests` cobre retenção por idade, cap, clear repetido, arquivo ausente e a
  barreira contra callbacks tardios. Os testes de `CheckViewModel` agora comprovam o arquivo real do
  `DurableEvaluationJournal` removido no wipe local e depois de DELETE remoto aceito, bem como logs
  Activity/Evaluation limpos somente no sucesso e preservados na falha.
- A busca dos paths novos não encontrou `String(describing:)`, `localizedDescription`, telemetria, upload
  ou marker persistente. A busca do binário `Checking (Release)` não encontrou `Exportar diagnóstico`,
  `EvaluationDiagnosticsExporter` nem o identificador de acessibilidade Debug.

### 28.4. Evidência local

- testes focais: **85 aprovados, 0 falhas, 0 ignorados**, preservados em
  `.build/prompt16-targeted2-results.xcresult`;
- regressão Debug completa: **1.172 aprovados, 0 falhas, 0 ignorados**, preservada em
  `.build/prompt16-final-results.xcresult`;
- `Checking (Release)` para simulador compilou com sucesso; os avisos exibidos foram os já existentes em
  `AuthenticationDialogs`, `KeychainStore` e `CheckEventStream`;
- `./scripts/validate_background_simulator.sh 45D57727-95E8-4C58-A15F-A0087891AFD7` terminou com exit 0:
  47 eventos sanitizados, localização em background e ENTER/EXIT observados. O Simulator continuou
  classificando BGAppRefresh como `unavailable` e não entregou push silencioso; ambos permanecem
  inconclusivos e exigem iPhone físico, sem efeito sobre a decisão de exportação Debug-only.

Nenhum perfil distribuível foi promovido. Ação de exportação em produção, novas mensagens humanas
localizadas e qualquer uso de dados exportados fora do aparelho continuam pendentes de aprovação explícita
do produto/privacidade.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
feat(ios): complete private evaluation diagnostics lifecycle
```

---

## 29. Prompt 17 — política pura e observacional de elegibilidade

### 29.1. Escopo e preservação de D5

Foi adicionado `BackgroundLocationEligibility`, uma classificação **pura** que recebe somente fatos já
avaliados: contexto de conta válido, toggle automático, projeto ativo, consentimento, autorização e precisão
de localização, serviço mestre de localização, Background App Refresh (BAR) e Low Power. A entrada não recebe
nem persiste chave, projeto, coordenada ou outro dado identificável; ela não consulta preferências, inspector,
UI ou estado global.

Esta fase é estritamente observacional. Não houve alteração em `PermissionLadder`,
`SignificantLocationStartupPolicy`, `AppEnvironment`, `CheckViewModel`, monitores, registro de geofences,
strings/localizações, requests de permissão ou journal. Em especial, o gate D5 continua sendo
`notificationsGranted && preciseLocationGranted` nos fluxos atuais; a nova política não recebe notificações e
**não** é substituta de `minimumToStartGranted` nem de `AutomationHealth` legado.

### 29.2. Estados e sinais

| Estado | Condição observada | Avalia em foreground | Prontidão nativa | BAR / Low Power |
|---|---|---:|---|---|
| `blocked` | qualquer gate de contexto, toggle, projeto, consentimento, serviço, autorização ou precisão falha | não | `notReady` | permanecem sinais diagnósticos separados |
| `foregroundOnly` | gates válidos + `When In Use` + precisão exata | sim | `notReady` | BAR degrada apenas o timer; Low Power é aviso |
| `operational` | gates válidos + `Always` + precisão exata | sim | `readyForCoreLocation` | BAR degrada apenas o timer; Low Power é aviso |

As razões são enums ordenados de bloqueio/degradação. `TimerBackgroundSignal` distingue disponível,
negado e restrito; `LowPowerSignal` distingue normal e aviso. BAR negado/restrito não reduz a prontidão de
Core Location e não é comando para parar regiões. `readyForCoreLocation` descreve somente capacidade nominal
de configuração/autorização: não promete periodicidade, timer, entrega do SO ou recuperação após force-quit.

### 29.3. Cobertura e evidência

- `BackgroundLocationEligibilityTests` cobre os estados explícitos, razões tipadas, BAR negado/restrito,
  Low Power, determinismo e uma matriz de **1.536** combinações de gates de negócio, autorização, precisão,
  serviço, BAR e Low Power;
- a regressão focal de permissões, ativação e startup aprovou **54 testes, 0 falhas, 0 ignorados**, preservada
  em `.build/prompt17-targeted-results.xcresult`;
- a suíte Debug completa aprovou **1.180 testes, 0 falhas, 0 ignorados**, preservada em
  `.build/prompt17-full-results.xcresult`;
- `Checking (Release)` para simulador compilou com sucesso, com os avisos preexistentes de
  `AuthenticationDialogs`, `CheckEventStream` e `KeychainStore`; `git diff --check` terminou limpo.

Não foi necessário executar harness de background ou ensaio físico nesta fase, porque não houve mudança de
integração/monitoramento; o Prompt 17 não autoriza nem torna o Simulator prova de entrega de background.
O próximo consumidor da política deverá reconciliar explicitamente sua semântica observacional com D5 e com a
saúde visual legada antes de qualquer mudança de start/stop, reservada ao Prompt 22 e à evidência física.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
refactor(ios): centralize background location eligibility
```

---

## 30. Prompt 18 — auditoria integrada e perfis candidato/legado

### 30.1. Decisão de configuração e escopo

Não houve aprovação humana para promover Debug ou Staging a `candidate`. Portanto, nenhuma configuração
persistente foi alterada nesta fase: `Debug`, `Staging` e `Release` resolvem
`CHECKING_BACKGROUND_RELIABILITY_PROFILE = legacyWithDiagnostics`. O candidato foi exercitado somente por
injeção explícita nos testes; não houve assinatura de distribuição, TestFlight, instalação física ou alteração
de Release. `candidateWithMovementExperiment` não é selecionado por nenhum `.xcconfig`, logo o experimento
permanece desligado em todos os artefatos instaláveis.

| Artefato | Perfil persistente | Motor exercitado |
|---|---|---|
| Debug | `legacyWithDiagnostics` | legado no app; legado e candidato nos testes |
| Staging | `legacyWithDiagnostics` | legado no app; candidato somente por injeção local |
| Release | `legacyWithDiagnostics` | legado; build/revert é o rollback |

O profile é lido apenas do bundle e seleciona um único pipeline. Ele não consulta configuração remota nem
constitui kill switch: um rollback de Release continua exigindo um novo build ou revert de código.

Esta fase não alterou regra de produção, endpoint, matriz, schema da fila, persistência de profile ou wire.
Os únicos acréscimos de código foram testes de integração e um ajuste focal de determinismo em teste herdado
do Prompt 14.

### 30.2. Cobertura integrada e correção focal

Foi adicionado `BackgroundReliabilityIntegrationTests`, sempre construindo o profile candidato por injeção.

| Cenário | Evidência |
|---|---|
| TIMER candidato | uma captura/amostra, match, state, decisão, submit, ID/tempo e terminal no journal |
| significant preciso | seed válida chega ao match e ao terminal sem criar/iniciar driver padrão |
| geofence + significant | `PendingNormalWakeTests`/`PendingContextInvalidationTests` cobrem slot serial, pending e ausência de duplicata |
| primeiro wake falha, segundo funciona | regressão de wakes pendentes e drain normal |
| cold launch | `CheckViewModelHeadlessLifecycleTests` prova candidato sem UI/remote no launch e monitor/orquestrador isolados |
| unauthorized | `TimerSingleCaptureTests` mantém uma renovação para match quando permitida e bloqueia corretamente retry de submit sem prova server-side |
| expiração BG | controllers de refresh/processing, leases e terminais duráveis cobertos pelos testes de orquestrador/plataforma |
| invalidação em await | o teste novo suspende match sob gate; a fence comum termina `staleContext` antes de state/submit. Os paths reais de conta, toggle, projeto e consentimento continuam cobertos pelos testes de lifecycle/ViewModel |
| offline raw/decided/replay | `TimerSingleCaptureTests`, fila offline, `PendingCheckReplayerTests` e `OfflineSyncCoordinatorTests` |
| journal/wipe/privacidade | journal durável, exporter, recorder e rollback candidato→legado |

O teste de rollback cria journal e evento raw do candidato, injeta somente um campo futuro desconhecido no
envelope, abre-o no legado, confirma que a fila não mudou, limpa o journal e garante que o pending candidato
invalidado não é retomado pelo legado. A compatibilidade comprovada é de **campo desconhecido**; não se
alega compatibilidade com tipos de terminal ainda não definidos.

Foi encontrado um flake no teste do Prompt 14
`test_contextInvalidatedDuringReloginFinishesStaleWithoutRetryingDependency`: a task que pedia invalidação
podia perder a corrida para a liberação do login. O menor ajuste foi adicionar um `AsyncGate` de entrada no
fake de autenticação e usar `beginAutomationContextTransition` → liberar gate → aguardar quiescência →
`endAutomationContextTransition`. Não houve mudança de produção. O caso passou 20/20 iterações; os quatro
testes integrados novos também passaram 20 vezes (80 execuções), sem `sleep` de corrida.

### 30.3. Auditoria de contratos, concorrência e privacidade

- A comparação com o baseline preserva hashes de matriz, DTO/wire, modelos, `PendingCheckEvent`, store/fila
  offline, `ActivityLogger`, notificações e contratos estritos de acidente. As mudanças restantes pertencem
  aos seams aprovados dos Prompts 06/13/14/16; revisão semântica não encontrou endpoint, body, header ou
  `X-Client` modificados.
- O candidato e o legado são exercitados, porém nunca no mesmo motor. Leases, completion gates e
  continuations exactly-once são cobertos pelos testes de controle BG, leases, controllers e terminais.
- A busca não encontrou `Task.detached` novo em produção nesta fase, nem `String(describing:)`/
  `localizedDescription` nos novos caminhos de diagnóstico. O único `Task.detached` presente no diff é o
  teste lock-backed de linearização da fila do Prompt 13; ele é aguardado pelo teste e não é fire-and-forget.
- O novo `@unchecked Sendable` do teste de integração encapsula somente `FakeCheckRepository` lock-backed e
  `AsyncGate` actor; os `@unchecked Sendable` de produção revisados são lock-backed ou closures imutáveis
  `@Sendable`. Nenhum foi adicionado pela lógica de produção deste Prompt.
- A suíte de journal/export/recorder, incluindo fixtures com sentinelas de latitude, longitude, chave,
  senha, cookie, token, body, URL, local e região, passou. Não há telemetria ou exportação automática nova.

O build Swift 6 não introduziu warnings novos. Permanecem somente os cinco avisos preexistentes em
`AuthenticationDialogs` (2), `KeychainStore` (2) e `CheckEventStream` (1), arquivos não alterados por esta
fase.

### 30.4. Comandos, contagens e duração

| Validação | Resultado |
|---|---|
| integração focal | 4/4, 0 falhas; 10,7 s de sessão (`prompt18-integration-final.xcresult`) |
| matriz integrada | 163/163, 0 falhas; 10,1 s de sessão (`prompt18-integration-matrix-v2.xcresult`) |
| repetição determinística | relogin 20/20; integração 80/80, ambas 0 falhas |
| testes unitários Debug | 1.156/1.156, 0 falhas; 45,5 s de sessão (`prompt18-full-unit.xcresult`) |
| testes UI Debug | 28/28, 0 falhas; 266,9 s de sessão (`prompt18-full-ui.xcresult`) |
| build Staging/Release sem assinatura | `BUILD SUCCEEDED` nos dois; ~2 min cada |
| `validate_background_simulator.sh` | exit 0; 47 eventos sanitizados; ~57 s |

O harness observou atualização de localização em background, registro de BGAppRefresh/BGProcessing e ENTER/EXIT
de geofence. O Simulator classificou BGAppRefresh como `unavailable` e não entregou o push silencioso;
ambos continuam inconclusivos e requerem iPhone físico. Nenhum gate físico foi declarado nesta fase.

`git diff --check` passou após a auditoria, inclusive nos novos arquivos não rastreados. O worktree segue
deliberadamente acumulando os artefatos dos Prompts 01–17; esta fase não os resetou nem reescreveu.

### 30.5. Pendência externa preservada

A recuperação automática de submit com resposta indeterminada continua bloqueada sem contrato e homologação
do backend para idempotência de `clientEventId`/`eventTime`. Por isso o submit `unauthorized` não é
automaticamente reenviado/enfileirado: termina de forma segura conforme os Prompts 13/14. Testes locais e
fakes não são prova suficiente. A pendência pertence ao owner de produto/backend e não foi mascarada para
declarar prontidão de rollout candidato.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
test(ios): validate background reliability candidate end to end
```

---

## 31. Prompt 19 — atualização factual de specs e decision log

### 31.1. Escopo estritamente documental

Após a evidência integrada do Prompt 18, esta fase revisou somente documentação. Não alterou fonte Swift,
testes, configs de build, `PrivacyInfo.xcprivacy`, schema/wire, fila/replayer, arquivos de distribuição,
assinatura, instalação, backend, TestFlight ou README: os comandos de desenvolvimento não mudaram.

As specs históricas de julho agora explicam que são baseline Kotlin/legado quando divergem do contrato atual.
O estado distribuível não mudou: Debug, Staging e Release seguem `legacyWithDiagnostics`; o candidato é
exercitado somente por injeção local e não representa uma promoção configurada.

### 31.2. Comportamento documentado

- `port_spec_background_orchestrator.md` passou a registrar sample timestamped, limites de frescor 10 s/2 s,
  revalidação antes do matcher, captura única de TIMER, seed significant opcional, pending normal bounded e
  ordem de drain. Também documenta a divergência deliberada do drop Kotlin, BGAppRefresh oportunista,
  completion/lease/cancelamento exactly-once, tabela terminal→Bool e ausência de marker persistente.
- `port_spec_auth_lifecycle.md` distingue restore local headless de restore remoto após cena `.active`, sessão
  serial por geração, retry por estágio e os terminais de submit. 401/403 de submit não repetem/enfileiram;
  422 permanece não-auth/não-GPS; replay durável preserva ID/tempo sem transformar resposta indeterminada em
  retry.
- `port_spec_permissions_diagnostics.md` descreve journal v1 privado, allowlist/proibições, orphan,
  retenção/proteção, wipe, snapshot geracional de geofence, exportação DEBUG-only e eligibility puramente
  observacional. Não houve telemetria nem mudança de manifest por causa do journal local.
- `decision_log.md` registra perfis build-time, frescor, ordem/merge/drain, mapping de BGTask, bloqueio de
  idempotência, eligibility/handoff/movimento condicionais e export DEBUG-only. Para homologação de
  `Localização não Cadastrada`/422 e idempotência de `clientEventId`/`eventTime`, owner backend/produto e
  prazo continuam **não identificados no workspace**.
- `background_validation_physical.md` preserva, sem inventar novo ensaio, a timeline anterior de 14:11–15:34
  com ida/volta separadas e marca o candidato físico, SLO, dwell, drive-through, energia e amostra como
  pendentes de autorização/critério.
- `testflight_pilot.md` passa a ser runbook condicional: diagnósticos → candidato interno → coorte pequena →
  25% → 100%, sem upload sem autorização, com owner/hotfix/rollback ainda a designar.

### 31.3. Gates preservados

- a recuperação de submit indeterminado continua bloqueada até contrato server-side e homologação aprovada
  demonstrando uma única atividade lógica para o mesmo `clientEventId`/`eventTime`;
- 422 de `Localização não Cadastrada` continua tentativa obrigatória e não vira auth/GPS;
- o candidato físico, BGTask real, rádio, bateria, thermal, push e comportamento do daemon não foram
  declarados aprovados pelo Simulator;
- nenhuma promoção de perfil, artefato Release-equivalente, upload ou rollout foi inferida desta atualização.

### 31.4. Validação documental

Foram executados, sem build, instalação ou chamada de backend:

```text
git diff --check
git diff --no-index --check /dev/null docs/plans/background_reliability_execution.md
```

Ambos passaram. Uma auditoria local adicional confirmou pares de fences Markdown e a existência de todos os
links/caminhos relativos nos sete documentos revistos. A comparação de `git status --short` com o início do
Prompt 19 encontrou somente as seis specs/docs rastreadas desta fase como novas entradas; o relatório já era
não rastreado de fases anteriores. Nenhum arquivo de produção, teste, configuração ou README foi modificado
por este Prompt.

Mensagem de commit sugerida, caso o usuário decida versionar a fase:

```text
docs(ios): document background reliability candidate
```

---

## 32. Prompt 20 — Simulator e build Release não assinado

### 32.1. Escopo, ambiente e limites de autoridade

Esta fase não mudou fonte Swift, testes, `.xcconfig`, projeto, entitlements, Privacy Manifest, fila, schema,
backend, distribuição ou perfil persistente. O único arquivo alterado por ela é este relatório; os produtos,
logs e result bundles ficaram em `.build/`, ignorado pelo Git. Não houve iPhone físico, conta de distribuição,
assinatura de distribuição, TestFlight, upload, chamada de backend ou uso de credenciais.

O ambiente local encontrado dinamicamente foi Xcode 26.6 (build 17F113), SDK iPhoneSimulator 26.5 e XcodeGen
2.45.4. O UUID de um Simulator disponível e já bootado foi obtido de `xcrun simctl list devices available`; o
comando não fixou um modelo de iPhone. O projeto foi gerado por:

```sh
./.tools/xcodegen/xcodegen/bin/xcodegen generate
```

Não houve aprovação humana para promover Debug ou Staging a `candidate`. Assim, o candidato foi exercitado
somente por injeção explícita nos testes; nenhum artefato candidato foi autorizado para assinatura ou
instalação. Debug, Staging e Release persistem em `legacyWithDiagnostics`.

### 32.2. Matriz local executada

| Validação | Resultado | Evidência preservada |
|---|---:|---|
| seleção dirigida do candidato (controllers BG, leases, terminal/journal, geofence, auth e lifecycle) | 179/179, 0 falhas/ignorados | `.build/prompt20-candidate-targeted.xcresult` |
| suíte unitária completa com os seams/injeções de candidato | 1.156/1.156, 0 falhas/ignorados | `.build/prompt20-full-unit.xcresult` |
| perfil legado e rollback candidato → legado | 10/10, 0 falhas/ignorados | `.build/prompt20-legacy-profile.xcresult` |
| testes UI Debug | 28/28, 0 falhas/ignorados | `.build/prompt20-ui.xcresult` |
| `validate_background_simulator.sh` com o UUID descoberto | exit 0; 47 eventos sanitizados | relatório no container efêmero do Simulator |

Os tempos registrados pelos result bundles foram aproximadamente 98 s (seleção dirigida), 126 s (suíte
unitária), 86 s (legado) e 363 s (UI), já incluindo a preparação de cada sessão. A execução interna dos
testes UI foi 266,459 s. O runner de testes usa a assinatura técnica `Sign to Run Locally` exigida pelo
Simulator; não usa certificado, profile, time ou identidade de distribuição.

O harness abriu somente o app Debug no Simulator. Ele confirmou atualização de localização enquanto a cena
estava em background, registro de BGAppRefresh/BGProcessing e entrega simulada de ENTER e EXIT de geofence.
O caminho significant foi coberto pelos testes de seed do candidato; o daemon de mudança significativa real
não é provado pelo Simulator. A submissão de BGAppRefresh foi classificada pelo próprio script como
`unavailable` e o callback de push silencioso não foi entregue nesta execução, ambos como **inconclusivos**,
não como sucesso nem como regressão. O push foi uma simulação local de `simctl`, não APNs externo.

### 32.3. Builds e archive sem assinatura de distribuição

Foram executados builds isolados em `.build/` para Debug, Staging e Release. Para Release e archive foi usado
o destino `generic/platform=iOS Simulator` e os overrides explícitos:

```text
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Os três builds terminaram com exit 0. O archive de Simulator também foi suportado e terminou com exit 0 em
`.build/prompt20-release-simulator.xcarchive`; não foi necessário nem permitido fazer fallback para hardware
físico. A inspeção do produto/arquivo encontrou `Signature=adhoc, linker-signed`, `TeamIdentifier=not set`,
nenhum `embedded.mobileprovision` e nenhum artefato `.xcent`. Essa assinatura ad-hoc técnica é gerada pelo
linker do Simulator para tornar o bundle executável ali; não é assinatura de distribuição, não usa
credencial e não torna o archive instalável/distribuível.

| Configuração | Perfil no `Info.plist` final | Resultado |
|---|---|---|
| Debug | `legacyWithDiagnostics` | build sem assinatura de distribuição, exit 0 |
| Staging | `legacyWithDiagnostics` | build sem assinatura de distribuição, exit 0 |
| Release | `legacyWithDiagnostics` | build e archive genéricos de Simulator, exit 0 |

Os cinco avisos de fonte distintos observados nos logs são os mesmos da baseline: dois bindings sem
`@Sendable` em `AuthenticationDialogs`, dois retornos de `withLock` não consumidos em `KeychainStore` e um
`await` redundante em `CheckEventStream`. Não há warning novo de concorrência nos paths desta sequência.
Avisos ambientais do runner/UI Simulator foram registrados como ambientais, não como evidência de aparelho
físico.

### 32.4. Inspeção do artefato Release

- O `Info.plist` Release contém exatamente `UIBackgroundModes = location, fetch, processing,
  remote-notification` e os identificadores permitidos `br.com.tscode.checking.refresh` e
  `br.com.tscode.checking.processing`.
- `legacyWithDiagnostics` resolve o pipeline legado e deixa `movementExperimentEnabled` falso. O valor de
  enum do experimento permanece como metadata estática do binário, mas não é o perfil efetivo nem habilita um
  segundo motor.
- A análise de rota confirma um único motor: `AppEnvironment.live` e o router de BG selecionam candidato
  **ou** legado; no Release a seleção efetiva é legado. O fluxo de `PhysicalValidationScreen` é alcançável
  apenas pela rota `#if DEBUG`; `BackgroundValidationHarness`, recorder, exporter e activity sheet são
  compilados sob `#if DEBUG`. No binário Release não foram encontrados argumentos/nomes de storage do harness
  (`--background-validation`, `--disable-background-validation` e equivalentes) nem símbolos dos tipos
  DEBUG-only.
- O bundle Release não contém seção DWARF embutida. O archive possui um dSYM externo normal para
  simbolicação, mantido somente em `.build`, e não uma superfície de harness no app Release.
- `project.yml` não declara packages e não há `Package.swift` no repositório; `otool -L` mostrou somente
  frameworks/bibliotecas do sistema Apple. O único entitlement declarado é `aps-environment`; não surgiu
  entitlement ou dependência inesperada.
- O journal persistente permanece local, bounded (500 records/30 dias, proteção
  `completeUntilFirstUserAuthentication`) e tipado por allowlist. A exportação deliberada é `#if DEBUG`; os
  testes completos incluem os scanners com sentinelas de localização, região, credenciais, cookie, token,
  body e URL. Não há telemetria ou exportação automática no Release.

### 32.5. Limitações que permanecem externas ao Simulator

Esta fase **não** declara validação de rádio/GPS real, energia/thermal, agendamento ou expiração real de
BGTask, cold relaunch real, force-quit/reboot, entrega real de push, comportamento do daemon significant ou
SLO. Esses itens continuam pendentes de aprovação explícita para ensaio físico controlado no Prompt 21.
Também continuam pendentes o contrato/homologação server-side de idempotência e a decisão de habilitar
candidate em configuração instalável.

`git diff --check` e a verificação equivalente do relatório não rastreado passaram após o registro final;
as fences Markdown também estão pareadas. O worktree acumulado dos Prompts anteriores foi preservado; esta
fase não realizou reset, commit ou alteração oportunista para ocultar limitações do Simulator.

## 33. Prompt 21 — pré-verificação de artefato físico (2026-08-04)

O owner autorizou o ensaio físico controlado e o uso do ambiente de produção **somente com a
conta/projeto de teste**. Esta autorização não transforma o servidor em prova prévia de idempotência: qualquer
tentativa de repetição do mesmo `clientEventId`/`eventTime` continua a exigir um cenário descartável,
observação explícita de uma única atividade lógica e registro sanitizado antes de ser usada como evidência.

Como a árvore de trabalho ainda contém as alterações locais dos Prompts 01–20 e não foi criado commit, a
identidade do conteúdo executável foi congelada por manifesto SHA-256 de 214 arquivos em
`.build/prompt21-candidate-source-manifest.sha256`. O digest do manifesto é:

```text
8ee94297d71d6eeefb983469e787aa0999e3f17505bc8d00086b8121366a0ca9
```

Foi gerado o projeto por XcodeGen e tentado o build genérico `Checking (Staging)` com o override transitório
`CHECKING_BACKGROUND_RELIABILITY_PROFILE=candidate`. A variante preserva o bundle isolado e os APNs de
desenvolvimento de Staging; portanto é adequada apenas como pré-ensaio seguro, **não** como alegação de
entitlements de produção equivalentes a Release.

O build parou na assinatura antes de compilar ou produzir um app instalável: este Mac não possui identidade
de code signing, profile de provisionamento nem conta Apple configurada no Xcode. Uma segunda tentativa com
provisionamento automático retornou `No Accounts`; ela não registrou dispositivo, não criou profile nem
instalou aplicativo. Nenhuma chamada ao backend, login de aplicação ou uso de credencial ocorreu.

Próximo pré-requisito: configurar no Xcode uma conta Apple Developer autorizada para a equipe do app e
repetir o build Staging candidato. Depois disso, ainda será necessária a confirmação do dispositivo e a
execução controlada contra a conta/projeto de teste; o ensaio físico formal permanece pendente.

### 33.1. Retentativa após configuração do Xcode

A conta Apple Developer foi configurada localmente e a identidade de desenvolvimento passou a estar disponível.
O manifesto do conteúdo candidato permaneceu idêntico ao digest acima. O build genérico de `Checking
(Staging)` com `CHECKING_BACKGROUND_RELIABILITY_PROFILE=candidate` e provisionamento automático terminou com
`BUILD SUCCEEDED`; o profile de desenvolvimento Staging foi resolvido sem registrar o dispositivo por este
comando.

A inspeção do produto confirmou assinatura válida, bundle `br.com.tscode.checking.staging`, perfil efetivo
`candidate`, otimização `-O`, ausência de `DEBUG` e ausência das strings do harness de validação DEBUG. Os
modos de background continuam `location`, `fetch`, `processing` e `remote-notification`. Os avisos são os
cinco já presentes na baseline de fonte e um aviso de extração de metadados AppIntents sem dependência; não
houve erro de build novo. Os hashes SHA-256 do executável e do `Info.plist` foram preservados nos logs de
`.build/`.

Os entitlements da build são deliberadamente os de desenvolvimento de Staging (`aps-environment =
development`, `get-task-allow = true`). Por isso ela é um **pré-ensaio funcional isolado**, não um artefato
físico Release-equivalente nem evidência para promover Release. A candidata foi instalada no iPhone conectado
somente depois de confirmar que o bundle Staging ainda não existia nele. A instalação não substituiu o bundle
de produção e não iniciou o app.

Até este ponto não houve launch, login, chamada ao backend, coleta de journal, TestFlight, distribuição ou
registro de resultado físico. O próximo passo requer a configuração manual, no aparelho, da conta/projeto de
teste e das permissões nominais antes de qualquer percurso.

### 33.2. Snapshot sanitizado após a configuração manual

Após a configuração manual no aparelho, foi copiado exclusivamente o arquivo allowlisted
`Library/Application Support/BackgroundReliability/evaluation-journal-v1.json` para
`.build/prompt21-device-evidence/`. Nenhum Keychain, banco de atividades, fila offline, log do sistema ou
outro conteúdo do container foi lido. O snapshot passou a validação estrutural do schema v1 e não contém chaves
proibidas de coordenada, região, URL, corpo, senha, cookie ou token.

O resumo sanitizado contém 13 records, todos terminais, sem expiração de owner, erro Core Location ou HTTP.
Os quatro records mais recentes atingiram `decision` e terminaram em `no_action`, incluindo wakes de
significant location e geofence. Os records anteriores `not_configured`/`toggle_off` foram preservados como
evidência de configuração progressiva e não são reclassificados. Esse estado é compatível com a configuração
atual, mas não prova cada permissão do iOS nem qualquer ação de servidor.

O snapshot de geofences requested/confirmed/failed/omitted/pending/uncertain não é exposto na build Staging
otimizada: `PhysicalValidationScreen`, recorder e exportador são `#if DEBUG`. O journal não substitui esse
snapshot. Consequentemente, esta build não pode declarar satisfeita a pré-condição nominal das nove regiões e
não deve iniciar o percurso formal do Prompt 21. O único passo físico seguro disponível é um smoke
warm/suspended, explicitamente não formal, seguido de nova coleta do mesmo journal allowlisted.

### 33.3. Roteiro planejado de pré-ensaio (não é resultado)

O owner definiu a seguinte sequência de observação automática, usando apenas os nomes funcionais já aprovados:

| Janela esperada | Evento esperado |
|---|---|
| hoje, ~17:00 | check-out ao deixar o local atual |
| amanhã, ~08:00 | check-in na Zona Mista |
| imediatamente depois | check-in no Escritório Principal |
| amanhã, ~08:20 | check-in no Escritório Avançado P80 |
| amanhã, ~08:30 | check-in na Unidade P80 |
| amanhã, ~08:50 | check-in no Escritório Avançado P80 |
| amanhã, ~09:00 | check-in no Escritório Principal |

Os horários acima são hipóteses observacionais, não comandos para criar presença manual nem promessa de wake
do iOS. Durante a janela o app deve permanecer em background quando não for indispensável configurá-lo; não
fazer check-in/check-out manual, force-quit, reinstalação, retry, teste de 422, replay ou alteração de
permissão. Se ocorrer ação em local incorreto, duplicada, crash/hang, resposta indeterminada ou dado sensível
exposto, preservar a evidência e encerrar a rodada sem tentativa corretiva.

Foi carregado um LaunchAgent local e datado para 2026-08-05. Ele tentará snapshots sanitizados às 09:00,
09:05, 09:15, 09:30, 09:55, 10:00, 10:10 e 10:15, somente se o iPhone estiver conectado ao Mac. Cada tentativa lê apenas
o journal allowlisted e produz resumo de contagens/enums; não abre o app nem acessa Keychain, banco de
atividades, fila offline ou backend. O job é best-effort: o Mac deve estar ligado e com sessão iniciada, e o
iPhone deve ser conectado perto do fim sem abrir o Checking Staging. Uma falha de conexão não é evidência de
falha do aplicativo.

### 33.4. Coleta de término do pré-ensaio Staging

O aparelho só foi conectado/destravado após as três primeiras tentativas automáticas de leitura; elas falharam
de forma segura como `device_or_app_unavailable`/`journal_copy_failed` e não abriram o app. A primeira cópia
válida ocorreu depois da conexão, seguida de repetição local para validar o resumidor. O LaunchAgent foi
removido imediatamente após a coleta, portanto não manterá acesso agendado ao aparelho.

O prefixo de 13 records do snapshot basal foi preservado na comparação canônica do conteúdo no journal final.
Foram acrescentados 41 records, todos terminais: zero órfãos, expiração de owner ou erro de localização; zero chaves proibidas no
schema. Houve 31 wakes em background, com geofence, significant location e timer presentes. Isso é evidência
de execução observável em background, não garantia de entrega futura pelo iOS.

| Métrica sanitizada | Resultado |
|---|---:|
| `submitted_check_out` | 1, na faixa local de 17h do dia anterior |
| `submitted_check_in` | 5: três na faixa de 08h e duas na de 09h local |
| `http_rejected` | 5; todos diagnósticos HTTP válidos `422`/`client_error` |
| `no_action` | 19 no delta do percurso |
| `paused` | 8 |
| `skipped_no_movement` | 3 |
| records sem terminal | 0 |

O roteiro previa seis check-ins, portanto a contagem de cinco não aprova a sequência. O journal deliberadamente
não contém nome de local, ID de região, coordenada ou identidade; ele não permite atribuir a ausência a uma
das transições nem afirmar local correto. Após a cópia final, a confirmação visual da história no app é o
próximo passo seguro. As cinco respostas 422 foram preservadas como terminais `http_rejected`, não como
`submissionOutcomeUnknown`; nenhum replay ou retry automático foi iniciado nesta coleta.

Este resultado continua sendo pré-ensaio Staging. Ele não prova o artefato Release-equivalente, confirmação de
geofences por geração, idempotência server-side, origem de cada 422, ausência de duplicação por local ou os
demais gates físicos formais do Prompt 21.

### 33.5. Confirmação visual posterior à cópia

Depois de a cópia final ter sido preservada, o owner abriu o Checking Staging e confirmou que os check-ins
mostrados no histórico estavam corretos para o roteiro planejado. Essa é a evidência de UI para os nomes
funcionais, que o journal deliberadamente não armazena.

Permanece uma discrepância de observabilidade: o roteiro enumerava seis check-ins e a interface foi confirmada
como correta, enquanto o journal sanitizado contém cinco terminais `submitted_check_in`. Não se deve escolher
uma fonte como vencedora nem reexecutar ações para “corrigir” a evidência. Isso não prova defeito do journal:
a tabela visual vem do histórico remoto, enquanto o journal cobre somente avaliações automáticas canônicas;
replay offline, ação manual anterior, outro cliente ou comportamento remoto podem acrescentar linha ao
histórico sem novo terminal local. O schema local deliberadamente não preserva ID de evento, horário de submit,
nome de local ou projeto, portanto as duas fontes não podem ser correlacionadas retrospectivamente. Não foi
feita alteração de código durante o percurso. A confirmação visual não transforma este pré-ensaio Staging em
gate físico formal aprovado.

Uma cópia read-only adicional, feita depois de abrir a candidata para a confirmação visual, acrescentou quatro
records terminais `no_action` (foreground, geofence e significant location) e nenhum `submitted_check_in`.
Assim, a hipótese de que a abertura posterior tenha criado o sexto check-in não explica a diferença. A próxima
investigação deve correlacionar o histórico remoto com os terminais locais e as respostas 422 usando um
contrato/backend autorizado; não houve retry, replay, reenvio ou mudança de dados para tentar reproduzi-la.

### 33.6. Configuração local `PhysicalValidation` para o snapshot de geofences

Foi adicionada a configuração XcodeGen `PhysicalValidation`, em modo Release, com perfil
`candidate`, otimização `-O`, APNs de produção e o símbolo de compilação `PHYSICAL_VALIDATION`. Ela usa o
bundle isolado `br.com.tscode.checking.physicalvalidation` e o nome distinto `Checking Physical Validation`.
O objetivo é permitir, no futuro e somente depois de aprovação, um artefato de validação equivalente ao
Release **exceto pela identidade isolada do bundle**.

Esta configuração é local e não-shipping por política: nesta fase não houve criação de App ID/profile,
assinatura, instalação, upload ou qualquer ação no Apple Developer Portal. Um futuro ensaio no aparelho ainda
precisará de App ID e profile isolados explicitamente aprovados. O build de Simulator usa somente overrides
temporários de assinatura desabilitada.

A rota de Ajustes de `PhysicalValidation` abre exclusivamente uma tela read-only que consulta o snapshot
existente do monitor candidato. Ela exibe apenas geração ordinal, contagens `requested`, `confirmed`,
`failed`, `omitted`, `pending`, `inheritedUnknown`, estado `confirmationUncertain` e códigos fechados de
falha. Não recebe nem apresenta ID físico/lógico, token, local, coordenada ou texto bruto de erro. A tela não
inicia monitor, captura, avaliação, recorder, exportação ou compartilhamento.

`BackgroundValidationHarness`, `BackgroundValidationRecorder`, `EvaluationDiagnosticsExporter` e a activity
sheet continuam compilados exclusivamente sob `#if DEBUG`; a tela técnica Debug completa também permanece
fora de `PhysicalValidation`. Release não define `PHYSICAL_VALIDATION`, não expõe a rota e não ganha superfície
de exportação/diagnóstico. Isto torna o snapshot observável para o gate de geofences, mas não aprova o ensaio
físico formal, o contrato de idempotência, a investigação de HTTP 422 nem uma distribuição TestFlight.

## 34. Prompt 25 — Preflight da candidata TestFlight (2026-08-05)

O target solicitado para a próxima candidata é `1.6.7 (5)`; a versão foi alterada apenas localmente. Esta é
uma preparação de pré-voo, não uma promoção: não foi criado archive, aplicada assinatura de distribuição ou
feito upload para App Store Connect/TestFlight.

### 34.1. Evidência local disponível

- A configuração isolada e não-shipping `PhysicalValidation` seleciona `candidate`, usa otimização `-O` e APNs
  de produção, mas não realizou ação no Apple Developer Portal, assinatura, instalação, archive ou upload.
- Os 13 testes focados passaram; a suíte unitária completa passou em `1161/1161` e os testes de UI em `28/28`.
- O harness de Simulator produziu 47 eventos sanitizados. BG refresh e silent push permanecem inconclusivos no
  Simulator, portanto não são evidência de entrega em dispositivo.
- Os perfis persistentes de `Debug`, `Staging` e `Release` continuam `legacyWithDiagnostics`. O candidato só
  foi exercitado em build com override temporário; nenhum perfil distribuível foi promovido.

### 34.2. Gates externos antes da candidata TestFlight

| Gate | Evidência ainda necessária |
|---|---|
| Idempotência server-side e HTTP 422 | Contrato/homologação aprovada de que repetir o mesmo `clientEventId`/`eventTime` não duplica atividade, e política explícita para os terminais HTTP 422 observados. |
| Ensaio físico e geofences | Amostra física formal e confirmação por geração de `requested`/`confirmed`/`failed`/`omitted`/`pending`/`confirmationUncertain`, sem callback ambíguo aceito como confirmado. |
| Smoke do Release exato | Build candidata com perfil, entitlements e identidade finais, inspecionada e exercitada no smoke definido para o artefato que será distribuído. |
| Perfil final e App Store Connect | Escolha humana registrada para o perfil persistente de Release, verificação do app/versão/build no App Store Connect e autorização final para archive, assinatura de distribuição e upload. |

Nenhum desses gates é satisfeito por teste local, Simulator ou pelo pré-ensaio Staging já registrado. A versão
local não deve ser enviada enquanto todos permanecerem bloqueando.

### 34.3. Instalação controlada para observação durante o dia

Com autorização explícita do owner e com o aparelho conectado/destravado, foi compilada e instalada a
variante de desenvolvimento **isolada** `Checking Staging` no bundle
`br.com.tscode.checking.staging`, versão `1.6.7 (5)`, com profile `candidate`. A assinatura foi verificada
antes da instalação; os entitlements efetivos são de desenvolvimento (`aps-environment = development` e
`get-task-allow = true`). A instalação atualiza somente o bundle Staging e não substitui o bundle de produção
`br.com.tscode.checking`.

O owner fará a observação normal durante o dia e retornará com o aparelho conectado para validação. O agente
não abriu a aplicação, não efetuou login, não leu Keychain/atividade/fila, não chamou o backend e não programou
coleta automática. Uma coleta futura, se autorizada, continuará limitada ao journal allowlisted e sanitizado.
Esta instalação é pré-voo e não é archive Release-equivalente, assinatura de distribuição nem TestFlight.
