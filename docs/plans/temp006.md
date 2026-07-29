# temp006 — Zona Mista: cooldown indevidamente burlado por drift de GPS (check-out/in espúrio)

> **Status:** diagnóstico concluído (2026-06-22), confirmado com dados de produção (read-only) e leitura
> do código nas duas superfícies. Solução **aprovada pelo dono do produto**. Este documento contém
> **prompts completos e autossuficientes** para um agente de IA implementar a correção. **Nenhum código
> foi alterado ainda.**
>
> **Regra geral:** alterar **apenas o que for necessário**. A mudança é **de decisão client-side** (não há
> mudança no servidor, nem migração, nem dados). É uma **alteração deliberada da Situação 8** (a spec
> atual descreve o comportamento que causa o problema), então a spec também é atualizada.

---

## 1. Sumário executivo (o que acontece)

A "Zona Mista" é uma localização de **alternância automática**: ao ser detectado nela, o app faz check-out
se a última atividade foi check-in, e check-in se foi check-out (Situação 8). Para evitar flapping, há o
campo **'Intervalo de Tempo Zona Mista'** (tabela Projetos; P80 = **30 min**) que funciona como cooldown.

**O problema:** o cooldown hoje só vale para **leituras consecutivas dentro da própria Zona Mista** (quando
o estado registrado do usuário já é "Zona Mista"). Quando a última atividade foi em **outra** localização
(ex.: "Escritório Principal", fisicamente **adjacente** à Zona Mista), uma leitura de GPS que driftou para
"Zona Mista" dispara a alternância **imediatamente**, sem cooldown — gerando um check-out (ou check-in)
**espúrio** segundos depois de uma atividade legítima.

**Solução aprovada:** estender o cooldown para **qualquer** última atividade. Ao detectar "Zona Mista",
**suprimir a alternância automática se a última atividade registrada (check-in OU check-out, em QUALQUER
localização) ocorreu há menos que o intervalo**. Simétrico (cobre check-out espúrio após check-in e
check-in espúrio após check-out). As **exceções imediatas** já existentes (Situação 8, linhas 85–86 — saída
por "Zona de CheckOut"/afastamento, ou re-entrada por outra área cadastrada) **permanecem**, porque rodam
em **outros** `resolved_local`, fora da função da Zona Mista.

---

## 2. Evidência de produção (read-only, 2026-06-22)

Acesso: `docs/Instrucoes/instrucoes_acesso_Digital_Ocean.md` (SSH via WSL → `docker exec checkcheck-db-1
psql -U postgres -d checking`). Banco `checking`, container `checkcheck-db-1`.

**Usuário:** `users.id=45`, `chave=U4T4`, `nome="Tiago Bermudez Souto de Oliveira"`, `projeto=P80`. Cliente:
`device_id=web-check` → **Check Web (navegador)**, não o app Kotlin (que marcaria `checking-android`).
Projeto P80: `mixed_zone_interval_minutes = 30`.

**Timeline do incidente (`check_events`)** — oscilação por drift entre "Escritório Principal" e "Zona Mista":

| id | hora (UTC) | source | ação | local |
|---|---|---|---|---|
| 21110 | 23:44:02 | forms | check-out | **Zona Mista** (flap anterior) |
| 21111 | 23:44:08 | forms | check-in | Escritório Principal |
| 21113/21115 | 23:45:11/26 | web/forms | check-in | Escritório Principal |
| **21116/21117** | **23:45:36/50** | web/forms | **check-out** | **Zona Mista** ← acidental |
| 21118–21120 | 23:45:52+ | web/forms | check-in | Escritório Principal |

O check-out indevido (21116) ocorreu **~25 s** depois do check-in (21113), bem dentro dos 30 min. Estado
atual do usuário: `local=Zona Mista, checkin=f` (preso em check-out). O evento 21110 mostra que **não é
único** — é um flap recorrente sempre que o GPS oscila perto da fronteira dos dois geofences.

---

## 3. Causa-raiz no código (e por que é "por design" hoje)

A decisão é **100% client-side**; o servidor (`/api/web/check` → `submit_forms_event`) apenas registra a
ação que o cliente envia (com dedup de mesma-ação-mesmo-dia). Há **duas superfícies espelhadas**:

