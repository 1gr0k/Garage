import Foundation
import GarageCore
import GarageStorage
import GarageSync
import Observation
import SwiftData
import UIKit

/// Composition root: единственное место, где приложение создаёт адаптеры хранилища и сети
/// и собирает из них use case'ы и ViewModel.
@Observable
final class AppDependencies {
    let container: ModelContainer
    /// Один на приложение: состояние синхронизации общее для всех экранов.
    let syncViewModel: SyncViewModel

    private let addServiceRecord: AddServiceRecord
    private let updateServiceRecord: UpdateServiceRecord
    private let recordEditing: any ServiceRecordEditing
    private let receiptPreparer: any ReceiptImagePreparing

    init(
        container: ModelContainer,
        credentials: any SyncCredentialsStore = KeychainCredentialsStore(),
        registrar: any DeviceRegistrar = SyncAPIDeviceRegistrar(),
        deviceName: @escaping @MainActor () -> String = { UIDevice.current.name }
    ) {
        self.container = container
        let service = SwiftDataSyncService(container: container, credentials: credentials)
        syncViewModel = SyncViewModel(
            service: service,
            registerDevice: RegisterDevice(registrar: registrar, credentials: credentials),
            syncNow: SyncNow(service: service, credentials: credentials),
            forgetDevice: ForgetDevice(service: service, credentials: credentials),
            credentials: credentials,
            deviceName: deviceName)
        // Один адаптер реализует оба порта: добавление и правку/удаление.
        let recordRepository = SwiftDataServiceRecordRepository(container: container)
        addServiceRecord = AddServiceRecord(records: recordRepository)
        updateServiceRecord = UpdateServiceRecord(records: recordRepository)
        recordEditing = recordRepository
        receiptPreparer = ImageIOReceiptPreparer()
    }

    func makeServiceRecordFormViewModel(vehicleID: Vehicle.ID, currentMileageKm: Int) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            mode: .add(vehicleID: vehicleID), currentMileageKm: currentMileageKm,
            addServiceRecord: addServiceRecord, updateServiceRecord: updateServiceRecord, records: recordEditing,
            receiptPreparer: receiptPreparer)
    }

    /// Форма правки. `currentMileageKm` — пробег машины без учёта самой записи (считает вызывающий).
    func makeServiceRecordFormViewModel(
        editing record: ServiceRecord, hasStoredReceipt: Bool, storedReceipt: Data?, currentMileageKm: Int
    ) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            mode: .edit(original: record, hasStoredReceipt: hasStoredReceipt), currentMileageKm: currentMileageKm,
            storedReceipt: storedReceipt, addServiceRecord: addServiceRecord,
            updateServiceRecord: updateServiceRecord, records: recordEditing, receiptPreparer: receiptPreparer)
    }

    func makeVehicleDetailViewModel() -> VehicleDetailViewModel {
        VehicleDetailViewModel(records: recordEditing)
    }

    /// Боевой запуск: хранилище готовится вне главного потока, затем собираются зависимости.
    static func bootstrap() async throws -> AppDependencies {
        AppDependencies(container: try await AppBootstrap.prepare())
    }

    /// Рабочие зависимости на in-memory хранилище с демо-данными, для превью.
    static func preview() -> AppDependencies {
        let container = try! GarageStore.makeContainer(inMemory: true)
        SampleSeeder.insertSamples(into: container.mainContext)
        return AppDependencies(container: container)
    }
}
