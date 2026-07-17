# Spec de porte — UI & Design System

> Especificação de fidelidade visual para portar a interface do Android (Jetpack Compose) para iOS (SwiftUI), com paridade de tokens. **Reproduzir os tokens e a composição — não substituir por `Form`/componentes padrão** (plano §3.2).
> Base: Android `1.6.5` / `versionCode 24`. A referência é a hierarquia Compose + tokens (as imagens do manual são capturas do Checking Web, não do Android). Verificado por leitura direta de todo `presentation/theme` + `CheckScreen` + splash (2026-07-15).
> Cross-ref: tema de acidente ↔ [port_spec_accident_video.md](port_spec_accident_video.md) §9; ordem da tela ↔ specs de auth/check; i18n dos textos → spec de i18n. UI **sem testes unitários portáveis** (só smoke tests de instrumentação) → validar por **snapshot** (§14).

Fontes: [Color.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/theme/Color.kt) · [Tokens.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/theme/Tokens.kt) · [Type.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/theme/Type.kt) · [Theme.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/theme/Theme.kt) · [AppFonts.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/theme/AppFonts.kt) · [AppSplashScreen.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/splash/AppSplashScreen.kt) · [CheckScreen.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/check/CheckScreen.kt) · [CheckCard.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/presentation/components/CheckCard.kt)

---

## 1. Abordagem

Criar um **design system SwiftUI próprio** (não `Form`): `enum Tokens` de dimensões, `Color` semânticas, `Font` derivadas, e componentes reutilizáveis espelhando os Compose. Cores em `Color(hex:)` (helper) ou Asset Catalog. Aparência **clara consistente** (decisão posterior sobre dark mode).

## 2. Tokens de cor (ARGB hex exato → SwiftUI `Color`)

| Token | Hex | Papel |
|---|---|---|
| `CheckingPrimary` / `CheckingTeal` / `CheckingHeaderBg` | `#0F766E` | verde-petróleo (primary, header, splash bg) |
| `CheckingPrimaryDark` | `#115E59` | teal escuro (gradiente/hover, onPrimaryContainer) |
| `CheckingAccentBgSoft` / `CheckingTealLight` | `#CCFBF1` | primaryContainer / teal-light |
| `CheckingAccident` | `#C8222A` | vermelho de acidente/emergência |
| `CheckingTextStrong` | `#0F172A` · `…StrongAlt` `#1F2937` | texto forte |
| `CheckingTextMuted` `#475569` · `…Light` `#64748B` · `…Soft` `#94A3B8` | — | texto suave |
| `CheckingSuccess` `#166534` · `Warning` `#92400E` · `Error` `#B42318` · `ErrorVivid` `#FF0000` | — | estados |
| `CheckingActivityWarning` `#EA580C` · `ActivityInfo` `#1E40AF` | — | severidade do log |
| `CheckingSurfaceStart` `#F7F8FA` · `SurfaceEnd` `#EEF2F7` | — | gradiente de fundo |
| `CheckingOnPrimary` `#FFFFFF` · `CardBg` `#FFFFFF` | — | branco |
| `CheckingCardTint` `#F8FAFC` | — | painel interno (era `rgba(248,250,252,0.9)` **achatado**) |
| `CheckingDivider` `#E2E8F0` · `InputBg` `#F8FAFC` · `InputBorder` `#CBD5E1` | — | divisores/inputs |
| **glow chave/senha:** `FieldPendingBorder` `#F97316` · `PendingGlow` `#FB923C` · `AuthedBorder` `#16A34A` · `AuthedGlow` `#22C55E` | — | laranja=pendente, verde=autenticado |
| `CheckingChoiceSelectedBg` `#E6F2F0` (era `rgba(15,118,110,0.08)`) | — | escolha selecionada |
| `TransportChoiceBgStart` `#9ED8FF` · `End` `#6BBDFF` · `Border` `#7DC8FF` | — | acentos de transporte |
| `CheckingLatestBorder` `#16A34A` · `LatestBg` `#DCFCE7` (era `rgba(…,0.76)`) | — | destaque "última atividade" |
| `CheckingLocationSuccess` `#0F766E` · `Error` `#B42318` · `Muted` `#94A3B8` | — | valor de localização |
| acidente rows: `Red #FF0000` · `Yellow #FFFF00` · `Turquoise #00CED1` · `LightGreen #90EE90` · `LightGray #D3D3D3` · `LightBlue #ADD8E6` | — | acentos (se a tabela de situação aparecer) |