- **Check Web:** `sistema/app/static/check/automatic-activities.js` (motor) + `sistema/app/static/check/app.js`
  (apenas passa `{ mixedZoneIntervalMinutes, referenceTime }`, **não precisa mudar**).
- **App Kotlin:** `checking_kotlin/app/src/main/java/br/com/tscode/checking/domain/checkrules/AutoActivities.kt`
  (espelho quase idêntico). Repo git **independente** (`checking_kotlin`, origin=checking-kotlin).

A função-chave é `shouldAttemptAutomaticMixedZoneLocationEvent(locationPayload, remoteState, settings)`. Ela
tem dois ramos:
- **Branch A** — `resolved_local` (Zona Mista) == `current_local` registrado (também Zona Mista): aplica o
  cooldown (correto; é o caso de leituras consecutivas dentro da Zona Mista).
- **Branch B** — `current_local` registrado é **outra** localização (ex.: "Escritório Principal"): **dispara
  imediatamente** (`if (lastRecordedAction !== 'checkin') return true; return resolvedLocal !==
  lastCheckInLocation;` → sempre `true` no caso check-in, pois `lastCheckInLocation` nunca é "Zona Mista" no
  Branch B). **Aqui está o furo.**

Isso é o que a spec descreve hoje — `docs/regras_e_situacoes/regras_checkin_checkout_webapp.txt`, Situação 8:
- linha 78: "Se a leitura atual apontar 'Zona Mista' e a última atividade relevante **não tiver sido
  realizada na própria 'Zona Mista'**, então a alternância automática deve ser **imediata**";
- linha 81: o cooldown vale "**apenas às leituras consecutivas na própria 'Zona Mista'**".

Ou seja, **não é bug de implementação; é a regra escrita assim**. Mudar exige atualizar a spec e as duas
implementações + testes.

---

## 4. Decisão de design (a correção, em detalhe)

**Mudança cirúrgica:** manter o **Branch A inalterado**; adicionar, **no topo do Branch B**, um gate de
cooldown baseado na **última atividade registrada (qualquer local, qualquer ação)**. Se o cooldown estiver
ativo → `return false` (não dispara). Caso contrário → segue a lógica atual do Branch B.

Novo helper (mesma forma do `isMixedZoneCooldownActive`, mas sem exigir que o `current_local` seja Zona
Mista — usa a última atividade registrada de qualquer local):

- `resolveLastRecordedActivityTimestamp(state)`: pega `resolveLastRecordedAction(state)`; se não for
  checkin/checkout → `null`; senão devolve `resolveRecordedActionTimestamp(state, lastAction)`.
- `isMixedZoneCooldownActiveForLastActivity(state, intervalMinutes, referenceTime)`: `lastTimestamp =
  resolveLastRecordedActivityTimestamp(state)`; se null → false; `cooldownMs =
  resolveMixedZoneCooldownMilliseconds(intervalMinutes)`; se ≤0 → false; `ref =
  resolveReferenceTimestamp(referenceTime)` (JS) / `referenceTime ?: Instant.now()` (Kotlin); se null →
  false; retorna `(ref - lastTimestamp) < cooldownMs`.

**Por que é seguro/cirúrgico (não prende quem realmente sai/entra):** o gate só afeta leituras que resolvem
para **"Zona Mista"**. As saídas/entradas **genuínas** resolvem para **outro** `resolved_local`
("Zona de CheckOut", `outside_workplace`/"Fora do Local de Trabalho", ou outra área cadastrada) e são
tratadas em **ramos separados e inalterados** (`isCheckoutZoneLocationName`, `shouldAttemptAutomaticOutOf
RangeCheckout`, e o ramo de área cadastrada). Isso são exatamente as **exceções imediatas** já documentadas
na Situação 8 (linhas 85 e 86), que **permanecem**.

**Comportamento resultante (Situação 8 revisada):**
- Leitura "Zona Mista" com última atividade (qualquer local) **dentro** do intervalo → **não alterna**
  (suprime). ✅ resolve o incidente do U4T4 e o espelho (check-in espúrio após check-out).
- Leitura "Zona Mista" com última atividade **fora** do intervalo (ou sem atividade registrada) → alterna
  normalmente (8A check-out / 8B check-in). ✅
- Repetições consecutivas dentro da própria Zona Mista (Branch A) → inalterado.
- Saída genuína ("Zona de CheckOut"/afastamento) ou re-entrada por outra área cadastrada → imediato,
  **sem** cooldown (exceções das linhas 85–86, inalteradas). ✅

