import Fluent

/// The single monotonic version counter (single-user mode): one row with `id == 1`.
final class Counter: Model, @unchecked Sendable {
    static let schema = "counter"
    static let rowID = 1

    @ID(custom: "id", generatedBy: .user) var id: Int?
    @Field(key: "value") var value: Int64

    init() {}

    init(id: Int = Counter.rowID, value: Int64) {
        self.id = id
        self.value = value
    }
}