> **Alpha achatado:** `CardTint` (0.9), `ChoiceSelectedBg` (0.08), `LatestBg` (0.76) já foram pré-achatados para hex opaco no Kotlin. **Recomendação:** manter os valores opacos exatos no iOS (paridade garantida); reintroduzir o alpha só se um snapshot lado a lado divergir.

## 3. Tokens de dimensão (`Tokens.kt` → constantes Swift, `dp` → `pt`)

```swift
enum Tokens {
    // Layout
    static let headerHeight: CGFloat = 64, cardMaxWidth: CGFloat = 680
    static let cardRadius: CGFloat = 16, cardRadiusLarge: CGFloat = 22
    static let controlHeight: CGFloat = 40, controlRadius: CGFloat = 12, controlRadiusLarge: CGFloat = 14
    // Spacing
    static let sectionGap: CGFloat = 12, sectionGapLarge: CGFloat = 16, itemGap: CGFloat = 8
    static let cardPadding: CGFloat = 20, cardPaddingSmall: CGFloat = 16
    static let inputPaddingH: CGFloat = 14, inputPaddingV: CGFloat = 12
    static let buttonPaddingH: CGFloat = 20, buttonPaddingV: CGFloat = 12
    // Elevation (sombra) + ícones
    static let cardElevation: CGFloat = 8, dialogElevation: CGFloat = 8
    static let iconDefault: CGFloat = 24, iconSmall: CGFloat = 20, iconLarge: CGFloat = 28
}
```
> `dp`→`pt` é 1:1 conceitualmente (pontos independentes de densidade em ambas). `cardElevation 8dp` → sombra SwiftUI equivalente (calibrar por snapshot).

## 4. Tipografia (`Type.kt` → SwiftUI `Font`)

Fonte padrão do sistema (Material default); **Arimo só no splash** (§10). `sp` → `pt`. Pesos e tracking **exatos**:

| Estilo | Tamanho/linha | Peso | tracking (letterSpacing) |
|---|---|---|---|
| titleLarge | 22 / 28 | Bold | 0 |
| titleMedium | 18 / 24 | SemiBold | 0 |
| titleSmall | 15 / 20 | SemiBold | 0 |
| bodyLarge | 15 / 22 | Regular | 0 |
| bodyMedium | 14 / 20 | Regular | 0 |
| bodySmall | 13 / 18 | Regular | 0 |
| labelLarge | 14 / 20 | **Bold** | 0.1 |
| labelMedium | 12 / 16 | SemiBold | 0.5 |
| labelSmall | 11 / 16 | SemiBold | 0.5 |

> **Header brand** sobrescreve `titleLarge`: `FontWeight.ExtraBold` + `letterSpacing = -0.5` (fácil de perder). No SwiftUI: `.fontWeight(.heavy)` + `.tracking(-0.5)`.

## 5. Color schemes (normal + acidente) — `LocalAccidentModeActive` → `Environment`

Normal: `primary #0F766E`, `onPrimary #FFF`, `primaryContainer #CCFBF1`, `onPrimaryContainer #115E59`, `surface/background #F7F8FA`, `onSurface #0F172A`, `error #B42318`, `outline #CBD5E1`, `outlineVariant #E2E8F0`.
**Acidente** (swap global quando `accidentState.isActive`): `primary #C8222A`, `onPrimary #FFF`, `primaryContainer #FDE7E9`, `onPrimaryContainer #8C1A20`, `secondary #C8222A`. iOS: um `@Environment(\.accidentModeActive)` (default false) + um resolvedor de paleta que troca `primary`/containers. `ProvideAccidentTheme(active:)` envolve a tela toda.

