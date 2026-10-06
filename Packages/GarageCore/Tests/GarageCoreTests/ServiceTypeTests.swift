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

private let allStorageStrings = [
    "oilChange", "filters", "tires", "brakes", "chain", "suspension", "inspection", "repair",
    "other:Замена свечей",
]

@Test func storageStringMatchesJSONElements() {
    #expect(allTypes.map(\.storageString) == allStorageStrings)
}

@Test func storageStringRoundTrips() throws {
    for type in allTypes + [.other("oilChange"), .other("")] {
        #expect(try ServiceType(storageString: type.storageString) == type)
    }
}

@Test func unknownStorageStringThrows() {
    #expect(throws: ValidationError.unknownServiceType("tuning")) {
        try ServiceType(storageString: "tuning")
    }
}
