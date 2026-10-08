import Foundation

/// A domain invariant violated when constructing or decoding a model.
public enum ValidationError: Error, Hashable, Sendable {
    case negativeMileage(Int)
    case mileageTooLarge(Int)
    case nonPositiveQuantity(Int)
    case quantityTooLarge(Int)
    case unknownServiceType(String)
    case emptyPartName
    case negativeAmount(Money)
    case amountTooLarge(Money)
    case emptyServiceTypeDescription
    case invalidAmount(String)
    // Правила обслуживания.
    /// У правила нет ни интервала по времени, ни по пробегу.
    case noInterval
    /// Значение интервала по времени вне границ (`ServicePeriod.daysRange` / `monthsRange`).
    case periodOutOfRange(Int)
    /// Интервал по пробегу вне `1...ServiceRecord.maxMileageKm`.
    case distanceOutOfRange(Int)
    case unknownPeriod(String)
}
