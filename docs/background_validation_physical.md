# Fase 2 — validação de background em iPhone físico

Data de início: **21/07/2026**  
Status: **relançamento frio e fallback de mudança significativa implementados; build físico instalado; aguardando percurso de confirmação**

## Estado vinculante para o candidato de confiabilidade — 2026-08-04

Nenhum ensaio físico novo foi executado nesta atualização documental. A evidência abaixo é histórica e
permanece preservada, mas não aprova o perfil de confiabilidade `candidate` atual: todos os configs instaláveis
(`Debug`, `Staging` e `Release`) continuam `legacyWithDiagnostics`, e não há aprovação para produzir/instalar
um artefato físico Release-equivalente do candidato. Resultados de unitários/Simulator não substituem esse
gate.

### Linha do tempo anterior preservada — 14:11–15:34

Esta transcrição registra apenas evidência anterior já analisada no plano; não representa novo ensaio nem
altera a interpretação dos dados físicos existentes. Ida e volta permanecem separadas.

**Ida / saída e chegada à unidade de teste**

| Horário local | Evidência anterior | Interpretação limitada |
|---|---|---|
| 14:11:25 | `Background evaluation (TIMER)` seguido de `Auto-check skipped (no movement)` | ciclo anterior terminou normalmente |
| 14:31:14–20 | EXITs de geofence, mudança significativa, fix ~25 m e tentativa em `Localização não Cadastrada` rejeitada | iOS acordou o app e GPS/matcher funcionaram; a rejeição 422 é dependência de backend separada |
| 14:50:18 | `Background evaluation (TIMER)` sem terminal posterior observável | avaliação órfã ou observabilidade insuficiente; não contar como sucesso |
| 15:10:33–38 | mudança significativa + ENTER; em seguida `Signed in`, registro de nove geofences, fix ~12 m e check-in na unidade de teste | avaliação/captura/matriz funcionaram quando executadas; a reconstrução de auth/UI era indício, não prova suficiente por si |

**Volta / retorno ao escritório de referência**

| Horário local | Evidência anterior | Interpretação limitada |
|---|---|---|
| 15:19:18–19 | mudança significativa, fix ~22 m, local desconhecido e tentativa rejeitada | GPS continuou operacional; 422 não pode ser mascarado nem classificado como auth/GPS |
| 15:21:55–56 | ENTER, fix ~19 m e check-in no escritório de referência | retorno concluído pelo fluxo então em observação |
| 15:34:14 | primeira avaliação explicitamente `FOREGROUND` após o percurso | os eventos anteriores não dependeram de abrir a tela |

### Gates físicos ainda pendentes

O candidato físico continua **pendente** de autorização explícita e de roteiro controlado. Permanecem sem
aprovação/critério final: SLO de chegada, dwell mínimo, passagem sem dwell/drive-through, orçamento de
energia/thermal, amostra de aparelhos e percursos, calibração final de frescor, reboot observado, degradação de
permissão/precisão, push backend e homologação backend da tentativa obrigatória de `Localização não Cadastrada`.
Não inferir aprovação desses itens a partir dos registros históricos abaixo.

## Ambiente

- aparelho: iPhone 14 Pro (`iPhone15,2`);
- sistema: iOS 26.5.2;
- bundle: `br.com.tscode.checking.debug`;
- assinatura: Apple Development + provisioning profile automático;
- APNs: sandbox (`aps-environment=development`);
- build: Debug instrumentado, sem credenciais ou token no binário;
- conta: conta de teste autenticada pela interface; identificador e senha omitidos da evidência.

## Preparação executada

1. login real pelo `CheckViewModel`/backend;
2. senha e cookie de sessão persistidos separadamente no Keychain com
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
3. notificações autorizadas;
4. localização autorizada como **Sempre**, com precisão exata;
5. Atualização em 2º Plano disponível;
6. consentimento explícito do ensaio registrado;
7. geofences reais da conta buscadas e entregues ao Core Location;
8. sessão contínua e mudanças significativas iniciadas pelo harness exclusivo de Debug;
9. app enviado ao background e tela bloqueada pelo usuário.

Durante o smoke, o aparelho foi desbloqueado brevemente para ler uma mensagem em outro app. O relatório
continuou contendo apenas `scene_phase_inactive` → `scene_phase_background`, com **zero** callbacks ativos;
portanto o Checking não voltou ao foreground e o ensaio não precisou ser reiniciado.

## Evidência inicial

