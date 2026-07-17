import Foundation

// Modelos de domínio de acidente — port de domain/model/AccidentModels.kt.
// O orquestrador lê `AccidentState.activeAccidents[].accidentId`; o modelo completo serve ao slice de acidente.

enum AccidentZone: String, Sendable, Equatable { case safety, accident }
enum AccidentSafetyStatus: String, Sendable, Equatable { case ok, help }

struct AccidentUserReport: Sendable, Equatable {
    var zone: AccidentZone?
    var status: AccidentSafetyStatus?
    var reportedAt: Date?
}

struct AccidentActiveItem: Sendable, Equatable {
    var accidentId: Int
    var accidentNumberLabel: String
    var projectId: Int
    var projectName: String
    var locationName: String
    var description: String?
    var awarenessStatus: String
    var currentUserReport: AccidentUserReport?
}

struct AccidentState: Sendable, Equatable {
    var isActive: Bool
    var accidentId: Int?
    var accidentNumberLabel: String?
    var projectId: Int?
    var projectName: String?
    var locationName: String?
    var description: String?
    var awarenessStatus: String?
    var currentUserReport: AccidentUserReport?
    var activeAccidents: [AccidentActiveItem]
}

/// Resultado do upload de vídeo — port de domain/model VideoUploadResult.
struct VideoUploadResult: Sendable, Equatable {
    var videoId: Int
    var publicUrl: String
    var capturedAt: Date
}

/// Resultado da chamada de emergência — port de domain/model EmergencyCallResult. `callStatus` é
/// String pura (não enum) — espelha o backend. A emergência real é acionada pelo BACKEND (Twilio).
struct EmergencyCallResult: Sendable, Equatable {
    var callNumber: Int
    var callNumberLabel: String
    var callSid: String?
    var callStatus: String
    var message: String
}

/// Opção de projeto/local do wizard — o Kotlin retorna `Pair<Int,String>`/`Triple<Int,String,Bool>`
/// do repositório e mapeia p/ `WizardProject`/`WizardLocation` na VM; aqui unificamos num único tipo
/// nomeado (mesma forma, sem a indireção do tuple — simplificação sem efeito de wire/comportamento).
struct WizardProject: Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
}
struct WizardLocation: Sendable, Equatable, Identifiable {
    var id: Int
    var name: String
    var registered: Bool
}
