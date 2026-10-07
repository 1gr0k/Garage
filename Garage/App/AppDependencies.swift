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
        addServiceRecord = AddServiceRecord(records: SwiftDataServiceRecordRepository(container: container))
        receiptPreparer = ImageIOReceiptPreparer()
    }

    func makeServiceRecordFormViewModel(vehicleID: Vehicle.ID, currentMileageKm: Int) -> ServiceRecordFormViewModel {
        ServiceRecordFormViewModel(
            vehicleID: vehicleID, currentMileageKm: currentMileageKm, addServiceRecord: addServiceRecord,
            receiptPreparer: receiptPreparer)
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
