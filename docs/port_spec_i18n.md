# Spec de porte — Internacionalização (i18n)

> Especificação executável para portar o sistema de tradução do Android para iOS (Swift), com paridade de resolução, fallback e interpolação.
> Base: Android `1.6.5` / `versionCode 24`. Verificado por leitura direta do motor `i18n/*` + estrutura dos dicionários + teste (2026-07-15).
> Escopo: 6 idiomas, resolução/alias, fallback **per-key** para pt, interpolação `{token}`, `KnownApiMessages` (reverse-map de strings pt do servidor), idioma efetivo para background, weekday 0=segunda, placeholders de `PrivacyConfig`.
> Cross-ref: mensagens do servidor → [port_spec_network_contracts.md](port_spec_network_contracts.md); weekday do transporte → [port_spec_transport.md](port_spec_transport.md) §8; textos de permissão/notificação → specs de background/acidente.

Fontes: [I18n.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/i18n/I18n.kt) · [LanguageCode.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/i18n/LanguageCode.kt) · [LocalI18n.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/i18n/LocalI18n.kt) · [KnownApiMessages.kt](../../kotlin/app/src/main/java/br/com/tscode/checking/i18n/KnownApiMessages.kt) · `i18n/dictionaries/*.kt` · teste [I18nTest.kt](../../kotlin/app/src/test/java/br/com/tscode/checking/i18n/I18nTest.kt)

---

## 1. Decisão de arquitetura (String Catalog vs. dicionário portado)

O plano sugere **String Catalog (`.xcstrings`)**. Porém, **quatro comportamentos** do motor Kotlin não são triviais no String Catalog padrão:
1. **Fallback per-key para pt** (não per-idioma) — mapeia ao "source/development language = pt" do String Catalog (traduções ausentes caem para pt) **se pt for a development language**.
2. **Chave ausente em pt também → retorna a própria `keyPath`** (String Catalog devolveria a chave crua também — ok).
3. **Interpolação `{token}` nomeada** — **não** é o `%@`/`%1$@` posicional do `String(format:)`/`.stringsdict`. Exige um interpolador custom.
4. **`KnownApiMessages` reverse-map** (string pt do servidor → keyPath) exige um **índice das folhas pt**, que precisa ser construível.

**Recomendação:** usar String Catalog para *armazenar* as strings (com **pt como development language** → fallback automático), **mas** envolver tudo num `t()` custom que faz a interpolação `{token}` e a resolução de idioma; e gerar em build-time um **índice `pt-leaf → key`** para o `KnownApiMessages`. Alternativa igualmente fiel: **portar os dicionários aninhados** como estruturas Swift (JSON/`[String: Any]`), preservando `t()` 1:1 — mais simples para os pontos 3 e 4. Escolher no Marco 0; a spec abaixo descreve a semântica a preservar em qualquer caso.

## 2. Idiomas e aliases

`DEFAULT_LANGUAGE = "pt"`. 6 idiomas (`SUPPORTED_LANGUAGES`, nesta ordem, com label/nativeLabel/locale):
`zh` (Chinese / 中文 / zh-CN) · `en` (English / English / en-US) · `id` (Indonesian / Bahasa Indonesia / id-ID) · `ms` (Malay / Bahasa Melayu / ms-MY) · `pt` (Portuguese / Português / pt-BR) · `tl` (Tagalog (Filipino) / Tagalog (Filipino) / fil-PH).

**Alias map** (`LANGUAGE_ALIAS_MAP`): `fil→tl`, `in→id` (código Java legado de indonésio), + identidades (`pt/en/zh/ms/id/tl`). Chinês é só `zh` (zh-Hant e zh-Hans colapsam para `zh`).

## 3. `resolveLanguageCode(code, fallback?)` — Swift

