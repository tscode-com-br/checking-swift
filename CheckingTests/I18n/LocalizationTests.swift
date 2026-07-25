import XCTest
@testable import Checking

final class LocalizationTests: XCTestCase {
    func test_supportedLanguages_matchAndroidContract() {
        XCTAssertEqual(Set(supportedLanguages.map(\.code)), Set(["pt", "en", "zh", "ms", "id", "tl"]))
        XCTAssertEqual(supportedLanguages.count, 6)
    }

    func test_languageResolution_acceptsRegionsAndLegacyAliases() {
        XCTAssertEqual(resolveLanguageCode("pt-BR"), "pt")
        XCTAssertEqual(resolveLanguageCode("zh_Hans_CN"), "zh")
        XCTAssertEqual(resolveLanguageCode("fil-PH"), "tl")
        XCTAssertEqual(resolveLanguageCode("in-ID"), "id")
        XCTAssertEqual(resolveLanguageCode("unsupported"), "pt")
        XCTAssertEqual(resolveLanguageCode("unsupported", fallback: ""), "")
    }

    func test_initialLanguage_prefersStoredThenDeviceThenPortuguese() {
        XCTAssertEqual(resolveInitialLanguageCode("ms", preferredLanguages: ["en-US"]), "ms")
        XCTAssertEqual(resolveInitialLanguageCode(nil, preferredLanguages: ["de-DE", "en-US"]), "en")
        XCTAssertEqual(resolveInitialLanguageCode("", preferredLanguages: ["de-DE"]), "pt")
    }

    func test_generatedCatalogs_haveExpectedCanonicalCoverage() {
        XCTAssertGreaterThanOrEqual(generatedPtStrings.count, 660)
        XCTAssertGreaterThanOrEqual(generatedEnStrings.count, 610)
        for code in ["zh", "ms", "id", "tl"] {
            XCTAssertGreaterThanOrEqual(generatedLocalizationCatalogs[code]?.count ?? 0, 465, code)
        }
    }

    func test_everyLanguageHasNativeTranslationForEveryIOSOverride() {
        for language in supportedLanguages.map(\.code) {
            let nativeKeys = language == defaultLanguageCode
                ? Set(generatedPtStrings.keys).union(iosPortugueseOverrideStrings.keys)
                : Set(generatedLocalizationCatalogs[language]?.keys ?? [:].keys)
                    .union(iosPlatformLocalizationOverrides[language]?.keys ?? [:].keys)
            let missing = Set(iosPortugueseOverrideStrings.keys).subtracting(nativeKeys).sorted()
            XCTAssertEqual(
                missing, [],
                "Missing native \(language) translations: \(missing.joined(separator: ", "))")
        }
    }

    func test_platformOverrideTokensMatchPortugueseSource() throws {
        let expression = try NSRegularExpression(pattern: #"\{([^}]+)\}"#)
        func tokens(in text: String) -> Set<String> {
            Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            })
        }

        for (language, entries) in iosPlatformLocalizationOverrides {
            for (key, translation) in entries {
                guard let portuguese = iosPortugueseOverrideStrings[key] ?? generatedPtStrings[key] else {
                    XCTFail("\(language) override has no Portuguese source: \(key)")
                    continue
                }
                XCTAssertEqual(
                    tokens(in: translation), tokens(in: portuguese),
                    "Token mismatch for \(language).\(key)")
            }
        }
    }

    func test_generatedEditorialTranslationsContainNoProtectionMarkers() {
        for (language, entries) in iosAdditionalEditorialStrings {
            let leaked = entries.filter { $0.value.contains("ZXQ") }.map(\.key).sorted()
            XCTAssertEqual(leaked, [], "Protection markers leaked in \(language): \(leaked)")
        }
    }

    func test_translationUsesRequestedLanguageAndPortuguesePerKeyFallback() {
        XCTAssertEqual(t("auth.keyLabel", lang: "en"), "Key")
        XCTAssertEqual(t("auth.keyLabel", lang: "fil-PH"), "Susi")
        XCTAssertNotEqual(t("auth.keyLabel", lang: "zh"), t("auth.keyLabel", lang: "pt"))
        XCTAssertEqual(t("iosManual.sections.introduction.title", lang: "ms"), "Pengenalan")
        XCTAssertEqual(t("does.not.exist", lang: "en"), "does.not.exist")
    }

    func test_noProjectMessageExplainsMissingMembership() {
        XCTAssertEqual(
            t("projects.noActiveProject", lang: "pt"),
            "O usuário não está cadastrado em nenhum projeto.")
        XCTAssertEqual(
            t("projects.noActiveProject", lang: "en"),
            "The user is not registered in any project.")
    }

    func test_interpolationMatchesAndroidMissingTokenSemantics() {
        XCTAssertEqual(
            t("location.accuracyTemplate", ["accuracy": "±8 m"], lang: "en"),
            generatedEnStrings["location.accuracyTemplate"]?.replacingOccurrences(of: "{accuracy}", with: "±8 m"))
        XCTAssertFalse(t("location.accuracyTemplate", [:], lang: "en").contains("{"))
    }

    func test_knownPortugueseApiMessageIsLocalized() {
        let portuguese = generatedPtStrings["history.loadError"]!
        XCTAssertEqual(localizeApiMessage(portuguese, lang: "en"), generatedEnStrings["history.loadError"])
        XCTAssertEqual(localizeApiMessage("Mensagem externa desconhecida", lang: "en"), "Mensagem externa desconhecida")
    }
}