**Trade-off residual (aceito):** se a ÚNICA rota de saída de um usuário passar exclusivamente pela "Zona
Mista" (sem "Zona de CheckOut" e sem afastamento suficiente) e ele sair dentro do intervalo, o check-out
automático fica adiado até o intervalo expirar (ele ainda pode fazer manual). O admin ajusta o intervalo.

**Atenção (Kotlin):** `resolveAutomaticActivityForMatch(match, state, mixedZoneIntervalMinutes)` constrói
`MixedZoneDecisionSettings(mixedZoneIntervalMinutes)` **sem** `referenceTime` → usa `Instant.now()`. Logo,
testes que passam por essa função são **dependentes do relógio**: timestamps do estado devem ser
**relativos a agora** (ex.: `now.minusSeconds(...)`). Para asserções determinísticas, teste a função pura
`shouldAttemptAutomaticMixedZoneLocationEvent(..., MixedZoneDecisionSettings(interval, referenceTime=now))`.

---

## 5. PROMPT 1 (NECESSÁRIO) — Check Web: motor + testes + spec (faça PRIMEIRO; é a referência)

```
CONTEXTO DO PROJETO
- Repositório "checkcheck" (monólito). O Check Web fica em sistema/app/static/check/ e é servido pelo
  MONÓLITO (deploy via repo root `checking` → workflow "Deploy OceanDrive"; NÃO é o sub-repo admin2).
- Idioma: comentários/docs em português; identificadores em inglês.

PROBLEMA (confie no diagnóstico, mas confirme lendo o código)
- A "Zona Mista" alterna check-in/check-out automaticamente (Situação 8). Há um cooldown ('Intervalo de
  Tempo Zona Mista', campo do projeto; default 30 min). HOJE o cooldown só vale para leituras consecutivas
  DENTRO da própria Zona Mista. Quando a última atividade foi em OUTRA localização adjacente (ex.:
  "Escritório Principal"), um drift de GPS para "Zona Mista" dispara a alternância IMEDIATAMENTE, gerando
  check-out/in espúrio. Caso real (U4T4): check-in em "Escritório Principal" e, ~25 s depois, check-out
  espúrio em "Zona Mista".

ARQUIVO PRINCIPAL
- sistema/app/static/check/automatic-activities.js. A função shouldAttemptAutomaticMixedZoneLocationEvent
  tem dois ramos. Bloco atual (confira na fonte):
      // Branch A: resolved_local (Zona Mista) == current_local registrado (também Zona Mista)
      if (normalizeLocationName(resolvedLocal)
          && normalizeLocationName(resolvedLocal) === normalizeLocationName(currentRecordedLocation)) {
        if (!isLastRelevantActivityInMixedZone(remoteState) || cooldownMilliseconds <= 0) return false;
        return !isMixedZoneCooldownActive(remoteState, decisionSettings.mixedZoneIntervalMinutes, decisionSettings.referenceTime);
      }
      // Branch B: estado registrado em OUTRA localização → DISPARA imediatamente (o furo)
      if (lastRecordedAction !== 'checkin') return true;
      return normalizeLocationName(resolvedLocal) !== normalizeLocationName(lastCheckInLocation);
- app.js já chama a função passando { mixedZoneIntervalMinutes, referenceTime: settings.referenceTime }.
  NÃO precisa mexer em app.js.

MUDANÇA ALVO (mínima, cirúrgica)
1. Adicione dois helpers puros no módulo (mesmo estilo dos existentes):
   - resolveLastRecordedActivityTimestamp(state): lastAction = resolveLastRecordedAction(state); se não for
     'checkin' nem 'checkout' → null; senão return resolveRecordedActionTimestamp(state, lastAction).
   - isMixedZoneCooldownActiveForLastActivity(state, mixedZoneIntervalMinutes, referenceTime):
       const lastTimestamp = resolveLastRecordedActivityTimestamp(state); if (!lastTimestamp) return false;
       const cooldownMilliseconds = resolveMixedZoneCooldownMilliseconds(mixedZoneIntervalMinutes);
       if (!cooldownMilliseconds) return false;
       const ref = resolveReferenceTimestamp(referenceTime); if (!ref) return false;
       return ref.getTime() - lastTimestamp.getTime() < cooldownMilliseconds;
2. No Branch B (e SOMENTE nele — NÃO mexa no Branch A), adicione no TOPO, antes do `if (lastRecordedAction
   !== 'checkin')`:
       if (isMixedZoneCooldownActiveForLastActivity(
             remoteState,
             decisionSettings.mixedZoneIntervalMinutes,
             decisionSettings.referenceTime)) {
         return false;
       }
   Mantenha o restante do Branch B como está.
3. Exporte os dois novos helpers no objeto de retorno do módulo (junto de isMixedZoneCooldownActive etc.),
   para que os testes possam exercê-los diretamente.
4. Comente o trecho explicando o porquê (drift de GPS entre Zona Mista e localização adjacente; saídas/
   entradas genuínas resolvem para OUTRO resolved_local e seguem pelas exceções imediatas, intocadas).

RESTRIÇÕES
- NÃO altere o Branch A nem outras funções (isCheckoutZoneLocationName, shouldAttemptAutomaticOutOfRange
  Checkout, o ramo de área cadastrada). As exceções imediatas (Situação 8, linhas 85–86) DEVEM continuar
  funcionando — e funcionam, pois rodam em OUTRO resolved_local.
- NÃO mexa no servidor, nem em app.js (além de nada). Sem mudança de dados/contrato.

TESTES (arquivo: tests/web_automatic_activities.test.js — usa node:test/assert)
- Descubra como o projeto roda esses testes (provavelmente `node --test tests/web_automatic_activities.test.js`;
  confira package.json). Rode antes para ver o estado atual.
- ADICIONE (interval 20):
  a) Drift check-out (replica U4T4): state {current_action:'checkin', current_local:'Escritório Principal',
     last_checkin_at:'2026-04-16T09:00:00', last_checkout_at:'2026-04-16T08:00:00'}, resolved_local
     'Zona Mista':
       - referenceTime '2026-04-16T09:10:00' (10<20) → shouldAttemptAutomaticLocationEvent == false (suprime).
       - referenceTime '2026-04-16T09:30:00' (30>=20) → == true (alterna).
  b) Drift check-in (simétrico): state {current_action:'checkout', current_local:'Zona de CheckOut',
     last_checkin_at:'...08:00', last_checkout_at:'...09:00'}, resolved_local 'Zona Mista':
       - 09:10 → false;  09:30 → true.
  c) Exceção imediata preservada: resolved_local 'Zona de CheckOut' com último check-in recente →
     shouldAttemptAutomaticLocationEvent == true (check-out imediato; ramo não-Zona-Mista). E
     resolved_local 'Escritório Principal' após check-out recente → true (check-in imediato).
  d) Unit do helper: isMixedZoneCooldownActiveForLastActivity true dentro / false fora do intervalo, e
     false quando interval<1 ou sem timestamp.
- ATUALIZE (vai quebrar com o fix — encoda o comportamento ANTIGO): o teste
  `mixed zone initial entry triggers automatic alternation from prior non-mixed states`. Hoje ele afirma
  `true` para atividade prévia 10 min atrás com interval 20 (dentro do cooldown). Reescreva para refletir a
  nova regra: DENTRO do intervalo → false; FORA do intervalo (ex.: referenceTime 09:30) → true. Mantenha a
  cobertura das mesmas variantes de estado.
- PRESERVE os demais testes de Zona Mista (Branch A: cooldown consecutivo; exit exceptions) verdes.

SPEC (atualize no MESMO commit)
- docs/regras_e_situacoes/regras_checkin_checkout_webapp.txt, Situação 8: reescreva as linhas 77–87 para a
  nova regra: o cooldown ('Intervalo de Tempo Zona Mista') passa a valer SEMPRE que a leitura aponta
  'Zona Mista', com base na ÚLTIMA atividade registrada (check-in OU check-out, em QUALQUER localização);
  a alternância 8A/8B só ocorre quando `tempo_decorrido >= intervalo`. MANTENHA explicitamente as exceções
  imediatas (linhas 85–86) — saída por 'Zona de CheckOut'/afastamento e re-entrada por outra área
  cadastrada continuam imediatas, sem cooldown. Deixe claro que isso vale para Check Web e é espelhado no
  app Kotlin (ver docs/regras_e_situacoes/regras_checkin_checkout_kotlin.txt).

ENTREGÁVEL: diff mínimo em automatic-activities.js + testes (novos + o atualizado) verdes + spec atualizada.
Explique no resumo por que as exceções imediatas continuam funcionando sem alteração.
```

