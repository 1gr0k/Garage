import Foundation

/// A domain invariant violated when constructing or decoding a model.
public enum ValidationError: Error, Hashable, Sendable {
    case negativeMileage(Int)
    case nonPositiveQuantity(Int)
    case unknownServiceType(String)
    case emptyPartName
    case negativeAmount(Money)
    case emptyServiceTypeDescription
    case invalidAmount(String)
}
