# Checking (iOS)

Port Swift/SwiftUI do app Android `Checking` (Kotlin), com perda ZERO de funcionalidades. Este diretório
é a **fundação** — a estrutura, a composição de dependências e a camada Core. A lógica de cada subsistema
é implementada seguindo as specs em [`docs/`](docs/).

## Como gerar e abrir o projeto

O `.xcodeproj` é **gerado** (não versionado) a partir de [`project.yml`](project.yml) via [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen        # uma vez
cd ios
xcodegen generate            # cria Checking.xcodeproj
open Checking.xcodeproj      # ou: xcodebuild -scheme Checking -destination 'platform=iOS Simulator,name=iPhone 15' test
```

> Alternativas: importar os arquivos manualmente num projeto Xcode novo, ou converter para Tuist. Requisitos:
> Xcode 16+ (Swift 6), iOS mínimo **17.0** (plano §5).

## Estrutura (plano §6)

```
ios/
├── project.yml                 # spec do XcodeGen
├── Config/                     # Debug/Staging/Release .xcconfig (bundle id, APNs env, versão, backend)
├── Checking/
│   ├── App/                    # CheckingApp, AppDelegate (APNs+BGTasks), AppEnvironment, AppLifecycleCoordinator, RootView
│   ├── Core/                   # API, Errors (AppResult/ApiError), Logging (OSLog), Security, Time (Clock), Utilities
│   ├── Domain/                 # Models, CheckRules, UseCases, Repositories (protocolos) — sem UIKit/CoreLocation
│   ├── Data/                   # DTOs (Codable), Network (URLSession/SSE), Persistence (Core Data/store), Repositories
│   ├── Platform/               # Background, Location, Notifications, Camera, Connectivity, Permissions
│   ├── Features/               # Splash, Check, Settings, Transport, Accident, Manual, About, Privacy (SwiftUI + ViewModels)
│   ├── DesignSystem/           # Tokens, Components, Assets.xcassets
│   ├── Localization/           # .xcstrings (6 idiomas, fallback pt) + InfoPlist.strings
│   ├── Resources/
│   ├── Info.plist              # background modes, BGTask ids, usage descriptions, config do backend
│   ├── Checking.entitlements   # aps-environment
│   └── PrivacyInfo.xcprivacy   # rótulos de privacidade (AUDITAR antes de publicar — plano §22.2)
├── CheckingTests/              # XCTest unit (rede dos ~256 testes portados)
├── CheckingUITests/            # XCTest UI/smoke
└── docs/                       # plano + decisões + 11 port specs
```

**Regras de dependência** (plano §6): `Domain` não importa SwiftUI/UIKit/CoreLocation/AVFoundation;
`Features` consomem casos de uso e estados, não URLSession/DB direto; `Platform` encapsula APIs do sistema;
`Data` implementa protocolos do domínio; `AppEnvironment` faz a composição; relógio/UUID/rede/localização/
notificações injetáveis para teste; **nenhum singleton global mutável como fonte de verdade**.

## Mapa pasta → port spec (`docs/`)

| Camada / pasta | Spec de porte |
|---|---|
| `Domain/CheckRules`, `Domain/UseCases` | `port_spec_decision_engine.md` |
| `Data/Persistence` (fila offline), `Platform/Background` (replay) | `port_spec_offline_replay.md` |
| `Features/Check` (auth), `Data/Repositories` (auth) | `port_spec_auth_lifecycle.md` |
| `Platform/Background`, `Platform/Location` | `port_spec_background_orchestrator.md` |
| `Data/Network`, `Data/DTOs`, `Core/Errors` | `port_spec_network_contracts.md` |
| `Features/Transport` | `port_spec_transport.md` |
| `Features/Accident`, `Platform/Camera` | `port_spec_accident_video.md` |
| `DesignSystem`, `Features/Splash`, `Features/Check` | `port_spec_ui_design_system.md` |
| `Localization` | `port_spec_i18n.md` |
| `Data/Persistence`, `Core/Time`, `Core/Security` | `port_spec_persistence_foundation.md` |
| `Platform/Permissions`, `Platform/Background/diagnostics` | `port_spec_permissions_diagnostics.md` |
| decisões de fidelidade D1–D6 | `decision_log.md` |

## Pendências de Marco 0 (§32) — antes de codar a fundo

- [ ] `DEVELOPMENT_TEAM` (Apple Developer Team), bundle IDs, ownership de certificados/APNs (§32.3).
- [ ] Backend homologa **`X-Client: checking-ios`** com as regras do `checking-android` (§32.5) — **bloqueador**.
- [ ] Backend implementa APNs + lifecycle de device token (§32.7).
- [ ] Limite/prioridade de regiões (cap 20 do iOS) (§32.6).
- [ ] `PrivacyConfig` legal preenchido + `PrivacyInfo.xcprivacy` auditado (§22).
- [ ] Distribuição (App Store pública / Custom App / interna) (§32.2).

## Estado atual

Fundação compilável: `CheckingApp` roda e mostra a marca; `CoreFoundationTests` verde (AppResult/ApiError/
ApiConfig/Clock). Próximo passo recomendado (plano §34): **Fase 2 — prova técnica de segundo plano** em
aparelho real, e/ou implementar a camada **Domain** (motor de decisão) com os ~116 testes como rede.
