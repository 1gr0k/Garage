import Foundation
import GarageAPI
import Vapor

/// A JSON response encoded with the shared API configuration.
func jsonResponse(_ value: some Encodable, status: HTTPResponseStatus = .ok) throws -> Response {
    var headers = HTTPHeaders()
    headers.contentType = .json
    return Response(
        status: status, headers: headers, body: .init(data: try APICoding.makeEncoder().encode(value)))
}
