import Fluent
import Foundation
import GarageAPI
import Vapor

struct ChangesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("v1", "changes", use: pull)
        routes.post("v1", "changes", use: push)
    }

    @Sendable
    func pull(_ request: Request) async throws -> Response {
        let after = try Self.parseAfter(request)
        let limit = try Self.parseLimit(request)

        var rows = try await EntityRow.query(on: request.db)
            .filter(\.$version > after)
            .sort(\.$version)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }

        let changes = try rows.map { try $0.toServerChange() }
        let cursor = changes.last.map { String($0.version) } ?? String(after)
        return try jsonResponse(PullResponse(changes: changes, cursor: cursor, hasMore: hasMore))
    }

    @Sendable
    func push(_ request: Request) async throws -> Response {
        let body = try request.content.decode(PushRequest.self)
        guard body.changes.count <= APIPath.maxPushBatch else {
            throw ServerError.malformed(
                "At most \(APIPath.maxPushBatch) changes per request", field: "changes")
        }
        var results: [PushResult] = []
        results.reserveCapacity(body.changes.count)
        for change in body.changes {
            results.append(await request.application.changeWriter.apply(change))
        }
        return try jsonResponse(PushResponse(results: results))
    }

    private static func parseAfter(_ request: Request) throws -> Int64 {
        guard let raw = try request.query.get(String?.self, at: APIPath.afterQuery) else { return 0 }
        guard isDecimal(raw), let value = Int64(raw) else {
            throw ServerError.malformed(
                "after must be a non-negative integer", field: APIPath.afterQuery)
        }
        return value
    }

    private static func parseLimit(_ request: Request) throws -> Int {
        guard let raw = try request.query.get(String?.self, at: APIPath.limitQuery) else {
            return APIPath.defaultPullLimit
        }
        guard isDecimal(raw), let value = Int(raw), (1...APIPath.maxPullLimit).contains(value) else {
            throw ServerError.malformed(
                "limit must be between 1 and \(APIPath.maxPullLimit)", field: APIPath.limitQuery)
        }
        return value
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }
}