```swift
let DEFAULT_LANGUAGE = "pt"
let SUPPORTED = ["zh","en","id","ms","pt","tl"]           // ordem de SUPPORTED_LANGUAGES
let ALIAS: [String:String] = ["fil":"tl","tl":"tl","pt":"pt","en":"en","zh":"zh","ms":"ms","id":"id","in":"id"]

func resolveLanguageCode(_ code: String?, _ fallback: String? = nil) -> String {
    let fallbackProvided = fallback != nil
    let resolvedFallback = fallbackProvided ? fallback!.trimmed.lowercased() : DEFAULT_LANGUAGE
    let normalized = (code ?? "").trimmed.lowercased()
    func defaulted() -> String {
        if resolvedFallback.isEmpty && fallbackProvided { return "" }        // SENTINELA de string vazia
        return SUPPORTED.contains(resolvedFallback) ? resolvedFallback : (SUPPORTED.first ?? DEFAULT_LANGUAGE)
    }
    if normalized.isEmpty { return defaulted() }
    if SUPPORTED.contains(normalized) { return normalized }
    let base = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? normalized
    let aliased = ALIAS[normalized] ?? ALIAS[base] ?? base                   // split em '-'/'_' → alias
    if SUPPORTED.contains(aliased) { return aliased }
    return defaulted()
}
```
> ⚠️ **Sentinela `fallback == ""`**: passar `fallback=""` significa "retorne string vazia se não casar" (usado pela detecção de idioma do dispositivo). Sem fallback → default `pt`. Preservar exatamente. iOS `Locale` reporta `pt-BR`, `zh-Hans-CN`, `fil` → split em `-`/`_` + alias resolve todos.

## 4. `t(keyPath, values?, lang?)` — Swift

```swift
func t(_ keyPath: String, _ values: [String:String]? = nil, lang: String? = nil) -> String {
    let code = resolveLanguageCode(lang ?? activeLanguageCode)
    let dict = getDictionary(code)                    // resolve → dict[resolved] ?? dict[pt] ?? [:]
    let value = readTranslationValue(dict, keyPath)   // traversa por '.'; nil se faltar
        ?? readTranslationValue(getDictionary(DEFAULT_LANGUAGE), keyPath)   // FALLBACK PER-KEY para pt
    switch value {
    case let s as String: return interpolate(s, values)
    case nil:             return keyPath              // ausente em ambos → retorna a keyPath literal
    default:              return String(describing: value!)
    }
}
```
- **Fallback per-key**: se a chave falta no idioma ativo, tenta em **pt** (não troca o idioma inteiro). Só `pt` e `en` têm a árvore completa (manual/instruções/sobre/privacidade); `zh/ms/id/tl` são menores e dependem do fallback pt por-chave. Um port ingênuo que assume dicionários paralelos completos **quebra** — manter o fallback reverso.
- **Ausente em ambos** → retorna a `keyPath` (nunca string vazia; útil para detectar chave faltante).

## 5. Interpolação `{token}` (custom, não `String(format:)`)

```swift
func interpolate(_ template: String, _ values: [String:String]?) -> String {
    guard let values = values else { return template }            // sem values → template inalterado
    return template.replacing(#/\{([^}]+)\}/#) { m in values[String(m.1)] ?? "" }   // ausente → string vazia
}
```
Tokens `{chave}`, `{project}`, `{limit}`, `{deadlineTime}`, `{accuracy}`, `{local}`, `{hora}`, `{label}`, `{location}`, `{serviceDateLabel}`, `{requestLabel}` (do call-site) e `{controller}`, `{privacyEmail}`, `{hostingCountry}`, `{minAge}`, `{retentionHistory}`, `{retentionLocalDays}`, `{retentionVideo}` (de `PrivacyConfig`, §9). **Não** é `%@` posicional — usar interpolador de chaves nomeadas.

## 6. Estrutura dos dicionários

Mapas aninhados (`d(vararg pairs)` no Kotlin). Chave = caminho pontilhado (`readTranslationValue` traversa por `.`). Ex.: `auth.brand="Checking"`, `settings.title`, `autoActivities.notification.eventBody="{local} • {hora}"`, `transport.weekdays.short.0="Seg"`. Tamanhos: pt `984` / en `912` / zh·ms·id·tl `747` linhas cada (os 4 menores dependem do fallback pt).

