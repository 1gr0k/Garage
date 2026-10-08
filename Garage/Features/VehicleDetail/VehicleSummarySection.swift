import GarageCore
import SwiftUI

/// Верхняя секция экрана машины: пробег и сумма расходов.
struct VehicleSummarySection: View {
    let mileage: Int
    let totalCost: Money

    var body: some View {
        Section {
            LabeledContent("Mileage", value: mileage.kilometers)
            LabeledContent("Total spent", value: totalCost.formatted)
        }
    }
}