| Verificação | Resultado | Evidência sanitizada |
|---|---|---|
| Build/assinatura física | Aprovado | Build para `iphoneos` e instalação via CoreDevice concluídos. |
| Autenticação pela interface | Aprovado | Activity log persistido contém `Signed in.`. |
| Persistência segura | Aprovado em teste automatizado | Nova instância recupera senha/cookie; `clear` remove; nenhum valor secreto é logado. |
| Geofences reais | Aprovado para registro | Activity log contém `Geofences registered (9).`; 0 regiões omitidas para esta conta. |
| Entrada em background | Aprovado | Evento `scene_phase_background`. |
| Localização contínua em background | Aprovado no smoke | 3 callbacks na primeira coleta; 6 na segunda, todos com `applicationState=background`. |
| Continuidade com tela bloqueada | Aprovado no smoke | A contagem dobrou entre amostras sem foreground do app. |
| Token APNs sandbox | Aprovado | `apns_device_token_received`, 32 bytes; valor não coletado nem documentado. |
| Mudanças significativas | Em observação | O deslocamento causou a retomada do processo, mas o relatório não permite atribuir inequivocamente o gatilho a este serviço. |
| Geofence ENTER/EXIT real | Aprovado para entrega do sistema | Foram recebidos em background EXIT e ENTER das regiões reais numéricas `1` e `21`. A regra de negócio não foi exercitada porque as atividades automáticas estavam desligadas. |
| BGAppRefresh | Reprovado neste build | O iOS executou `checking.refresh` às 09:47:55 e o callback caiu com `EXC_BREAKPOINT/SIGTRAP` por violação de isolamento/fila Swift. |
| BGProcessing | Em observação | Registrado, mas sem execução comprovada no período preservado. |
| Push via backend | Pendente | Ainda não existe lifecycle de token no backend; emissão local do token não prova entrega. |
| Relançamento pelo sistema | Parcial/inconclusivo | Há um novo processo em background às 11:02:50, logo após deslocamento e eventos de região, mas `launchOptions[.location]` foi registrado como falso. Não contar como aprovação ainda. |
| Reboot/primeiro desbloqueio | Pendente | Cenário separado após preservar a evidência corrente. |
| Precisão reduzida/permissões revogadas | Pendente | Cenários de degradação após o caminho ideal. |
| Bateria/24 horas | Amostra inválida para o gate | O processo caiu antes da primeira leitura e o harness usa GPS contínuo em precisão máxima; é necessário reiniciar após a correção. |

Os arquivos brutos copiados do container ficam somente em `.build/device-evidence/`, ignorado pelo Git.
As consultas usadas no relatório não imprimem coordenadas, senha, cookie ou token APNs.

## Avaliação parcial — 09:49 a 12:00

### Linha do tempo e bateria

O aparelho tem **75% de saúde da bateria**. A carga caiu de **98% para 87% em 2h11**, equivalente a
aproximadamente **5,0 pontos percentuais por hora** na janela completa. Esse número não pode ser atribuído
integralmente ao Checking:

- às 09:47:55, dois minutos antes da primeira leitura, o processo caiu ao receber um `BGAppRefresh`;
- entre 09:49 e aproximadamente 11:02, portanto, o app não estava executando a sessão contínua;
- às 11:02 surgiu um novo processo em background e, até 11:56, a bateria passou de 94% para 89% — cerca
  de **5,6 pontos percentuais por hora** nesta subjanela;
- a troca de eSIM e o uso do telefone entre 11:58 e 12:00 tornam os dois últimos pontos inadequados para
  medir o app;
- a capacidade degradada da bateria e a granularidade inteira do indicador aumentam a incerteza;
- o harness de diagnóstico mantém `kCLLocationAccuracyBest`, filtro de 1 metro, pausa automática desligada
  e atualizações contínuas. Trata-se de um perfil deliberadamente agressivo para provar callbacks, não do
  perfil energético final baseado em geofence/mudança significativa e sessões curtas de precisão.

Conclusão energética parcial: o consumo durante a sessão contínua merece otimização, mas **não há base
válida para aprovar nem reprovar o orçamento de energia do produto** com esta amostra.

### Evidência técnica preservada

