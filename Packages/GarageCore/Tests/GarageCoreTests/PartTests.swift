import Testing
@testable import GarageCore

@Test func totalPriceMultipliesByQuantity() throws {
    let plug = try Part(name: "Свеча зажигания", partNumber: "NGK-6962", unitPrice: Money(rubles: 650, kopecks: 50), quantity: 4)

    #expect(plug.totalPrice == Money(rubles: 2_602))
}

@Test func partNumberIsOptional() throws {
    let rag = try Part(name: "Ветошь", unitPrice: Money(rubles: 100))

    #expect(rag.partNumber == nil)
    #expect(rag.quantity == 1)
    #expect(try roundTrip(rag) == rag)
}

@Test(arguments: [0, -3])
func partRejectsNonPositiveQuantity(quantity: Int) {
    #expect(throws: ValidationError.nonPositiveQuantity(quantity)) {
        try Part(name: "Фильтр", unitPrice: Money(rubles: 500), quantity: quantity)
    }
}

@Test func decodingPartValidatesQuantity() {
    let json = """
    {"id":"0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9","name":"Фильтр","unitPrice":50000,"quantity":0}
    """

    #expect(throws: ValidationError.nonPositiveQuantity(0)) {
        try decode(Part.self, from: json)
    }
}

@Test func updateQuantityValidatesAndKeepsOldValueOnFailure() throws {
    var filter = try Part(name: "Фильтр", unitPrice: Money(rubles: 500), quantity: 2)

    try filter.updateQuantity(3)
    #expect(filter.quantity == 3)
    #expect(filter.totalPrice == Money(rubles: 1_500))

    #expect(throws: ValidationError.nonPositiveQuantity(0)) {
        try filter.updateQuantity(0)
    }
    #expect(filter.quantity == 3)
}
