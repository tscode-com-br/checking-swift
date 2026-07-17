import XCTest
@testable import Checking

// Port de AppPreferencesDataSourceTest.kt — round-trip verbatim sobre um UserDefaults isolado. §9.5.
// (O Flow "emite-atual-depois-atualiza" do Kotlin vira leitura async round-trip no iOS.)
final class AppPreferencesStoreTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaultsPreferencesStore!

    override func setUp() {
        suiteName = "test_prefs_\(UUID().uuidString)"
        store = UserDefaultsPreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
    }
    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func test_language_default_and_roundtrip() async {
        var v = await store.language(); XCTAssertEqual(v, "")
        await store.setLanguage("zh"); v = await store.language(); XCTAssertEqual(v, "zh")
        await store.setLanguage("en"); v = await store.language(); XCTAssertEqual(v, "en")
    }
    func test_chave_default_and_roundtrip() async {
        var v = await store.chave(); XCTAssertEqual(v, "")
        await store.setChave("HR70"); v = await store.chave(); XCTAssertEqual(v, "HR70")
    }
    func test_userSettingsJson_roundtrips_verbatim() async {
        let json = #"{"HR70":{"projects":["PROJ1"],"activeProject":"PROJ1","automaticActivitiesEnabled":true}}"#
        var v = await store.userSettingsJson(); XCTAssertEqual(v, "")
        await store.setUserSettingsJson(json); v = await store.userSettingsJson(); XCTAssertEqual(v, json)
    }
    func test_transportLocalJson_roundtrips() async {
        let json = #"{"HR70":{"dismissed":["req-1"],"realized":[]}}"#
        await store.setTransportLocalJson(json)
        let v = await store.transportLocalJson(); XCTAssertEqual(v, json)
    }
    func test_flag_default_and_roundtrip() async {
        var f = await store.getFlag("location_hint_shown"); XCTAssertFalse(f)
        await store.setFlag("location_hint_shown", true); f = await store.getFlag("location_hint_shown"); XCTAssertTrue(f)
        await store.setFlag("location_hint_shown", false); f = await store.getFlag("location_hint_shown"); XCTAssertFalse(f)
    }
    func test_flag_names_are_independent() async {
        await store.setFlag("flag_a", true); await store.setFlag("flag_b", false)
        let a = await store.getFlag("flag_a"); let b = await store.getFlag("flag_b")
        XCTAssertTrue(a); XCTAssertFalse(b)
    }
    func test_overwriting_chave_replaces_value() async {
        await store.setChave("AA00"); await store.setChave("BB11")
        let v = await store.chave(); XCTAssertEqual(v, "BB11")
    }
}
