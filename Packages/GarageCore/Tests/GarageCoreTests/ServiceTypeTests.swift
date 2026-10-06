import Testing

@testable import GarageCore

private let allTypes: [ServiceType] = [
    .oilChange, .filters, .tires, .brakes, .chain, .suspension, .inspection, .repair,
    .other("Замена свечей"),
]

@Test func serviceTypeJSONIsStable() throws {
    let expected = """
        ["oilChange","filters","tires","brakes","chain","suspension","inspection","repair","other:Замена свечей"]
        """

    #expect(try encodedString(allTypes) == expected)
}

@Test func serviceTypeRoundTripsThroughJSON() throws {
    #expect(try roundTrip(allTypes) == allTypes)
    // A custom description that happens to match a known case name stays custom.
    #expect(try roundTrip(ServiceType.other("oilChange")) == .other("oilChange"))
    #expect(try roundTrip(ServiceType.other("")) == .other(""))
}

@Test func unknownServiceTypeFailsToDecode() {
    #expect(throws: DecodingError.self) {
        try decode(ServiceType.self, from: #""tuning""#)
    }
}