## 6. Shell da tela principal (`CheckScreen`)

Ordem de composição (de fora para dentro):
1. **`ProvideAccidentTheme(active: accidentState.isActive)`** envolve tudo.
2. **Fundo**: `LinearGradient` vertical `#F7F8FA → #EEF2F7`; safe-area padding; tap no fundo limpa o foco.
3. **Watermark Petrobras**: imagem `petrobras_watermark`, **`opacity 0.06`**, **`width = 78%`** da tela (`fillMaxWidth(0.78)`), centralizada **atrás** do conteúdo. (Sensível a marca — mesma opacidade baixa.)
4. **Header** (`64pt`, bg `#0F766E`): ícone do logo `36×28pt` + texto da marca (`titleLarge` **ExtraBold**, tracking **-0.5**, branco), `spacedBy 10pt`.
5. **AccidentBanner** (abaixo do header, acima do scroll).
6. **Corpo rolável**: um único **`CheckCard`** contendo as seções (`spacedBy sectionGap = 12pt`).

## 7. `CheckCard` + `TintedPanel` (parâmetros exatos)

```swift
// CheckCard: o grande cartão branco que segura tudo.
//   maxWidth 680, fillMaxWidth, corner 16, bg #FFFFFF, sombra(elevation 8), borda 1pt teal(#0F766E)@0.18, padding 20.
// TintedPanel: painel interno (history/notification/location), DENTRO do CheckCard.
//   corner (controlRadius+2 = 14), bg #F8FAFC, borda 1pt teal@0.16, padding h12/v10.
```

## 8. Ordem das seções dentro do `CheckCard` (preservar EXATO)

`spacedBy` no Compose só espaça **filhos emitidos** — seções ocultas contribuem **zero** altura e zero gap. No SwiftUI, o `VStack(spacing: 12)` deve **não** emitir spacers para seções ocultas (usar `if` que não renderiza nada).

1. **HistoryCard** — sempre visível (placeholders antes do login).
2. **AccidentInquiryCard** — se autenticado + `primaryActiveAccident != nil` + cenário ∉ {`hideCard`, `checkedOutAutoOff`}. ⚠️ **D2**: aqui o Android passa `automticActivitiesEnabled = state.userProjects != null` (`CheckScreen.kt:257`) — o iOS passa o **flag real** `automaticActivitiesEnabled` (ver accident spec §2 e `decision_log.md`).
3. **NotificationCard** — se `notificationTone != .none || notificationPrimary` não vazio. Secondary vira `status.updatingApp` enquanto `isLocationLoading`.
4. **LocationCard** ("Local" GPS) — só se `automaticActivitiesEnabled && locationPermissionSufficient`.
5. **AuthRow** (chave | senha | engrenagem, com glow colorido) — se `!isInitializing`.
6. **Seções só-autenticado** (se `isAuthenticated`), nesta ordem:
   - **AutoActivitiesNudgeCard** — se `showAutoActivitiesNudge`.
   - **RegistrationFieldset** — escolha check-in/out + botão de transporte (se `transportEnabled`).
   - **InformeFieldset** — normal/retroativo.
   - **ProjectsFieldset** — checkboxes de projeto.
   - **LocationSelectField** ("Local" dropdown) — se `requiresManualLocation && availableLocations` não vazio.
   - **PrimaryButton** "Registrar {check-in/out}" (`enabled = canSubmit`).
   - **AccidentReportButton** — sempre (autenticado), abaixo de "Registrar".

## 9. Overlays / diálogos (sheets/overlays, **não** rotas de navegação)

