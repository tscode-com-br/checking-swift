# Fase 2 — validação de background no iOS Simulator

> Data da execução: 21 de julho de 2026  
> Ambiente: Xcode 26.5, iOS Simulator 26.5, iPhone 17  
> Bundle: `br.com.tscode.checking.debug`  
> Resultado do gate: **parcialmente aprovado no simulador; aparelho físico continua obrigatório**

## Objetivo

Exercitar, de forma reproduzível a partir do terminal integrado do VS Code, os mecanismos de background
que o iOS Simulator consegue representar:

- autorização de localização “Sempre” e precisão completa;
- transição SwiftUI para background;
- atualização contínua de localização em background;
- monitoramento de região com entrada e saída;
- registro/submissão de BackgroundTasks;
- registro APNs e push silencioso simulado;
- persistência de evidências fora do processo.

Esta execução não substitui a matriz obrigatória em iPhone físico definida no plano. O simulador não
reproduz rádio/GPS, políticas reais de energia, heurísticas de agendamento, suspensão prolongada, reboot,
pressão de memória ou confiabilidade ao longo de um turno.

## Instrumentação

Foi criado um harness compilado somente em `DEBUG`, ativado pelo argumento:

```text
--background-validation
```

O harness:

- configura `CLLocationManager` com `allowsBackgroundLocationUpdates`;
- inicia atualização padrão e mudanças significativas;
- monitora uma região de 250 metros em Singapura;
- registra callbacks e o `applicationState` correspondente;
- registra transições de `scenePhase`;
- registra resultado de `BGTaskScheduler.register` e `submit`;
- registra somente presença/tamanho do token e callback remoto de APNs;
- grava `Documents/background-validation.json` atomicamente, no schema 2, com nomes de evento, chaves e
  valores fechados.
  Identifier/token de região, local, coordenadas e erros brutos são removidos inclusive de reports antigos
  ao relançar o app.

O argumento `--disable-background-validation` desativa a instrumentação. O script sempre o executa na
limpeza, inclusive quando uma asserção falha.

## Cenário executado

1. Gerar o projeto com XcodeGen.
2. Compilar o target Debug.
3. Instalar o aplicativo no iPhone simulado.
4. Conceder `location-always` pelo `simctl`.
5. Posicionar o aparelho fora da região.
6. Abrir o Checking com o harness.
7. Abrir Ajustes para enviar o Checking ao background sem force-quit.
8. Simular deslocamento até o centro da região.
9. Simular deslocamento de saída.
10. Enviar push silencioso com `simctl push`.
11. Ler e validar o relatório JSON no container do aplicativo.

Comando reproduzível:

```bash
cd ios
./scripts/validate_background_simulator.sh
```

Opcionalmente, o UDID de outro simulador pode ser passado como primeiro argumento.

## Resultados observados

| Verificação | Resultado | Evidência |
|---|---|---|
| Build Debug | Aprovado | `xcodebuild` terminou com código 0. |
| Autorização de localização | Aprovado | `authorization=always`, `accuracy=full`. |
| Entrada em background | Aprovado | `scene_phase_background`. |
| Localização contínua em background | Aprovado | Vários `location_update` com `applicationState=background`. |
| Registro da região sintética do harness | Aprovado | `geofence_monitoring_started`; não é confirmação técnica do conjunto candidato por geração. |
| Geofence ENTER | Aprovado | `geofence_enter` em background. |
| Geofence EXIT | Aprovado | `geofence_exit` em background. |
| Mudanças significativas | Parcial | Serviço iniciado; a origem de cada update não pode ser isolada da atualização contínua no simulador. |
| Handlers BGAppRefresh/BGProcessing | Aprovado | Ambos retornaram `register=true`. |
| Submissão de BGAppRefresh | Não validável no Simulator | `BGTaskSchedulerErrorDomain Code=1` (`Unavailable`). |
| Token APNs do Simulator | Aprovado | `apns_device_token_received`, 80 bytes. |
| Push silencioso em background | Inconclusivo | `simctl push` aceitou o payload, mas o callback do app não foi observado. |
| Relançamento por evento de localização | Não validado | Exige cenário próprio e confirmação posterior em aparelho físico. |
| Force-quit | Fora do gate | O iOS não garante relançamento depois de encerramento explícito. |
| Bateria/24 horas | Não validável | O Simulator não representa consumo ou heurísticas reais. |

O erro `BGTaskSchedulerErrorDomain Code=1` é `BGTaskSchedulerErrorCodeUnavailable`. A própria SDK instalada
documenta como causa esperada o aplicativo estar em Simulator, que não suporta background processing.
Por isso, o registro dos handlers foi verificado, mas submissão, expiração e execução permanecem no gate
de aparelho físico.

## Conclusão

O Simulator comprovou que a configuração `UIBackgroundModes=location`, a autorização “Sempre”, a sessão
contínua e a região **sintética do harness** conseguem entregar callbacks enquanto o Checking está em
background. Isso valida o wiring básico de Core Location, não a confirmação por geração do monitor candidato.
Os perfis distribuíveis continuam em `legacyWithDiagnostics`; a prova de `requested → confirmed` do candidato
permanece coberta pelo adapter testável e exige ensaio físico controlado antes de qualquer rollout.

A Fase 2 ainda **não pode ser marcada como concluída**, porque faltam:

- execução em iPhone físico por pelo menos 24 horas;
- medição de consumo energético;
- BGAppRefresh/BGProcessing reais, incluindo expiração;
- APNs sandbox/backend e ciclo completo do device token;
- push silencioso/alert push reais;
- relançamento após encerramento pelo sistema;
- reboot e primeiro desbloqueio;
- precisão reduzida, permissões revogadas e Background App Refresh desligado;
- integração da sessão de background com o usuário autenticado e as regras reais do Checking.

O gate correto é: **PoC do Simulator aprovada para Core Location; Fase 2 física pendente**.
