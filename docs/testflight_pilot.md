# Piloto TestFlight — Checking iOS

## Estado vinculante — preparação solicitada; distribuição bloqueada (2026-08-05)

O owner solicitou a preparação de uma candidata para TestFlight. Isso não é autorização final de
distribuição: não houve archive, assinatura de distribuição ou upload da candidata TestFlight. `Debug`,
`Staging` e `Release` persistem em `legacyWithDiagnostics`; o candidato foi exercitado por injeção/override
temporário e a configuração isolada, não-shipping, `PhysicalValidation` serve somente ao pré-voo agregado.
Ela não promove o perfil de Release. Esta página continua sendo um runbook condicional enquanto os gates
técnicos, físicos, de backend e de App Store Connect não estiverem resolvidos.

O rollout, se aprovado em decisões futuras, deve avançar estritamente nesta ordem:

| Etapa | Gate antes de avançar | Estado atual |
|---|---|---|
| Diagnósticos locais | unitários, UI, Simulator, privacidade e diff auditados | evidência local concluída; não é gate físico |
| Candidato interno | gates de backend/físicos resolvidos, artefato exato e aprovação final de produto/release | preparação solicitada; bloqueado pelos gates |
| Coorte pequena | owner aprova resultados internos e critérios de segurança/privacidade | pendente |
| 25% | sem P0/P1, métricas/feedback revisados pelo owner | pendente |
| 100% | aceite formal de produto/release e todos os gates externos resolvidos | pendente |

O owner nominal de produto/release, o owner de backend e os respectivos prazos de aprovação não estão
identificados no workspace; devem ser registrados antes de qualquer upload. Hotfix/rollback exige interromper
a expansão, avaliar o incidente e entregar build/revert substituto. O profile não oferece kill switch remoto.
Nenhum upload deve ser tentado para "testar" os gates.

## Registro histórico — não é a candidata atual

- versão: `1.6.5`;
- build: `25`;
- bundle ID: `br.com.tscode.checking`;
- configuração: `Release`, arm64, iPhone, iOS mínimo 17;
- backend: `https://tscode.com.br/api/web/`;
- APNs: produção;
- archive: `.build/archives/Checking-1.6.5-25.xcarchive`;
- regressão: 564 testes unitários e 27 testes de UI aprovados;
- App Icon 1024×1024 RGB sem transparência incluído;
- Privacy Manifest e descrições localizadas de permissões incluídos;
- `ITSAppUsesNonExemptEncryption = false`;
- Validação Física, harness e demais instrumentos `DEBUG` ausentes do binário.

O archive abaixo é registro histórico e não deve ser enviado sem uma nova autorização explícita. Na eventual
distribuição aprovada, o Xcode deve usar assinatura de distribuição apropriada; esta nota não delega essa
decisão nem autoriza upload.

## Escopo e limitações históricas do piloto

Incluído:

- cadastro, criação/alteração de senha e autenticação;
- cadastro em múltiplos projetos;
- registro manual e histórico;
- atividades automáticas por geofence e mudança significativa;
- localizações não cadastradas e deduplicação de atividade;
- Pausa Programada e preferências de notificação;
- funcionamento suspenso, tela bloqueada e relançamento pelo iOS;
- Instruções, Suporte, Sobre, Privacidade e Acidentes na extensão já implementada.

Não incluído ou ainda não homologado:

- Transportes;
- push remoto de Acidentes pelo backend/APNs;
- bateria em amostra controlada de 24 horas;
- reboot formalmente observado;
- cenários de degradação de permissão e precisão;
- revisão humana/jurídica final das traduções e textos de privacidade;
- uso operacional real de Reportar Acidente.

Os testadores não devem reportar acidentes reais nem acionar chamadas de emergência durante o piloto. O
botão só deve ser exercitado em roteiro previamente combinado e ambiente seguro.

## 1. Pré-requisitos da conta Apple — após gate de distribuição

1. Confirmar que o contrato mais recente do Apple Developer Program está aceito.
2. Confirmar acesso ao App Store Connect como Account Holder, Admin ou App Manager; Developer também pode
   fazer upload, mas não gerencia todos os grupos externos.