- relatório posterior ao relançamento: 99 eventos entre 11:02:50 e 12:09:49;
- 81 atualizações de localização, todas com `applicationState=background` e nenhuma em `active`;
- duas saídas e duas entradas reais: EXIT `21`, EXIT `1`, ENTER `1`, ENTER `21`, todas em background;
- autorização `Sempre`, precisão completa e monitoramento de regiões disponíveis;
- nenhum erro de localização/geofence no período preservado;
- apenas um crash do Checking nos relatórios do sistema: 09:47:55;
- processo atual ainda vivo no momento da coleta;
- banco de atividades registra `Background evaluation (GEOFENCE)`, mas em seguida registra
  `Automatic activities are OFF.`. Assim, não houve validação ponta a ponta de check-in/check-out.

### Falhas encontradas na instrumentação

1. O handler de `BGTaskScheduler` foi registrado sem fila explícita, embora o fechamento carregue isolamento
   de ator. O iOS o chamou na fila `com.apple.BGTaskScheduler (br.com.tscode.checking.refresh)` e o runtime
   Swift encerrou o processo por `dispatch_assert_queue`.
2. O gravador mantém o relatório apenas em memória e, ao relançar, começa vazio antes de sobrescrever o JSON.
   Por isso, a evidência anterior às 11:02 foi perdida no arquivo corrente.
3. O modo físico (`includeSyntheticRegion: false`) não é persistido. Após relançamento, o valor padrão volta
   a habilitar a região sintética de Singapura, embora os quatro eventos numéricos acima sejam de regiões reais.
4. A tela de validação não permite habilitar as atividades automáticas e a conta iniciou com o valor local
   padrão desligado. O próximo ensaio deve confirmar explicitamente esse gate antes de ir ao background.

### Decisão desta rodada

Este primeiro ensaio é encerrado como **diagnóstico parcial**, não como teste de 24 horas aprovado. Antes de
reiniciá-lo, corrigir o callback de `BGTaskScheduler`, tornar o relatório cumulativo entre processos, persistir
o modo físico sem geofence sintética e expor/validar o estado de atividades automáticas. Depois, gerar um novo
build, iniciar um relatório limpo e repetir a medição com uma linha de base de bateria comparável.

## Correções aplicadas antes do segundo ensaio

Em 21/07/2026, após preservar a primeira coleta:

- os handlers de `BGAppRefresh` e `BGProcessing` passaram a ser registrados explicitamente na fila principal,
  eliminando a incompatibilidade de isolamento que causou o `SIGTRAP`;
- o gravador passou a carregar o JSON existente ao criar um novo processo e continuar a sequência de eventos;
- os modos de região sintética e localização contínua passaram a ser persistidos entre relançamentos;
- o perfil físico passou a usar somente geofences reais + mudanças significativas, sem GPS contínuo de
  precisão máxima; o perfil agressivo foi mantido apenas no Simulator;
- a tela física passou a exigir ativação explícita das atividades automáticas e persiste os projetos/projeto
  ativo retornados pela conta antes de liberar o botão de início;
- o início grava um gate sanitizado confirmando toggle e projeto configurado.

Verificação anterior à reinstalação: 510 testes unitários aprovados; nova regressão direcionada com 10 testes
aprovados; prova do Simulator aprovada para localização em background, ENTER/EXIT, APNs e registro dos dois
handlers; build físico assinado e instalado. A execução real de `BGAppRefresh` corrigido continua sendo um
critério do segundo ensaio, pois o Simulator não agenda esse evento.

## Segundo ensaio curto — aprovado com ressalva de backend

Janela principal: 13:22–14:24 de 21/07/2026. Deslocamento efetivo informado pelo usuário: 14:00–14:24.

- 51 eventos preservados; nenhum erro de localização e nenhum novo crash;
- mesmo PID (`11538`) durante toda a janela observada;
- quatro `BGAppRefresh` iniciados e concluídos, aproximadamente às 13:24, 13:39, 13:54 e 14:09;
- o ciclo das 14:09 resolveu `Unidade P80` e submeteu check-in com sucesso;
- saídas/entradas de regiões reais foram recebidas em background;
- duas atualizações por mudança significativa, ambas em background e nenhuma em primeiro plano;
- check-ins confirmados em `Escritório Avançado da P80` (14:06), `Unidade P80` (14:09), novamente no
  `Escritório Avançado da P80` (14:14) e `Escritório Principal` (14:24);
- as quatro notificações foram observadas pelo usuário; três chegaram com a tela bloqueada;
- bateria permaneceu em 100% entre a saída às 14:00 e o retorno às 14:24, com GPS contínuo desligado;
- desbloquear o aparelho para a coleta não trouxe o Checking ao foreground.

Dois achados adicionais:

1. O Core Location entregou ENTER duplicado (`didDetermineState(.inside)` + `didEnterRegion`) ao monitor de
   produção. O single-flight já impediu submissões duplicadas. Foi adicionada deduplicação por região/direção
   em janela de 3 segundos, coberta por três testes, antes do build destinado ao ensaio de 24 horas.
2. Nas duas transições por área não cadastrada, o motor tomou a mesma decisão do Kotlin — check-in em
   `Localização não Cadastrada` — mas o servidor recusou a submissão para `X-Client: checking-ios`. O código
   Kotlin documenta que essa operação depende de uma exceção/relaxamento no backend atualmente concedido ao
   cliente Android. A paridade completa requer que o backend reconheça também o cliente iOS; não mascarar isso
   identificando o app iOS como Android.

> **Decisão confirmada pelo produto em 21/07/2026:** a tentativa de check-in em `Localização não Cadastrada`
> é comportamento obrigatório e deve ser preservada. Não suprimir a decisão no cliente como forma de contornar
> o HTTP 422. O backend deve homologar `X-Client: checking-ios` com a mesma regra de `checking-android`.

Conclusão: background, geofences, timer, regras em locais cadastrados, notificações e perfil energético curto
estão aprovados. A dependência de backend para localização não cadastrada fica aberta e não invalida o início
do ensaio de 24 horas, mas bloqueia a paridade integral desse ramo.

## Roteiro esperado do ensaio prolongado

Planejado pelo usuário para 21–22/07/2026:

| Janela local | Situação esperada | Evidência procurada |
|---|---|---|
| 21/07, 16:40–17:10 | Check-out | CHECK_OUT único, notificação, trigger e local coerentes. |
| Noite, 20:00–07:00 | Pausa programada padrão | Nenhuma atividade indevida; observar BGTasks e consumo. |
| 22/07, 07:40–08:10 | Zona Mista e Escritório Principal | Retomada após pausa, ação da Zona Mista conforme último estado/cooldown e mudança para Principal. |
| 22/07, 08:15–08:30 | Escritório Avançado da P80 e Unidade P80 | Check-ins por mudança de local, sem duplicação. |
| 22/07, 08:50–09:20 | Escritório Avançado da P80 e Escritório Principal | Novos check-ins por mudança, notificações e latência. |
| 22/07, 09:20–09:30 | Fim do percurso funcional | Coleta parcial completa sem abrir o Checking antes da cópia. |
| Aproximadamente T+24h | Gate estrito de duração/energia | Coleta final de 24 horas; bateria, crashes, relançamentos e continuidade. |

O percurso até 09:30 corresponde a aproximadamente 19 horas se o ensaio começar perto de 14:30. Para manter
o gate literal de 24 horas, fazer a coleta funcional às 09:30 sem tocar em `Encerrar ensaio` e deixar o app em
background até aproximadamente 14:30 antes da coleta final.

### Marco inicial confirmado

- relatório reiniciado em 21/07/2026 às 14:38:56 (horário local aproximado informado: 14:39);
- bateria: 100%, aparelho ainda carregando;
- background confirmado às 14:40:05;
- localização `Sempre`, precisão completa, geofences reais e mudanças significativas ativas;
- localização contínua desligada;
- atividades automáticas persistidas como `true`;
- projetos persistidos: P80/P82/P83, projeto ativo P80;
- 9 geofences registradas;
- processo vivo, sem novo crash ou erro no relatório inicial.

O evento sanitizado `automatic_activities_gate` marcou `projectConfigured=false` porque a propriedade transitória
`uiState.userProjects` não é repopulada no restore após reinstalação. A fonte efetivamente consumida pelo
orquestrador (`pref_user_settings_json`) contém o projeto ativo P80; portanto é um falso negativo da
instrumentação, não falha operacional. Corrigir a tela após preservar o ensaio; não reinstalar durante a janela.

## Primeiro ensaio prolongado — reprovado, causa corrigida

Janela preservada: 21/07/2026 14:39 até 22/07/2026 aproximadamente 08:03.

### Evidência observada