Renderizados **acima** do conteúdo (preservam o estado do Check por baixo — manter como overlays/`sheet`/`fullScreenCover`, não `NavigationStack` push):
- Diálogos do `dialogOpen`: `Settings`, `PasswordChange`, `SelfRegistration`, `AutoActivities`, `ScheduledPause`, `Notifications`, `EvaluationLog`, `History` (check), `Activities` (log).
- **Delete account**: `AlertDialog` com botão **confirmar VERMELHO** (`#B42318`) e cancelar teal.
- **Acidente**: ack dialog (fila), actions dialog, **VideoRecordScreen** (full-screen), **Wizard** (full-screen).
- **Transporte**: `TransportScreen` full-screen modal.
> Settings expõe: idioma, trocar/criar senha, atividades automáticas, pausa programada, notificações, suporte (WhatsApp `wa.me/{support.phoneNumber}?text=`), sobre, privacidade, manual, log de atividades, **remover cadastro**.

## 10. Splash animado (`AppSplashScreen`)

Fundo teal `#0F766E`. **Única animação**: o "V" do checkmark desenhado progressivamente (como à mão). Geometria (viewBox `220×170`), replicar com Core Graphics/SwiftUI `Path` + `trim(from:0, to:progress)`:
- Canvas `300×232pt`, escala `min(w/220, h/170)`, centralizada; `translate(18,16)` externo; **`rotate(-12°)` pivot `(74,70)`**.
- Elementos estáticos (branco): card `M30,8 H114 A18,18…Z` (stroke 10), photo (fill), nameLine `M28,74 H64` (stroke 10), roleLine `M28,96 H56` (stroke 10), arc1 `M154,30 C167,34 176,43 180,56` (stroke 8), arc2 `M166,18 C184,24 197,38 202,56` (stroke 8) — todos `StrokeCap.Round`.
- **Checkmark animado**: `M92,78 L118,104 L162,44`, **stroke 20** round; revelado por `PathMeasure.getSegment(0, length·progress)` → SwiftUI `.trim(to: progress)`.
- Animação: `tween(1000ms, FastOutSlowInEasing)` → **delay 450ms** → `onFinished` (navega para CHECK). iOS: `.easeInOut`/curva equivalente, 1s + 0.45s.
- **Versão** (`BuildConfig.VERSION_NAME` = `1.6.5`): abaixo do logo, `labelMedium` + **Arimo** + tracking 1, branco@0.9, padding-top 8.
- **Créditos** (rodapé, padding-bottom 28, spacedBy 2): `labelSmall` + **Arimo** + `fontSize 13.75` (labelSmall 11 + 25%) + tracking 1.5, branco: "Dilnei Schmidt", "Tamer Salmem", "Thiago Soares do Nascimento".

## 11. Inventário de componentes (espelhar 1:1)

`CheckCard` (+`TintedPanel`) · `AuthRow` · `GlowField` (campo com brilho) · `PasswordField` · `PrimaryButton` · `ChoiceCard` · `NotificationCard` · `HistoryCard` · `LocationCard` · `LocationSelectField` · `RegistrationFieldset` · `InformeFieldset` · `ProjectsFieldset` · `AutoActivitiesNudgeCard` · `DialogScaffold` · `SettingsDialog` · `SelfRegistrationDialog` · `PasswordChangeDialog` · `CheckHistoryDialog` (+ acidente: `AccidentBanner`, `AccidentInquiryCard`, `AccidentReportButton`, `AccidentAckDialog`, `AccidentActionsDialog`, `AccidentWizard`; transporte: `TransportScreen`).
> **GlowField** é o campo com o "brilho" colorido (chave/senha/engrenagem): laranja=pendente (`#F97316`/`#FB923C`), verde=autenticado (`#16A34A`/`#22C55E`); a engrenagem usa o glow de saúde do automático (Off=sem glow, Healthy=verde, Degraded=laranja).

## 12. Fonte Arimo

Empacotar **Arimo** (Google Fonts OFL, variável, instância Regular 400) e usá-la **só** nos textos do splash (versão + créditos). O app usa a fonte padrão do sistema em todo o resto. iOS: adicionar ao bundle + `Info.plist UIAppFonts`; escopar via `.font(.custom("Arimo", size:))` só no splash.

## 13. Adaptações iOS controladas (plano §16.3 — não são defeitos de paridade)

