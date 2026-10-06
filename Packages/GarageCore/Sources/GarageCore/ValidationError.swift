import Foundation

/// A domain invariant violated when constructing or decoding a model.
public enum ValidationError: Error, Hashable, Sendable {
    case negativeMileage(Int)
    case nonPositiveQuantity(Int)
    case quantityTooLarge(Int)
    case unknownServiceType(String)
    case emptyPartName
    case negativeAmount(Money)
    case amountTooLarge(Money)
    case emptyServiceTypeDescription
    case invalidAmount(String)
}