- o relatório acumulou 68 eventos sem perder a coleta entre processos;
- o iOS encerrou e recriou o processo três vezes, aproximadamente às 16:43, 18:14 e 07:12;
- não houve novo crash; o único `.ips` continuou sendo o incidente antigo das 09:47;
- 28 atualizações por mudança significativa, todas em background e nenhuma em primeiro plano;
- o sistema entregou EXIT das regiões 1/21 às 16:43 e ENTER das regiões 1/21 às 07:58;
- apenas dois `BGAppRefresh` executaram, às 14:49 e 15:05; ambos concluíram sem crash;
- o relatório manteve um pedido de refresh pendente em cada relançamento, mas o iOS não voltou a executá-lo
  durante a janela — confirmação de que BGTask é oportunista e não pode ser o gatilho primário;
- os logs persistidos após os relançamentos contêm autenticação silenciosa, mas nenhum trigger GEOFENCE,
  checkout ou check-in;
- não foram recebidas notificações no checkout esperado nem nos check-ins da manhã.

### Causa raiz

As regiões continuaram armadas e acordaram o aplicativo corretamente. Porém,
`CLLocationManagerGeofenceMonitor` criava seu `CLLocationManager`/delegate somente no primeiro `sync`.
Após um relançamento frio em background, o coletor Debug era inicializado cedo e recebia o ENTER/EXIT, mas o
monitor de produção ainda não tinha delegate; por isso não chamava `orchestrator.runOnce(.geofence)`.

Correção: o manager e o delegate de produção agora são criados imediatamente na composição `AppEnvironment.live`,
sob `MainActor`, antes dos callbacks pendentes do Core Location. O falso negativo de `projectConfigured` também
passou a ler a mesma preferência persistida consumida pelo orquestrador. Verificação: 8 testes direcionados e
suíte completa de 514 testes aprovados; build físico assinado, instalado e aberto em 22/07/2026.

### Bateria parcial

- 100% às 14:39 (ainda carregando) para 87% às 16:42, com uso mínimo: aproximadamente 6,3 pontos percentuais/h;
- 86% às 16:47 para 83% às 17:17 durante deslocamento;
- 83% às 17:17 para 16% às 22:30 com uso intenso do aparelho — trecho não atribuível ao app;
- carga noturna até 100%; 98% às 07:00 para 88% às 07:52 com navegação GPS por cerca de 45 minutos — confuso;
- saúde da bateria informada anteriormente: 75%.

O primeiro trecho estacionário continua alto apesar de o perfil confirmar `continuous=false`. Não atribuir ao
Checking sem consultar a tela Ajustes > Bateria (percentual e atividade em segundo plano por app). O novo ensaio
deve repetir uma janela estacionária comparável e registrar essa tela.

## Protocolo do ensaio de 24 horas

- não forçar o encerramento do Checking durante o caminho ideal;
- manter o aparelho em uso normal e registrar bateria no início, T+1h, T+4h, T+8h e T+24h;
- manter o app em background e bloquear a tela entre as verificações;
- realizar deslocamento suficiente para produzir atualização significativa;
- se possível, atravessar uma das nove regiões reais para capturar ENTER/EXIT;
- anotar reinícios, aquecimento, indicador de localização, perda de rede e retorno da rede;
- copiar o relatório incrementalmente sem colocar o app em foreground;
- preservar este primeiro ensaio antes de executar force-quit, revogação ou precisão reduzida.

## Ensaio dirigido de relançamento frio — correção aprovada, nova lacuna encontrada

Janela: 22/07/2026, aproximadamente 08:08–09:21. O ensaio foi iniciado em primeiro plano, o Checking foi
enviado ao background e o processo `14338` foi encerrado às 08:08:45 por `SIGTERM` via ferramenta de
desenvolvimento, sem gesto de force-quit na interface do iOS. Assim, as regiões permaneceram elegíveis para
acordar o aplicativo. O relatório foi copiado depois do percurso sem abrir nem reinstalar o Checking.

### Prova da correção do delegate

- o processo estava ausente após o encerramento e o aplicativo foi relançado em background às 08:18:56,
  aproximadamente três minutos depois da saída do Escritório Principal informada às 08:16;
- no mesmo instante, o coletor e o monitor de produção receberam EXIT das regiões `1` e `21`;
- o relatório contém `production_geofence_exit` para as duas regiões e o banco contém
  `Background evaluation (GEOFENCE)`;
- a avaliação obteve fix com precisão aproximada de 26 m e o matcher respondeu localização desconhecida;
- o motor decidiu que nenhuma ação era necessária segundo o estado remoto daquele instante. Isso não remove
  o ramo obrigatório de `Localização não Cadastrada`: a tentativa continua condicionada à matriz Kotlin
  (última ação check-in e último local diferente de `Localização não Cadastrada`);