## 7. `KnownApiMessages` — reverse-map das mensagens pt do servidor

O servidor **sempre** envia mensagens em **pt-BR**. Quando o idioma ativo é outro, mapeia a folha pt de volta à sua keyPath e re-emite via `t()`.
```swift
enum KnownApiMessages {
    // índice construído uma vez: TODA folha String do dicionário pt → sua keyPath pontilhada.
    static let ptIndex: [String:String] = buildIndex(ptDictionary(), prefix: "")   // recursivo
    static func localizeApiMessage(_ message: String, lang: String = "pt") -> String {
        let raw = message.trimmed
        if raw.isEmpty { return "" }
        if lang == DEFAULT_LANGUAGE { return raw }                       // pt → passa direto
        if let key = ptIndex[raw] { return t(key, lang: lang) }
        if raw == TRANSPORT_CONFLICT_GENERIC { return t("transport.requestBuilder.conflictGeneric", lang: lang) }
        if raw.hasPrefix(TRANSPORT_CONFLICT_PREFIX) && raw.hasSuffix(".") {   // parte dinâmica (data)
            let date = String(raw.dropFirst(TRANSPORT_CONFLICT_PREFIX.count).dropLast())
            return t("transport.requestBuilder.conflictByDate", ["serviceDateLabel": date], lang: lang)
        }
        return raw                                                       // desconhecida → inalterada
    }
    // localizeLocationLabel: special-cases + fallback para localizeApiMessage (ver §8)
}
```
> ⚠️ **Contrato byte-exato de strings pt (incl. formas SEM acento):** o índice casa por **igualdade exata**. Qualquer edição no `Pt.kt` quebra a localização de mensagens do servidor **silenciosamente**. Literais sensíveis: `"Precisao Insuficiente"`, `"Ja existe uma solicitacao de transporte ativa para essa data."`, prefixo `"Ja existe uma solicitacao de transporte ativa para "`, `"A chave do usuario nao esta cadastrada"` (sem acento). Manter **byte-idênticos** ao servidor.

## 8. `localizeLocationLabel` — labels de localização

Special-cases (antes do `localizeApiMessage`): `"Escritório Principal"` → `location.defaultManualLocationLabel`; `"Precisao Insuficiente"` → `location.accuracyFallbackManualLocationLabel`; `"Fora do Local de Trabalho"` → `location.outsideWorkplaceLabel`; `"Localização não Cadastrada"` → `location.unregisteredLocationLabel`; `"Zona Mista"` → `location.mixedZoneLabel`; zona de checkout (via `isCheckoutZoneLocationName`) → `location.checkoutZoneLabel`; senão → `localizeApiMessage`.

## 9. Idioma ativo, inicial e efetivo (background)

- **`activeLanguageCode`** — global mutável (`private set`), default `pt`. `setActiveLanguageCode(code)` resolve e grava. iOS: um estado observável no `AppEnvironment`/`SessionManager` (não um global mutável solto — plano §6).
- **`resolveInitialLanguageCode(stored, deviceFallback=true)`**: stored → resolve (sentinela "") → `set`; senão device → `set`; senão pt → `set`. **Muta** o global.
- **`resolveEffectiveLanguageCode(stored)`**: stored → device → pt. **Não muta** — seguro fora da UI. Usado pelo orquestrador/notificações para seguir o **mesmo** idioma que a UI resolveu (não forçar pt). Portar como função pura.
- **`detectDeviceLanguageCode()`**: itera os locales do dispositivo, `resolveLanguageCode(locale.language, "")` (sentinela ""), primeiro não-vazio; senão pt. iOS: iterar `Locale.preferredLanguages`.

## 10. Weekday index `0 = segunda`

`transport.weekdays.short.0..6` = `Seg…Dom`; `full.0..6` = `Segunda-feira…Domingo`. **`0=Segunda (Monday) … 6=Domingo (Sunday)`** (ordem ISO/brasileira, **não** domingo-first). No iOS, mapear o índice de dia com segunda=0 (ver spec de transporte). Sem `.stringsdict`/ICU plural — só `{token}`.

