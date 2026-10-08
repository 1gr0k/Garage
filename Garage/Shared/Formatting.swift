import GarageCore
import SwiftUI

extension Money {
    var formatted: String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }

    /// Like `formatted`, without kopecks ("10 000 000 ₽").
    nonisolated var formattedWhole: String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB").precision(.fractionLength(0)))
    }
}

extension ServiceType {
    /// Display name. User-entered text for `.other` is returned as is, without a catalog lookup.
    var title: String {
        if case .other(let text) = self { return text }
        return String(localized: ServiceTypeChoice(self).title)
    }
}

extension Int {
    /// Distance in kilometers formatted for the current locale ("87,400 km" / "87 400 км").
    nonisolated var kilometers: String {
        Measurement(value: Double(self), unit: UnitLength.kilometers).formatted(
            .measurement(
                width: .abbreviated, usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

extension ServiceTypeChoice {
    var title: LocalizedStringResource {
        switch self {
        case .oilChange: "Oil change"
        case .filters: "Filters"
        case .tires: "Tires"
        case .brakes: "Brakes"
        case .chain: "Chain"
        case .suspension: "Suspension"
        case .inspection: "Inspection"
        case .repair: "Repair"
        case .other: "Other"
        }
    }
}

extension ServiceRecordDraft.FieldError {
    var message: LocalizedStringResource {
        switch self {
        case .required: "Required"
        case .notANumber: "Enter a valid number"
        case .invalid(let error): error.message
        }
    }
}

extension VehicleKind {
    var title: LocalizedStringResource {
        switch self {
        case .car: "Car"
        case .motorcycle: "Motorcycle"
        case .bicycle: "Bicycle"
        }
    }
}

extension VehicleDraft.FieldError {
    var message: LocalizedStringResource {
        switch self {
        case .required: "Required"
        case .notANumber: "Enter a valid number"
        // Годы строками: числовая интерполяция добавила бы разделители тысяч («1,900»).
        case .yearOutOfRange(let years): "Enter a year from \(String(years.lowerBound)) to \(String(years.upperBound))"
        case .invalid(let error): error.message
        }
    }
}

extension ValidationError {
    var message: LocalizedStringResource {
        switch self {
        case .negativeMileage: "Mileage can't be negative"
        case .nonPositiveQuantity: "Quantity must be at least 1"
        case .mileageTooLarge: "Mileage can't exceed \(ServiceRecord.maxMileageKm.kilometers)"
        case .quantityTooLarge: "Quantity can't exceed \(Part.maxQuantity)"
        case .unknownServiceType: "Unknown service type"
        case .emptyPartName: "Required"
        case .negativeAmount: "Amount can't be negative"
        case .amountTooLarge: "Amount can't exceed \(Money.maxAmount.formattedWhole)"
        case .emptyServiceTypeDescription: "Required"
        case .invalidAmount: "Enter a valid amount"
        case .noInterval: "Choose a time or mileage interval"
        // Границы строками: числовая интерполяция добавила бы разделители тысяч («3,650»).
        case .periodOutOfRange:
            "Interval must be from 1 to \(String(ServicePeriod.daysRange.upperBound)) days or from 1 to \(String(ServicePeriod.monthsRange.upperBound)) months"
        case .distanceOutOfRange: "Distance must be from 1 to \(ServiceRecord.maxMileageKm.kilometers)"
        case .unknownPeriod: "Unknown interval"
        }
    }
}
