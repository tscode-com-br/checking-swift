import XCTest

/// Smoke test de UI — prova que o app lança e mostra a raiz. Expandir com os fluxos das specs
/// (cadastro/login, check manual, transporte, acidente) conforme forem implementados.
@MainActor
final class CheckingUITests: XCTestCase {

    func test_appLaunches_showsBrand() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-dynamic-type-default"]
        app.launch()
        let header = app.descendants(matching: .any)["check.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        // O frame acessível inclui a safe area superior (62 pt neste simulador com Dynamic Island)
        // além dos 48 pt do conteúdo visual.
        XCTAssertLessThanOrEqual(header.frame.height, 112,
                                 "O cabeçalho principal deve permanecer compacto no tamanho de texto padrão")
    }

    func test_initialCheckCard_showsHistoryCredentialsAndSettings() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["history.checkin"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.checkout"].exists)
        let key = app.textFields["auth.key"]
        let securePassword = app.secureTextFields["auth.password"]
        let visiblePassword = app.textFields["auth.password"]
        XCTAssertTrue(key.exists)
        XCTAssertTrue(securePassword.exists || visiblePassword.exists)
        let password = securePassword.exists ? securePassword : visiblePassword
        XCTAssertEqual(
            password.frame.height,
            key.frame.height,
            accuracy: 1,
            "O campo Senha deve manter a mesma altura do campo Chave, inclusive no primeiro acesso")
        XCTAssertTrue(app.buttons["auth.settings"].exists)
    }