## 11. `PrivacyConfig` — placeholders legais

A tela de privacidade injeta `{controller}`, `{privacyEmail}`, `{hostingCountry}`, `{retentionHistory}`, `{retentionLocalDays}`, `{retentionVideo}`, `{minAge}` de um objeto **`PrivacyConfig`** separado (não do i18n). Enquanto não preenchido, `privacy.configPendingNotice` é exibido ("Configuração de privacidade pendente… Preencha PrivacyConfig antes de publicar."). Localizar `PrivacyConfig` e preencher os valores legais concretos **antes de publicar** (Marco 0 / §32).

## 12. Suporte (WhatsApp)

`support.phoneNumber = "5521992174446"` e `support.messageTemplate = "Preciso de ajuda com a aplicação Checking Web. Minha chave é {chave}."` vêm do **i18n** (não do BuildConfig, que tem o WhatsApp vazio). O botão de suporte abre `https://wa.me/{phoneNumber}?text={messageTemplate}`.

## 13. Integração Compose → SwiftUI

`rememberT(langFlow)` / `tr(...)`: retornam um `TranslateFunction = (keyPath, values?) -> String` que fecha sobre o idioma atual. iOS: um `@Environment`/`@Observable` do idioma + uma função `t(_:_:)` reativa (recompõe ao trocar idioma). `onLanguageSelected` re-resolve o prompt de auth (ver spec de auth).

## 14. Mapa de testes Kotlin → Swift XCTest (`I18nTest`, 19 testes)

| grupo | testes |
|---|---|
| `resolveLanguageCode` | supported (6 códigos)→mesmo; `PT`/`EN`→lowercase; `""`→pt; `nil`→pt; `"xx"`→pt; `"fil"`→tl / `"in"`→id; `("xx","en")`→en; `("","")`→"" (**sentinela**) |
| `t()` | known key → ≠ keyPath, não-vazio; `"unknown.key.path"` → keyPath literal; interpolação `autoActivities.notification.eventBody` com `{local}=Office A`,`{hora}=09:30` → contém ambos; `"xx"` → == valor pt; en → não-vazio; **6 idiomas** → não-vazio e ≠ keyPath para `settings.title` |
| `getDictionary` | 6 idiomas carregam não-vazio; `"xx"` → == dicionário pt |
| regressão | 5 chaves `history.*` resolvem nos 6 idiomas; `settings.activitiesLabel` nos 6; 16 seções `manual.sections.*.title` nos 6 **não** começam com prefixo numérico (`^\s*\d+\.`) |

## 15. Checklist de fidelidade
- [ ] 6 idiomas (`zh/en/id/ms/pt/tl`), default pt; alias `fil→tl`, `in→id`; chinês só `zh`.
- [ ] `resolveLanguageCode`: normaliza, split `-`/`_`, alias, **sentinela `fallback==""`→""**.
- [ ] `t()`: **fallback per-key para pt**; ausente em ambos → **keyPath**; interpolação `{token}` (não `%@`).
- [ ] `KnownApiMessages`: índice `pt-leaf→key`; conflito de transporte com data dinâmica; **strings pt byte-exatas** (incl. sem acento).
- [ ] `localizeLocationLabel` com os 6 special-cases.
- [ ] `resolveEffectiveLanguageCode` (não-mutante) para notificações de background; idioma ativo observável, não global solto.
- [ ] Weekday `0=segunda`; sem plural ICU.
- [ ] `PrivacyConfig` preenchido antes de publicar; `support.phoneNumber` do i18n.
- [ ] String Catalog com **pt como development language** (ou dicionário portado) + interpolador custom + índice reverso.
- [ ] 19 testes portados e verdes; cobertura das 6 línguas comparada automaticamente entre catálogos (plano §23).

## 16. Constantes
`DEFAULT_LANGUAGE = "pt"` · 6 idiomas `zh/en/id/ms/pt/tl` · alias `fil→tl`, `in→id` · weekday `0=segunda…6=domingo` · `support.phoneNumber = "5521992174446"` · notif split `62` chars (spec de auth §3) · sem ICU plural.
