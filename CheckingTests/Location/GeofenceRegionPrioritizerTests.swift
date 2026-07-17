import XCTest
@testable import Checking

/// Testes exaustivos da priorização determinística sob o cap de 20 do iOS (plano §9.2). Lógica NOVA sem
/// contraparte Kotlin (Android registra todos os círculos, cap 100) — logo, sem teste Kotlin para portar;
/// estes testes são a rede de segurança do requisito "ranking determinístico e auditável, sem truncar em
/// silêncio". A chave de ordenação é `(tier, distância, id)`.
final class GeofenceRegionPrioritizerTests: XCTestCase {

    private func circle(_ id: Int, local: String = "L", lat: Double = 0, lng: Double = 0, radius: Double = 100) -> GeofenceCircle {
        GeofenceCircle(id: id, local: local, centerLat: lat, centerLng: lng, radiusMeters: radius)
    }

    // MARK: cap / truncagem

    func test_emptyInput_selectsNothing() {
        let sel = GeofenceRegionPrioritizer.select([])
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertTrue(sel.omitted.isEmpty)
        XCTAssertEqual(sel.omittedCount, 0)
    }

    func test_fewerThanCap_allSelected_noneOmitted() {
        let circles = (1...5).map { circle($0) }
        let sel = GeofenceRegionPrioritizer.select(circles, cap: 20)
        XCTAssertEqual(sel.selected.count, 5)
        XCTAssertEqual(sel.omittedCount, 0)
    }

    func test_exactlyCap_allSelected() {
        let circles = (1...20).map { circle($0) }
        let sel = GeofenceRegionPrioritizer.select(circles, cap: 20)
        XCTAssertEqual(sel.selected.count, 20)
        XCTAssertEqual(sel.omittedCount, 0)
    }

    func test_moreThanCap_truncatesAndReportsOmitted() {
        let circles = (1...25).map { circle($0) }
        let sel = GeofenceRegionPrioritizer.select(circles, cap: 20)
        XCTAssertEqual(sel.selected.count, 20)
        XCTAssertEqual(sel.omittedCount, 5)
        // selected + omitted == todo o conjunto (nada some).
        XCTAssertEqual(Set((sel.selected + sel.omitted).map(\.id)), Set(circles.map(\.id)))
    }

    func test_defaultCapIs20() {
        XCTAssertEqual(GeofenceRegionPrioritizer.iosRegionCap, 20)
        let sel = GeofenceRegionPrioritizer.select((1...30).map { circle($0) })
        XCTAssertEqual(sel.selected.count, 20)
        XCTAssertEqual(sel.omittedCount, 10)
    }

    // MARK: ordem por id (sem hints)

    func test_noHints_ordersByIdAscending() {
        let circles = [circle(9), circle(3), circle(21), circle(1)]
        let sel = GeofenceRegionPrioritizer.select(circles, cap: 3)
        XCTAssertEqual(sel.selected.map(\.id), [1, 3, 9])
        XCTAssertEqual(sel.omitted.map(\.id), [21])
    }

    // MARK: tier 1 — área do check-in atual

