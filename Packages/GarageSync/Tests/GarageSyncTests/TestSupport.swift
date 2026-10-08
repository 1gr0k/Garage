import Foundation
import GarageAPI
import GarageCore

@testable import GarageSync

enum TestError: Error { case noScenario }

/// A scripted transport: responses are consumed in order, every request is recorded.
actor FakeHTTPTransport: HTTPTransport {
    enum Step: Sendable {
        case respond(Int, Data)
        case fail(any Error)
        /// Runs a side effect (e.g. a local edit made while the sync is in flight), then the step.
        indirect case before(@Sendable () async -> Void, Step)

        static func golden(_ name: String, status: Int = 200) throws -> Step {
            .respond(status, try GoldenExamples.data(name))
        }

        static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Step {
            .respond(status, try APICoding.makeEncoder().encode(value))
        }
    }

    private var steps: [Step]
    private(set) var requests: [HTTPRequest] = []

    init(_ steps: [Step] = []) {
        self.steps = steps
    }

    func enqueue(_ step: Step) {
        steps.append(step)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw TestError.noScenario }
        return try await run(steps.removeFirst())
    }

    private func run(_ step: Step) async throws -> HTTPResponse {
        switch step {
        case .respond(let status, let body): return HTTPResponse(status: status, body: body)
        case .fail(let error): throw error
        case .before(let effect, let next):
            await effect()
            return try await run(next)
        }
    }
}

struct StoredRecord: Hashable, Sendable {
    var record: ServiceRecord
    var extras: RecordSyncExtras
}

struct StoredRule: Hashable, Sendable {
    var rule: MaintenanceRule
    var extras: RuleSyncExtras
}

actor InMemorySyncStore: SyncStore {
    private(set) var vehicles: [UUID: Vehicle] = [:]
    private(set) var vehicleExtras: [UUID: VehicleSyncExtras] = [:]
    private(set) var records: [UUID: StoredRecord] = [:]
    private(set) var rules: [UUID: StoredRule] = [:]
    private var versions: [EntityRef: Int64] = [:]
    private var queue: [PendingChange] = []
    private var storedCursor: String?

    // MARK: Test helpers

    func setVersion(_ version: Int64, of ref: EntityRef) {
        versions[ref] = version
    }

    func upsertLocal(_ entity: SyncEntity, modifiedAt: Date, changeID: UUID) {
        write(entity)
        enqueue(.upsert(entity), modifiedAt: modifiedAt, changeID: changeID)
    }

    func deleteLocal(_ ref: EntityRef, modifiedAt: Date, changeID: UUID) {
        remove(ref)
        enqueue(.delete(ref), modifiedAt: modifiedAt, changeID: changeID)
    }

    /// Сущность, уже синхронизированная с сервером: данные и версия есть, в очереди ничего.
    func storeSynced(_ entity: SyncEntity, version: Int64) {
        write(entity)
        versions[entity.ref] = version
    }

    func vehicle(_ id: UUID) -> Vehicle? { vehicles[id] }
    func extras(ofVehicle id: UUID) -> VehicleSyncExtras? { vehicleExtras[id] }
    func stored(_ id: UUID) -> StoredRecord? { records[id] }
    func storedRule(_ id: UUID) -> StoredRule? { rules[id] }

    private func enqueue(_ operation: LocalOperation, modifiedAt: Date, changeID: UUID) {
        let ref = operation.ref
        if let index = queue.firstIndex(where: { $0.operation.ref == ref }) {
            queue[index] = PendingChange(
                changeID: changeID, baseVersion: queue[index].baseVersion, modifiedAt: modifiedAt,
                operation: operation)
        } else {
            queue.append(
                PendingChange(
                    changeID: changeID, baseVersion: versions[ref], modifiedAt: modifiedAt, operation: operation))
        }
    }

    private func write(_ entity: SyncEntity) {
        switch entity {
        case .vehicle(let vehicle, let extras):
            vehicles[vehicle.id] = vehicle
            vehicleExtras[vehicle.id] = extras
        case .serviceRecord(let record, let extras): records[record.id] = StoredRecord(record: record, extras: extras)
        case .maintenanceRule(let rule, let extras): rules[rule.id] = StoredRule(rule: rule, extras: extras)
        }
    }

    private func remove(_ ref: EntityRef) {
        switch ref.kind {
        case .vehicle:
            vehicles[ref.id] = nil
            vehicleExtras[ref.id] = nil
        case .serviceRecord: records[ref.id] = nil
        case .maintenanceRule: rules[ref.id] = nil
        }
    }

    // MARK: SyncStore

    func pendingChanges() -> [PendingChange] { queue }

    func pendingChange(for ref: EntityRef) -> PendingChange? {
        queue.first { $0.operation.ref == ref }
    }

    func version(of ref: EntityRef) -> Int64? { versions[ref] }

    func markApplied(changeID: UUID, version: Int64) {
        guard let index = queue.firstIndex(where: { $0.changeID == changeID }) else { return }
        versions[queue[index].operation.ref] = version
        queue.remove(at: index)
    }

    func rebase(changeID: UUID, onto version: Int64) {
        guard let index = queue.firstIndex(where: { $0.changeID == changeID }) else { return }
        queue[index].baseVersion = version
    }

    /// Refs whose `apply` fails with `SyncStoreError`, like a record without its vehicle.
    var unappliable: Set<EntityRef> = []

    func setUnappliable(_ ref: EntityRef) { unappliable.insert(ref) }

    func apply(_ change: RemoteChange, for ref: EntityRef) throws {
        if unappliable.contains(ref) { throw SyncStoreError(cannotApply: TestError.noScenario) }
        switch change.operation {
        case .upsert(let entity): write(entity)
        case .delete(let ref):
            if ref.kind == .vehicle { dropChildren(ofVehicle: ref.id) }
            remove(ref)
        }
        if let version = change.version { versions[ref] = version }
        queue.removeAll { $0.operation.ref == ref }
    }

    /// Каскад, как требует контракт `SyncStore.apply`: записи и правила машины удаляются вместе с pending-upsert'ами.
    /// Условие `!isDelete` защитное: у дочерней сущности с pending-delete самой сущности уже нет, её не найти.
    private func dropChildren(ofVehicle id: UUID) {
        let children =
            records.values.filter { $0.record.vehicleID == id }.map {
                EntityRef(kind: .serviceRecord, id: $0.record.id)
            }
            + rules.values.filter { $0.rule.vehicleID == id }.map { EntityRef(kind: .maintenanceRule, id: $0.rule.id) }
        for childRef in children {
            remove(childRef)
            queue.removeAll { $0.operation.ref == childRef && !$0.operation.isDelete }
        }
    }

    func discard(changeID: UUID) {
        queue.removeAll { $0.changeID == changeID }
    }

    func cursor() -> String? { storedCursor }
    func setCursor(_ cursor: String?) { storedCursor = cursor }
}

