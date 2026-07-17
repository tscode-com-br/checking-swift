import Foundation

// DTOs de projeto — port de data/dto/ProjectDtos.kt. Ver port_spec_network_contracts.md §7.

/// Os 11 primeiros campos vêm do `GET /projects` público; os 8 últimos NÃO são populados por esse
/// endpoint — defaults só p/ decode seguro (nunca usar em lógica de domínio; espelha o comentário Kotlin).
struct ProjectRow: Decodable, Sendable {
    let id: Int
    let name: String
    let countryCode: String
    let countryName: String
    let timezoneName: String
    let timezoneLabel: String
    let address: String
    let zipCode: String
    let formsEnabled: Bool
    let transportEnabled: Bool
    let emergencyPhone: String
    // Privados — defaults só p/ decode seguro; NÃO usar em lógica de domínio.
    let twilioAccountSid: String
    let twilioAuthToken: String
    let twilioPhoneNumber: String
    let mobileAdmin: String
    let emailLocalEmergency: String
    let emergencyCallMessage: String
    let inactivityDaysThreshold: Int
    let mixedZoneIntervalMinutes: Int

    enum CodingKeys: String, CodingKey {
        case id, name, address
        case countryCode = "country_code"
        case countryName = "country_name"
        case timezoneName = "timezone_name"
        case timezoneLabel = "timezone_label"
        case zipCode = "zip_code"
        case formsEnabled = "forms_enabled"
        case transportEnabled = "transport_enabled"
        case emergencyPhone = "emergency_phone"
        case twilioAccountSid = "twilio_account_sid"
        case twilioAuthToken = "twilio_auth_token"
        case twilioPhoneNumber = "twilio_phone_number"
        case mobileAdmin = "mobile_admin"
        case emailLocalEmergency = "email_local_emergency"
        case emergencyCallMessage = "emergency_call_message"
        case inactivityDaysThreshold = "inactivity_days_threshold"
        case mixedZoneIntervalMinutes = "mixed_zone_interval_minutes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        countryCode = try c.decode(String.self, forKey: .countryCode)
        countryName = try c.decode(String.self, forKey: .countryName)
        timezoneName = try c.decode(String.self, forKey: .timezoneName)
        timezoneLabel = try c.decode(String.self, forKey: .timezoneLabel)
        address = try c.decode(String.self, forKey: .address)
        zipCode = try c.decode(String.self, forKey: .zipCode)
        formsEnabled = try c.decode(Bool.self, forKey: .formsEnabled)
        transportEnabled = try c.decode(Bool.self, forKey: .transportEnabled)
        emergencyPhone = try c.decode(String.self, forKey: .emergencyPhone)
        twilioAccountSid = try c.decodeIfPresent(String.self, forKey: .twilioAccountSid) ?? ""
        twilioAuthToken = try c.decodeIfPresent(String.self, forKey: .twilioAuthToken) ?? ""
        twilioPhoneNumber = try c.decodeIfPresent(String.self, forKey: .twilioPhoneNumber) ?? ""
        mobileAdmin = try c.decodeIfPresent(String.self, forKey: .mobileAdmin) ?? ""
        emailLocalEmergency = try c.decodeIfPresent(String.self, forKey: .emailLocalEmergency) ?? ""
        emergencyCallMessage = try c.decodeIfPresent(String.self, forKey: .emergencyCallMessage) ?? ""
        inactivityDaysThreshold = try c.decodeIfPresent(Int.self, forKey: .inactivityDaysThreshold) ?? 60
        mixedZoneIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .mixedZoneIntervalMinutes) ?? 30
    }

    // Init memberwise p/ fakes/testes (os 8 privados com default, como no Kotlin).
    init(id: Int, name: String, countryCode: String, countryName: String, timezoneName: String, timezoneLabel: String,
         address: String, zipCode: String, formsEnabled: Bool, transportEnabled: Bool, emergencyPhone: String,
         twilioAccountSid: String = "", twilioAuthToken: String = "", twilioPhoneNumber: String = "",
         mobileAdmin: String = "", emailLocalEmergency: String = "", emergencyCallMessage: String = "",
         inactivityDaysThreshold: Int = 60, mixedZoneIntervalMinutes: Int = 30) {
        self.id = id; self.name = name; self.countryCode = countryCode; self.countryName = countryName
        self.timezoneName = timezoneName; self.timezoneLabel = timezoneLabel; self.address = address
        self.zipCode = zipCode; self.formsEnabled = formsEnabled; self.transportEnabled = transportEnabled
        self.emergencyPhone = emergencyPhone; self.twilioAccountSid = twilioAccountSid
        self.twilioAuthToken = twilioAuthToken; self.twilioPhoneNumber = twilioPhoneNumber
        self.mobileAdmin = mobileAdmin; self.emailLocalEmergency = emailLocalEmergency
        self.emergencyCallMessage = emergencyCallMessage; self.inactivityDaysThreshold = inactivityDaysThreshold
        self.mixedZoneIntervalMinutes = mixedZoneIntervalMinutes
    }
}

struct WebUserProjectsResponse: Decodable, Sendable {
    let projects: [String]
    let activeProject: String
    enum CodingKeys: String, CodingKey { case projects; case activeProject = "active_project" }
    init(projects: [String], activeProject: String) { self.projects = projects; self.activeProject = activeProject }
}

struct WebUserProjectsUpdateRequest: Encodable, Sendable {
    let projects: [String]
}

struct WebUserProjectsUpdateResponse: Decodable, Sendable {
    let projects: [String]
    let activeProject: String
    let ok: Bool
    let message: String
    enum CodingKeys: String, CodingKey { case projects, ok, message; case activeProject = "active_project" }
    init(projects: [String], activeProject: String, ok: Bool, message: String) {
        self.projects = projects; self.activeProject = activeProject; self.ok = ok; self.message = message
    }
}

struct WebProjectUpdateRequest: Encodable, Sendable {
    let project: String
}

struct WebProjectUpdateResponse: Decodable, Sendable {
    let projects: [String]
    let activeProject: String
    let ok: Bool
    let message: String
    let project: String
    enum CodingKeys: String, CodingKey { case projects, ok, message, project; case activeProject = "active_project" }
    init(projects: [String], activeProject: String, ok: Bool, message: String, project: String) {
        self.projects = projects; self.activeProject = activeProject; self.ok = ok
        self.message = message; self.project = project
    }
}
