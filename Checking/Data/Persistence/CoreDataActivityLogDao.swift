import CoreData

/// DAO Core Data do activity log — port de ActivityLogDao.kt (Room). Síncrono via `performAndWait`
/// (o `ActivityLogger` já escreve off-thread). Ordem newest-first = `(atEpochMs DESC, seq DESC)`.
/// Ver port_spec_persistence §3.
final class CoreDataActivityLogDao: ActivityLogDao, @unchecked Sendable {
    private let context: NSManagedObjectContext
    private var seqCounter: Int64?

    init(stack: CoreDataStack) {
        context = stack.container.newBackgroundContext()
    }

    private static var newestFirst: [NSSortDescriptor] {
        [NSSortDescriptor(key: "atEpochMs", ascending: false), NSSortDescriptor(key: "seq", ascending: false)]
    }

    /// Sequência monotônica (substitui o autoincrement). Semeada do maior `seq` existente; +1 por insert.
    private func nextSeq() -> Int64 {
        if seqCounter == nil {
            let request = NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName)
            request.sortDescriptors = [NSSortDescriptor(key: "seq", ascending: false)]
            request.fetchLimit = 1
            let maxSeq = ((try? context.fetch(request))?.first?.value(forKey: "seq") as? NSNumber)?.int64Value ?? 0
            seqCounter = maxSeq
        }
        seqCounter! += 1
        return seqCounter!
    }

    func insert(_ row: ActivityLogRow) throws {
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: ActivityLogModel.entityName, into: context)
            object.setValue(nextSeq(), forKey: "seq")
            object.setValue(row.atEpochMs, forKey: "atEpochMs")
            object.setValue(row.actor, forKey: "actor")
            object.setValue(row.kind, forKey: "kind")
            object.setValue(row.severity, forKey: "severity")
            object.setValue(row.description, forKey: "desc")
            object.setValue(row.location, forKey: "location")
            try context.save()
        }
    }

    func deleteOlderThan(_ epochMs: Int64) {
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName)
            request.predicate = NSPredicate(format: "atEpochMs < %lld", epochMs)   // `<` estrito (mantém ==)
            deleteFetched(request)
        }
    }

    func trimToMax(_ max: Int) {
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName)
            request.sortDescriptors = Self.newestFirst
            request.fetchOffset = max        // pula os `max` mais novos → o resto é deletado
            deleteFetched(request)
        }
    }

    func pageNewestFirst(limit: Int, offset: Int) -> [ActivityLogRow] {
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName)
            request.sortDescriptors = Self.newestFirst
            request.fetchLimit = limit
            request.fetchOffset = offset
            return ((try? context.fetch(request)) ?? []).map { object in
                ActivityLogRow(
                    id: ((object.value(forKey: "seq") as? NSNumber)?.int64Value) ?? 0,
                    atEpochMs: ((object.value(forKey: "atEpochMs") as? NSNumber)?.int64Value) ?? 0,
                    actor: object.value(forKey: "actor") as? String ?? "",
                    kind: object.value(forKey: "kind") as? String ?? "",
                    severity: object.value(forKey: "severity") as? String ?? "",
                    description: object.value(forKey: "desc") as? String ?? "",
                    location: object.value(forKey: "location") as? String)
            }
        }
    }

    func count() -> Int {
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName)
            return (try? context.count(for: request)) ?? 0
        }
    }

    func clearAll() {
        context.performAndWait {
            deleteFetched(NSFetchRequest<NSManagedObject>(entityName: ActivityLogModel.entityName))
        }
    }

    /// Fetch-and-delete (não NSBatchDeleteRequest — funciona em qualquer store e mantém o contexto coerente).
    private func deleteFetched(_ request: NSFetchRequest<NSManagedObject>) {
        let victims = (try? context.fetch(request)) ?? []
        guard !victims.isEmpty else { return }
        victims.forEach { context.delete($0) }
        try? context.save()
    }
}
