# Plano de conversão do Checking Android para iOS

> Documento de arquitetura, execução e validação  
> Estado: versão inicial revisada contra auditoria de ground-truth do código Android  
> Base analisada: aplicativo Android `1.6.5` (`versionCode 24`)  
> Documento de origem: `ios/docs/preliminar_plan.txt`  
> Validação de fidelidade: auditoria de ground-truth (18 agentes, evidência `arquivo:linha`), 2026-07-14 — decisões em `ios/docs/decision_log.md`  
> Última atualização: 14 de julho de 2026

## 1. Objetivo

Construir, dentro de `ios`, um aplicativo iPhone em Swift que reproduza com máxima fidelidade o aplicativo Android existente, preservando:

- identidade visual, hierarquia de telas, textos e fluxos;
- contratos da API e regras de negócio;
- autenticação, cadastro e aprovação de usuários;
- check-in e check-out manual e automático;
- operação offline e idempotência;
- transporte;
- modo acidente, notificações e vídeo;
- privacidade, segurança, idiomas e diagnósticos;
- a melhor continuidade operacional em segundo plano que o iOS permite oficialmente.

O Android será tratado como referência funcional, visual e de regras. Não será tratado como uma especificação literal de infraestrutura, porque os modelos de execução em segundo plano do Android e do iOS são diferentes.

## 2. Princípios obrigatórios

1. **Paridade observável acima de paridade interna.** O usuário deve perceber os mesmos fluxos, resultados e estados, ainda que a implementação use mecanismos nativos diferentes.
2. **Regras portadas, não reinterpretadas.** A matriz de atividades automáticas deve ser portada caso a caso e coberta por testes equivalentes aos testes Kotlin.
3. **Sem promessas incompatíveis com o iOS.** Não será descrita como “garantida a cada 15 minutos” nenhuma execução que dependa do agendador do sistema.
4. **Segundo plano é requisito arquitetural.** Ele deve ser provado em dispositivo real antes de a maior parte das telas ser construída.
5. **Servidor como autoridade.** Matching de localização, situação operacional e aceitação de atividades continuam sendo decididos pela API.
6. **Offline desde o início.** Idempotência, fila criptografada, ordenação e replay não podem ser acrescentados apenas ao final.
7. **Segurança e privacidade por padrão.** Credenciais, cookies, coordenadas, vídeo e logs terão tratamento explícito.
8. **Dependências mínimas.** Preferir frameworks Apple; qualquer biblioteca externa exigirá justificativa, auditoria de privacidade e plano de atualização.
9. **Acessibilidade e localização fazem parte da paridade.** Os seis idiomas e os recursos assistivos não serão tarefas opcionais de acabamento.
10. **Toda divergência será deliberada.** Diferenças inevitáveis ou correções de ambiguidades do Android serão registradas em um log de decisões.

## 3. O que significa “idêntico” neste projeto

### 3.1 Paridade funcional

As mesmas entradas válidas devem produzir os mesmos resultados de negócio, incluindo:

- validação de chave e senha;
- cadastro, aprovação e login automático;
- estados de check-in/check-out;
- situações de localização automática;
- prevenção de duplicidade;
- zona mista e seus intervalos;
- pausa programada;
- eventos retroativos;
- projetos e localização manual;
- transporte;
- acidentes, confirmações e vídeo;
- comportamento de erro, reautenticação e operação offline.

### 3.2 Paridade visual

A versão iOS deverá reproduzir os tokens e a composição do Android, e não simplesmente substituir tudo por componentes padrão de `Form`:

- verde-petróleo `#0F766E`;
- gradiente cinza claro;
- cartão branco principal;
- marca-d’água Petrobras com opacidade equivalente;
- bordas, raios, sombras, brilhos laranja e verde;
- tema vermelho de acidente;
- splash, logotipo, versão e créditos;
- ordem, estados e transições dos componentes;
- tipografia Arimo onde ela for a fonte da referência;
- aparência clara consistente, salvo decisão posterior sobre modo escuro.

“Pixel perfect” será aferido por capturas lado a lado e testes de snapshot em tamanhos de iPhone definidos. Adaptações obrigatórias de safe area, teclado, Dynamic Type e acessibilidade não serão consideradas defeitos de paridade.

### 3.3 Paridade operacional

Em condições normais, o usuário deve conseguir habilitar o automático, deixar o aplicativo em segundo plano, deslocar-se entre as áreas e receber o resultado correspondente sem precisar abrir o app. No entanto, o aceite será expresso em condições e métricas, e não como uma garantia absoluta de periodicidade.

### 3.4 Paridade que não é tecnicamente possível

O iOS não oferece equivalentes públicos para:

- foreground service Android permanente;
- `START_STICKY`;
- `BOOT_COMPLETED` irrestrito;
- wake lock;
- alarme que reinicia arbitrariamente um processo;
- isenção de otimização de bateria;
- timer garantido a cada 15 minutos;
- reinício garantido depois de o usuário forçar o encerramento do app.

Essas diferenças serão compensadas por uma estratégia em camadas descrita neste documento. Se o usuário encerrar explicitamente o aplicativo, desabilitar Localização, desabilitar Atualização em 2º Plano ou negar a autorização necessária, o sistema deve informar claramente que a automação está degradada ou indisponível.

### 3.5 Matriz de equivalência entre plataformas

| Referência Android | Implementação iOS planejada | Nível esperado |
|---|---|---|
| Jetpack Compose/Material 3 customizado | SwiftUI + design system próprio | Equivalência visual alta |
| MVVM + `StateFlow` | MVVM + estado observável no `MainActor` | Equivalência arquitetural |
| Hilt | Composição explícita em `AppEnvironment` | Equivalência funcional |
| Retrofit/OkHttp | URLSession/Codable | Equivalência de contrato |
| DataStore | Repositório de preferências tipado | Equivalência funcional |
| Room | Core Data | Equivalência funcional |
| EncryptedSharedPreferences | Keychain + CryptoKit/Data Protection | Proteção equivalente ou superior |
| Foreground service `START_STICKY` | Core Location em background + restauração | Equivalência parcial condicionada ao iOS |
| Timer do service a cada 15 min | Eventos de localização + reconciliação | Sem periodicidade exata |
| WorkManager de 15 min | BGAppRefresh/BGProcessing oportunistas | Equivalência parcial |
| Geofencing Android | Regiões Core Location | Alta, com limite iOS de 20 |
| Boot/update receiver | Restauração em launch/relaunch permitido | Equivalência parcial |
| Alarm após remoção dos recentes | Sem equivalente público | Não disponível após force-quit |
| Wake lock | Prazo concedido pelo sistema + conclusão cooperativa | Sem equivalente direto |
| Notificação do foreground service | Indicador de localização do iOS + notificações de resultado | Semântica adaptada |
| SSE ativo | URLSession streaming em foreground | Equivalência alta enquanto ativo |
| Worker de acidentes | APNs + BGTask + reconciliação | Alta se backend APNs estiver pronto |
| CameraX | AVFoundation | Equivalência alta |
| Upload MP4 comum | Background URLSession a partir de arquivo | Continuidade iOS apropriada |
| Seis dicionários Kotlin | String Catalog e InfoPlist.strings | Equivalência completa |

Qualquer linha classificada como parcial deverá possuir um roteiro de teste, uma mensagem de degradação e aceite explícito do produto.

## 4. Referência funcional congelada

Antes do desenvolvimento, deve ser produzido um pacote de referência da versão Android analisada contendo:

- APK/build reproduzível e número da versão;
- gravação de todos os fluxos;
- capturas de cada tela, modal, loading, vazio, sucesso e erro;
- capturas nos seis idiomas;
- inventário de textos e chaves de tradução;
- inventário de endpoints, cabeçalhos, DTOs e códigos de erro;
- valores de tokens visuais;
- matriz de regras automáticas;
- preferências padrão;
- dados de teste e contas de staging;
- resultados dos 296 testes Kotlin;
- decisões sobre as ambiguidades listadas na seção 29.

Qualquer mudança posterior no Android deverá ser classificada como correção a incorporar, nova funcionalidade ou alteração fora do escopo da primeira versão iOS.

## 5. Decisões de plataforma propostas

Estas decisões são recomendações iniciais. Devem ser confirmadas no Marco 0.

| Tema | Decisão recomendada | Justificativa |
|---|---|---|
| Interface | SwiftUI | Composição declarativa próxima do Compose e bom suporte a previews e snapshots. |
| Linguagem | Swift 6, concorrência estrita | Evita corridas entre localização, rede, fila offline e ciclo de vida. |
| iOS mínimo | iOS 17.0 | Bom alcance e SwiftUI moderno; manter adaptadores para APIs novas. |
| Localização | `CLLocationManager` como base compatível | É adequado a background, relançamento por eventos e versões suportadas. |
| APIs modernas | `CLLocationUpdate`/`CLMonitor` sob disponibilidade | Adotar quando trouxerem ganho mensurável, sem dividir as regras de negócio. |
| Estado de UI | MVVM com estado imutável e `@Observable`/`ObservableObject` | Mantém correspondência conceitual com `StateFlow`. |
| Concorrência | `async/await`, `AsyncSequence` e actors | Serializa recursos sensíveis e elimina callbacks dispersos. |
| Rede | `URLSession` e `Codable` | Stack nativa suficiente para REST, SSE e upload. |
| Persistência estruturada | Core Data | Maturidade, migrações, consultas, background contexts e testes. |
| Segredos | Keychain Services | Armazenamento nativo de credenciais e chaves criptográficas. |
| Criptografia de payloads | CryptoKit/AES-GCM | Proteção explícita da fila offline e dados sensíveis. |
| Logs | `OSLog` + banco local sanitizado | Diagnóstico sem vazar dados privados no log do sistema. |
| Câmera/vídeo | AVFoundation | Gravação, permissões e controle de arquivo nativos. |
| Notificações | UserNotifications + APNs | Alertas locais e eventos remotos de acidente. |
| Dependências externas | Nenhuma na fundação | Reduz risco de supply chain e obrigações de privacy manifest. |