3. Em **Certificates, Identifiers & Profiles**, confirmar o App ID explícito
   `br.com.tscode.checking`, com Push Notifications habilitado.
4. Em **App Store Connect › Apps**, criar o app caso ainda não exista:
   - plataforma: iOS;
   - nome: Checking;
   - idioma principal: Português (Brasil);
   - bundle ID: `br.com.tscode.checking`;
   - SKU sugerido: `checking-ios`;
   - acesso do usuário: acesso total ou grupo explicitamente escolhido.
5. Em **Xcode › Settings › Accounts**, confirmar a mesma equipe e, em **Manage Certificates**, permitir
   assinatura Apple Distribution/cloud-managed.

## 2. Upload pelo Xcode Organizer — somente após autorização explícita

1. Abrir `.build/archives/Checking-1.6.5-25.xcarchive`.
2. Selecionar o archive **Checking 1.6.5 (25)**.
3. Clicar **Distribute App**.
4. Escolher **App Store Connect** e **Upload** somente se o gate autorizar; não selecionar “TestFlight
   Internal Only” apenas quando a progressão aprovada incluir grupo externo depois da revisão beta.
5. Manter assinatura automática e upload de símbolos habilitados.
6. Confirmar que o resumo mostra equipe `F8Z6CMJHAR`, bundle `br.com.tscode.checking`, versão `1.6.5` e build
   `25`.
7. Executar **Validate App** quando oferecido; resolver todos os erros antes do upload.
8. Clicar **Upload** uma única vez e guardar o relatório da distribuição.

Depois do upload, aguardar o processamento no App Store Connect. Não repetir o upload do mesmo build enquanto
o estado for `Processing`. Um novo binário exige incrementar o build para `26`, `27` etc.

## 3. Configuração do build no App Store Connect — após upload autorizado

1. Abrir **Apps › Checking › TestFlight › iOS** e selecionar `1.6.5 (25)`.
2. Resolver a declaração de conformidade de exportação. O app não implementa criptografia proprietária;
   utiliza HTTPS/TLS e Keychain do sistema, e o bundle declara `ITSAppUsesNonExemptEncryption = false`.
3. Revisar avisos de processamento; qualquer `Invalid Binary` bloqueia a distribuição.
4. Preencher **Test Information**:
   - Beta App Description;
   - Feedback Email;
   - Marketing URL, se desejada;
   - Privacy Policy URL: `https://www.tscode.com.br/checking/privacidade`;
   - nome, telefone e e-mail do contato responsável.
5. Preencher no App Store Connect os rótulos de privacidade coerentes com o Privacy Manifest: localização
   precisa, identificador do usuário, nome/e-mail, conteúdo livre, fotos/vídeos e áudio; vinculados ao usuário,
   usados para funcionalidade e sem tracking. Fazer revisão jurídica antes de publicação pública.

## 4. Primeiro grupo interno — após aprovação do candidato interno

Antes do grupo externo, criar **Internal Testing › Equipe Interna**. Testadores internos precisam ser usuários
do App Store Connect e podem ter acesso ao conteúdo da conta; por isso, não transformar usuários comuns em
internos apenas para evitar a revisão beta.

Adicionar inicialmente apenas responsáveis reais pelo projeto. Associar o build `1.6.5 (25)` e fazer um smoke:

- instalação limpa pelo TestFlight;
- login e projeto;
- permissões Localização Sempre, Precisão Exata e Notificações;
- check manual controlado;
- reabertura, background e tela bloqueada;
- ausência da opção Validação Física;
- ícone, nome e versão corretos.

## 5. Grupo externo selecionado — após aprovação da coorte pequena

1. Criar **External Testing › Piloto Inicial**.
2. Adicionar o build `1.6.5 (25)`.
3. Preencher **What to Test** e desabilitar notificação automática até a aprovação beta, se desejar controlar o
   momento dos convites.
