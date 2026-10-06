import Foundation

/// A domain invariant violated when constructing or decoding a model.
public enum ValidationError: Error, Equatable, Sendable {
    case negativeMileage(Int)
    case nonPositiveQuantity(Int)
    case unknownServiceType(String)
}
