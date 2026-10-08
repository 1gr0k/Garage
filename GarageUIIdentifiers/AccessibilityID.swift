import Foundation

/// Идентификаторы доступности для UI-тестов. Файл входит и в приложение, и в `GarageUITests`:
/// вью и тесты компилируют одни и те же строки. Идентификатор — не текст для пользователя,
/// в каталог строк он не идёт и от языка не зависит.
nonisolated enum AccessibilityID {
    enum VehicleList {
        static let add = "vehicleList.add"
        static let sync = "vehicleList.sync"
        static let empty = "vehicleList.empty"
        /// Префикс идентификаторов строк машин: для предиката `BEGINSWITH`.
        static let rowPrefix = "vehicleList.row."
        static func row(_ id: UUID) -> String { rowPrefix + id.uuidString }
        static func rowSubtitle(_ id: UUID) -> String { "vehicleList.rowSubtitle." + id.uuidString }
        static let swipeDelete = "vehicleList.swipeDelete"
        static let confirmDelete = "vehicleList.confirmDelete"
    }

    enum SyncSettings {
        static let close = "syncSettings.close"
    }

    enum VehicleDetail {
        static let addRecord = "vehicleDetail.addRecord"
        static let more = "vehicleDetail.more"
        static let edit = "vehicleDetail.edit"
        static let deleteVehicle = "vehicleDetail.deleteVehicle"
        static let confirmDeleteVehicle = "vehicleDetail.confirmDeleteVehicle"
        static let notFound = "vehicleDetail.notFound"
        static let noRecords = "vehicleDetail.noRecords"
        /// Префикс идентификаторов строк записей.
        static let recordPrefix = "vehicleDetail.record."
        static func record(_ id: UUID) -> String { recordPrefix + id.uuidString }
        static func receiptClip(_ id: UUID) -> String { "vehicleDetail.receiptClip." + id.uuidString }
        static let swipeDeleteRecord = "vehicleDetail.swipeDeleteRecord"
        static let confirmDeleteRecord = "vehicleDetail.confirmDeleteRecord"
    }

    enum VehicleForm {
        static let close = "vehicleForm.close"
        static let confirm = "vehicleForm.confirm"
        static let kind = "vehicleForm.kind"
        static let make = "vehicleForm.make"
        static let makeError = "vehicleForm.makeError"
        static let model = "vehicleForm.model"
        static let modelError = "vehicleForm.modelError"
        static let year = "vehicleForm.year"
        static let yearError = "vehicleForm.yearError"
        static let mileage = "vehicleForm.mileage"
        static let mileageError = "vehicleForm.mileageError"
    }

    enum ServiceRecordForm {
        static let close = "serviceRecordForm.close"
        static let confirm = "serviceRecordForm.confirm"
        static let mileage = "serviceRecordForm.mileage"
        static let mileageError = "serviceRecordForm.mileageError"
        static let attachPhoto = "serviceRecordForm.attachPhoto"
        static let replacePhoto = "serviceRecordForm.replacePhoto"
        static let removePhoto = "serviceRecordForm.removePhoto"
        static let deleteRecord = "serviceRecordForm.deleteRecord"
        static let confirmDelete = "serviceRecordForm.confirmDelete"
    }
}
