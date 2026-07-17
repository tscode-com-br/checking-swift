import CoreData

/// Modelo Core Data programático do activity log — port de CheckingActivityDatabase (Room v1, isolado).
/// Entidade `ActivityLogEntity` num store PRÓPRIO (não misturar no modelo principal). Ver port_spec_persistence §3.
/// `seq` (Int64 monotônico) substitui o PK autoincrement do Room — é o tiebreaker de timestamps iguais.
enum ActivityLogModel {
    static let entityName = "ActivityLogEntity"

    static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = entityName
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
            let attr = NSAttributeDescription()
            attr.name = name
            attr.attributeType = type
            attr.isOptional = optional
            return attr
        }
        // NB: `desc` (não `description` — reservado por NSObject).
        entity.properties = [
            attribute("seq", .integer64AttributeType),
            attribute("atEpochMs", .integer64AttributeType),
            attribute("actor", .stringAttributeType),
            attribute("kind", .stringAttributeType),
            attribute("severity", .stringAttributeType),
            attribute("desc", .stringAttributeType),
            attribute("location", .stringAttributeType, optional: true),
        ]
        model.entities = [entity]
        return model
    }
}

/// Container isolado do activity log (`checking_activity`). Ver port_spec_persistence §3.
final class CoreDataStack: @unchecked Sendable {
    let container: NSPersistentContainer

    /// `inMemory: true` → store SQLite efêmero (`/dev/null`) para testes.
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "CheckingActivity", managedObjectModel: ActivityLogModel.make())
        let description = NSPersistentStoreDescription()
        description.type = NSSQLiteStoreType
        if inMemory {
            description.url = URL(fileURLWithPath: "/dev/null")
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            description.url = directory.appendingPathComponent("checking_activity.sqlite")
        }
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { fatalError("CoreDataStack load failed: \(loadError)") }
    }
}
