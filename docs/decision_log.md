# Log de decisões de fidelidade — port Android → iOS

> Registro das divergências/ambiguidades do app Android que **não devem ser copiadas cegamente**,
> com a decisão adotada para o iOS. Formato conforme `conversion_plan.md` §29.
> Base analisada: Android `1.6.5` (`versionCode 24`).
> Fonte da verificação: auditoria de ground-truth (18 agentes, evidência `arquivo:linha`) — 2026-07-14.
> Dono das decisões: **Produto (Tamer Salmem)** — ajuste se o dono formal for outro.
> Data das decisões: **2026-07-14**.

Caminho base do código Kotlin: `kotlin/app/src/main/java/br/com/tscode/checking/`

## Convenção

- **Natureza — Replicar**: reproduzir o comportamento observado em produção (mesmo que seja bug/no-op), porque "fiel" = paridade com o binário publicado.
- **Natureza — Corrigir**: implementar a intenção correta, porque o comportamento de produção causa dano ativo (UX enganosa, risco LGPD) e o próprio plano (Princípio 2 e §29) manda não portar inconsistências.

Cada decisão adotada **precisa de um teste Swift** que afirme o comportamento escolhido (ver seção final).

---

## D1 — Callback que "desliga o automático" após falha do auto-checkin do acidente

- **Status:** confirmado (código morto / no-op).
- **Evidência:**
  - Lambda vazio com `TODO`: `presentation/check/CheckScreen.kt:119` — `accidentVm.onDisableAutoActivities = { /* TODO Phase 6: vm.setAutomaticActivitiesEnabled(false) */ }` (o método citado **nem existe**).
  - Declaração/uso do callback: `presentation/accident/AccidentViewModel.kt:44-45` (declaração) e `:270-275` (invocação após `AUTO_CHECKIN_RETRIES = 3` falhas → `FAILED` → `onDisableAutoActivities?.invoke()`).
  - Caminho real de desligamento (não usado aqui): `presentation/check/CheckViewModel.kt:1449-1464` (`onAutomaticActivitiesToggled(false)` → `AutoActivityController.stop()`).
  - Vestígio morto adicional: `AccidentUiState.needsDisableAutoActivities` (`AccidentUiState.kt:85`) e `onNeedsDisableAutoActivitiesHandled()` (`:550-551`) nunca são setados para `true`.
- **Comportamento Android (produção):** NÃO desliga o automático após a falha (no-op).
- **Decisão iOS:** **NÃO desligar** — reproduzir o comportamento publicado.
- **Natureza:** Replicar.
- **Justificativa:** é código morto; desligar seria comportamento novo e, dado D3 (o auto-checkin pode falhar à toa), potencialmente agressivo. A intenção original fica registrada como pendência de produto, não como requisito de v1.

## D2 — Flag de "automático" no cenário de acidente (usa proxy errado + hardcode)

- **Status:** confirmado (defeito de dano ativo).
- **Evidência:**
  - `presentation/check/CheckScreen.kt:257` passa `automticActivitiesEnabled = state.userProjects != null` para `AccidentUiState.inquiryScenario(...)`.
  - Parâmetro (grafia "automtic"): `AccidentUiState.kt:99`; uso: `:110` — `!automticActivitiesEnabled` decide entre `InquiryScenario.CheckedOutAutoOff` (esconde o card de acidente, `CheckScreen.kt:259-260`) e prosseguir para a sequência de auto-checkin.
  - Flag correto disponível no mesmo `state`: `CheckUiState.automaticActivitiesEnabled` (`CheckUiState.kt:115`), já usado corretamente em `CheckScreen.kt:302,490`.
  - 2º call-site hardcoda `true`: `AccidentViewModel.kt:81` → o toggle real **nunca** chega ao `inquiryScenario` em lugar algum.
- **Comportamento Android (produção):** trata o automático como **sempre ligado** (pois `userProjects != null` sempre que o usuário autenticado carregou projetos; e a VM hardcoda `true`).
- **Decisão iOS:** **passar o flag real** `automaticActivitiesEnabled`.
- **Natureza:** Corrigir.
- **Impacto:** usuário em check-out com automático **desligado** → `CheckedOutAutoOff` (sem card/sequência de auto-checkin); se os projetos falharem ao carregar, não mostra falsamente `CheckedOutAutoOff`.