- não houve crash novo. O único relatório `.ips` do Checking continua sendo o incidente já corrigido de
  21/07 às 09:47.

Mesmo com `launchOptions[.location]` registrado como `false`, a sequência processo ausente → novo launch em
background → callback de produção no instante da travessia comprova operacionalmente a restauração. Em iOS
com ciclo de vida por cenas, esse booleano isolado não deve ser usado como único critério de relançamento.

### Linha do tempo funcional

| Horário local | Observação do usuário | Evidência persistida |
|---|---|---|
| 08:16 | saída do Escritório Principal para área não cadastrada | EXIT de `1`/`21` às 08:18:56, relançamento frio e avaliação GEOFENCE; matcher `unknown`, sem ação pela matriz/estado remoto |
| 08:21 | chegada ao Escritório Avançado P80, sem notificação | atualização por mudança significativa às 08:20:20; nenhum ENTER de região e nenhuma avaliação de produção |
| 08:24 | chegada à Unidade P80, sem notificação | atualização por mudança significativa às 08:27:19; nenhum ENTER de região e nenhuma avaliação de produção |
| 09:05 | retorno ao Escritório Avançado P80 | `BGAppRefresh` iniciou às 09:06:39 |
| 09:06 | notificação observada | TIMER resolveu Escritório Avançado da P80 e concluiu CHECK_IN às 09:06:40 |
| 09:14 | chegada ao Escritório Principal | ENTER de `1` às 09:14:07; GEOFENCE resolveu Principal e concluiu CHECK_IN no mesmo segundo |
| 09:15 | notificação observada | segundo ENTER (`21`) às 09:14:58; nova avaliação foi corretamente inócua por já estar no mesmo local |

O check-in de 09:06 confirma que o `BGAppRefresh` corrigido continua estável, mas a espera de cerca de 45
minutos desde a primeira chegada ao P80 não é aceitável como comportamento-alvo e não pode depender do timer,
cuja execução é discricionária.

### Nova causa operacional

O plano da Camada B exige que `startMonitoringSignificantLocationChanges` seja um fallback de produção e que
cada evento elegível acorde o mesmo orquestrador. No build atual, porém, a única chamada a essa API está no
`BackgroundValidationHarness` exclusivo de Debug: ele registra `location_update`, mas não executa
`BackgroundCheckOrchestrator`. Por isso, as leituras reais de 08:20 e 08:27 provaram movimento enquanto o fluxo
de negócio permaneceu parado. As entradas das geofences do P80 também não foram entregues pelo Core Location
nessa passagem; o fallback previsto deveria ter coberto exatamente esse caso.

Antes de repetir o ensaio prolongado, era necessário implementar um monitor de mudanças significativas de
produção, com manager/delegate criado cedo o suficiente para relançamento frio, gate de automação,
coalescência/single-flight e encaminhamento ao orquestrador. Essa correção foi concluída e instalada conforme
a seção seguinte. O percurso deve ser repetido e exigir uma avaliação próxima das leituras de mudança
significativa mesmo quando o ENTER de região não chegar.

### Bateria desta janela

O usuário registrou 88% entre 08:16 e 08:24, 87% às 09:05 e 86% às 09:14: queda de dois pontos em cerca de
58 minutos de deslocamento. É uma amostra melhor que a estacionária anterior, mas ainda não isola o consumo do
Checking. A atribuição em Ajustes > Bateria continua necessária, considerando a saúde informada de 75%.

## Correção da Camada B instalada — 22/07/2026 às 09:36

Foi adicionada uma implementação de produção dedicada a mudanças significativas, separada do harness Debug:

- `CLLocationManagerSignificantChangeMonitor` cria manager e delegate na composição inicial do app;
- a restauração no launch só arma o serviço com chave válida, consentimento explícito, automático habilitado e
  projeto ativo;
- habilitar o automático com consentimento já existente inicia o serviço; trocar de chave, desabilitar ou
  excluir a conta o interrompe;
- cada callback registra `production_significant_location` sem coordenadas e acorda o mesmo orquestrador
  single-flight com o gatilho distinguível `SIGNIFICANT_LOCATION`;
- matching, decisão de `Localização não Cadastrada`, submissão, idempotência e notificações continuam passando
  pela mesma implementação compartilhada com GEOFENCE/TIMER — nenhuma regra Kotlin foi duplicada no monitor;
- o início do ensaio registra `production_significant_monitor_status` para provar que o serviço está ativo.