Se o mínimo subir para iOS 18, a camada de localização poderá adotar as APIs modernas como implementação principal. Essa decisão não deve ficar implícita no código: será registrada com alcance de aparelhos e versão de Xcode suportada.

## 6. Estrutura proposta do projeto

```text
ios/
├── Checking.xcodeproj
├── Checking/
│   ├── App/
│   │   ├── CheckingApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppEnvironment.swift
│   │   └── AppLifecycleCoordinator.swift
│   ├── Core/
│   │   ├── API/
│   │   ├── Errors/
│   │   ├── Logging/
│   │   ├── Security/
│   │   ├── Time/
│   │   └── Utilities/
│   ├── Domain/
│   │   ├── Models/
│   │   ├── CheckRules/
│   │   ├── UseCases/
│   │   └── Repositories/
│   ├── Data/
│   │   ├── DTOs/
│   │   ├── Network/
│   │   ├── Persistence/
│   │   └── Repositories/
│   ├── Platform/
│   │   ├── Background/
│   │   ├── Location/
│   │   ├── Notifications/
│   │   ├── Camera/
│   │   ├── Connectivity/
│   │   └── Permissions/
│   ├── Features/
│   │   ├── Splash/
│   │   ├── Check/
│   │   ├── Settings/
│   │   ├── Transport/
│   │   ├── Accident/
│   │   ├── Manual/
│   │   ├── About/
│   │   └── Privacy/
│   ├── DesignSystem/
│   │   ├── Tokens/
│   │   ├── Components/
│   │   └── Assets.xcassets/
│   ├── Localization/
│   ├── Resources/
│   ├── Info.plist
│   ├── Checking.entitlements
│   └── PrivacyInfo.xcprivacy
├── CheckingTests/
├── CheckingUITests/
├── Config/
│   ├── Debug.xcconfig
│   ├── Staging.xcconfig
│   └── Release.xcconfig
└── docs/
```

Regras de dependência:

- `Domain` não importa SwiftUI, UIKit, Core Location nem AVFoundation.
- `Features` consomem casos de uso e estados, não acessam URLSession ou banco diretamente.
- `Platform` encapsula APIs do sistema.
- `Data` implementa protocolos definidos no domínio.
- `AppEnvironment` realiza a composição de dependências.
- relógio, UUID, rede, localização e notificações devem ser injetáveis para testes.
- nenhum singleton global mutável será fonte de verdade.

## 7. Arquitetura de estado e concorrência

### 7.1 Fontes de verdade

- Sessão e identidade: `SessionManager` actor.
- Estado operacional remoto: `CheckRepository`, com cache versionado e prazo explícito.
- Preferências: repositório local por chave do usuário.
- Fila offline: `OfflineQueue` actor.
- Execuções automáticas: `BackgroundCheckOrchestrator` actor.
- Localização: `LocationService` isolado, publicando eventos tipados.
- Estado de cada tela: ViewModel no `MainActor`.

### 7.2 Single-flight

Somente uma avaliação automática poderá executar por conta e dispositivo a cada instante. Todos os gatilhos — geofence, mudança significativa, atualização padrão, push, BGTask e foreground — convergirão para o mesmo orquestrador.

O orquestrador deverá:

1. registrar o gatilho;
2. coalescer gatilhos equivalentes;
3. rejeitar ou enfileirar concorrência conforme prioridade;
4. respeitar cancelamento e prazo disponível;
5. persistir o resultado antes de liberar o lock;
6. concluir corretamente qualquer tarefa do sistema.

### 7.3 Relógio e datas

Todas as regras deverão usar um `Clock` injetável. Instantes serão persistidos em UTC; apresentação e pausa programada usarão o fuso vigente do aparelho conforme regra aprovada. Testes devem cobrir horário de verão, mudança manual de hora, mudança de fuso e transições que atravessam meia-noite.

## 8. Contrato de rede e backend

### 8.1 Cliente HTTP

O cliente iOS deverá manter:

- base URL configurável, com produção inicialmente em `https://tscode.com.br/api/web/`;
- TLS via App Transport Security, sem exceções inseguras;
- cabeçalho de identificação, recomendado `X-Client: checking-ios`;
- timeouts equivalentes aos 15/30 segundos Android, diferenciados por operação;
- suporte a JSON e datas aceitas pela API;
- cookies de sessão;
- chave de idempotência;
- mapeamento central de 401, 403, 409, 422, outros 4xx, 5xx, timeout e falta de rede;
- redaction de senha, cookie, token, coordenadas e corpo sensível em logs.

O backend deve confirmar formalmente que `checking-ios` terá as mesmas regras concedidas ao cliente Android, inclusive qualquer tratamento especial de “Localização não Cadastrada”. Até essa confirmação, o cabeçalho é um bloqueador de integração.

### 8.2 Cookies e reautenticação

Cookies de sessão não dependerão apenas de um armazenamento implícito do sistema. Um `SessionCookieStore` deverá:

- interpretar `Set-Cookie`, domínio, caminho, expiração e flags;
- persistir material necessário no Keychain;
- injetar somente cookies válidos para o host correto;
- invalidar tudo em logout, troca de conta e exclusão local;
- realizar uma única tentativa de relogin silencioso em 401;
- impedir loops de autenticação;
- ser acessível em execução de background após o primeiro desbloqueio.

### 8.3 Server-Sent Events

SSE será usado enquanto o app estiver ativo para transporte e acidentes. O cliente deve suportar parsing incremental, heartbeat, reconexão com jitter, `Last-Event-ID` se o servidor fornecer e cancelamento quando a tela/conta deixar de ser válida.

SSE não será considerado canal confiável enquanto o app estiver suspenso. Alertas relevantes de acidente deverão usar APNs; polling e SSE serão mecanismos de reconciliação.

### 8.4 Contratos verificáveis

Cada endpoint usado no Kotlin deverá gerar uma ficha contendo:

- método e caminho;
- cabeçalhos;
- request e response;
- campos opcionais/nulos;
- formato de datas;
- códigos de sucesso e erro;
- idempotência;
- cacheabilidade;
- comportamento offline;
- fixture JSON anonimizada.

Testes de contrato devem executar contra staging e detectar deriva antes da publicação.

## 9. Estratégia de funcionamento em segundo plano

### 9.1 Premissa da plataforma

O iOS normalmente suspende aplicativos pouco depois de eles deixarem o primeiro plano. `BGAppRefreshTask` e push silencioso são oportunistas: o sistema decide quando executá-los. A automação não pode ser construída ao redor de um timer de 15 minutos.

A arquitetura será orientada por eventos relevantes de localização e complementada por mecanismos de reconciliação.

### 9.2 Camada A — monitoramento de regiões

Usar regiões geográficas do Core Location para entrada e saída das áreas fornecidas pelo servidor.

Requisitos:

- registrar as regiões somente após autenticação, consentimento e permissão apropriada;
- identificadores determinísticos e versionados;
- reconciliar adições, alterações e remoções de forma idempotente;
- restaurar o contexto a partir do identificador quando o sistema relançar o app;
- considerar estado inicial explicitamente, pois registrar uma região não equivale a receber imediatamente um evento de entrada;
- encaminhar todo evento ao orquestrador comum;
- renovar o conjunto quando servidor, projeto ou usuário mudar;
- manter logs de regiões aceitas, rejeitadas e omitidas, sem coordenadas em texto claro.

O iOS limita o monitoramento a 20 regiões por aplicativo. Portanto, uma das condições a seguir deverá ser contratada:

1. o backend sempre devolve no máximo 20 regiões relevantes para o usuário; ou
2. backend e app definem prioridade determinística.

Prioridade recomendada caso seja necessário selecionar:

1. área do check-in atual e respectiva zona de saída;
2. áreas do projeto ativo;
3. áreas explicitamente favoritas/recentes;
4. áreas mais próximas da posição conhecida;
5. demais áreas até o limite.

O app deverá comunicar no diagnóstico quando áreas deixarem de ser monitoradas. Não será aceitável truncar silenciosamente uma lista.

### 9.3 Camada B — mudanças significativas de localização

Com autorização “Sempre”, `startMonitoringSignificantLocationChanges` será usado como fallback de movimento amplo e como oportunidade de relançamento do app. Ele não substitui geofence nem oferece granularidade de 15 minutos; eventos dependem de deslocamento relevante e condições do sistema.

Ao receber um evento:

1. aplicar o gate de permissão, conta, automático e pausa;
2. verificar deslocamento mínimo;
3. iniciar uma captura curta de melhor precisão se houver tempo;
4. consultar matcher e estado;
5. aplicar regras e enviar/enfileirar a atividade;
6. atualizar regiões priorizadas quando necessário.

### 9.4 Camada C — atualizações padrão em background

Quando atividades automáticas estiverem habilitadas, poderá ser mantida uma sessão de localização iniciada em primeiro plano com:

- `UIBackgroundModes = location`;
- `allowsBackgroundLocationUpdates = true`;
- indicador de uso de localização conforme comportamento do sistema;
- `distanceFilter` e precisão calibrados em campo;
- tratamento de `accuracyAuthorization` reduzida;
- pausa automática do Core Location avaliada por ensaio, sem esconder perda operacional;
- captura de alta precisão em rajadas, não GPS máximo indefinidamente.

Estratégia recomendada de produção: híbrida e orientada por eventos. Geofences e mudanças significativas permanecem armadas; atualizações padrão identificam deslocamento e o app solicita precisão maior apenas quando há motivo para avaliar.

Uma modalidade realmente contínua só será ativada se os ensaios demonstrarem necessidade, autonomia aceitável e justificativa legítima para App Review. O `activityType` deverá descrever o uso real; categorias de navegação ou fitness não serão utilizadas apenas para obter mais tempo de execução.

### 9.5 Camada D — retorno ao primeiro plano

Em todo launch ou transição para ativo:

- reavaliar permissões e precisão;
- atualizar o painel de integridade;
- reconciliar sessão e estado;
- reproduzir a fila offline;
- atualizar regiões;
- consultar acidentes e transporte;
- executar avaliação automática se habilitada e fora de pausa;
- reagendar tarefas de background.

Essa é uma garantia controlável pelo aplicativo e deve corrigir qualquer estado perdido durante suspensão.

### 9.6 Camada E — BackgroundTasks

Registrar os identificadores antes do fim do launch:

- `BGAppRefreshTask`: reconciliação curta de sessão, acidentes, estado e fila;
- `BGProcessingTask`: manutenção/replay mais pesado quando o sistema conceder tempo.

Regras:

- `earliestBeginDate` é uma preferência mínima, não agenda garantida;
- reagendar no início ou final de cada execução;
- declarar identificadores permitidos no `Info.plist`;
- configurar expiração e cancelar trabalho cooperativamente;
- sempre chamar `setTaskCompleted(success:)`;
- usar restrições de rede/energia coerentes;
- não usar BGTask como relógio de ponto de 15 minutos;
- testar em aparelho físico e com os comandos de depuração recomendados pela Apple.

### 9.7 Camada F — APNs

APNs é requisito para alertas de acidente em segundo plano e recomendado para invalidação de estado.

O backend deverá implementar:

- cadastro e atualização de device token por usuário, instalação e ambiente;
- remoção de token em logout/exclusão e limpeza de tokens inválidos;
- autenticação APNs por chave ou certificado, com rotação documentada;
- payload mínimo, sem dados pessoais desnecessários;
- alert push para acidentes que exijam ciência do usuário;
- background push apenas como oportunidade de sincronização;
- `apns-topic`, prioridade, expiração e `collapse-id` corretos;
- rastreabilidade de aceite/rejeição pela APNs sem tratar aceite como entrega;
- fallback por consulta no foreground e BGTask.

Push silencioso não terá frequência artificial de 15 minutos e não será a única forma de executar uma função crítica, pois pode ser limitado ou agrupado pelo sistema.

### 9.8 Camada G — tempo adicional para concluir um evento

`beginBackgroundTask` poderá proteger a conclusão curta de uma operação iniciada quando o app estava ativo ou recebeu um evento. Ele não será usado para manter um loop, iniciar rastreamento arbitrário ou substituir Core Location/BGTask.

### 9.9 Camada H — notificações locais

Notificações locais informarão, conforme preferência do usuário:

- check-in/check-out automático concluído;
- atividade preservada offline;
- necessidade de reautenticação;
- autorização degradada;
- acidente novo ou pendente de confirmação quando detectado;
- início/fim previsto de pausa quando útil.

Notificação agendada não executa livremente código do app. Uma notificação de fim de pausa pode orientar o usuário, mas não será tratada como mecanismo garantido de reativação.

### 9.10 Estados de término e reinício

| Situação | Expectativa suportada |
|---|---|
| App em background/suspenso | Eventos Core Location podem acordar ou dar tempo ao app conforme autorização e configuração. |
| App encerrado pelo sistema | Geofence e mudança significativa podem relançá-lo; restaurar estado de forma rápida e idempotente. |
| Reinício do iPhone | Monitoramentos persistem conforme API, mas a execução e o acesso a dados dependem do primeiro desbloqueio. |
| Usuário força encerramento | Não prometer relançamento automático; mostrar aviso na próxima abertura. |
| Background App Refresh desligado | Diagnóstico deve indicar degradação; mecanismos e relançamentos sofrem restrições. |
| Localização desligada | Automático indisponível; manter check manual quando permitido. |
| “Sempre” negado | Primeiro plano funciona; automação completa fica degradada e isso deve ser explícito. |
| Precisão exata negada | Tentar matcher com precisão reportada e oferecer fallback manual conforme resposta. |
| Modo Pouca Energia | Reduzir trabalho não essencial e sinalizar possível degradação sem bloquear manual. |

## 10. Orquestrador de atividades automáticas

Todos os gatilhos devem chamar a mesma máquina de execução:

```text
gatilho
  -> gate de single-flight
  -> identidade/sessão
  -> consentimento e permissões
  -> automático habilitado
  -> pausa programada
  -> prazo de background disponível
  -> posição preliminar
  -> filtro de deslocamento
  -> captura precisa, quando necessária
  -> matcher do servidor + estado atual
  -> matriz de decisão pura
  -> envio idempotente ou fila offline
  -> persistência do resultado
  -> notificação e diagnóstico
```

O filtro de movimento deve começar com a regra Android `max(50 m, 2 × precisão)` e somente mudar mediante evidência registrada. Os caches iniciais serão equivalentes:

- estado remoto: 45 segundos;
- opções: 15 minutos;
- regiões: 1 hora.

Cada cache precisa de chave por usuário/ambiente, timestamp monotônico quando aplicável e invalidação em logout, mudança de projeto e resposta incompatível.

## 11. Portabilidade da matriz de decisão

A lógica de `AutoActivities.kt` deverá ser portada como função pura. Os mesmos conceitos e nomes serão preservados onde isso facilitar auditoria:

- `MATCHED`;
- `ACCURACY_TOO_LOW`;
- `NOT_IN_KNOWN_LOCATION`;
- `OUTSIDE_WORKPLACE`;
- `NO_KNOWN_LOCATIONS`.

Casos mínimos de aceite:

- último evento check-in + entrada em Zona de CheckOut gera check-out;
- check-in + afastamento do trabalho gera check-out em “Fora do Local de Trabalho”;
- último evento check-out + entrada em área cadastrada gera check-in;
- mudança entre áreas gera check-in na nova área;
- repetição na mesma área não duplica;
- check-in + proximidade sem área cadastrada registra a mudança prevista;
- check-out + localização não cadastrada não gera check-in;
- zona mista alterna respeitando cooldown;
- baixa precisão não gera atividade automática;
- não existem dois check-outs consecutivos;
- eventos atrasados/offline não corrompem o estado mais recente;
- decisões concorrentes não ultrapassam o gate de single-flight.

Os testes Kotlin deverão ser inventariados em uma tabela `teste Kotlin -> teste Swift`, com resultado esperado e eventual justificativa de divergência.

## 12. Permissões, consentimento e integridade operacional

### 12.1 Escada de autorização

As permissões serão solicitadas em contexto, nunca todas no primeiro launch:

1. exibir a explicação interna de privacidade e o benefício funcional;
2. solicitar notificações ao habilitar avisos/automático ou em momento equivalente aprovado;
3. solicitar localização “Durante o Uso” ao usar localização pela primeira vez;
4. validar que o recurso funciona em primeiro plano;
5. ao usuário habilitar atividades automáticas, explicar segundo plano e solicitar “Sempre” em etapa separada;
6. explicar precisão exata e tratar precisão reduzida;
7. solicitar câmera e microfone somente ao iniciar gravação de acidente.

O pedido de “Sempre” é um recurso escasso e contextual. Não deve ser desperdiçado antes de o usuário compreender a funcionalidade. Se negado, o app deve apresentar instruções para Ajustes, sem loops ou pressão enganosa.

### 12.2 Chaves e capacidades

Planejar e localizar nos seis idiomas:

- `NSLocationWhenInUseUsageDescription`;
- `NSLocationAlwaysAndWhenInUseUsageDescription`;
- `NSCameraUsageDescription`;
- `NSMicrophoneUsageDescription`.

Capacidades candidatas, habilitadas somente quando usadas:

- Background Modes — Location updates;
- Background Modes — Background fetch;
- Background Modes — Background processing;
- Background Modes — Remote notifications;
- Push Notifications.

Adicionar `BGTaskSchedulerPermittedIdentifiers` para as tarefas registradas. Qualquer capability deve corresponder a código real e a uma justificativa de produto.

### 12.3 Painel de integridade

A tela de atividades automáticas deverá mostrar separadamente:

- consentimento interno;
- Localização habilitada no sistema;
- autorização Durante o Uso/Sempre;
- precisão exata/reduzida;
- notificações autorizadas;
- Atualização em 2º Plano disponível;
- Modo Pouca Energia;
- automático habilitado no servidor/local;
- pausa ativa e próxima transição;
- regiões monitoradas e quantidade omitida;
- horário e resultado da última avaliação;
- fila offline pendente;
- necessidade de abrir Ajustes.

Não haverá instrução sobre “autostart” ou “ignorar otimização de bateria”, pois esses controles Android não existem no iOS.

## 13. Pausa programada

Preservar os padrões atuais:

- todos os dias, das 20:00 às 07:00;
- sábado inteiro;
- domingo inteiro.

A regra será uma função pura, independente de UI e de Core Location. Durante a pausa:

- eventos recebidos passam pelo gate e não coletam posição adicional nem geram atividade;
- sessões contínuas de alta precisão são interrompidas;
- regiões e mudanças significativas podem permanecer registradas para permitir retomada e evitar perda de configuração, mas seus eventos serão no-op enquanto a pausa estiver ativa;
- replay de eventos já decididos pode continuar apenas se a política aprovada permitir;
- notificações de transição respeitam preferência do usuário.

O iOS não garante executar código exatamente no fim da pausa. A retomada ocorrerá no primeiro gatilho disponível: localização, foreground, BGTask ou push. Se retomada no horário exato for requisito crítico, o backend deverá agendar uma notificação/APNs de apoio, ainda sem garantia absoluta de execução silenciosa.

Testes devem cobrir pausas que atravessam meia-noite, fim de semana, mudança de fuso, horário de verão e alteração de configuração durante uma pausa.

## 14. Operação offline

### 14.1 Modelo da fila

Portar os dois tipos de evento:

- `Raw`: posição capturada, mas matching não concluído;
- `Decided`: ação decidida, mas submissão não confirmada.

Cada registro deve conter, conforme o tipo:

- UUID/idempotency key;
- usuário e ambiente;
- instante original em UTC;
- origem do gatilho;
- coordenadas, altitude se usada, precisão e idade da leitura;
- decisão e contexto necessários;
- número de tentativas, próximo retry e último erro sanitizado;
- versão do schema.