---

## 6. PROMPT 2 (NECESSÁRIO) — App Kotlin: espelhar a mesma regra + testes + spec

> Repo **independente** `checking_kotlin` (origin=checking-kotlin). Releases via **AAB/Play Store**
> (versionCode é one-way; último = 1.6.2/21 → próximo ≥ 22) — **humano-gated**, ver PROMPT 3.

```
CONTEXTO
- O app Kotlin (checking_kotlin/) espelha o motor de decisão do Check Web. A correção da Zona Mista feita
  no PROMPT 1 (sistema/app/static/check/automatic-activities.js) precisa ser replicada IDÊNTICA na lógica.
- Atenção (memória do projeto): se a resolução de plugins do Gradle falhar por MITM SSL do Avast, use
  `-Djavax.net.ssl.trustStoreType=Windows-ROOT` em org.gradle.jvmargs.

ARQUIVO PRINCIPAL
- checking_kotlin/app/src/main/java/br/com/tscode/checking/domain/checkrules/AutoActivities.kt.
  A função shouldAttemptAutomaticMixedZoneLocationEvent tem a MESMA estrutura Branch A/Branch B do web.
  Bloco atual (confira na fonte):
      if (normalizeLocationName(resolvedLocal).isNotEmpty() &&
          normalizeLocationName(resolvedLocal) == normalizeLocationName(currentRecordedLocation)) {
          if (!isLastRelevantActivityInMixedZone(remoteState) || cooldownMs <= 0) return false
          return !isMixedZoneCooldownActive(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime)
      }
      if (lastRecordedAction != CheckAction.CHECKIN) return true
      return normalizeLocationName(resolvedLocal) != normalizeLocationName(lastCheckInLocation)

MUDANÇA ALVO (espelho exato do PROMPT 1)
1. Adicione dois helpers puros:
   - fun resolveLastRecordedActivityTimestamp(state: HistoryState?): Instant? {
         val lastAction = resolveLastRecordedAction(state)
         if (lastAction != CheckAction.CHECKIN && lastAction != CheckAction.CHECKOUT) return null
         return resolveRecordedActionTimestamp(state, lastAction)
     }
   - fun isMixedZoneCooldownActiveForLastActivity(state: HistoryState?, mixedZoneIntervalMinutes: Int,
         referenceTime: Instant? = null): Boolean {
         val lastTimestamp = resolveLastRecordedActivityTimestamp(state) ?: return false
         val cooldownMs = resolveMixedZoneCooldownMilliseconds(mixedZoneIntervalMinutes)
         if (cooldownMs <= 0) return false
         val reference = referenceTime ?: Instant.now()
         return (reference.toEpochMilli() - lastTimestamp.toEpochMilli()) < cooldownMs
     }
2. No Branch B (SOMENTE nele; NÃO mexa no Branch A), adicione no TOPO:
       if (isMixedZoneCooldownActiveForLastActivity(remoteState, settings.mixedZoneIntervalMinutes, settings.referenceTime)) {
           return false
       }
   Mantenha o restante do Branch B.
3. Comente igual ao web (drift de GPS; exceções imediatas seguem por outro resolvedLocal, intocadas).

ATENÇÃO À TESTABILIDADE (importante)
- resolveAutomaticActivityForMatch(match, state, mixedZoneIntervalMinutes) cria
  MixedZoneDecisionSettings(mixedZoneIntervalMinutes) SEM referenceTime → usa Instant.now(). Logo, testes
  que passam por essa função são dependentes do relógio: use timestamps RELATIVOS a agora
  (ex.: now.minusSeconds(5*60) = dentro de 15 min; now.minusSeconds(20*60) = fora). Para asserções
  determinísticas do cooldown, prefira testar a função pura shouldAttemptAutomaticMixedZoneLocationEvent
  passando MixedZoneDecisionSettings(interval, referenceTime = now).

TESTES (em checking_kotlin/app/src/test/java/br/com/tscode/checking/checkrules/)
- Rode primeiro a suíte atual: `./gradlew :app:testDebugUnitTest` (veja AutoActivitiesSituationTest,
  SituationMatrixTest, AutoActivitiesTest, CheckoutPreservationTest, LocationChangeContinuationTest).
- ADICIONE (via função pura, referenceTime = now, interval 15):
  a) Drift check-out: history(CHECKIN, currentLocal="Unidade P80", lastCheckinAt=now.minusSeconds(5*60)),
     match(MATCHED,"Zona Mista") → shouldAttemptAutomaticMixedZoneLocationEvent == false. Com
     lastCheckinAt=now.minusSeconds(20*60) → == true.
  b) Drift check-in (simétrico): history(CHECKOUT, currentLocal="Unidade P80",
     lastCheckoutAt=now.minusSeconds(5*60)) → false; minusSeconds(20*60) → true.
  c) Exceção imediata preservada: resolveAutomaticActivityForMatch com match 'Zona de CheckOut' após
     check-in recente → CheckAction.CHECKOUT imediato; e 'Escritório Principal' após check-out → CHECKIN.
- ATUALIZE (vão quebrar — encodam o comportamento ANTIGO de alternância imediata fora da Zona Mista):
  os testes da seção "Situation 8: Zona Mista alternation (last activity NOT in the mixed zone)" em
  AutoActivitiesSituationTest.kt (≈ linhas 202–217). Verifique o helper history(): se ele cria
  lastCheckin/CheckoutAt recentes (próximos de now), com o fix eles passariam a retornar null (suprimido).
  Ajuste-os para refletir a nova regra: dentro do intervalo → sem ação; fora do intervalo → alterna.
  Confira também SituationMatrixTest (8a/8b/8c/8d) e CheckoutPreservationTest — onde o currentLocal já é
  "Zona Mista" (Branch A) ou a saída é por OUTRO local (exceção), devem permanecer verdes; só ajuste os
  que dependem da alternância imediata a partir de local não-Zona-Mista dentro do intervalo.
- PRESERVE Branch A (cooldown consecutivo) e as exceções verdes.

SPEC
- Atualize docs/regras_e_situacoes/regras_checkin_checkout_kotlin.txt na seção equivalente à Situação 8,
  espelhando exatamente a nova regra descrita no PROMPT 1.

ENTREGÁVEL: diff mínimo em AutoActivities.kt + testes (novos + atualizados) com `:app:testDebugUnitTest`
verde + spec kotlin atualizada. O comportamento deve ser BYTE-A-BYTE equivalente ao do PROMPT 1 (web).
```