Verificação automatizada: 7 testes direcionados e suíte completa de **519 testes**, todos aprovados. O projeto
foi regenerado, o build físico foi assinado com o profile de desenvolvimento e instalado sobre o aplicativo
existente, preservando seus dados.

Smoke no iPhone após a instalação, às 09:36:48:

- `production_significant_monitor_started` confirmou a restauração pelo estado persistido;
- um callback real `production_significant_location` foi recebido imediatamente;
- o banco registrou `Background evaluation (SIGNIFICANT_LOCATION)`;
- a captura curta resolveu `Escritório Principal` com boa precisão e a matriz concluiu corretamente que não
  havia nova ação a submeter;
- não houve crash nem erro de localização.

Esse smoke aprova a conexão monitor → orquestrador → captura/matcher/matriz. A entrega após deslocamento com app
suspenso ou processo relançado continua sendo o objetivo do percurso físico da tarde.

## Build integrada candidata ao percurso da tarde — instalada às 10:59

Em 22/07/2026, após o smoke da Camada B, foi preparada uma build que mantém toda a instrumentação e acrescenta
a tela definitiva de autenticação e registro manual. Ela inclui carregamento/persistência real de projetos,
localizações, captura da tela, check manual normal/retroativo, fila offline idempotente, histórico expandido,
nudge, Ajustes operacionais, painel vivo de permissões/consentimento, Pausa Programada e preferências de avisos.
Evidências antes do aparelho: **538 testes unitários**, **6 testes de UI**, inspeção visual no iPhone 17
Simulator e build arm64 assinada para o `TS 14 PRO`, todos verdes.

A primeira candidata foi instalada às 10:44 e revisada manualmente no aparelho. A revisão confirmou login,
históricos e permissões, e encontrou três problemas puramente visuais em Pausa Programada, Avisos e histórico.
Eles foram corrigidos e protegidos por dois novos testes de UI. Após **538 testes unitários + 8 testes de UI**
verdes, nova assinatura e validação, a candidata corrigida foi instalada às 10:59 e aberta com processo ativo.
Uma segunda revisão de legibilidade/usabilidade foi instalada às 12:41: histórico responsivo sem corte do
local e Pausa Programada reorganizada em ativação, período e dias inteiros. A nova candidata repetiu os
**538 testes unitários + 8 testes de UI**, assinatura e validação do processo no aparelho.
Às 12:48 foi instalada a apresentação final das credenciais autenticadas: chave visível, senha com máscara
fixa e cadeado, sem leitura/exposição do segredo do Keychain. A regressão completa permaneceu verde.
Às 13:01 foi instalada a tela `Ajustes › Atividades`, alimentada pelo log Core Data real. Ela permitirá
inspecionar no próprio aparelho os gatilhos e resultados do próximo ensaio antes de qualquer reinstalação;
`Clear` não deve ser usado durante o ensaio. Candidata aprovada em **539 testes unitários + 9 testes de UI**.
Às 13:23 foi instalada e aberta a sub-slice UI-7, sem iniciar ensaio: Instruções de Uso completas com as
capturas oficiais, Suporte/WhatsApp, Sobre e Privacidade/LGPD. A instalação preserva os dados da aplicação;
o wipe local existe apenas atrás de confirmação explícita na tela de Privacidade. Candidata aprovada em
**543 testes unitários + 12 testes de UI**, build arm64 assinado e processo físico confirmado ativo (PID 15045).
Às 13:33 as Instruções de Uso foram substituídas por um manual específico do iPhone, com oito capítulos e oito
capturas reproduzíveis do iPhone 17 Simulator. As imagens usam somente fixtures, não contêm dados do aparelho
físico e cobrem tela principal, Ajustes, Automático, Pausa, Avisos, Histórico, Atividades e Privacidade. O texto
também documenta latência controlada pelo iOS, tela bloqueada, reinício e force-quit. Regressão mantida em
**543 testes unitários + 12 testes de UI**; build físico reinstalado, aberto e confirmado ativo (PID 15057).
Às 14:12 o manual foi reorganizado como guia operacional em cinco capítulos e subtópicos 2.1–4.6, com 12
capturas do simulador e destaques numerados sobre os controles. Foram acrescentados os cenários sem cadastro,
sem senha e sem projeto, o cartão de local/precisão, as explicações completas de Ajustes e a pendência formal do
módulo Acidentes. Os rótulos visíveis passaram de `Avisos` para `Notificações` e de `Informe` para
`Assiduidade`. A candidata foi aprovada em **543 testes unitários + 12 testes de UI**, assinada, instalada no
`TS 14 PRO` e aberta com sucesso. A documentação mantém pendentes a confirmação backend dos 45 dias de
inatividade e a homologação editorial da deduplicação do FORMS.
Antes de sair, confirmar:

1. login restaurado e projeto P80 visível;
2. Atividades Automáticas ainda habilitadas no diagnóstico físico;
3. localização `Sempre` + precisão completa e monitor significativo ativo;
4. abrir Ajustes no app e confirmar o chip `Ativadas`, checklist todo permitido, Pausa Programada e Notificações;
5. tocar no histórico de Check-In/Check-Out e confirmar carregamento da tabela real;
6. iniciar novo ensaio físico, colocar em segundo plano e bloquear;
7. executar o percurso registrando horário, bateria, local esperado e notificação observada;
8. ao retornar, copiar o relatório antes de abrir/reinstalar novamente.

O teste manual da nova UI deve evitar registrar presença artificial antes da saída. No percurso, as atividades
automáticas e as tentativas de `Localização não Cadastrada` continuam sendo avaliadas pela mesma matriz já
aprovada; o botão manual será usado em um roteiro controlado separado.

## Percurso preservado de 22–23/07/2026

As anotações manuais detalhadas foram perdidas por falha de sincronização, mas o container foi copiado antes
de qualquer nova instalação para `.build/device-evidence/20260723-095151/`. A reconstrução usa o relatório
cumulativo e o banco Core Data, sem registrar coordenadas, credenciais ou token APNs.

- ensaio iniciado às 17:05:08 e enviado ao background às 17:05:23;
- às 17:09:10, duas saídas de geofence chegaram em background; às 17:09:11 a captura resolveu `Zona Mista`
  com precisão de 24 m e o backend aceitou o check-out;
- localizações não cadastradas continuaram sendo avaliadas depois do check-out, sempre concluindo corretamente
  que nenhuma nova atividade era necessária;
- a Pausa Programada iniciou às 21:52:48 e terminou às 07:39:43; sua transição não interrompeu a restauração
  posterior do monitor;
- o iOS recriou o processo quatro vezes — 21:52, 22:37, 07:39 e 09:01 — sem qualquer evento de cena ativa;
  após cada recriação, o monitor de mudanças significativas e a instrumentação foram restaurados;
- foram preservadas 27 atualizações de localização e quatro entregas de geofence, todas com
  `applicationState=background`; não houve retorno do Checking ao primeiro plano;
- às 09:21:58 uma mudança significativa ainda resolveu uma localização não cadastrada. Às 09:26:55 chegou o
  ENTER de geofence do `Escritório Principal`; às 09:26:56 a captura resolveu o local com precisão de 19 m e
  o backend aceitou o check-in. Um segundo ENTER às 09:27:27 foi deduplicado como “nenhuma ação necessária”;
- `BGAppRefresh` concluiu sem falha às 09:22 e às 09:39;
- não há novo crash do Checking nos relatórios do sistema; permanece apenas o crash antigo de 21/07 já
  diagnosticado e corrigido;
- as notificações de check-out e check-in foram percebidas com o aparelho bloqueado. A visualização apenas
  como contador é a preferência `Contagem` do próprio iOS, não uma decisão do aplicativo;
- a medição de bateria deste percurso é inconclusiva porque as anotações foram perdidas.

Conclusão: o percurso aprova check-out e check-in automáticos após suspensão e recriações silenciosas do
processo, inclusive com passagens por locais não cadastrados. A Fase 2 permanece aberta somente para os gates
separados de energia, reboot explicitamente observado, degradação de permissão/precisão e push pelo backend.

Após a coleta, o corpo das notificações de atividade foi alterado para `Check-In @ Localização` e
`Check-Out @ Localização`, com ação localizada nos seis idiomas e fallback para a mensagem genérica quando o
local não estiver disponível. A regressão completa aprovou **564 testes unitários**.

## Gate atual

O relançamento frio e a entrega do evento ao delegate de produção estão aprovados no iPhone real. Geofences,
mudanças significativas de produção, APNs sandbox, `BGAppRefresh`, autenticação silenciosa e notificações locais
também possuem evidência física. A **Fase 2 continua aberta** até repetir o percurso com o app suspenso/processo
recriado, medir energia por app e executar os cenários ainda pendentes de reboot, degradação de
permissão/precisão, push e duração prolongada.
