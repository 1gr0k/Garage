import Fluent
import Foundation
import GarageAPI
import Vapor

struct ReceiptsController: RouteCollection {
    private static let cacheControl = "public, max-age=31536000, immutable"

    func boot(routes: any RoutesBuilder) throws {
        // One byte above the limit is collected so that an oversized body is answered with our own
        // `413 payloadTooLarge` by the check below; anything bigger is cut off by Vapor (also mapped to 413).
        routes.on(
            .PUT, "v1", "receipts", ":sha256", body: .collect(maxSize: .init(value: APIPath.maxReceiptBytes + 1)),
            use: put)
        routes.get("v1", "receipts", ":sha256", use: get)
    }

    @Sendable
    func put(_ request: Request) async throws -> Response {
        let sha256 = try Self.sha256Parameter(request)
        guard request.headers.contentType == .init(type: "image", subType: "jpeg") else {
            throw ServerError(.unsupportedMediaType, "Content-Type must be image/jpeg")
        }
        let bytes = Data(request.body.data?.readableBytesView ?? [])
        guard bytes.count <= APIPath.maxReceiptBytes else {
            throw ServerError(.payloadTooLarge, "Receipt must be at most \(APIPath.maxReceiptBytes) bytes")
        }
        guard Hashing.sha256Hex(bytes) == sha256 else {
            throw ServerError(.hashMismatch, "SHA-256 of the body does not match the path")
        }

        if try await Receipt.find(sha256, on: request.db) != nil {
            return Response(status: .ok)
        }
        try await Receipt(sha256: sha256, bytes: bytes).create(on: request.db)
        return Response(status: .created)
    }

    @Sendable
    func get(_ request: Request) async throws -> Response {
        let sha256 = try Self.sha256Parameter(request)
        guard let receipt = try await Receipt.find(sha256, on: request.db) else {
            throw ServerError(.notFound, "Receipt \(sha256) does not exist")
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: "\"\(sha256)\"")
        headers.replaceOrAdd(name: .cacheControl, value: Self.cacheControl)
        if let ifNoneMatch = request.headers.first(name: .ifNoneMatch), Self.matches(ifNoneMatch, sha256: sha256) {
            return Response(status: .notModified, headers: headers)
        }
        headers.contentType = .init(type: "image", subType: "jpeg")
        return Response(status: .ok, headers: headers, body: .init(data: receipt.bytes))
    }

    private static func sha256Parameter(_ request: Request) throws -> String {
        guard let value = request.parameters.get("sha256"), Hashing.isSHA256Hex(value) else {
            throw ServerError.malformed(
                "sha256 must be 64 lowercase hex characters", field: "sha256")
        }
        return value
    }

    /// `If-None-Match`: `*` or a comma-separated list of (possibly weak) quoted entity tags.
    private static func matches(_ header: String, sha256: String) -> Bool {
        header.split(separator: ",").contains { candidate in
            var tag = candidate.trimmingCharacters(in: .whitespaces)
            if tag == "*" { return true }
            if tag.hasPrefix("W/") { tag.removeFirst(2) }
            return tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == sha256
        }
    }
}