### 14.2 Segurança e persistência

- máximo inicial de 200 eventos, com política explícita quando o limite for atingido;
- payload sensível cifrado por AES-GCM;
- chave simétrica aleatória no Keychain;
- arquivo/banco com Data Protection compatível com background após primeiro desbloqueio;
- escrita atômica e recuperação após encerramento no meio da gravação;
- migrações versionadas e testadas;
- exclusão total em limpeza local/exclusão de conta.

Credenciais e chaves necessárias em background usarão, após revisão de ameaça, acessibilidade equivalente a `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: disponíveis após o primeiro desbloqueio e não migráveis para outro aparelho.

### 14.3 Replay

- processar em ordem cronológica;
- uma única instância de replay;
- aguardar conectividade, mas não confiar somente no monitor de rede;
- backoff exponencial com jitter;
- preservar timestamp e UUID originais;
- em 401, tentar reautenticação uma vez;
- classificar erro permanente versus transitório;
- reconciliar resposta perdida usando idempotência;
- manter eventos antigos no histórico, mas usar somente as últimas 24 horas para preencher estado operacional, conforme Android;
- não descartar silenciosamente evento inválido: mover para estado terminal diagnosticável.

## 15. Autenticação e ciclo de conta

Reproduzir:

- chave alfanumérica de quatro caracteres;
- senha de 3 a 10 caracteres;
- consulta de existência da chave;
- criação de senha para usuário existente;
- autocadastro;
- espera de aprovação com polling de 10 segundos em foreground;
- verificação da senha após debounce equivalente a 800 ms;
- login automático opt-in conforme comportamento atual;
- logout;
- relogin silencioso em background;
- alteração de senha;
- exclusão remota, inclusive estados bloqueados.

Ao trocar usuário, sair ou apagar dados, realizar uma transação lógica que limpe:

- cookies e credenciais;
- tokens APNs associados localmente e no backend;
- preferências por chave;
- caches e projetos;
- regiões e sessões de localização;
- fila offline separada;
- banco de atividades e avaliações;
- acidentes notificados;
- preferências de transporte;
- arquivos temporários e uploads pendentes que não devam sobreviver.

Testar falha parcial de cada etapa e tornar a limpeza repetível.

## 16. Tela principal e sistema visual

### 16.1 Design system

Criar tokens Swift derivados de `Color.kt`, `Tokens.kt`, `Type.kt` e temas de acidente:

- cores semânticas;
- tipografia e pesos;
- espaçamento;
- dimensões e raios;
- sombras e glows;
- opacidades;
- duração e curva de animações;
- estados enabled, pressed, focused, loading e error.

Componentes reutilizáveis previstos:

- header/shell;
- cartão principal;
- campo com glow;
- campo de senha;
- botão primário;
- choice card;
- notification card;
- history card;
- location card;
- fieldsets de autenticação, informe, projetos e registro;
- modal/dialog scaffold;
- banners de permissão e integridade.

### 16.2 Ordem funcional

Preservar a ordem observada no Android:

1. último check-in e check-out;
2. avisos de acidente;
3. status;
4. GPS quando automático estiver ativo;
5. chave, senha e ajustes;
6. incentivo ao automático;
7. escolha check-in/check-out;
8. transporte quando habilitado;
9. informe normal/retroativo;
10. projetos;
11. localização manual quando aplicável;
12. registro;
13. acidente.

### 16.3 Adaptações iOS controladas

- respeitar safe areas e home indicator;
- comportamento de teclado e foco previsível;
- suporte a telas pequenas e orientação aprovada;
- Dynamic Type sem truncar ações críticas;
- VoiceOver com ordem equivalente à visual;
- área de toque mínima;
- contraste aferido;
- reduzir animações quando `Reduce Motion` estiver ativo;
- não depender apenas de cor para estado.

## 17. Check manual, histórico e projetos

### 17.1 Check manual

- mesmos campos obrigatórios e validações;
- normal e retroativo;
- projeto e localização;
- fallback manual em baixa precisão/permissão conforme regra do servidor;
- feedback de loading, sucesso e erro;
- idempotência também para submissões manuais;
- bloqueio de múltiplos taps;
- preservação segura do formulário em interrupções.

### 17.2 Histórico

- paginação e ordenação equivalentes;
- último check-in e checkout sempre coerentes com o estado remoto;
- destaque de eventos pendentes quando adequado;
- datas e fusos exibidos conforme contrato aprovado;
- empty/error/retry states visualmente equivalentes.

### 17.3 Projetos

- projeto ativo e seleção múltipla conforme Android;
- persistência por usuário;
- invalidação quando servidor remover acesso;
- atualização de regiões e dados dependentes após mudança;
- nenhuma preferência de um usuário pode vazar para outro.

## 18. Transporte

Reproduzir:

- tela cheia;
- endereço e ZIP de seis dígitos;
- solicitação regular em dias de semana;
- fim de semana;
- transporte extra por data/hora;
- estados pendente, confirmado, rejeitado, cancelado e realizado;
- veículo, placa, cor, horário e tolerância;
- ciência do usuário;
- cancelamento e histórico;
- estado local de ocultação/realização.

Atualização:

- SSE enquanto app/tela estiver ativo;
- refresh de 30 segundos apenas enquanto houver solicitações ativas e o app puder executar;
- APNs futuro para alterações relevantes, se o backend implementar;
- reconciliação ao foreground;
- backoff e cancelamento corretos.

O plano de teste deve incluir atualização concorrente entre SSE, polling e ação do usuário, impedindo regressão para um estado mais antigo.

## 19. Modo acidente

### 19.1 Fluxo

Portar o wizard:

1. projeto;
2. localização cadastrada ou livre;
3. descrição;
4. Zona de Segurança/Zona de Acidente;
5. “OK”/“Preciso de ajuda”;
6. confirmação e envio idempotente.

Reproduzir tema vermelho, avisos, fila de ciência, consulta de acidentes e acionamento do serviço de emergência pelo backend.

### 19.2 Atualização e alerta

- SSE e polling de 30 segundos em foreground quando houver acidente;
- APNs alert para novos acidentes e mudanças críticas;
- BGAppRefresh como reconciliação oportunista;
- consulta ao abrir ou reativar o app;
- deduplicação por ID do acidente e persistência de “já notificado”;
- ação da notificação abre diretamente o contexto correto;
- conteúdo da lock screen minimiza exposição de dados sensíveis.

O worker Android de 15 minutos não pode ser prometido como periodicidade no iOS. APNs é a principal mitigação e constitui dependência de backend para equivalência adequada.

### 19.3 Vídeo

Usar AVFoundation com:

- câmera traseira;
- resolução equivalente ao HD Android, validada por aparelho;
- áudio;
- orientação correta;
- preview e estados de gravação;
- limites de duração/tamanho definidos;
- tolerância a interrupção por ligação, falta de espaço e revogação de permissão;
- arquivo temporário protegido;
- upload com progresso e idempotency key;
- `URLSessionConfiguration.background` para continuar transferência a partir de arquivo;
- restauração do delegate após relançamento;
- exclusão somente após confirmação real do servidor;
- opção clara de tentar novamente em falha.

A UI jamais deverá mostrar sucesso apenas porque a função terminou. Deve verificar status HTTP, payload e resultado de negócio.

> **Nota de fidelidade (D4 — `decision_log.md`):** no Android atual esse resultado não é inspecionado — a UI mostra “enviado” mesmo em falha e o MP4 temporário **vaza** no cache (não há exclusão prematura, ao contrário do que o `preliminar_plan.txt` sugeria). O iOS deve corrigir: estado de erro em `.failure`, exclusão somente em sucesso confirmado e limpeza/retenção explícita do temporário para re-tentativa.

## 20. Notificações

Definir categorias e ações, no mínimo:

- atividade automática concluída;
- reautenticação necessária;
- permissão degradada;
- acidente novo;
- acidente aguardando ciência;
- transporte atualizado, se aprovado;
- fila offline sincronizada, se configurado.

Requisitos:

- pedir autorização em contexto;
- respeitar preferências locais;
- foreground presentation deliberada;
- deep links autenticados e validados;
- deduplicação;
- cooldown de reautenticação de uma hora;
- conteúdo localizado;
- nenhum segredo, coordenada precisa ou descrição sensível desnecessária na tela bloqueada;
- badge somente se possuir semântica definida;
- teste de token APNs em sandbox e produção.

## 21. Segurança

### 21.1 Modelo de ameaça mínimo

Considerar:

- aparelho perdido ou bloqueado;
- backup/restauração em outro aparelho;
- leitura de logs;
- interceptação de tráfego;
- replay de atividade;
- troca de conta;
- resposta perdida do servidor;
- banco/arquivo corrompido;
- vídeo residual;
- token APNs órfão;
- abuso de deep link/notificação;
- dependência comprometida.

### 21.2 Controles

- ATS/TLS sem HTTP claro;
- Keychain para senha, sessão e chaves;
- itens sensíveis `ThisDeviceOnly` quando apropriado;
- CryptoKit para fila sensível;
- Data Protection em banco, fila e vídeo;
- idempotência de ponta a ponta;
- validação de schema e limites de entrada;
- nenhuma senha/cookie/token em `OSLog`;
- coordenadas privadas nos logs;
- limpeza de clipboard se alguma função o usar;
- deep links com allowlist e verificação de estado;
- arquivos temporários em diretório apropriado e lifecycle explícito;
- revisão de dependências e SBOM se alguma for adicionada;
- segregação de ambientes e segredos fora do repositório.

Certificate pinning não é requisito inicial: introduzi-lo sem rotação segura pode indisponibilizar o app. Se adotado, exigirá estratégia de múltiplas chaves, expiração, observabilidade e escape operacional.

## 22. Privacidade, transparência e App Store

### 22.1 Política e consentimento

Preservar e revisar juridicamente:

- controlador Tamer Salmem;
- hospedagem em Singapura;
- idade mínima de 18 anos;
- ausência de publicidade, analytics e tracking SDKs;
- canal de privacidade;
- finalidade e retenção de localização, atividade e vídeo;
- exclusão local e remota;
- consentimento destacado para localização contínua.

O consentimento deve ser granular, revogável e versionado. Revogar o automático deve interromper sessões de localização e remover monitoramentos quando apropriado.

### 22.2 Privacy Manifest e rótulos

Criar `PrivacyInfo.xcprivacy` e auditar:

- tipos de dados coletados;
- vínculo com a identidade;
- finalidade de funcionalidade;
- ausência de tracking;
- required reason APIs efetivamente usadas;
- manifests de qualquer SDK externo.

Preparar respostas do App Store Connect para, conforme comportamento final:

- localização precisa;
- identificadores/conta;
- informações de contato/cadastro;
- conteúdo do usuário, incluindo descrição e vídeo de acidente;
- diagnósticos, apenas se enviados ao servidor;
- demais dados realmente coletados.

Dados processados apenas no aparelho serão distinguidos de dados transmitidos. A política pública precisa corresponder ao binário e às respostas da loja.

### 22.3 App Review

Preparar um pacote de revisão contendo:

- conta de demonstração funcional;
- instruções para habilitar o automático;
- vídeo mostrando a função legítima de localização em background;
- explicação objetiva dos Background Modes;
- justificativa de negócio para “Sempre”;
- endpoint de staging/produção disponível;
- passos de acidente sem disparar emergência real;
- política de privacidade pública;
- contatos de suporte;
- notas sobre qualquer hardware/condição externa.

O uso de background deve atender ao propósito declarado. Não serão habilitados modos de background apenas para manter o processo vivo.

## 23. Internacionalização

Idiomas obrigatórios:

- português;
- inglês;
- chinês;
- malaio;
- indonésio;
- tagalog/filipino.

Plano:

- migrar as chaves, não copiar apenas strings visíveis;
- usar String Catalog (`.xcstrings`);
- separar texto de formatação;
- pluralização e interpolação tipadas;
- localizar permissões do `Info.plist`, notificações e atalhos;
- testar expansão de texto e caracteres chineses;
- definir idioma de fallback;
- comparar cobertura automaticamente entre catálogos;
- revisão humana de textos críticos, especialmente privacidade, acidente e permissões.

## 24. Observabilidade e diagnóstico

### 24.1 Log local

Manter limite de 30 dias ou 5.000 registros, com poda determinística. Categorias:

- ciclo de vida;
- autenticação;
- permissão;
- localização;
- gatilho de background;
- avaliação automática;
- decisão;
- fila/replay;
- notificação;
- APNs;
- acidente;
- transporte;
- upload;
- persistência.

Logs devem registrar IDs opacos, durações, precisão categorizada e códigos de resultado, sem senha, cookie, vídeo, descrição sensível ou coordenadas exatas.

### 24.2 Registro de avaliação

Cada tentativa automática deve responder:

- quando e por que começou;
- estado da autorização;
- se estava em pausa;
- se foi coalescida;
- qualidade/idade da posição sem expor coordenada;
- resposta categórica do matcher;
- decisão tomada;
- envio, fila ou erro;
- tempo total;
- prazo restante da tarefa do sistema.

### 24.3 Telemetria remota

O Android declara ausência de analytics. Portanto, não será adicionado analytics remoto implicitamente. Qualquer telemetria operacional futura exigirá decisão de privacidade, minimização, política, consentimento quando aplicável e atualização dos rótulos.

## 25. Qualidade e estratégia de testes

### 25.1 Testes unitários

- portar 1:1 os testes das regras Kotlin;
- senha e estado do cliente;
- pausa programada;
- cache e validade temporal;
- seleção/priorização de até 20 regiões;
- coalescência e single-flight;
- parsing de cookies, JSON, datas e erros;
- fila, criptografia, limite, replay e migração;
- deduplicação de notificações;
- máquina de estado de transporte e acidente;
- limpeza total de conta;
- clocks, timezones e DST;
- obrigações de teste das decisões de fidelidade D1–D6 ([`decision_log.md`](decision_log.md)): não-desligamento do automático após falha do acidente (D1); gate do cenário de acidente pelo flag real de automático (D2/D7); acidente sem submissão de check-in próprio (D3); estado de erro + preservação do temporário em falha de upload (D4); início do motor apenas com notificações + localização precisa (D5); fila offline vazia após o wipe (D6).

### 25.2 Testes de integração

- URLProtocol/stub server para rede;
- banco real temporário;
- Keychain isolado por target de teste;
- fixtures do servidor;
- upload e restauração de background session;
- contratos contra staging;
- APNs sandbox;
- migração entre versões de schema.

### 25.3 Testes de UI e snapshot

- fluxo de cadastro, aprovação, login e senha;
- check manual e retroativo;
- configurações e permissões;
- histórico;
- transporte;
- acidente e vídeo com doubles seguros;
- manual, sobre e privacidade;
- estados vazio/loading/erro/sucesso;
- snapshots nos seis idiomas;
- iPhone pequeno, médio e grande;
- Dynamic Type, VoiceOver, Reduce Motion e contraste;
- teclado, rotação suportada e interrupções.

### 25.4 Matriz obrigatória de dispositivos reais

O simulador não valida background de localização. Testar aparelhos reais em todas as versões de iOS suportadas, contemplando:

- foreground;
- background imediato;
- tela bloqueada por minutos e por horas;
- app suspenso;
- encerrado pelo sistema;
- encerrado explicitamente pelo usuário;
- reinício antes e depois do primeiro desbloqueio;
- atualização do aplicativo;
- autorização “Durante o Uso” e “Sempre”;
- precisão exata ligada/desligada;
- Localização ligada/desligada;
- notificações ligadas/desligadas;
- Atualização em 2º Plano ligada/desligada;
- Modo Pouca Energia;
- Wi-Fi, celular, troca de rede, modo avião e rede cativa;
- GPS ruim, leitura antiga e salto impossível;
- entrada/saída de região, regiões sobrepostas e zona mista;
- mais de 20 regiões;
- vários gatilhos simultâneos;
- sessão expirada;
- offline curto e de vários dias;
- fila cheia e resposta perdida;
- fuso/DST/relógio alterados;
- pouco armazenamento;
- câmera/microfone interrompidos;
- upload com app bloqueado/encerrado pelo sistema.

### 25.5 Testes de falha e caos

Injetar:

- timeout em cada etapa;
- 401, 403, 409, 422, 429 e 5xx;
- JSON parcial ou campo novo;
- cookie expirado;
- matcher bem-sucedido e envio perdido;
- kill entre decisão e persistência;
- kill entre persistência e resposta;
- banco corrompido;
- Keychain temporariamente indisponível após reboot;
- APNs duplicada, fora de ordem ou expirada;
- SSE desconectado e eventos repetidos;
- mudança de usuário com tarefas em voo.

### 25.6 Energia e desempenho

Usar Instruments, MetricKit quando aprovado e relatórios de campo para medir:

- consumo de localização em 8/12/24 horas;
- wakeups e tempo de CPU;
- rede e volume de payload;
- memória e launch time;
- duração de captura GPS;
- tempo de replay;
- tamanho de banco, fila e logs;
- impacto do SSE/polling;
- aquecimento durante vídeo/upload.

Nenhuma configuração de precisão/intervalo será promovida sem ensaio de autonomia em cenário real.

## 26. Objetivos de serviço e critérios mensuráveis

Os valores abaixo são metas iniciais para homologação, sujeitos a calibração com dados reais:

| Cenário | Meta inicial | Observação |
|---|---:|---|
| Check manual online | confirmação p95 em até 5 s | Exclui indisponibilidade do backend. |
| Avaliação ao retornar ao app | iniciar em até 2 s | Se automático habilitado e sem pausa. |
| Captura precisa | encerrar em até 15 s | Mantém referência Android; aceitar melhor leitura disponível. |
| Fila offline | zero perda em 200 eventos | Inclui encerramento durante escrita. |
| Replay | ordem e idempotência de 100% | Sem duplicação lógica. |
| Gatilho de geofence | medir p50/p95 em campo | Não transformar em garantia absoluta de minutos. |
| Acidente foreground | atualização em até 30 s sem SSE | SSE deve reduzir latência. |
| Acidente background | medir entrega APNs p50/p95 | APNs não é garantia de entrega. |
| Crash-free interno | >= 99,9% das sessões | Antes de rollout amplo. |
| Energia | limite a aprovar em ensaio de turno | Medir contra baseline sem automático. |

Os relatórios devem separar falha do app, indisponibilidade do backend, permissão negada e limitação documentada do sistema.

## 27. CI/CD, assinatura e ambientes

### 27.1 Ambientes

Criar `Debug`, `Staging` e `Release`, com:

- bundle identifiers distintos quando necessário;
- URLs e cabeçalhos em `.xcconfig`;
- APNs sandbox/produção corretos;
- nenhum segredo versionado;
- ícone/nome de staging distinguíveis;
- feature flags somente quando auditáveis.

### 27.2 Pipeline

Em toda mudança:

- format/lint definido pelo projeto;
- build com warnings tratados;
- testes unitários;
- testes de integração selecionados;
- verificação de cobertura da matriz Kotlin/Swift;
- validação de strings ausentes;
- análise estática e secrets scan;
- validação do privacy manifest;
- geração de archive em branches de release.

Em release:

- versão e build automatizados;
- archive assinado;
- testes UI/smoke em aparelhos;
- upload para TestFlight;
- release notes e changelog;
- símbolos de crash armazenados com acesso restrito;
- plano de rollback, sabendo que App Store não permite downgrade automático.

## 28. Fases de execução e gates

### Marco 0 — decisões e baseline

Entregas:

- pacote de referência Android;
- mínimo de iOS e aparelhos suportados;
- bundle ID, conta Apple Developer e modalidade de distribuição;
- staging e contas de teste;
- confirmação de `X-Client: checking-ios`;
- decisão sobre máximo/prioridade de regiões;
- decisão sobre APNs e endpoints de token;
- matriz das ambiguidades Android;
- SLOs e orçamento de energia aprovados;
- autorização de uso dos ativos e marca Petrobras.

Gate: nenhuma dependência externa crítica permanece sem dono e prazo.

### Fase 1 — fundação do projeto

Entregas:

- projeto Xcode e targets;
- configurações de ambiente;
- composição de dependências;
- design system inicial;
- localização base;
- logging, clock e erros;
- CI inicial;
- conventions de testes.

Gate: builds reprodutíveis em CI e aparelho real, sem segredos no repositório.

### Fase 2 — prova técnica de segundo plano

Esta fase ocorre cedo para reduzir o maior risco.

> **Execução em 21/07/2026:** a prova reproduzível no iOS Simulator aprovou atualização contínua de
> localização em background e geofences ENTER/EXIT. BackgroundTasks e push silencioso permaneceram
> inconclusivos por limitações do Simulator. A fase não está concluída até o gate em aparelho físico.
> Evidências e comando: [`background_validation_simulator.md`](background_validation_simulator.md).
>
> **Execução física iniciada em 21/07/2026:** smoke em iPhone 14 Pro/iOS 26.5.2 aprovou login pela UI,
> Keychain, 9 geofences registradas, token APNs sandbox e callbacks contínuos com o app em background e a
> tela bloqueada. A avaliação parcial aprovou a entrega em background de ENTER/EXIT de regiões reais, mas
> detectou um crash no callback de `BGAppRefresh`, perda do relatório anterior após relançamento e atividades
> automáticas desligadas. O primeiro ensaio prolongado foi encerrado como diagnóstico; deve ser reiniciado
> após as correções. Os handlers agora usam fila explícita compatível com Swift 6, o relatório continua entre
> processos, o perfil físico usa geofence + mudanças significativas sem GPS contínuo e a UI exige atividades
> automáticas/projeto válidos. Build corrigido instalado; aguardando o segundo ensaio. Reboot, degradação, push
> e o gate de 24 horas seguem abertos. Evidências:
> [`background_validation_physical.md`](background_validation_physical.md).
>
> **Segundo smoke físico aprovado em 21/07/2026:** quatro ciclos reais de `BGAppRefresh` concluíram sem crash;
> geofences/timer realizaram quatro check-ins coerentes durante deslocamento, com notificações inclusive sob
> tela bloqueada, e a bateria permaneceu em 100% na janela móvel de 24 minutos. ENTERs redundantes do Core
> Location foram deduplicados antes do build de 24 horas. Ressalva: o backend ainda rejeita a mudança para
> `Localização não Cadastrada` quando `X-Client=checking-ios`, embora o motor tenha paridade com o Kotlin.
> O produto confirmou que essa tentativa é obrigatória: não remover nem silenciar o ramo no iOS; homologar o
> cliente iOS no backend com a mesma exceção concedida ao Android.
>
> **Primeiro ensaio prolongado reprovado em 22/07/2026:** o iOS preservou as regiões, relançou o processo três
> vezes e entregou EXIT/ENTER ao coletor, mas o delegate de produção era criado apenas no primeiro `sync` e
> perdeu o evento pendente após relançamento frio. Resultado: sem triggers de geofence nem atividades. O manager
> de produção agora é criado imediatamente na composição do app; 514 testes passaram e o build corrigido foi
> instalado. O consumo estacionário observado (~6,3 pontos percentuais/h, bateria com 75% de saúde) requer
> atribuição pela tela de Bateria e nova amostra controlada.
>
> **Ensaio dirigido de relançamento frio em 22/07/2026:** após encerrar o processo por `SIGTERM` sem force-quit,
> o iOS relançou o app em background na saída do Escritório Principal e o delegate corrigido registrou EXIT de
> duas regiões, `production_geofence_exit` e avaliação GEOFENCE. A causa raiz anterior está, portanto, corrigida.
> Não houve crash. Durante as chegadas ao Escritório Avançado e à Unidade P80, porém, o Core Location não
> entregou ENTER; o harness recebeu mudanças significativas às 08:20 e 08:27, mas elas não acionaram o negócio.
> Auditoria confirmou que `startMonitoringSignificantLocationChanges` ainda existe apenas no harness Debug,
> embora a Camada B deste plano determine seu uso em produção. O check-in do P80 ocorreu somente quando um
> `BGAppRefresh` discricionário executou às 09:06; no Principal, o ENTER gerou check-in imediato às 09:14.
> Próxima correção obrigatória antes de novo ensaio prolongado: monitor de mudanças significativas de produção,
> restauração fria e encaminhamento single-flight ao orquestrador, com gatilho distinguível nos diagnósticos.
>
> **Correção da Camada B instalada em 22/07/2026:** o novo monitor de produção nasce cedo, restaura apenas com
> chave/consentimento/automático/projeto elegíveis e encaminha callbacks como `SIGNIFICANT_LOCATION` ao mesmo
> orquestrador. Troca de conta, desativação e exclusão interrompem o serviço. Sete testes direcionados e a suíte
> completa de 519 testes passaram. O build físico assinado foi instalado preservando os dados. No smoke real
> das 09:36:48, o iPhone registrou `production_significant_location`, executou
> `Background evaluation (SIGNIFICANT_LOCATION)`, obteve match do local atual e concluiu a matriz sem ação
> duplicada. Resta repetir o percurso com o app suspenso ou relançado e aferir latência/energia.

Entregas:

- app mínimo com escada de permissão;
- geofence de staging;
- mudança significativa;
- sessão de localização em background;
- relançamento/restauração;
- BGAppRefresh e BGProcessing instrumentados;
- APNs sandbox mínimo;
- relatório de 24 horas em dispositivos reais;
- bateria, latência, force-quit, reboot e precisão reduzida documentados.

Gate: estratégia viável comprovada e limitações aceitas. Se falhar, revisar produto/backend antes de avançar.

### Fase 3 — domínio e regras

Entregas:

- modelos de domínio;
- matriz automática pura;
- pausa programada;
- estado do cliente;
- password rules;
- contratos de repositório;
- portabilidade dos testes Kotlin relevantes.

Gate: 100% dos casos de regra mapeados passam ou possuem divergência formalmente aprovada.

### Fase 4 — rede, sessão e persistência

Entregas:

- API client e DTOs;
- cookie/Keychain;
- autenticação e reautenticação;
- Core Data e migrações;
- fila offline criptografada;
- network monitor como sinal, não fonte absoluta;
- testes de contrato.

Gate: login, sessão expirada, offline/replay e limpeza total aprovados em staging.

### Fase 5 — shell visual, autenticação e tela principal

> **Sub-slice UI-3 executada em 22/07/2026:** a tela definitiva passou a usar o estado e o `CheckViewModel`
> reais após o splash. Foram ligados histórico, avisos, chave/senha/engrenagem, cadastro assistido e troca de
> senha em overlays, preservando a ordem do Android e o acesso `DEBUG` à validação física. Build e inspeção
> visual no iPhone 17 Simulator aprovados; 525 testes unitários e o smoke de UI da árvore inicial passaram.
> A Fase 5 permanece aberta: faltam a tela autenticada completa, ajustes completos, os cinco idiomas adicionais
> e a revisão lado a lado/snapshots nos aparelhos-alvo. A build não foi instalada no iPhone físico para não
> invalidar o ensaio de background em andamento. Detalhes: [`port_spec_ui_design_system.md`](port_spec_ui_design_system.md#18-implementação--tela-inicial-e-autenticação-sub-slice-ui-3-2026-07-22).
>
> **Sub-slice UI-4 executada em 22/07/2026:** a área autenticada agora carrega projetos, catálogo, locais e
> permissões reais; exibe registro Check-In/Check-Out, informe Normal/Retroativo, associação de projetos,
> fallback de local manual e botão de submissão. O envio preserva UUID/timestamp no fallback offline, trata
> expiração de sessão, reconcilia histórico e persiste o projeto ativo para o motor em background. A troca de
> chave também passou a restaurar preferências isoladas por conta. Build/inspeção no iPhone 17 Simulator,
> smoke de UI autenticado e **533 testes unitários** aprovados. A build arm64 assinada para o iPhone conectado
> está pronta, mas não foi instalada para preservar o ensaio atual. Transporte, acidente, nudge/ajustes
> completos e snapshots lado a lado continuam pendentes. Detalhes:
> [`port_spec_ui_design_system.md`](port_spec_ui_design_system.md#19-implementação--registro-manual-localização-e-projetos-sub-slice-ui-4-2026-07-22).
>
> **Sub-slice UI-5 executada em 22/07/2026:** foram integrados nudge por chave, Ajustes agrupados, painel vivo
> de Atividades Automáticas/consentimento/permissões, Pausa Programada, preferências de avisos, confirmação
> destrutiva de remoção e histórico expandido filtrado. Escritas concorrentes de preferências são serializadas
> e preservam projetos; o toggle controla o monitor significativo e reavalia o motor. A suíte aprovou **538
> testes unitários e 6 testes de UI**; a navegação interna dos Ajustes teve um defeito de toque descoberto pelo
> smoke e corrigido antes do build físico. Transporte, acidente e conteúdo/idiomas permanecem fora do candidato.
> Detalhes: [`port_spec_ui_design_system.md`](port_spec_ui_design_system.md#20-implementação--ajustes-operacionais-e-histórico-expandido-sub-slice-ui-5-2026-07-22).
>
> **Sub-slice UI-6 executada em 22/07/2026:** o log de Atividades do Android foi ligado ao store Core Data
> real nos Ajustes, com snapshot, paginação newest-first de 30, agrupamento por dia, cores de severidade,
> carregamento incremental e limpeza protegida contra leituras concorrentes. O conteúdo permanece em inglês
> por especificação do Android. Evidência: **539 testes unitários + 9 testes de UI**, captura e build físico
> instalado. Idiomas e demais conteúdos continuam pendentes.
>
> **Sub-slice UI-7 executada em 22/07/2026:** o grupo Ajuda foi completado com Instruções de Uso, Suporte,
> Sobre e Privacidade. A rota de instruções foi adaptada ao fluxo efetivo do iPhone, com oito capítulos e oito
> capturas nativas reproduzíveis do simulador, sem dados pessoais. Sobre inclui a história e as matrizes
> Web/Nativo; Suporte abre WhatsApp com chave predefinida; Privacidade
> inclui as dez seções LGPD, e-mail/política e wipe local completo, separado da exclusão remota. Navegação
> preserva o `CheckViewModel`. Evidência: **543 testes unitários + 12 testes de UI**, build e inspeção no simulador; detalhes em
> [`port_spec_ui_design_system.md`](port_spec_ui_design_system.md#22-implementação--conteúdo-suporte-e-privacidade-sub-slice-ui-7-2026-07-22).

Entregas:

- splash;
- shell e componentes;
- cadastro/aprovação/senha/login;
- tela principal em todos os estados;
- ajustes básicos;
- snapshots de referência.

Gate: revisão visual lado a lado nos aparelhos-alvo e fluxos de autenticação aprovados.

### Fase 6 — check manual, histórico e projetos

> **Execução parcial em 22/07/2026:** o núcleo de check manual normal/retroativo, seleção de projeto/local,
> idempotência, fila offline, mensagens e atualização do histórico foi integrado na UI-4. O gate permanece
> aberto até os roteiros reais de sucesso/erro/offline no iPhone e comparação Android. O histórico expandido
> foi concluído na UI-5 com estados loading/vazio/erro/retry.

Entregas:

- check normal/retroativo;
- seleção de projeto/local;
- histórico;
- mensagens e erros;
- idempotência;
- fallback manual.

Gate: paridade funcional e visual contra roteiro Android.

### Fase 7 — motor automático completo

Entregas:

- orquestrador single-flight;
- todos os gatilhos em camadas;
- matcher/estado/decisão;
- cache e filtro de movimento;
- regiões priorizadas;
- pausa programada;
- notificações;
- diagnóstico;
- replay integrado.

Gate: matriz real de background aprovada e orçamento de energia atendido.

### Fase 8 — transporte

> **Decisão de escopo em 22/07/2026:** Transporte foi adiado por decisão do produto e não integra o primeiro
> candidato iOS nem o programa inicial de testes. A interface não deve oferecer controles de Transporte
> inoperantes, mesmo quando a API indicar `transportEnabled`; o domínio e as especificações existentes serão
> preservados para uma etapa posterior. As Fases 9 a 12 prosseguem normalmente, sem depender desta fase.

Entregas:

- todos os tipos e estados de solicitação;
- SSE, polling foreground e reconciliação;
- ciência, cancelamento e histórico;
- persistência local relevante.

Gate: testes de estado concorrente e roteiro completo aprovados.

### Fase 9 — acidente e vídeo

> **Execução funcional em 22/07/2026:** o estado/contrato de Acidentes existente foi conectado à tela
> principal com banner, consulta de zona, confirmações, ciência, ações, emergência e wizard de cinco passos.
> A captura agora é AVFoundation real (traseira + microfone, MP4 HD e preview), aguarda a finalização do
> contêiner e envia por background URLSession restaurável a partir de arquivo protegido. Falhas mantêm a
> gravação, oferecem retry e reutilizam a idempotency key; sucesso só é exibido após HTTP e JSON válidos.
> Notificações locais/APNs possuem categoria, ação de abertura, reconhecimento de payload e reconciliação.
> Build e testes direcionados estão verdes, incluindo dois roteiros de UI. Permanecem para o gate: endpoint
> backend de device token APNs, ensaio seguro em staging/iPhone, capturas finais e capítulo 5 do manual.

Entregas:

- wizard e tema;
- consulta/SSE/polling;
- APNs e deep link;
- fila de ciência;
- emergência via backend;
- gravação e upload em background;
- tratamento real de sucesso/erro.
- concluir o capítulo `5. Reportar Acidente` das Instruções de Uso somente depois da implementação e da
  homologação, cobrindo: abertura do fluxo, situação e zona de segurança, vídeo e upload, notificações, chamada
  de emergência, estados de erro/sucesso, encerramento e advertências operacionais; produzir capturas nativas
  com doubles seguros, sem disparar um acidente ou serviço real durante a documentação.

Gate: ensaio ponta a ponta em ambiente seguro, sem acionar serviço real indevidamente.

### Fase 10 — conteúdo, privacidade e acessibilidade

> **Execução parcial em 22/07/2026 (UI-7):** manual, Sobre, Suporte e a superfície LGPD em português estão
> implementados e integrados, incluindo os canais externos e a limpeza local testada. Permanecem abertos os
> cinco idiomas adicionais, auditoria completa de acessibilidade/contraste/Reduce Motion, rótulos finais de
> privacidade e revisão jurídica/editorial para publicação. A revisão deve também confirmar no backend a regra
> informada de 45 dias sem atividade para desligamento de projetos e a deduplicação diária do FORMS; defaults de
> DTO não serão tratados como regra de negócio.
>
> **Auditoria de Privacy Manifest em 22/07/2026:** além de localização precisa, identificador e conteúdo
> livre, o manifesto passou a declarar explicitamente nome, e-mail, fotos/vídeos e áudio, todos vinculados ao
> usuário, apenas para funcionalidade e sem tracking. O plist foi validado. A mesma matriz deverá ser
> reproduzida no App Store Connect e revisada pelo responsável jurídico antes da publicação.
>
> **Internacionalização estrutural e acessibilidade em 22/07/2026:** os seis dicionários canônicos do Kotlin
> foram convertidos para catálogos Swift planos por um gerador reproduzível (3.158 traduções), com resolução
> de variantes/aliases, detecção do idioma preferido do iPhone, fallback por chave para português e tradução
> de mensagens conhecidas da API. Ajustes agora oferece um seletor persistente para português, inglês, chinês,
> malaio, indonésio e tagalog/filipino; a troca para inglês foi validada por UI test. As quatro mensagens de
> permissão do sistema possuem `InfoPlist.strings` nos seis idiomas e foram verificadas dentro do bundle.
> A tipografia passou a usar estilos semânticos com Dynamic Type; histórico, escolhas, seletores e botões se
> reorganizam/crescem sem alturas rígidas. A auditoria XCTest aprovou detecção de elementos, regiões de toque,
> descrições, Dynamic Type, corte de texto e traits. Os pares de cor foram aprovados por cálculo WCAG AA; o
> teste de contraste visual do XCTest foi substituído por esse cálculo porque gera falsos positivos nos glows
> translúcidos do SwiftUI. Permanecem abertos: traduzir/revisar os textos exclusivos do iOS que hoje usam
> fallback português (principalmente o manual novo, privacidade e adições de Acidente), VoiceOver manual e
> revisão humana dos seis idiomas. Reduce Motion já elimina o desenho/fade do splash e reduz sua espera, mas
> ainda será confirmado no roteiro assistivo em aparelho.
>
> **Fechamento editorial do inglês em 22/07/2026:** os textos exclusivos do iPhone receberam uma camada
> editorial inglesa completa, incluindo o novo manual ilustrado, permissões operacionais, Suporte e todas as
> adições funcionais de Acidentes. A cobertura deixou de depender do fallback português para as 455 chaves
> editoriais nativas do iOS. Testes automatizados agora falham se uma nova chave portuguesa não possuir versão
> inglesa própria ou se os tokens de interpolação divergirem; um roteiro de UI abre diretamente o manual em
> inglês e valida título, introdução, capítulos e navegação. Chinês, malaio, indonésio e tagalog/filipino
> continuam com os catálogos canônicos do Android e fallback seguro para o conteúdo exclusivo do iPhone;
> esses quatro idiomas só serão declarados completos após tradução editorial e revisão humana, especialmente
> dos textos jurídicos, de privacidade e segurança. Evidência do bloco: **560 testes unitários e 18 testes de
> UI aprovados**, sem falhas.
>
> **Catálogos editoriais adicionais em 22/07/2026:** as 288 chaves específicas do iPhone que ainda não
> existiam em cada catálogo Android receberam versões preliminares em chinês simplificado, malaio, indonésio
> e tagalog/filipino, totalizando **1.152 traduções novas**. O artefato Swift é estático e o aplicativo não usa
> tradução online em tempo de execução. Marcas e tokens de interpolação são protegidos durante a geração;
> testes exigem cobertura nativa das 455 chaves editoriais em cada um dos seis idiomas, igualdade dos tokens e
> ausência de marcadores internos. Um roteiro de UI abre o manual nos quatro idiomas e valida título,
> introdução e navegação. Esta entrega elimina o fallback português nas superfícies editoriais, mas **não
> encerra a revisão linguística**: as traduções geradas são rascunhos de engenharia e os textos de LGPD,
> consentimento, privacidade, emergência e segurança precisam de revisão por pessoas fluentes e pelo
> responsável jurídico antes da publicação. Evidência do bloco: **561 testes unitários e 19 testes de UI
> aprovados**, sem falhas.
>
> **Hardening assistivo em 22/07/2026:** a árvore de acessibilidade passou a isolar conteúdo sob diálogos,
> usar botões semânticos reais em Ajustes, anunciar seleção e valores de projetos/locais/permissões, publicar
> avisos operacionais e de Acidente ao VoiceOver, agrupar bullets/anotações e expor títulos no rotor de
> cabeçalhos. Chave, senha, cabeçalhos, permissões, horários, histórico e ações de Acidente receberam layouts
> adaptativos; no tamanho máximo `Accessibility 5`, o histórico vira uma lista vertical rotulada e os controles
> que competiam horizontalmente são empilhados. O splash usa fontes escaláveis e uma política testável que
> remove animação e espera longa com Reduce Motion. As auditorias estruturais passaram na tela principal em
> tamanho normal e, no tamanho máximo, em tela principal, Ajustes, manual, Atividades Automáticas, histórico e
> wizard de Acidentes. Evidência: **562 testes unitários e 26 testes de UI aprovados**, sem falhas. O gate ainda
> exige a execução humana no iPhone do roteiro
> [`accessibility_validation.md`](accessibility_validation.md), pois automação não comprova pronúncia, conforto
> auditivo, gestos reais nem retorno subjetivamente lógico do foco.

Entregas:

- manual, sobre e privacidade;
- seis idiomas completos;
- painel de integridade;
- log de atividades/avaliações;
- VoiceOver, Dynamic Type, contraste e Reduce Motion;
- privacy manifest e rótulos preliminares.

Gate: zero string obrigatória ausente e auditoria de acessibilidade/privacidade aprovada.

### Fase 11 — hardening e homologação

Entregas:

- matriz completa de dispositivos reais;
- testes de caos;
- ensaio de turno e 24 horas;
- profiling de bateria, CPU, rede e armazenamento;
- pentest/revisão de ameaça proporcionais;
- correção de P0/P1;
- documentação operacional e suporte.

Gate: Definition of Done integral atendida.

### Fase 12 — TestFlight, App Review e rollout

> O primeiro piloto será iniciado somente após a conclusão e o hardening das demais funcionalidades deste
> ciclo. Seu escopo funcional excluirá Transporte de forma explícita nas notas do build e nos roteiros de
> teste. Testes automatizados, inspeções técnicas e builds em aparelhos continuam obrigatórios durante o
> desenvolvimento; apenas o programa de testes com usuários fica postergado.

Entregas:

- piloto interno;
- piloto de campo controlado;
- coleta de diagnóstico consentida;
- pacote de App Review;
- publicação gradual;
- runbook de incidente e rollback;
- acompanhamento das versões de iOS suportadas.

Gate: estabilidade e SLOs atendidos no piloto antes de ampliar usuários.

## 29. Divergências e ambiguidades a resolver antes do port

**Status: RESOLVIDO (2026-07-14).** As seis ambiguidades foram verificadas contra o código atual por auditoria de ground-truth (todas confirmadas, com evidência `arquivo:linha`) e decididas pelo produto. O registro completo — dono, data, evidência, comportamento Android e resultado adotado no iOS — está em [`ios/docs/decision_log.md`](decision_log.md). Resumo:

| # | Item encontrado no Android | Verificação | Decisão adotada no iOS | Natureza |
|---|---|---|---|---|
| D1 | Callback de acidente contém `TODO` ao desligar automático | Confirmado — no-op/código morto (`CheckScreen.kt:119`) | **Não desligar** o automático após falha (fiel à produção) | Replicar |
| D2/D7 | Cenário passa `state.userProjects != null` (e a VM hardcoda `true`) onde se espera o estado do automático | Confirmado (`CheckScreen.kt:257`, `AccidentViewModel.kt:81`) | **Passar o flag real** `automaticActivitiesEnabled` | Corrigir |
| D3 | “Auto-checkin do acidente” apenas consulta novamente | Confirmado — detect-and-wait passivo, desacoplamento intencional | **Manter passivo** (não submete check-in nem aciona o motor) | Replicar |
| D4 | Upload de vídeo não verifica `AppResult` na UI | Confirmado (falso sucesso); o defeito de arquivo é **vazamento** do temporário na falha, **não** exclusão prematura | **Inspecionar o Result**: sucesso só em `.success`; deletar o temporário só em sucesso e limpar/reter em falha | Corrigir |
| D5 | Comentários divergem da permissão realmente mínima | Confirmado — gate real = notificações + localização precisa (`PermissionLadder.kt:49-50`) | **Espelhar o comportamento atual**; “Always” recomendado (degradado no iOS sem ele) | Replicar |
| D6 | Limpeza local não evidencia remoção da fila separada | Confirmado — Room **é** limpo; a única residual é a **fila offline cifrada** | **Wipe completo**, incluindo a fila offline cifrada (expor `clear()`) | Corrigir |

Cada decisão possui uma obrigação de teste correspondente (ver §25.1 e `decision_log.md`).

## 30. Registro de riscos

| Risco | Impacto | Mitigação | Gate/dono |
|---|---|---|---|
| iOS suspender execução e não respeitar periodicidade | Crítico | Estratégia orientada por localização, APNs, reconciliação e comunicação transparente. | Prova técnica/Fase 2 |
| Usuário negar “Sempre” ou precisão exata | Alto | Escada contextual, painel de integridade e fallback manual. | Produto + UX |
| Mais de 20 geofences | Crítico | Limite do backend ou ranking determinístico auditável. | Backend/Marco 0 |
| Force-quit impedir relançamento | Alto | Não prometer; informar estado e reconciliar na abertura. | Produto + suporte |
| Rejeição na App Review por background | Crítico | Uso legítimo, capabilities mínimas, vídeo e notas de revisão. | Release |
| Backend sem APNs | Crítico para acidente | Implementar token e push antes da homologação. | Backend/Fase 2 e 9 |
| Backend não reconhecer cliente iOS | Crítico | Homologar `checking-ios` e contratos. | Backend/Marco 0 |
| Consumo excessivo de bateria | Alto | Eventos, rajadas de precisão e ensaios de turno. | Mobile/Fase 7 |
| SSE tratado como background confiável | Alto | APNs + polling/reconciliação; SSE apenas ativo. | Arquitetura |
| Fila duplicar eventos após resposta perdida | Alto | UUID e idempotência ponta a ponta. | Backend + mobile |
| Dados inacessíveis antes do primeiro unlock | Médio | Estado explícito e acessibilidade Keychain/Data Protection apropriada. | Segurança |
| Vazamento de localização/log/vídeo | Crítico | Criptografia, redaction, retenção e limpeza testada. | Segurança/privacidade |
| Upload interrompido | Alto | Background URLSession a partir de arquivo e restauração. | Fase 9 |
| Fuso horário alterar pausa/retroativo | Alto | Clock injetável, UTC e testes DST/fuso. | Domínio |
| Deriva visual | Médio | Tokens, snapshots e revisão lado a lado. | Design/Fase 5 |
| Deriva da API | Alto | Fixtures e contract tests em CI/staging. | Backend + mobile |
| Nova versão do iOS mudar comportamento | Alto | Matriz beta, dispositivos reais e feature switches controladas. | Manutenção |
| Ativo de marca sem autorização | Alto | Verificação jurídica antes da distribuição. | Produto/Marco 0 |

## 31. Definition of Done da primeira versão

A conversão será considerada pronta somente quando:

- todos os fluxos do inventário Android estiverem implementados ou formalmente excluídos;
- regras Kotlin estiverem mapeadas e os testes Swift correspondentes aprovados;
- capturas de referência atenderem à tolerância visual definida;
- os seis idiomas estiverem completos e revisados;
- automático funcionar na matriz aprovada de dispositivos/estados;
- limitações inevitáveis do iOS estiverem corretas na UX e documentação;
- geofences acima do limite tiverem política explícita;
- operação offline não perder nem duplicar eventos lógicos;
- limpeza de conta remover todo dado local, inclusive fila e arquivos;
- alertas de acidente por APNs estiverem homologados;
- upload de vídeo sobreviver aos cenários suportados e nunca indicar falso sucesso;
- privacidade, Info.plist, capabilities e App Store labels corresponderem ao comportamento real;
- acessibilidade crítica estiver aprovada;
- bateria e desempenho atenderem ao orçamento;
- não houver defeitos P0/P1 abertos;
- TestFlight de campo atingir os SLOs;
- runbooks de suporte, incidente, token APNs e backend estiverem disponíveis.

## 32. Questões que precisam de decisão

Estas questões não impedem o início da fundação, mas impedem o fechamento de escopo/release:

1. Qual será o mínimo de iOS e a lista de iPhones suportados?
2. A distribuição será App Store pública, Custom App via Apple Business Manager, ad hoc ou interna?
3. Qual Apple Developer Team, bundle ID e ownership de certificados/APNs serão usados?
4. Existe ambiente de staging completo e seguro para acidente/emergência?
5. O backend aceitará `X-Client: checking-ios` com as mesmas regras do Android?
6. Quantas áreas um usuário pode receber hoje? Quem define a prioridade acima de 20?
7. O backend implementará APNs e lifecycle de device token?
8. A organização aceita o indicador visual de localização e o custo energético de uma sessão contínua, se necessária?
9. Qual latência real é aceitável para check automático e alerta de acidente?
10. A pausa usa fuso do aparelho, do projeto ou do servidor?
11. Replay durante uma pausa pode enviar evento decidido anteriormente?
12. Qual o limite de duração/tamanho do vídeo e a política de retenção?
13. Quais dados de diagnóstico podem ser compartilhados com suporte?
14. A marca Petrobras e os ativos fornecidos estão autorizados no app iOS?
15. Como devem ser resolvidas as seis ambiguidades da seção 29?

## 33. Referências oficiais da Apple

Estas fontes sustentam as decisões de plataforma e devem ser revalidadas no início da implementação, pois APIs e regras da loja evoluem:

- [Handling location updates in the background](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Choosing the Location Services authorization to request](https://developer.apple.com/documentation/corelocation/choosing-the-location-services-authorization-to-request)
- [Requesting authorization to use Location Services](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services)
- [Monitoring proximity to geographic regions](https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)
- [Significant-change location service](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges%28%29)
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [Choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [Using background tasks to update your app](https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app)
- [Pushing background updates to your app](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Registering your app with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns)
- [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Requesting authorization to capture and save media](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
- [Keychain accessibility after first unlock, this device only](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing use of required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 34. Próximo passo recomendado

Executar o **Marco 0** e, em seguida, a **Fase 2 — prova técnica de segundo plano** antes da implementação integral da interface. O primeiro artefato técnico deve ser um protótipo instrumentado, instalado em iPhones reais, capaz de demonstrar geofence, mudança significativa, sessão de localização, relançamento, BGTask e APNs nas condições da matriz.

O resultado dessa prova definirá a configuração final de precisão, distância, energia e expectativa de latência. Somente então o comportamento de background deve ser congelado como contrato de homologação da versão iOS.