## D3 — "Auto-checkin do acidente" é detect-and-wait passivo (não submete check-in)

- **Status:** confirmado (design intencional, nome enganoso).
- **Evidência:**
  - `presentation/accident/AccidentViewModel.kt:245-277` (`triggerAutoCheckin`): `AUTO_CHECKIN_RETRIES = 3`, intervalo 3s (constantes `:29-30`); a cada tentativa chama só `repository.getState(chave)` (`:255`) + `refreshState()` (`:258`) = `@GET check/accident/state`; inspeciona `currentActionIsCheckin` (`:259`).
  - `currentActionIsCheckin` só é populado por `onCheckWebState` (`:66-73`, set em `:71` a partir de `historyState.currentAction == "CHECKIN"`), empurrado pelo módulo Check via `CheckScreen.kt:125`.
  - Não existe endpoint de check-in em `AccidentApi.kt:21-53` (só state/open/report/acknowledge/emergency-call/video/wizard).
  - Variante background idem: `platform/background/BackgroundCheckOrchestrator.kt:154-175` (`runAccidentCheck`) e `:330-346` (`maybeNotifyAccident`) só fazem polling.
- **Comportamento Android (produção):** não submete check-in; espera passivamente o motor de check virar o estado compartilhado. Se o motor estiver ocioso/desligado, falha determinística após ~9s.
- **Decisão iOS:** **manter passivo** — portar literal (o acidente consulta o estado e lê o check-in do módulo Check; não emite check-in nem aciona o motor).
- **Natureza:** Replicar (desacoplamento intencional — ver `platform/background/AccidentWatchWorker.kt:14-18`).
- **Nota de coerência:** combinado com D2, o auto-checkin passivo só roda para quem tem automático ON → o motor tende a estar ativo → conclui com mais frequência que no Android atual.

## D4 — Upload de vídeo: falso sucesso + vazamento do arquivo temporário

- **Status:** confirmado (falso sucesso) / o plano preliminar estava **impreciso** quanto ao arquivo.
- **Evidência:**
  - `data/repository/AccidentRepositoryImpl.kt:101-124` — `uploadVideo` retorna `AppResult<VideoUploadResult>`; o `delete()` do temporário (`:118`, `runCatching { videoFile.delete() }`) está **dentro** do `safeApiCall`, **após** o `api.uploadVideo(...)` (`:111`) retornar sem exceção → só roda em sucesso HTTP. **Não há exclusão prematura.**
  - `data/remote/ApiCallUtils.kt:8-21` — `safeApiCall` converte todo erro em `AppResult.Failure` **retornado** e nunca relança.
  - `presentation/accident/AccidentViewModel.kt:534-546` — `uploadVideo` **descarta** o `AppResult` (sem `is Success/Failure`).
  - `presentation/accident/VideoRecordScreen.kt:162-177` — `runCatching { onUpload() }` sempre termina → `phase = DONE` ("enviado"); o ramo `ERROR` só dispararia numa exceção lançada, que aqui nunca ocorre.
  - Idempotência: `idempotency_key` é UUID gerado por-tentativa (`AccidentViewModel.kt:541`), não persistido.
- **Comportamento Android (produção):** mostra "enviado" mesmo em falha de rede/5xx/401/409; o MP4 **vaza** no `cacheDir` na falha (não é deletado — o **oposto** de exclusão prematura).
- **Decisão iOS:** **corrigir** — inspecionar o `Result`: transicionar para sucesso/DONE **só** em `.success`; estado de erro em `.failure` (espelhando `submitReport`/`emergencyCall`/`open`, que já fazem `switch` em `AccidentViewModel.kt:198-238,499-522`). Deletar o temporário **só** em sucesso confirmado; em falha, limpar ou reter para re-tentativa, com opção clara de tentar de novo.
- **Natureza:** Corrigir.
- **Parts multipart a espelhar exatamente:** `chave`, `idempotency_key`, `video`.
- **Enhancement em aberto (a decidir depois):** persistir o `idempotency_key` entre re-tentativas do usuário (o Android só é idempotente dentro de uma tentativa).

