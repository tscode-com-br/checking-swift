import Foundation

/// Coordenada de referência para priorizar geofences pela proximidade (última posição conhecida).
struct GeoPoint: Sendable, Equatable {
    var lat: Double
    var lon: Double
}

/// Sinais de contexto para a priorização determinística das regiões (plano §9.2). Todos opcionais:
/// num relançamento a frio pode não haver nem posição conhecida nem check-in atual — a seleção então
/// degrada para "ordem por id" (ainda determinística), sem truncar silenciosamente.
struct GeofencePriorityHints: Sendable, Equatable {
    /// Última posição conhecida (fix GPS) — usada no critério "áreas mais próximas".
    var referenceLocation: GeoPoint?
    /// Nome do local do check-in atual — usado no critério "área do check-in atual e sua zona de saída".
    var currentLocalName: String?

    init(referenceLocation: GeoPoint? = nil, currentLocalName: String? = nil) {
        self.referenceLocation = referenceLocation
        self.currentLocalName = currentLocalName
    }
}

/// Resultado da seleção: o que será monitorado e o que ficou de fora pelo cap de 20 do iOS.
/// `omitted` NUNCA é descartado silenciosamente — o `GeofenceRegionManager` o reporta no diagnóstico
/// (plano §9.2: "Não será aceitável truncar silenciosamente uma lista").
struct GeofenceSelection: Sendable, Equatable {
    var selected: [GeofenceCircle]
    var omitted: [GeofenceCircle]
    var omittedCount: Int { omitted.count }
}

/// Priorização determinística e AUDITÁVEL das regiões de geofence sob o cap de 20 do iOS.
///
/// **Sem contraparte no Kotlin**: o Android permite até 100 geofences, então `GeofenceManager.kt` registra
/// TODOS os círculos sem ranquear. O iOS limita a **20 regiões por app** (`CLLocationManager`), então esta é
/// lógica genuinamente nova exigida pelo plano §9.2 — e ele é enfático: o ranking deve ser determinístico e
/// auditável, e as áreas omitidas devem ser comunicadas (nunca truncar em silêncio).
///
/// Ordem de prioridade recomendada pelo plano §9.2 e o que dela é realizável com os dados disponíveis
/// (`GeofenceCircle` = id/local/centro/raio; `GeofencePriorityHints` = posição + local atual):
///  1. **área do check-in atual e sua zona de saída** — círculo cujo `local` casa com `currentLocalName`.
///     (Uma `CLCircularRegion` observa entrada E saída, então incluir a área atual já cobre a "zona de saída".)
///  2. áreas do projeto ativo — **colapsa**: o `GET /check/geofences?chave` já devolve só os locais relevantes
///     do usuário/projeto, e o círculo não carrega projeto p/ distinguir sub-tiers. Todos ficam no mesmo tier.
///  3. favoritas/recentes — **colapsa**: `GeofenceCircle` não carrega esse sinal.
///  4. **mais próximas da posição conhecida** — ordena por distância (Haversine) a `referenceLocation`.
///  5. demais até o limite — desempate final estável por `id` crescente.
///
/// Chave de ordenação (lexicográfica, totalmente determinística): `(tier, distância, id)`.
enum GeofenceRegionPrioritizer {
    /// Limite rígido de regiões monitoradas por app no iOS (`CLLocationManager`).
    static let iosRegionCap = 20

    static func select(_ circles: [GeofenceCircle],
                       hints: GeofencePriorityHints = GeofencePriorityHints(),
                       cap: Int = iosRegionCap) -> GeofenceSelection {
        let ranked = circles.sorted { a, b in
            let ta = tier(a, hints), tb = tier(b, hints)
            if ta != tb { return ta < tb }
            let da = distance(a, hints), db = distance(b, hints)
            if da != db { return da < db }
            return a.id < b.id           // desempate final determinístico (não depende de sort estável)
        }
        guard cap >= 0 else { return GeofenceSelection(selected: [], omitted: ranked) }
        return GeofenceSelection(selected: Array(ranked.prefix(cap)), omitted: Array(ranked.dropFirst(cap)))
    }

    /// Tier 0 = área do check-in atual (casa com `currentLocalName`); 1 = as demais.
    private static func tier(_ circle: GeofenceCircle, _ hints: GeofencePriorityHints) -> Int {
        guard let current = hints.currentLocalName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else { return 1 }
        return circle.local.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(current) == .orderedSame ? 0 : 1
    }

    /// Distância (metros) ao ponto de referência; `.greatestFiniteMagnitude` sem referência → cai no id.
    private static func distance(_ circle: GeofenceCircle, _ hints: GeofencePriorityHints) -> Double {
        guard let ref = hints.referenceLocation else { return .greatestFiniteMagnitude }
        return haversineMeters(ref.lat, ref.lon, circle.centerLat, circle.centerLng)
    }

    /// Haversine puro (sem CoreLocation) — testável e determinístico. Grau de longitude encolhe com a
    /// latitude, então euclidiano em lat/lon ranquearia "mais próximo" errado; Haversine é correto.
    private static func haversineMeters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (bLat - aLat) * .pi / 180
        let dLon = (bLon - aLon) * .pi / 180
        let lat1 = aLat * .pi / 180
        let lat2 = bLat * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }
}