// MARK: Fixtures

func uuid(_ string: String) -> UUID { UUID(uuidString: string)! }

func date(_ string: String) -> Date {
    try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
}

enum IDs {
    static let vehicle = uuid("11111111-1111-4111-8111-111111111111")
    static let record = uuid("22222222-2222-4222-8222-222222222222")
    static let deletedRecord = uuid("33333333-3333-4333-8333-333333333333")
    static let rule = uuid("88888888-8888-4888-8888-888888888888")
    static let otherRule = uuid("88888888-8888-4888-8888-888888888889")
    static let orphanRecord = uuid("77777777-7777-4777-8777-777777777777")
    static let missingVehicle = uuid("99999999-9999-4999-8999-999999999999")
    static let changeA = uuid("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
    static let changeB = uuid("BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")
    static let changeC = uuid("CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")
    static let changeD = uuid("DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")
}

func ref(_ kind: EntityKind, _ id: UUID) -> EntityRef { EntityRef(kind: kind, id: id) }

func makeVehicle(id: UUID = IDs.vehicle, make: String = "Toyota", mileageKm: Int = 87_400) -> Vehicle {
    try! Vehicle(id: id, kind: .car, make: make, model: "Land Cruiser", year: 2019, mileageKm: mileageKm)
}

func makeRecord(
    id: UUID = IDs.record, vehicleID: UUID = IDs.vehicle, serviceType: ServiceType = .oilChange,
    laborKopecks: Int = 350_000, notes: String = "Заменено масло"
) -> ServiceRecord {
    try! ServiceRecord(
        id: id, vehicleID: vehicleID, date: date("2026-10-01T00:00:00.000Z"), mileageKm: 87_000,
        serviceType: serviceType, laborCost: Money(kopecks: laborKopecks), notes: notes)
}

func makeRule(
    id: UUID = IDs.rule, vehicleID: UUID = IDs.vehicle, serviceType: ServiceType = .oilChange,
    period: ServicePeriod? = .months(12), distanceKm: Int? = 10_000
) -> MaintenanceRule {
    try! MaintenanceRule(
        id: id, vehicleID: vehicleID, serviceType: serviceType, period: period, distanceKm: distanceKm,
        start: MaintenanceStart(date: date("2026-10-08T00:00:00.000Z"), mileageKm: 87_400))
}

func makeClient(_ transport: FakeHTTPTransport) -> SyncAPIClient {
    SyncAPIClient(transport: transport, token: "test-token")
}

func makeEngine(_ store: InMemorySyncStore, _ transport: FakeHTTPTransport) -> SyncEngine {
    SyncEngine(store: store, client: makeClient(transport))
}

func emptyPull(cursor: String) -> PullResponse {
    PullResponse(changes: [], cursor: cursor, hasMore: false)
}

func decodePush(_ request: HTTPRequest) throws -> PushRequest {
    try APICoding.makeDecoder().decode(PushRequest.self, from: request.body ?? Data())
}

// MARK: Receipts

actor InMemoryBlobStore: ReceiptBlobStore {
    var blobs: [String: Data]
    var missing: [ReceiptRefDTO]
    var failStoring = false
    private(set) var stored: [String: Data] = [:]

    init(blobs: [String: Data] = [:], missing: [ReceiptRefDTO] = []) {
        self.blobs = blobs
        self.missing = missing
    }

    func setFailStoring(_ value: Bool) { failStoring = value }

    func receiptData(sha256: String) -> Data? { blobs[sha256] }

    func missingReceipts() -> [ReceiptRefDTO] { missing.filter { stored[$0.sha256] == nil } }

    func storeReceipt(_ data: Data, for ref: ReceiptRefDTO) throws {
        if failStoring { throw TestError.noScenario }
        stored[ref.sha256] = data
    }
}

func makeEngine(
    _ store: InMemorySyncStore, _ transport: FakeHTTPTransport, receipts: InMemoryBlobStore
) -> SyncEngine {
    SyncEngine(store: store, client: makeClient(transport), receipts: receipts)
}
