import Foundation
import Vapor

func registerAppleProtocolRoutes(_ app: Application, config: WebConfig, manager: WebDownloadManager) {
    app.post("api", "apple", "authenticate") { req -> EventLoopFuture<Response> in
        try requireAccess(req, config: config)
        return try appleProtocolFuture(for: req, as: AppleAuthenticateRequest.self) { body in
            let account = try await AppleProtocolService.authenticate(body)
            return try jsonEncodableResponse(AppleAccountResponse(account: account))
        }
    }

    app.post("api", "apple", "purchase") { req -> EventLoopFuture<Response> in
        try requireAccess(req, config: config)
        return try appleProtocolFuture(for: req, as: AppleAccountRequest.self) { body in
            let account = try await AppleProtocolService.purchase(account: body.account, software: body.software)
            return try jsonEncodableResponse(AppleAccountResponse(account: account))
        }
    }

    app.post("api", "apple", "versions") { req -> EventLoopFuture<Response> in
        try requireAccess(req, config: config)
        return try appleProtocolFuture(for: req, as: AppleVersionListRequest.self) { body in
            let result = try await AppleProtocolService.listVersions(account: body.account, software: body.software)
            return try jsonEncodableResponse(AppleVersionListResponse(account: result.account, versions: result.versions))
        }
    }

    app.post("api", "apple", "version-metadata") { req -> EventLoopFuture<Response> in
        try requireAccess(req, config: config)
        return try appleProtocolFuture(for: req, as: AppleVersionMetadataRequest.self) { body in
            let result = try await AppleProtocolService.versionMetadata(
                account: body.account,
                software: body.software,
                versionId: body.versionId
            )
            return try jsonEncodableResponse(AppleVersionMetadataResponse(account: result.account, metadata: result.metadata))
        }
    }

    app.post("api", "downloads", "apple") { req -> EventLoopFuture<Response> in
        try requireAccess(req, config: config)
        return try appleProtocolFuture(for: req, as: AppleDownloadRequest.self) { body in
            guard body.accountHash.count >= WebConfig.minAccountHashLength else {
                throw AppleProtocolError(status: .badRequest, message: "Missing or invalid accountHash")
            }

            let result = try await AppleProtocolService.downloadInfo(
                account: body.account,
                software: body.software,
                externalVersionId: body.externalVersionId
            )
            var software = body.software
            software.version = result.output.bundleShortVersionString
            let task = try manager.createTask(CreateDownloadRequest(
                software: software,
                accountHash: body.accountHash,
                downloadURL: result.output.downloadURL,
                sinfs: result.output.sinfs,
                iTunesMetadata: result.output.iTunesMetadata
            ))
            return try jsonEncodableResponse(AppleDownloadResponse(account: result.account, task: task), status: .created)
        }
    }
}

private func appleProtocolFuture<T: Decodable>(
    for req: Request,
    as type: T.Type,
    _ body: @Sendable @escaping (T) async throws -> Response
) throws -> EventLoopFuture<Response> {
    do {
        let decoded = try req.content.decode(type)
        return appleProtocolFuture(on: req.eventLoop) {
            try await body(decoded)
        }
    } catch let error as DecodingError {
        return req.eventLoop.makeSucceededFuture(
            try appleErrorResponse(AppleProtocolError(status: .badRequest, message: String(describing: error)))
        )
    }
}

private func appleProtocolFuture(
    on eventLoop: EventLoop,
    _ body: @Sendable @escaping () async throws -> Response
) -> EventLoopFuture<Response> {
    eventLoop.makeFutureWithTask {
        try await appleProtocolResponse(body)
    }
}

private func appleProtocolResponse(_ body: () async throws -> Response) async throws -> Response {
    do {
        return try await body()
    } catch let error as AppleProtocolError {
        return try appleErrorResponse(error)
    } catch {
        return try appleErrorResponse(AppleProtocolError(message: String(describing: error)))
    }
}

private func appleErrorResponse(_ error: AppleProtocolError) throws -> Response {
    var payload: [String: Any] = ["error": error.message]
    if let code = error.code {
        payload["code"] = code
    }
    if error.codeRequired {
        payload["codeRequired"] = true
    }
    return try jsonResponse(payload, status: error.status)
}