---

## 7. PROMPT 3 (NECESSÁRIO) — Verificação e rollout (deploy humano-gated)

> **PARCIALMENTE EXECUTADO 2026-06-22 (decisão do dono).**
> - Passo 1 (local): web `node --test` **26/26**; Kotlin `:app:testDebugUnitTest` **BUILD SUCCESSFUL**
>   (`AutoActivitiesSituationTest` 24/0/0). Passo 2 (prod read-only): U4T4 eventos 21113–21117 e estado
>   **inalterados** (fix é client-side).
> - Passo 3 (Web): **NÃO deployado** — o dono escolheu deixar como working changes (automatic-activities.js
>   + teste JS + specs webapp/kotlin seguem uncommitted no repo principal).
> - Passo 4 (Kotlin): **commit + push SEM release** — `checking_kotlin` commit `205194c`
>   (`5d1a281 → 205194c`, branch main). Sem bump de versionCode, sem AAB, sem Play (release futuro/agrupado).
> - Passo 5: pendente (depende do deploy web / release Kotlin).

```
TAREFA: validar as duas correções e (com aprovação humana) publicar. NÃO publique sem aprovação explícita.

PASSO 1 — Verificação local
- Web: rode os testes JS (node --test tests/web_automatic_activities.test.js ou o runner do projeto) — 0
  falhas, incluindo os novos (drift check-out/in) e o teste atualizado.
- Kotlin: `cd checking_kotlin && ./gradlew :app:testDebugUnitTest` — 0 falhas (use o workaround Avast se
  preciso). Confirme que os testes da Situação 8 atualizados passam e que Branch A/exceções seguem verdes.
- (Opcional) Backend: a suíte python do monólito não é afetada (mudança é client-side), mas se rodar,
  ignore as falhas pré-existentes/ambientais já conhecidas (transport-AI/migração 0061/boot em subprocesso
  no Windows; test_api_flow não coleta no Windows).

PASSO 2 — Re-verificação de produção (read-only) do U4T4 ANTES de publicar
- docs/Instrucoes/instrucoes_acesso_Digital_Ocean.md (READ-ONLY, só SELECT):
    SELECT id, event_time, action, local FROM check_events WHERE id IN (21113,21115,21116,21117) ORDER BY id;
    SELECT chave, local, checkin, "time" FROM users WHERE chave='U4T4';
  (Apenas para contexto; o fix é client-side e não muda dados existentes.)

PASSO 3 — Deploy WEB (SOMENTE com aprovação humana)
- Caminho canônico: repo root `checking`, commit + push em `main` → workflow "Deploy OceanDrive".
  Monitore (instruções, Seção 6.3): gh run list/watch "Deploy OceanDrive"; conclusion=success e
  --log-failed vazio (a anotação "exit code 1" é ruído pós-passo, Seção 6.2). Confirme a imagem em prod =
  commit (docker inspect checkcheck-app-1 --format '{{.Config.Image}}') e o health ok.
- Verifique o asset servido mudou (Seção 6.1): compare content-length/etag de
  https://tscode.com.br/checking/user/automatic-activities.js ou procure um marcador do novo código.

PASSO 4 — Release KOTLIN (SOMENTE com aprovação humana; repo separado)
- checking_kotlin é repo git independente: commit + push no SEU origin.
- BUMP de versão obrigatório (versionCode é one-way; último = 1.6.2 / versionCode 21 → próximo ≥ 22):
  ver memória/processo de publicação (bundleRelease + keystore.properties; gradle.properties é placeholder,
  versão real via -P no release). Gere o AAB assinado e publique no Play Console (manual).
- Smoke-test do AAB com bundletool se possível; geofence não dispara em emulador (testar em device).

PASSO 5 — Confirmação pós-rollout
- Web: com o app aberto e Atividades Automáticas ligadas, um check-in em "Escritório Principal" seguido de
  drift para "Zona Mista" dentro de 30 min NÃO deve mais gerar check-out automático. (Confirmação funcional
  pelo operador; opcionalmente observar ausência de novos pares Escritório→ZonaMista no log de eventos.)

ENTREGÁVEL: relatório com contagem de testes (web + kotlin), saída dos SELECTs, status do Deploy OceanDrive
e do release Kotlin (se autorizados).
```