Safe areas / home indicator; teclado e foco previsíveis; telas pequenas; **Dynamic Type** sem truncar ações críticas; **VoiceOver** com ordem = visual; área de toque mínima; contraste aferido; **Reduce Motion** reduz animações (splash cai para estado final sem o desenho); não depender só de cor para estado (o glow tem também estado/label).

## 14. Validação por snapshot (plano §25.3 — não há teste unitário de UI portável)

Capturas lado a lado vs. o Android nos tamanhos de iPhone definidos, cobrindo: cadastro/aprovação/login/senha; check manual e retroativo; ajustes e permissões; histórico; transporte; acidente e vídeo (com doubles seguros); manual/sobre/privacidade; estados **vazio/loading/erro/sucesso**; **6 idiomas** (expansão de texto + chinês); iPhone pequeno/médio/grande; Dynamic Type, VoiceOver, Reduce Motion, contraste.

## 15. Checklist de fidelidade
- [x] Cores/tokens/tipografia com os valores hex/pt/pesos exatos (incl. header ExtraBold tracking -0.5). (§16)
- [x] Watermark Petrobras `opacity 0.06`, `width 78%`, centralizada atrás; alpha achatado mantido opaco. (§17)
- [x] `CheckCard` (maxW 680, corner 16, sombra 8, borda 1pt teal@0.18, padding 20) + `TintedPanel` (corner 14, teal@0.16, h12/v10). (§17 — cantos `.circular`, não squircle)
- [~] Shell + ordem das seções: shell feito (§17); a ordem exata das seções + zero-altura-quando-oculta é da próxima sub-slice (as seções). (sub-slice das seções)
- [ ] **D2**: `inquiryScenario` recebe o flag **real** de automático (não `userProjects != null`). (sub-slice do CheckScreen)
- [ ] Overlays/diálogos como sheets/overlays sobre o Check (não rotas); delete confirma em vermelho. (sub-slice de diálogos)
- [x] Splash: geometria exata (viewBox 220×170, rotate -12 pivot 74,70, checkmark trim, 1000ms+450ms), versão+créditos em Arimo. (§16)
- [x] Arimo só no splash; resto na fonte do sistema. (§16)
- [~] Swap de tema de acidente environment-driven (paleta vermelha exata) — resolvedor + `provideAccidentTheme` feitos (§16); o USO nas telas vem com o CheckScreen.
- [~] Adaptações iOS: Reduce Motion no splash feito (§16); safe area/Dynamic Type/VoiceOver por tela conforme forem portadas.
- [ ] Snapshots aprovados lado a lado nos aparelhos-alvo e 6 idiomas. (validação no Xcode/aparelho — sem teste headless)

## 16. Implementação — fundação do design system + splash (sub-slice UI-1, 2026-07-17)

Primeira peça da camada de UI. Port 1:1 de `presentation/theme/*` + `splash/AppSplashScreen.kt`. **Escopo:** fundação + splash; o `CheckScreen`, os componentes (§11), os diálogos e a validação por snapshot (§14) são sub-slices seguintes.
- ✅ **Tokens**: `CheckingColors` (~45 hex exatos de Color.kt), `Color(hex:)` puro/testável, `Tokens` (dimensões), `CheckingTypography` (9 estilos + override `headerBrand` ExtraBold/tracking -0.5). `lineHeight`→`lineSpacing` é aproximação documentada (calibrar por snapshot).
- ✅ **Paleta semântica** `CheckingPalette` (normal + acidente, port dos dois `lightColorScheme`) + resolvedor puro + `@Environment(\.checkingPalette)` + `provideAccidentTheme(active:)` (o swap do §5).
- ✅ **Splash** `AppSplashScreen`: geometria exata (viewBox 220×170, `rotate(-12°)` pivot 74,70), estáticos no `Canvas` + checkmark como `Shape` com `.trim` animável (curva Material `timingCurve(0.4,0,0.2,1)`, 1000ms+450ms), versão+créditos em **Arimo** (empacotada, PostScript `Arimo-Regular`, `Info.plist UIAppFonts`), Reduce Motion → estado final. `RootView` faz Splash → placeholder (CheckScreen real depois).
- 14 testes (parser hex, resolvedor de paleta, tabela de todos os tokens). Total 502 verdes. Visual validado por snapshot no Xcode/aparelho (§14 — sem teste unitário de UI portável).