    func test_currentArea_rankedFirst_evenWhenFarAndHighId() {
        // id alto e longe do ref, mas casa com o local atual → deve entrar em 1º e sobreviver ao cap.
        let current = circle(99, local: "Unidade P80", lat: 50, lng: 50)
        let others = (1...20).map { circle($0, local: "Outro", lat: 0, lng: 0) }
        let ref = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0, lon: 0), currentLocalName: "Unidade P80")
        let sel = GeofenceRegionPrioritizer.select(others + [current], hints: ref, cap: 20)
        XCTAssertEqual(sel.selected.first?.id, 99)                 // área atual em 1º
        XCTAssertTrue(sel.selected.contains { $0.id == 99 })       // não foi cortada pelo cap
        XCTAssertEqual(sel.omittedCount, 1)                        // um "Outro" saiu no lugar dela
    }

    func test_currentArea_matchIsTrimmedAndCaseInsensitive() {
        let current = circle(7, local: "  unidade p80 ")
        let others = [circle(1, local: "X"), circle(2, local: "Y")]
        let hints = GeofencePriorityHints(currentLocalName: "UNIDADE P80")
        let sel = GeofenceRegionPrioritizer.select(others + [current], hints: hints, cap: 3)
        XCTAssertEqual(sel.selected.first?.id, 7)
    }

    func test_currentLocalName_blankOrNil_noTierBoost_fallsToIdOrder() {
        let circles = [circle(3, local: "A"), circle(1, local: "B")]
        let blank = GeofencePriorityHints(currentLocalName: "   ")
        XCTAssertEqual(GeofenceRegionPrioritizer.select(circles, hints: blank, cap: 2).selected.map(\.id), [1, 3])
        let nilHint = GeofencePriorityHints(currentLocalName: nil)
        XCTAssertEqual(GeofenceRegionPrioritizer.select(circles, hints: nilHint, cap: 2).selected.map(\.id), [1, 3])
    }

    // MARK: tier 4 — proximidade (Haversine)

    func test_reference_ordersByNearestFirst() {
        // ref em (0,0). Círculos a distâncias crescentes em latitude.
        let near = circle(10, lat: 0.001, lng: 0)     // ~111 m
        let mid = circle(20, lat: 0.01, lng: 0)       // ~1.1 km
        let far = circle(30, lat: 0.1, lng: 0)        // ~11 km
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0, lon: 0))
        let sel = GeofenceRegionPrioritizer.select([far, mid, near], hints: hints, cap: 3)
        XCTAssertEqual(sel.selected.map(\.id), [10, 20, 30])   // do mais perto ao mais longe
    }

    func test_reference_truncatesFarthest() {
        let near = circle(1, lat: 0.001, lng: 0)
        let far = circle(2, lat: 0.5, lng: 0)
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0, lon: 0))
        let sel = GeofenceRegionPrioritizer.select([near, far], hints: hints, cap: 1)
        XCTAssertEqual(sel.selected.map(\.id), [1])
        XCTAssertEqual(sel.omitted.map(\.id), [2])              // o mais longe é cortado
    }

    func test_longitudeDistanceUsesHaversine_notNaiveEuclidean() {
        // Perto do equador, 1° de lat ≈ 1° de lng. Longe do polo o efeito some, mas a alta latitude
        // encolhe o grau de longitude — Haversine tem de rankear o vizinho de longitude como MAIS perto.
        // ref a 60°N: 0.5° de longitude ≈ 27.8 km; 0.5° de latitude ≈ 55.6 km. Nearest = o de longitude.
        let byLon = circle(1, lat: 60.0, lng: 0.5)
        let byLat = circle(2, lat: 60.5, lng: 0.0)
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 60, lon: 0))
        let sel = GeofenceRegionPrioritizer.select([byLat, byLon], hints: hints, cap: 1)
        XCTAssertEqual(sel.selected.map(\.id), [1])             // vizinho de longitude é o mais próximo
    }

    // MARK: desempate e determinismo

    func test_equalDistance_tieBrokenById() {
        // Dois círculos equidistantes do ref (simétricos) → id crescente decide.
        let a = circle(8, lat: 0.01, lng: 0)
        let b = circle(3, lat: -0.01, lng: 0)
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0, lon: 0))
        let sel = GeofenceRegionPrioritizer.select([a, b], hints: hints, cap: 1)
        XCTAssertEqual(sel.selected.map(\.id), [3])             // menor id vence o empate
    }

    func test_deterministic_sameInputSameOutput_regardlessOfInputOrder() {
        let circles = (1...30).map { circle($0, lat: Double($0) * 0.001, lng: 0) }
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0.05, lon: 0))
        let a = GeofenceRegionPrioritizer.select(circles, hints: hints).selected.map(\.id)
        let b = GeofenceRegionPrioritizer.select(circles.reversed(), hints: hints).selected.map(\.id)
        let c = GeofenceRegionPrioritizer.select(circles.shuffled(), hints: hints).selected.map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
    }

    func test_tierBeatsDistance_currentAreaFarStillFirst() {
        // Área atual longe (id 5) vs. um vizinho pertíssimo que NÃO é a área atual (id 1).
        let current = circle(5, local: "Atual", lat: 1.0, lng: 1.0)
        let nearOther = circle(1, local: "Outro", lat: 0.0001, lng: 0)
        let hints = GeofencePriorityHints(referenceLocation: GeoPoint(lat: 0, lon: 0), currentLocalName: "Atual")
        let sel = GeofenceRegionPrioritizer.select([nearOther, current], hints: hints, cap: 2)
        XCTAssertEqual(sel.selected.map(\.id), [5, 1])          // tier vence distância
    }

    // MARK: cap degenerado

    func test_capZero_selectsNothing_allOmitted() {
        let circles = (1...3).map { circle($0) }
        let sel = GeofenceRegionPrioritizer.select(circles, cap: 0)
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertEqual(sel.omittedCount, 3)
    }

    func test_negativeCap_treatedAsZero() {
        let circles = (1...3).map { circle($0) }
        let sel = GeofenceRegionPrioritizer.select(circles, cap: -5)
        XCTAssertTrue(sel.selected.isEmpty)
        XCTAssertEqual(sel.omittedCount, 3)
    }
}