## D5 — Comentários "Localização Sempre é obrigatória" vs. gate real

- **Status:** confirmado (deriva de documentação; o código já faz o certo).
- **Evidência:**
  - Gate real: `platform/background/permissions/PermissionLadder.kt:49-50` — `minimumToStartGranted = notificationsGranted && fineLocationGranted` (background/"Sempre" deliberadamente fora).
  - Honrado em: `AutoActivitiesDialog.kt:200-209`, `CheckViewModel.kt:1404-1411`, `AutoActivityController.kt:24-42` (só checa `ACCESS_FINE_LOCATION`).
  - Comentários obsoletos ("Always mandatory"): `AutoActivitiesDialog.kt:238-239,73-74`; `CheckViewModel.kt:1398`; `PermissionLadder.kt:15,59-61`.
- **Comportamento Android (produção):** inicia o motor com **notificações + localização precisa**; "Sempre"/background é **recomendado** (aviso "confiabilidade reduzida" + glow cosmético), nunca bloqueia.
- **Decisão iOS:** **espelhar o comportamento atual** — gate mínimo = notificações + localização precisa; "Always" e Low Power = recomendados/não bloqueantes. Ignorar os comentários obsoletos.
- **Natureza:** Replicar comportamento (não portar os comentários).
- **Ressalva iOS (documentar):** no iOS, region monitoring / significant-change **exigem** autorização "Always". Sem ela, o motor iOS roda em **modo degradado (foreground-only)**. A **estrutura do gate** espelha o Android, mas a capacidade real de background depende de "Always" — isso deve ser explícito no painel de integridade.

## D6 — "Apagar dados deste dispositivo" não limpa a fila offline criptografada

- **Status:** confirmado no Android; correção iOS implementada e coberta localmente.
- **Evidência:**
  - `presentation/privacy/PrivacyViewModel.kt:43-52` (`deleteLocalData`) executa 5 passos crash-guarded: `AutoActivityController.stop`, `authRepository.logout()` (cookies), `activityLog.clear()` (**Room — é limpo**), `securePasswordStore.clearAll()` (senhas), `appPrefs.clearAll()` (DataStore). O construtor (`:26-32`) **não injeta** `OfflineCheckQueue`/`OfflineQueueStore`.
  - `platform/background/offline/EncryptedOfflineQueueStore.kt:24-68` — arquivo `checking_offline_queue` (`:35`), key `pending_checks_json` (`:66`); migração legada que move o dado do DataStore cleartext para o arquivo cifrado e limpa o legado (`:54-63`). **Não expõe** `clear/clearAll/deleteAll` (grep confirma nenhum).
  - `data/local/AppPreferencesDataSource.kt:65` — `clearAll()` = `dataStore.edit { it.clear() }` (só DataStore); comentários `:63-64` e `PrivacyViewModel.kt:49` ("DataStore: ... offline queue") são **obsoletos**.
- **Correção de precisão do diagnóstico Android:** o **Room (activity log) É limpo** (via
  `activityLog.clear()`), tanto no wipe de privacidade quanto no `deleteAccount` remoto
  (`CheckViewModel.kt:1211-1223`). A **única residual confirmada no Android** é a fila offline criptografada
  (GPS preciso), que sobrevive ao wipe.
- **Comportamento Android (produção):** limpa DataStore + senhas + cookies + Room + para o motor; **deixa a fila offline criptografada** intacta.
- **Decisão iOS:** **corrigido** — wipe local e delete remoto aceito primeiro invalidam/quiescem a automação e
  então limpam o journal, a fila offline, ActivityLog, EvaluationLog, credenciais e preferências. Delete que
  falha ou retorna 409 preserva sessão e dados. A fila iOS expõe e usa `clear()`; não é mais TODO.
- **Natureza:** Corrigir.

---

## D7 — (dobrado em D2)

O hardcode `automaticActivitiesEnabled = true` em `AccidentViewModel.kt:81` é a segunda face do mesmo defeito de D2 e é resolvido pela mesma correção (passar o flag real em todos os call-sites de `inquiryScenario`).