4. Informar uma conta dedicada de revisão, com projeto ativo, no campo confidencial de Sign-In Information.
   Não colocar a senha em descrição pública, e-mail coletivo ou documento versionado.
5. Explicar nas Review Notes que o registro automático depende de entrada/saída de geofences corporativas e
   da permissão Localização Sempre; fora dessas áreas, “Localização não Cadastrada” é resultado esperado e não
   grava presença.
6. Submeter para **TestFlight App Review**. A primeira build externa normalmente recebe revisão completa.
7. Após aprovação, adicionar os testadores pelos e-mails informados. Preferir convites individuais; não criar
   link público neste piloto fechado.
8. Ativar **Automatically Notify Testers** ou enviar os convites manualmente.

### Beta App Description sugerida

> Checking registra check-in e check-out de usuários nos locais de trabalho associados aos seus projetos. O
> piloto avalia autenticação, projetos, registros manuais, atividades automáticas baseadas em geofence,
> notificações, histórico, funcionamento em segundo plano e consumo de bateria.

### What to Test sugerido

> Teste login, seleção de projetos, histórico, registro manual controlado, Atividades Automáticas, Pausa
> Programada e notificações. Com Localização Sempre e Precisão Exata, observe check-in/check-out ao entrar ou
> sair dos locais cadastrados, inclusive com tela bloqueada. Registre horário, bateria, local esperado, atraso da
> notificação e qualquer atividade incorreta. Transportes não faz parte desta versão. Não reporte acidentes reais
> nem acione emergência; esse fluxo somente será testado em roteiro seguro e supervisionado.

### Review Notes sugerida

> The app is an enterprise attendance client. Automatic check-in/out requires Always Location permission and
> entry into workplace geofences assigned to the signed-in test account. Outside those areas, “Unregistered
> Location” is expected and no attendance event is submitted. Manual registration, settings, history, privacy
> and instructions remain available for review. Transportation is not included in this beta. Please do not submit
> a real accident or trigger an emergency call. Dedicated reviewer credentials are provided in Sign-In
> Information.

## 6. Orientações aos testadores

- instalar o app TestFlight e aceitar o convite com uma Apple Account;
- conceder Notificações, Localização Sempre e Precisão Exata;
- manter Atualização em 2º Plano habilitada e Modo Pouca Energia desligado nos ensaios controlados;
- não forçar o encerramento do Checking no seletor;
- registrar modelo do iPhone, versão do iOS, horários, bateria, local esperado, notificação e condição da tela;
- enviar feedback pelo TestFlight, inclusive com screenshot quando não houver dado sensível;
- nunca fotografar ou compartilhar senha, coordenadas, cookies, tokens ou dados pessoais de terceiros;
- informar imediatamente qualquer check-in/check-out incorreto ou exposição indevida de localização.

A instalação TestFlight usa `br.com.tscode.checking`, enquanto a build de diagnóstico instalada diretamente usa
`br.com.tscode.checking.debug`; ambas podem coexistir, mas seus dados, Keychain, permissões e sessão são
independentes. Cada testador deverá autenticar e conceder permissões novamente.

## 7. Acompanhamento e encerramento

- depois do candidato interno autorizado, começar com coorte pequena de 3–5 pessoas; ampliar para 25% e 100%
  somente com aceite explícito do owner de produto/release e ausência dos critérios de bloqueio definidos;
- revisar diariamente crashes, sessões e feedback no App Store Connect;
- manter uma planilha sem coordenadas com dispositivo, iOS, cenário, resultado e bateria;
- diante de atividade incorreta, exposição de dados ou falha crítica, interromper a expansão, acionar o
  owner/hotfix e decidir por remover a disponibilidade da build e substituir por build/revert; não existe
  rollback remoto pelo profile;
- corrigir, incrementar `CURRENT_PROJECT_VERSION` e repetir os gates de regressão/artefato antes de qualquer
  novo upload autorizado;
- builds TestFlight expiram após 90 dias;
- o piloto não autoriza publicação na App Store; lançamento público exige os gates restantes da Fase 10/11.
