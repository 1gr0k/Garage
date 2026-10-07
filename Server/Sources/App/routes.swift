import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: DevicesController())

    let authenticated = app.grouped(DeviceAuthenticator(), RequireDeviceMiddleware())
    try authenticated.register(collection: ChangesController())
    try authenticated.register(collection: ReceiptsController())
}