---

## D8 — Perfil de confiabilidade e promoção

- **Status:** configuração vigente; promoção pendente de aprovação humana.
- **Decisão iOS:** `Debug`, `Staging` e `Release` permanecem `legacyWithDiagnostics`. `candidate` é exercitado
  por injeção/override local temporário e pela configuração isolada, não-shipping, `PhysicalValidation`, que
  serve exclusivamente ao pré-voo agregado; ela não promove Release. `candidateWithMovementExperiment` não é
  selecionado. O profile vem do bundle, escolhe um motor por vez e não é kill switch remoto. Rollback de
  Release exige novo build/revert, não uma flag remota.
- **Pendente explícito:** a escolha final do perfil de Release, o artefato Release-exato e qualquer archive,
  assinatura de distribuição, TestFlight ou upload continuam condicionados aos gates técnicos e à aprovação
  final registrada. `PhysicalValidation` ainda não autoriza ação no Apple Developer Portal.

## D9 — Frescor da amostra no candidato

- **Status:** aprovado para ensaio local; ainda não calibrado por percurso físico.
- **Decisão iOS:** `maximumAge = 10 s` e `futureTolerance = 2 s`. A amostra é revalidada imediatamente antes
  do matcher. Os valores só se aplicam ao candidato, não são SLO nem promessa de rollout.

## D10 — Ordem, captura e pending dos wakes candidatos

- **Status:** aprovado e testado localmente.
- **Decisão iOS:** ordem `gates/projeto/opções/pausa → captura → movimento → revalidação/match → state quando
  necessário → matriz → submit/fila`. TIMER faz no máximo uma captura. Há no máximo um pending normal, e a
  ordem de drain é `pause transition → pause activation → foreground/pause reconciliation → pending normal →
  accuracy retry → acidente`.
- **Natureza:** divergência deliberada do drop Kotlin: o follow-up bounded conserva o wake normal sem permitir
  motor paralelo; `coalesced`/`deferred` não são terminal e o waiter aguarda o ticket canônico.

## D11 — Completion de BGTask e cancelamento

- **Status:** mapping aprovado e testado localmente; hardware continua pendente.
- **Decisão iOS:** o Bool de `setTaskCompleted` relata conclusão controlada do trabalho do sistema, não sucesso
  do check-in. Terminais conhecidos/gates processados, `noAction`, `skip`, fila offline durável e rejeição
  permanente processada retornam `true`. `expired`, `cancelled` sem handoff durável,
  `submissionOutcomeUnknown`, `internalFailure` ou não admissão retornam `false`. Reagendamento, lease e
  completion são exactly-once; expiração de um owner não cancela outro owner válido.

## D12 — Idempotência de submit e `submissionOutcomeUnknown`

- **Status:** bloqueio externo; não há aprovação para retry/enqueue automático.
- **Decisão iOS vigente:** se submit já foi despachado e cancelamento torna a resposta indeterminada, terminar
  `submissionOutcomeUnknown`, completar BGTask com `false` e não criar segunda submissão,
  `PendingCheckEvent.Decided`, marker ou schema novo. `clientEventId`/`eventTime` são preservados pelo
  cliente/fila, mas isso **não** prova deduplicação server-side. Submit 401/403 é outro terminal
  (`unauthorized`) e também não reloga, repete ou enfileira automaticamente.
- **Critério para revisar:** contrato server-side e homologação que repita o mesmo par
  `clientEventId`/`eventTime`, demonstre uma única atividade lógica, identifique ambiente/data e tenha aceite
  do owner backend.
- **Homologação de `Localização não Cadastrada`/HTTP 422:** a tentativa obrigatória permanece; 422 não vira
  auth/GPS nem autoriza relogin/recaptura. Para esta homologação e para a prova de idempotência acima, owner
  backend/produto: **não identificado no workspace**; prazo: **não registrado**. Esses campos precisam de
  designação humana antes do gate físico/rollout.

## D13 — Eligibility, handoff, monitores e movimento

