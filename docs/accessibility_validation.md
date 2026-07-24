# Homologação assistiva no iPhone

## Objetivo

Validar com uma pessoa, em aparelho físico, o que a automação não consegue comprovar: pronúncia, clareza das
mensagens, ordem percebida, navegação por gestos e ausência de armadilhas de foco. Este roteiro não aciona
acidente, chamada de emergência, exclusão de conta ou atividade real.

## Preparação

1. Instalar uma build `Debug` apontada para fixtures ou ambiente seguro.
2. Em **Ajustes › Acessibilidade**, configurar o Atalho de Acessibilidade para VoiceOver.
3. Manter disponíveis português, inglês e chinês; fazer ao menos um smoke adicional em malaio, indonésio e
   tagalog/filipino.
4. Repetir o roteiro em um iPhone de tela menor e em um aparelho da geração-alvo do piloto.
5. Registrar modelo, versão do iOS, idioma, tamanho de texto, resultado e evidência de cada falha.

## Roteiro VoiceOver

- Ativar VoiceOver antes de abrir o Checking e confirmar que o splash não prende o foco.
- Percorrer a tela principal com deslizes para a direita: cabeçalho, históricos, mensagens, localização,
  credenciais, Ajustes, registro, assiduidade, projetos, local, Registrar e Reportar Acidente devem seguir a
  ordem visual.
- Confirmar que senha autenticada é anunciada como salva e protegida, nunca lida em voz alta.
- Confirmar que Check-In/Check-Out, Normal/Retroativo, projetos e locais anunciam o estado selecionado.
- Abrir cada seletor, alterar uma opção e confirmar que o novo valor é anunciado.
- Abrir Ajustes e confirmar que o foco não alcança os controles da tela principal enquanto o diálogo estiver
  aberto. Repetir em Atividades Automáticas, Pausa Programada, Notificações, histórico e Acidentes.
- Usar o rotor **Cabeçalhos** no manual, Sobre e Privacidade; todos os capítulos devem ser alcançáveis sem
  percorrer cada parágrafo.
- Confirmar que bullets e anotações de imagem são lidos como frases completas, sem anunciar a bolinha ou a
  imagem decorativa separadamente.
- Provocar somente mensagens seguras de sucesso, atenção e erro e confirmar o anúncio automático sem
  repetição excessiva.
- No fluxo seguro de Acidentes, validar projeto, local, descrição, situação, botões e confirmação. Não enviar
  um acidente real, não iniciar gravação operacional e não acionar serviço de emergência.
- Fechar cada diálogo e confirmar que o foco retorna a um ponto lógico da tela anterior.

## Dynamic Type e layout

- Em **Ajustes › Acessibilidade › Tela e Tamanho do Texto › Texto Maior**, selecionar o maior tamanho.
- Verificar tela principal, Ajustes, Atividades Automáticas, Pausa Programada, histórico, manual, Privacidade e
  wizard de Acidentes.
- Critério: nenhum texto cortado, sobreposto ou reduzido artificialmente; controles devem continuar com área
  tocável suficiente e o conteúdo completo deve permanecer alcançável por rolagem.
- No histórico, confirmar a apresentação vertical com rótulos de Data, Hora, Atividade e Local.

## Reduce Motion

- Ativar **Reduzir Movimento**, encerrar e abrir o aplicativo.
- Confirmar que o checkmark do splash aparece no estado final, sem desenho animado, e que a espera é curta.
- Confirmar que abertura e fechamento de conteúdo não causam deslocamentos ou fades desconfortáveis.

## Critério de aprovação

O gate humano fecha somente quando não houver bloqueio de navegação, foco fora de modal, informação dependente
apenas de cor, senha exposta, ação sem nome, texto truncado ou anúncio operacional incompreensível. Falhas de
segurança, Acidentes, autenticação e registro são P0/P1 e impedem o piloto.
