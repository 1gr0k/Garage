import Testing

@testable import GarageCore

@Test func rublesAndKopecksCombine() {
    #expect(Money(rubles: 1_234, kopecks: 50).kopecks == 123_450)
    #expect(Money(rubles: 10) == Money(kopecks: 1_000))
    #expect(Money.zero.kopecks == 0)
}

@Test func moneyArithmeticIsExact() {
    let a = Money(rubles: 0, kopecks: 10)
    let b = Money(rubles: 0, kopecks: 20)

    #expect(a + b == Money(kopecks: 30))
    #expect(b - a == Money(kopecks: 10))
    #expect(Money(rubles: 450, kopecks: 99) * 3 == Money(rubles: 1_352, kopecks: 97))
}

@Test func moneyIsComparable() {
    #expect(Money(rubles: 99, kopecks: 99) < Money(rubles: 100))
    #expect([Money(rubles: 5), .zero, Money(kopecks: 1)].max() == Money(rubles: 5))
}

@Test func moneyEncodesAsWholeKopecks() throws {
    let price = Money(rubles: 123, kopecks: 45)

    #expect(try encodedString(price) == "12345")
    #expect(try roundTrip(price) == price)
}