- **Status:** condicional.
- **Decisão iOS:** `BackgroundLocationEligibility` é somente observacional; D5 permanece intacta e não há
  start/stop novo por essa política. Aplicar eligibility e mover ownership nativo de monitor ficam condicionais
  ao Prompt 22 e à evidência correspondente. Handoff persistente de avaliação não existe e só pode ser
  considerado no Prompt 23 após decisão/evidência. O movement experiment permanece OFF; experimento de raio
  de wake fica fora desta sequência e exige plano e aprovação próprios.

## D14 — Exportação e telemetria de diagnóstico

- **Status:** decisão aprovada somente para DEBUG.
- **Decisão iOS:** exportação é gesto explícito da `PhysicalValidationScreen` DEBUG, bounded e sanitizado. Não
  há botão/share sheet Release, upload, telemetria remota ou export automático. Produção exige nova aprovação
  de produto/privacidade, localização e testes de acessibilidade.

---

## Resumo das decisões

| ID | Defeito | Natureza | Resultado iOS |
|----|---------|----------|---------------|
| D1 | Callback de disable é no-op | Replicar | Não desligar o automático após falha do auto-checkin |
| D2/D7 | Flag de automático usa proxy errado + hardcode | Corrigir | Passar o `automaticActivitiesEnabled` real |
| D3 | Auto-checkin do acidente só consulta | Replicar | Manter detect-and-wait passivo |
| D4 | Upload de vídeo: falso sucesso + vazamento | Corrigir | Inspecionar Result; sucesso só em `.success`; limpar temp corretamente |
| D5 | Comentários "Always obrigatório" | Replicar comportamento | Gate = notificações + precisa; "Always" recomendado (degradado no iOS sem ele) |
| D6 | Wipe não limpa fila offline | Corrigir | Wipe completo, incluindo a fila offline cifrada |
| D8 | Perfis de confiabilidade | Build-time | Debug/Staging/Release legados; `PhysicalValidation` isolada usa candidato só no pré-voo; sem kill switch remoto |
| D9 | Frescor candidato | Ensaio local | 10 s/2 s e revalidação antes do matcher |
| D10 | Wakes concorrentes | Divergência deliberada | Pending normal bounded e drain ordenado |
| D11 | Completion BGTask | Segurança de plataforma | Bool por conclusão controlada; lease/completion exactly-once |
| D12 | Submit indeterminado | Bloqueio externo | Unknown sem retry/enqueue até homologação server-side |
| D13 | Eligibility/handoff/movimento | Condicional | Política observacional; monitor/handoff/experimento aguardam gates |
| D14 | Exportação | DEBUG-only | Gesto explícito, sem telemetria ou superfície Release |

## Obrigações de teste (cada decisão vira um XCTest)

- **D1:** teste afirma que, após 3 falhas do auto-checkin do acidente, o automático **permanece ligado** (nenhum `stop`/persistência de flag ocorre).
- **D2/D7:** cenário de acidente com `automaticActivitiesEnabled = false` + check-out ⇒ `CheckedOutAutoOff`; com `true` ⇒ entra na sequência de auto-checkin.
- **D3:** o fluxo de acidente **não** chama nenhum endpoint de submissão de check-in; só polling de `accident/state` + leitura do estado do módulo Check.
- **D4:** upload que retorna `.failure` ⇒ estado de **erro** (não "enviado") e o temporário **não** é deletado (fica disponível para re-tentativa); `.success` ⇒ "enviado" + temporário deletado.
- **D5:** motor inicia com apenas notificações + localização precisa concedidas; ausência de "Always"/background ⇒ status "degradado" sem bloquear o início.
- **D6:** após o wipe, a fila offline cifrada fica **vazia** (0 eventos), além de DataStore/senhas/cookies/Room.
- **D8–D11:** testes de perfil, amostra, pending, leases, controllers e completion verificam seleção de um
  motor, limites de captura/pending e exactly-once.
- **D12:** testes locais preservam ID/tempo e verificam ausência de retry/enqueue automático; eles não são
  prova da homologação server-side exigida.
- **D13:** matriz pura de eligibility verifica estados/sinais sem produzir start/stop de monitor.
- **D14:** testes de export/wipe usam sentinelas de privacidade e verificam criação somente por ação DEBUG e
  cleanup idempotente.
