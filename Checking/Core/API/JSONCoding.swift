import Foundation

/// Config de (de)serialização do módulo. Espelha o `Json { ignoreUnknownKeys; coerceInputValues;
/// encodeDefaults }` do Android. Ver port_spec_network_contracts §1/§8.
///
/// - Decoder: `ignoreUnknownKeys` = comportamento padrão do `JSONDecoder` (chaves extras ignoradas).
///   Chaves são mapeadas via `CodingKeys` explícitos por DTO (mistura de snake_case e camelCase — não
///   dá para usar uma única `keyDecodingStrategy`).
/// - Encoder: `encodeDefaults` = requests emitem TODO campo, com `null` explícito p/ opcionais (cada
///   request DTO faz `encode(to:)` custom com `encodeNil`).
enum JSONCoding {
    static var decoder: JSONDecoder { JSONDecoder() }
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}
