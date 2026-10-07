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

@Test(arguments: [
    ("1250", 125_000), ("1250,5", 125_050), ("1250.50", 125_050), ("0,05", 5), ("7.", nil),
    ("1 250,50", 125_050), ("1\u{00A0}250", 125_000), ("1\u{202F}250,00", 125_000), (" 99 ", 9_900),
])
func parsingAcceptsSpacesAndBothSeparators(text: String, kopecks: Int?) throws {
    if let kopecks {
        #expect(try Money(parsing: text) == Money(kopecks: kopecks))
    } else {
        #expect(throws: ValidationError.invalidAmount(text)) { try Money(parsing: text) }
    }
}

@Test(arguments: ["", "  ", "-5", "+5", "abc", "12a", "1,234", "1,2,3", ",50", "1e3", "٣", "99999999999999999999"])
func parsingRejectsInvalidInput(text: String) {
    #expect(throws: ValidationError.invalidAmount(text)) { try Money(parsing: text) }
}

@Test(arguments: [
    (0, "0"), (125_000, "1250"), (125_050, "1250.50"), (5, "0.05"), (125_005, "1250.05"), (990, "9.90"),
])
func editingTextUsesTwoKopeckDigits(kopecks: Int, expected: String) {
    let money = Money(kopecks: kopecks)

    #expect(money.editingText() == expected)
    #expect(money.editingText(decimalSeparator: .period) == expected)
    #expect(money.editingText(decimalSeparator: .comma) == expected.replacing(".", with: ","))
}

@Test(
    arguments: [0, 5, 100, 125_050, 99_999_999, 1_000_000_000],
    [Money.DecimalSeparator.period, .comma])
func editingTextRoundTripsThroughParsing(kopecks: Int, separator: Money.DecimalSeparator) throws {
    let money = Money(kopecks: kopecks)

    #expect(try Money(parsing: money.editingText(decimalSeparator: separator)) == money)
}