**Revisão adversarial de fidelidade (3 lentes): 4 CONFIRMED corrigidos, 3 refutados.**
- ✅ **HIGH** — a animação do checkmark NÃO tocava: `withAnimation` não anima um valor lido só dentro do render closure de um `Canvas` (o SwiftUI não re-invoca o Canvas por frame). Corrigido: checkmark virou um `Shape` com `.trim` (que expõe `animatableData`), estáticos ficam no Canvas.
- ✅ **MEDIUM** — a paleta de acidente sobrescrevia `outline`/`outlineVariant` com os valores do app; o `AccidentColorScheme` do Kotlin NÃO os seta → caem no baseline M3 (`#79747E`/`#CAC4D0`). Corrigido + teste ajustado (não travar mais a igualdade errada).
- ✅ **LOW** — a curva `.easeInOut` ≠ `FastOutSlowInEasing`; trocada pela `timingCurve(0.4,0,0.2,1)` exata (junto com o fix HIGH).
- ✅ **LOW** — testes não afirmavam o hex da maioria dos tokens; adicionada tabela cobrindo os ~45 tokens + campos da paleta (guarda contra dígito trocado).
- ↩️ Refutados: paleta normal omite `secondaryContainer`/`surfaceVariant` etc. (não consumidos ainda; adicionar quando um componente precisar); `lineSpacing` aproxima demais (aproximação documentada, calibrar por snapshot); textos do splash com tamanho fixo não escalam com Dynamic Type (o splash é deliberadamente fixo — §13 mira telas de conteúdo).

## 17. Implementação — shell do CheckScreen + containers (sub-slice UI-2, 2026-07-17)

Port 1:1 da estrutura de `CheckScreen.kt` (§6) + `CheckCard.kt` (§7). **Escopo:** shell + containers reutilizáveis; as SEÇÕES dentro do card (§8) e o wiring do `CheckViewModel` real são as próximas sub-slices (shell é genérico nos slots `banner`/`cardBody`).
- ✅ **`CheckCard`** + **`TintedPanel`** (containers): maxW 680, corner 16, borda 1pt teal@0.18, sombra ~elevation 8 (aproximada), padding 20; painel interno tint #F8FAFC, corner 14, teal@0.16, h12/v10. Cantos **`.circular`** (arco do Compose), não squircle.
- ✅ **`CheckHeader`**: 64pt, teal, `spacedBy 10`, logo 36×28 + marca ExtraBold tracking -0.5.
- ✅ **`CheckingLogoMark`** + **`CheckingLogoGeometry`**: fonte ÚNICA da geometria do logo, compartilhada pelo splash e pelo header (o `ic_checking_logo.xml` é a MESMA geometria do splash, só com o checkmark completo). O splash foi refatorado p/ usá-la.
- ✅ **`CheckScreenShell`**: `provideAccidentTheme` → gradiente `#F7F8FA→#EEF2F7` → watermark Petrobras (0.06, 78%, centro) → header → slot do banner → scroll com um `CheckCard`; tap-limpa-foco; safe area = `systemBarsPadding`. Watermark copiada p/ o asset catalog. Plugado no `RootView` (splash → shell, corpo do card placeholder).
- Layout puro → sem novos testes unitários (502 verdes); fidelidade visual por snapshot (§14).

**Revisão adversarial de fidelidade (2 lentes): 1 CONFIRMED corrigido, 0 refutado.**
- ✅ **LOW** — `CheckCard`/`TintedPanel` usavam cantos `.continuous` (squircle da Apple); o `RoundedCornerShape` do Compose desenha arcos **circulares**. Trocado p/ `.circular`. Todo o resto (cores, bordas, padding, maxW/centralização, geometria/transform do logo, header, checkmark estático-vs-animado) confirmado fiel.
