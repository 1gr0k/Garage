import Foundation
import Testing

@testable import GarageCore

@Test func matchKeyIgnoresCaseAndEdgesOfOtherText() {
    #expect(ServiceType.other("Антифриз").matchKey == ServiceType.other("антифриз").matchKey)
    #expect(ServiceType.other("  Антифриз \n").matchKey == ServiceType.other("антифриз").matchKey)
}

@Test func matchKeyCollapsesInnerWhitespace() {
    let spaced = ServiceType.other("Ремень   ГРМ")
    #expect(spaced.matchKey == ServiceType.other("ремень грм").matchKey)
    #expect(spaced.matchKey == ServiceType.other("Ремень\tГРМ").matchKey)
    // U+00A0 и U+202F — тоже пробельные.
    #expect(spaced.matchKey == ServiceType.other("Ремень\u{00A0}ГРМ").matchKey)
    #expect(spaced.matchKey == ServiceType.other("Ремень\u{202F}\u{202F}ГРМ").matchKey)
}

@Test func matchKeyDoesNotFoldDiacritics() {
    #expect(ServiceType.other("ёлка").matchKey != ServiceType.other("елка").matchKey)
    #expect(ServiceType.other("йод").matchKey != ServiceType.other("иод").matchKey)
}

@Test func differentWordsDoNotMatch() {
    #expect(ServiceType.other("антифриз").matchKey != ServiceType.other("антифриз 2").matchKey)
}

@Test func fixedTypeNeverMatchesOtherWithTheSameWord() {
    #expect(ServiceType.oilChange.matchKey != ServiceType.other("oilChange").matchKey)
    #expect(ServiceType.oilChange.matchKey == ServiceType.oilChange.matchKey)
    for type in [ServiceType.oilChange, .filters, .tires, .brakes, .chain, .suspension, .inspection, .repair] {
        #expect(type.matchKey == type.storageString)
    }
}
