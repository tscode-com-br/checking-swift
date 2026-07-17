import XCTest
import CoreLocation
@testable import Checking

/// Port de `isBetter` (LocationProvider.kt) — sem teste dedicado no Kotlin (função privada, nunca testada
/// isoladamente lá), mas é lógica pura com regras não-óbvias o bastante para merecer cobertura direta.
/// `capture`/`CaptureSession` (integração CLLocationManager real) NÃO são testados aqui — ver comentário
/// no arquivo de produção.
final class CLLocationManagerLocationProviderTests: XCTestCase {

    private func fix(accuracy: CLLocationAccuracy, secondsFromNow: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 0,
                   timestamp: Date(timeIntervalSinceNow: secondsFromNow))
    }

    func test_isBetter_noCurrentFix_alwaysTrue() {
        XCTAssertTrue(CLLocationManagerLocationProvider.isBetter(fix(accuracy: 100), than: nil))
    }

    func test_isBetter_lowerAccuracyWins() {
        let candidate = fix(accuracy: 10)
        let current = fix(accuracy: 50)
        XCTAssertTrue(CLLocationManagerLocationProvider.isBetter(candidate, than: current))
    }

    func test_isBetter_higherAccuracyLoses() {
        let candidate = fix(accuracy: 50)
        let current = fix(accuracy: 10)
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(candidate, than: current))
    }

    func test_isBetter_tieAccuracy_newerTimestampWins() {
        let current = fix(accuracy: 20, secondsFromNow: -10)
        let candidate = fix(accuracy: 20, secondsFromNow: 0)
        XCTAssertTrue(CLLocationManagerLocationProvider.isBetter(candidate, than: current))
    }

    func test_isBetter_tieAccuracy_olderTimestampLoses() {
        let current = fix(accuracy: 20, secondsFromNow: 0)
        let candidate = fix(accuracy: 20, secondsFromNow: -10)
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(candidate, than: current))
    }

    func test_isBetter_invalidCandidateAccuracy_alwaysFalse() {
        let current = fix(accuracy: 999)   // até pior que o candidato — ainda perde por ser inválido
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(fix(accuracy: -1), than: current))
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(fix(accuracy: .infinity), than: current))
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(fix(accuracy: .nan), than: current))
    }

    func test_isBetter_validCandidate_invalidCurrent_alwaysTrue() {
        let current = fix(accuracy: -1)
        XCTAssertTrue(CLLocationManagerLocationProvider.isBetter(fix(accuracy: 500), than: current))
    }

    func test_isBetter_bothInvalid_false() {
        let current = fix(accuracy: -1)
        XCTAssertFalse(CLLocationManagerLocationProvider.isBetter(fix(accuracy: .nan), than: current))
    }

    func test_isValidAccuracy_negativeIsInvalid() {
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(-1))
    }

    func test_isValidAccuracy_nanAndInfiniteAreInvalid() {
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(.nan))
        XCTAssertFalse(CLLocationManagerLocationProvider.isValidAccuracy(.infinity))
    }

    func test_isValidAccuracy_zeroAndPositiveAreValid() {
        XCTAssertTrue(CLLocationManagerLocationProvider.isValidAccuracy(0))
        XCTAssertTrue(CLLocationManagerLocationProvider.isValidAccuracy(30))
    }
}
