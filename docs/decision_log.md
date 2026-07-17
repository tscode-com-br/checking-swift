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

- **Status:** confirmado (lacuna LGPD art. 18).
- **Evidência:**
  - `presentation/privacy/PrivacyViewModel.kt:43-52` (`deleteLocalData`) executa 5 passos crash-guarded: `AutoActivityController.stop`, `authRepository.logout()` (cookies), `activityLog.clear()` (**Room — é limpo**), `securePasswordStore.clearAll()` (senhas), `appPrefs.clearAll()` (DataStore). O construtor (`:26-32`) **não injeta** `OfflineCheckQueue`/`OfflineQueueStore`.
  - `platform/background/offline/EncryptedOfflineQueueStore.kt:24-68` — arquivo `checking_offline_queue` (`:35`), key `pending_checks_json` (`:66`); migração legada que move o dado do DataStore cleartext para o arquivo cifrado e limpa o legado (`:54-63`). **Não expõe** `clear/clearAll/deleteAll` (grep confirma nenhum).
  - `data/local/AppPreferencesDataSource.kt:65` — `clearAll()` = `dataStore.edit { it.clear() }` (só DataStore); comentários `:63-64` e `PrivacyViewModel.kt:49` ("DataStore: ... offline queue") são **obsoletos**.
- **Correção de precisão:** o **Room (activity log) É limpo** (via `activityLog.clear()`), tanto no wipe de privacidade quanto no `deleteAccount` remoto (`CheckViewModel.kt:1211-1223`). A **única residual confirmada** é a **fila offline criptografada** (GPS preciso), que sobrevive ao wipe.
- **Comportamento Android (produção):** limpa DataStore + senhas + cookies + Room + para o motor; **deixa a fila offline criptografada** intacta.
- **Decisão iOS:** **corrigir** — o wipe LGPD inclui explicitamente um passo crash-guarded que limpa o equivalente iOS da fila offline (Keychain/arquivo cifrado). Expor um método `clear()` na fila (que hoje não existe).
- **Natureza:** Corrigir.

---

## D7 — (dobrado em D2)

O hardcode `automaticActivitiesEnabled = true` em `AccidentViewModel.kt:81` é a segunda face do mesmo defeito de D2 e é resolvido pela mesma correção (passar o flag real em todos os call-sites de `inquiryScenario`).

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

## Obrigações de teste (cada decisão vira um XCTest)

- **D1:** teste afirma que, após 3 falhas do auto-checkin do acidente, o automático **permanece ligado** (nenhum `stop`/persistência de flag ocorre).
- **D2/D7:** cenário de acidente com `automaticActivitiesEnabled = false` + check-out ⇒ `CheckedOutAutoOff`; com `true` ⇒ entra na sequência de auto-checkin.
- **D3:** o fluxo de acidente **não** chama nenhum endpoint de submissão de check-in; só polling de `accident/state` + leitura do estado do módulo Check.
- **D4:** upload que retorna `.failure` ⇒ estado de **erro** (não "enviado") e o temporário **não** é deletado (fica disponível para re-tentativa); `.success` ⇒ "enviado" + temporário deletado.
- **D5:** motor inicia com apenas notificações + localização precisa concedidas; ausência de "Always"/background ⇒ status "degradado" sem bloquear o início.
- **D6:** após o wipe, a fila offline cifrada fica **vazia** (0 eventos), além de DataStore/senhas/cookies/Room.