    func test_passwordSaveButton_acceptsTapNearLeadingEdge() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-no-password",
            "--ui-test-password-dialog",
            "--ui-test-dynamic-type-default",
        ]
        app.launch()

        let save = app.buttons["password.submit"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        save.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        XCTAssertTrue(
            app.staticTexts["A nova senha deve ter entre 3 e 10 caractéres."].waitForExistence(timeout: 2),
            "Um toque dentro da borda esquerda deve acionar Salvar e executar a validação")
    }

    func test_authenticatedCheckCard_showsManualRegistrationSections() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"]
        app.launch()

        XCTAssertTrue(app.buttons["registration.checkin"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["registration.checkout"].exists)
        XCTAssertTrue(app.buttons["registration.informe.normal"].exists)
        XCTAssertTrue(app.buttons["registration.informe.retroativo"].exists)
        XCTAssertTrue(app.buttons["projects.selector"].exists)
        XCTAssertTrue(app.buttons["location.selector"].exists)
        XCTAssertTrue(app.buttons["registration.submit"].exists)
        XCTAssertEqual(app.textFields["auth.key"].value as? String, "HR70")
        XCTAssertTrue(app.staticTexts["auth.password.masked"].exists)
    }

    func test_authenticatedMain_actionButtonsMatchCompactControlHeight() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-dynamic-type-default"]
        app.launch()

        let identifiers = [
            "registration.checkin",
            "registration.checkout",
            "registration.informe.normal",
            "registration.informe.retroativo",
            "registration.submit",
            "accident.report",
        ]
        for identifier in identifiers {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 12), "Botão ausente: \(identifier)")
            XCTAssertEqual(button.frame.height, 40, accuracy: 1, "Altura divergente: \(identifier)")
        }
    }

    func test_authenticatedSettings_exposesAutomaticPauseAndNotifications() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"]
        app.launch()

        XCTAssertTrue(app.buttons["auth.settings"].waitForExistence(timeout: 12))
        app.buttons["auth.settings"].tap()
        XCTAssertTrue(app.buttons["settings.automatic"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["settings.scheduledPause"].exists)
        XCTAssertTrue(app.buttons["settings.notifications"].exists)
        XCTAssertTrue(app.buttons["settings.manual"].exists)
        XCTAssertTrue(app.buttons["settings.support"].exists)
        XCTAssertTrue(app.buttons["settings.about"].exists)
        XCTAssertTrue(app.buttons["settings.privacy"].exists)
        XCTAssertTrue(app.buttons["settings.activities"].exists)

        app.buttons["settings.automatic"].tap()
        XCTAssertTrue(app.staticTexts["Habilitar Atividades Automáticas"].waitForExistence(timeout: 3))

    }

    func test_settingsLanguageMenu_changesVisibleInterfaceLanguage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"]
        app.launch()

        XCTAssertTrue(app.buttons["auth.settings"].waitForExistence(timeout: 12))
        app.buttons["auth.settings"].tap()
        XCTAssertTrue(app.buttons["settings.language"].waitForExistence(timeout: 3))
        app.buttons["settings.language"].tap()
        XCTAssertTrue(app.buttons["English"].waitForExistence(timeout: 3))
        app.buttons["English"].tap()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Automatic Activities"].exists)
        XCTAssertEqual(app.buttons["settings.language"].value as? String, "English")
    }

    func test_authenticatedMain_passesSystemAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"]
        app.launch()

        XCTAssertTrue(app.buttons["registration.checkin"].waitForExistence(timeout: 12))
        // O auditor de contraste do XCTest produz falsos positivos nos controles SwiftUI que possuem
        // glow/sombra translúcida. O contraste é validado matematicamente em CheckingColorsTests; aqui
        // mantemos os seis auditores estruturais nativos, inclusive Dynamic Type e corte de texto.
        try app.performAccessibilityAudit(for: structuralAccessibilityAudits)
    }

    func test_authenticatedAutomaticDialog_rendersPermissionChecklist() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-automatic-dialog"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Habilitar Atividades Automáticas"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Notificações"].exists)
        XCTAssertTrue(app.staticTexts["Localização precisa"].exists)
        XCTAssertTrue(app.staticTexts["Localização Sempre"].exists)
    }

    func test_authenticatedHistory_opensFilteredDialog() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"]
        app.launch()

        XCTAssertTrue(app.buttons["history.checkin"].waitForExistence(timeout: 12))
        app.buttons["history.checkin"].tap()
        XCTAssertTrue(app.staticTexts["Histórico de Check-In"].waitForExistence(timeout: 3))
    }

    func test_notificationsDialog_exposesReadableLabels() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-notifications-dialog"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Notificações"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Notificar quando uma atividade automática for realizada."].exists)
        XCTAssertTrue(app.staticTexts["Notificar o início e o fim da Pausa Programada."].exists)
        XCTAssertTrue(app.staticTexts["Notificar quando houver um acidente reportado."].exists)
    }

    func test_documentationSettings_hidesPhysicalValidationTool() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-authenticated",
            "--ui-test-settings-dialog",
            "--ui-test-documentation",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Ajustes"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Remover Cadastro"].exists)
        XCTAssertFalse(app.staticTexts["Validação física — Fase 2"].exists)
    }

    func test_historyDialog_keepsBackAndHeaderVisibleAfterScrolling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-history-dialog"]
        app.launch()

        let back = app.buttons["history.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Data"].exists)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(app.staticTexts["Data"].exists)
    }

    func test_activitiesDialog_rendersDiagnosticEntriesAndFixedActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-activities-dialog"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Activities"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.scrollViews["activities.list"].exists)
        XCTAssertTrue(app.buttons["activities.clear"].isHittable)
        XCTAssertTrue(app.buttons["activities.close"].isHittable)
        XCTAssertTrue(app.staticTexts["Background evaluation (SIGNIFICANT_LOCATION)."].exists)
    }

    func test_manualScreen_rendersCompleteGuideAndReturns() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-manual"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Instruções de Uso"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Introdução"].exists)
        XCTAssertTrue(app.staticTexts["Primeira Utilização"].exists)
        XCTAssertTrue(app.buttons["information.back"].isHittable)
        app.buttons["information.back"].tap()
        XCTAssertTrue(app.buttons["auth.settings"].waitForExistence(timeout: 3))
    }

    func test_englishManual_rendersNativeEditorialContent() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-manual", "--ui-test-english"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Usage Instructions"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["A complete guide to getting started, configuring, and using Checking on iPhone."].exists)
        XCTAssertTrue(app.staticTexts["Introduction"].exists)
        XCTAssertTrue(app.staticTexts["First Use"].exists)
        XCTAssertTrue(app.buttons["information.back"].isHittable)
    }

    func test_additionalLanguages_renderNativeManualEditorialContent() {
        let fixtures = [
            ("zh", "使用说明", "在 iPhone 上入门、配置和使用 Checking 的完整指南。"),
            ("ms", "Arahan Penggunaan", "Panduan lengkap untuk memulakan, mengkonfigurasi dan menggunakan Checking pada iPhone."),
            ("id", "Petunjuk Penggunaan", "Panduan lengkap untuk memulai, mengonfigurasi, dan menggunakan Checking di iPhone."),
            ("tl", "Mga Tagubilin sa Paggamit", "Isang kumpletong gabay sa pagsisimula, pag-configure, at paggamit ng Checking sa iPhone."),
        ]

        for (language, title, introduction) in fixtures {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-test-authenticated", "--ui-test-manual", "--ui-test-language-\(language)",
            ]
            app.launch()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 12), language)
            XCTAssertTrue(app.staticTexts[introduction].exists, language)
            XCTAssertTrue(app.buttons["information.back"].isHittable, language)
            app.terminate()
        }
    }

    func test_aboutScreen_rendersSystemHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-about"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Sobre o Checking"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Como nasceu o Checking"].exists)
        XCTAssertTrue(app.buttons["information.back"].isHittable)
    }

    func test_privacyScreen_rendersLGPDSectionsAndActions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-privacy"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Privacidade e Proteção de Dados"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["1. Para que usamos seus dados (finalidade)"].exists)
        XCTAssertTrue(app.scrollViews["information.scroll"].exists)
        XCTAssertTrue(app.buttons["information.back"].isHittable)
    }

    func test_activeAccident_rendersBannerInquiryAndZoneConfirmation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-accident-active"]
        app.launch()

        XCTAssertTrue(app.staticTexts["accident.banner"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Estou em:"].exists)
        XCTAssertTrue(app.buttons["accident.report"].exists)

        let safetyButton = app.buttons["Zona de Segurança"]
        XCTAssertTrue(safetyButton.exists)
        safetyButton.tap()
        XCTAssertTrue(app.staticTexts["Você confirma que está fora de perigo?"].waitForExistence(timeout: 3))
    }

    func test_accidentWizard_rendersProjectSelectionStep() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-accident-wizard"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Selecione o Projeto"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["P80"].exists)
        XCTAssertTrue(app.buttons["P81"].exists)
    }

    func test_accessibilityXXXL_authenticatedMainPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.buttons["history.checkin"].waitForExistence(timeout: 12))
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_accessibilityXXXL_settingsIsModalAndPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-settings-dialog"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.staticTexts["Ajustes"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["registration.checkin"].exists)
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_accessibilityXXXL_manualPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-manual"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.staticTexts["Instruções de Uso"].waitForExistence(timeout: 12))
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_accessibilityXXXL_automaticActivitiesPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-automatic-dialog"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.staticTexts["Habilitar Atividades Automáticas"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["registration.checkin"].exists)
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_accessibilityXXXL_historyPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-history-dialog"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.buttons["history.back"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["registration.checkin"].exists)
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_accessibilityXXXL_accidentWizardPassesStructuralAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-accident-wizard"] + accessibilityXXXLArguments
        app.launch()

        XCTAssertTrue(app.staticTexts["Selecione o Projeto"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["registration.checkin"].exists)
        try app.performAccessibilityAudit(for: extremeDynamicTypeAudits)
    }

    func test_reduceMotion_skipsAnimatedSplashWait() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-authenticated", "--ui-test-reduce-motion"]
        app.launch()

        XCTAssertTrue(app.buttons["history.checkin"].waitForExistence(timeout: 1))
    }

    private var structuralAccessibilityAudits: XCUIAccessibilityAuditType {
        [.elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait]
    }

    /// O tamanho já está fixado no máximo pelo fixture; executar `.dynamicType` novamente faria o auditor
    /// interpretar deliberadamente o override como fonte sem suporte. Os demais auditores examinam o layout
    /// realmente renderizado em Accessibility 5. O suporte à variação é coberto pelo roteiro no tamanho padrão.
    private var extremeDynamicTypeAudits: XCUIAccessibilityAuditType {
        [.elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
    }

    private var accessibilityXXXLArguments: [String] {
        ["--ui-test-dynamic-type-xxxl"]
    }
}
