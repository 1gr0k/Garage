import Testing
@testable import GarageCore

@Test func displayNameCombinesMakeAndModel() {
    let first = Vehicle(make: "Toyota", model: "Land Cruiser", year: 2019)
    let second = Vehicle(make: "Toyota", model: "Land Cruiser", year: 2019)

    #expect(first.displayName == "Toyota Land Cruiser")
    #expect(first.id != second.id)
}
