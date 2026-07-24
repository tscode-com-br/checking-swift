import XCTest
@testable import Checking

final class InformationLinkTests: XCTestCase {
    func test_supportURL_usesOfficialNumberAndPrefillsCurrentKey() throws {
        let url = try XCTUnwrap(SupportLinkBuilder.url(chave: "HR70"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "wa.me")
        XCTAssertEqual(components.path, "/5521992174446")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "text" })?.value,
            "Preciso de ajuda com a aplicação Checking Web. Minha chave é HR70.")
    }

    func test_privacyEmail_prefillsLGPDRequestAndKey() throws {
        let url = try XCTUnwrap(PrivacyLinkBuilder.emailURL(chave: "HR70"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, PrivacyConfig.privacyRequestsEmail)
        XCTAssertTrue(components.queryItems?.first(where: { $0.name == "subject" })?.value?.contains("HR70") == true)
        XCTAssertTrue(components.queryItems?.first(where: { $0.name == "body" })?.value?.contains("Minha chave: HR70") == true)
    }

    func test_contentCatalog_containsAndroidManualAndPrivacyFacts() {
        XCTAssertEqual(t("iosManual.sections.introduction.title"), "Introdução")
        XCTAssertEqual(t("iosManual.sections.firstUse.title"), "Primeira Utilização")
        XCTAssertEqual(t("iosManual.sections.settings.title"), "Configurações do Aplicativo")
        XCTAssertEqual(t("iosManual.sections.main.title"), "Tela Principal")
        XCTAssertEqual(t("iosManual.sections.accident.title"), "Reportar Acidente")
        XCTAssertEqual(t("registration.informeTitle"), "Assiduidade")
        XCTAssertEqual(t("settings.notificationsLabel"), "Notificações")
        XCTAssertTrue(t("iosManual.sections.settings.topics.automatic.callout").contains("não garante execução contínua"))
        XCTAssertTrue(t("iosManual.sections.main.topics.location.item1").contains("Localização não Cadastrada"))
        XCTAssertEqual(t("privacy.heading"), "Privacidade e Proteção de Dados")
        XCTAssertTrue(t("about.rulesNativeBody").contains("Localização não Cadastrada"))
    }
}