---

## 8. Checklist de não-regressão / armadilhas

- [ ] **Só o Branch B** muda em ambas as superfícies; **Branch A intocado**.
- [ ] As **exceções imediatas** (Situação 8, linhas 85–86) seguem funcionando — elas rodam em OUTRO
      `resolved_local` ("Zona de CheckOut" / `outside_workplace` / outra área), fora da função da Zona Mista.
- [ ] **Simetria:** suprime tanto o check-out espúrio (após check-in) quanto o check-in espúrio (após
      check-out) dentro do intervalo.
- [ ] **Web e Kotlin idênticos** (mesma regra, mesmos nomes de helper). Não "sincronize" outras divergências
      intencionais (ex.: Kotlin "Change A/P6.1" no ramo de área cadastrada não-Zona-Mista — NÃO mexer).
- [ ] **Testes que MUDAM de expectativa:** web `mixed zone initial entry triggers automatic alternation from
      prior non-mixed states`; Kotlin "Situation 8 alternation (last activity NOT in the mixed zone)"
      (AutoActivitiesSituationTest ≈ linhas 202–217). Estes codificam o comportamento ANTIGO e DEVEM ser
      reescritos para a nova regra (dentro do intervalo → sem ação; fora → alterna).
- [ ] **Kotlin/relógio:** `resolveAutomaticActivityForMatch` usa `Instant.now()` (sem referenceTime). Testes
      por essa via usam timestamps relativos a agora; para determinismo, teste a função pura com
      `referenceTime = now`.
- [ ] **Spec atualizada** nos dois docs (webapp + kotlin), Situação 8.
- [ ] Deploy web pelo repo root `checking` → **Deploy OceanDrive** (monólito); Kotlin pelo repo separado +
      **AAB/Play** (versionCode ≥ 22). Ambos **humano-gated**.
- [ ] Sem mudança no servidor, sem migração, sem alteração de dados.
