import GarageCore
import SwiftUI

extension Money {
    var formatted: String {
        (Decimal(kopecks) / 100).formatted(.currency(code: "RUB"))
    }
}

extension ServiceType {
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
        case .other(let text): "\(text)"
        }
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

extension ValidationError {
    var message: LocalizedStringResource {
        switch self {
        case .negativeMileage: "Mileage can't be negative"
        case .nonPositiveQuantity: "Quantity must be at least 1"
        case .unknownServiceType: "Unknown service type"
        case .emptyPartName: "Required"
        case .negativeAmount: "Amount can't be negative"
        case .emptyServiceTypeDescription: "Required"
        case .invalidAmount: "Enter a valid amount"
        }
    }
}
