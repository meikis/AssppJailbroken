import Foundation
@testable import UnfairDaemonCore
import XCTVapor

final class WebRoutesTests: XCTestCase {
    func testAuthSettingsAndStaticRoutesShareOneVaporService() throws {
        let context = try WebTestContext()
        defer { context.cleanup() }

        let app = Application(.testing)
        defer { app.shutdown() }
        let manager = try WebDownloadManager(config: context.config)
        try webRoutes(app, config: context.config, manager: manager)

        try app.testable().test(.GET, "/api/auth/status") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.body.string, #"{"required":false}"#)
        }

        try app.testable().test(.GET, "/api/settings") { response in
            XCTAssertEqual(response.status, .ok)
            let json = try JSONSerialization.jsonObject(with: Data(response.body.string.utf8), options: []) as? [String: Any]
            XCTAssertEqual(json?["port"] as? Int, 18080)
            XCTAssertEqual(json?["dataDir"] as? String, context.dataDirectory.path)
            XCTAssertEqual(json?["unfairdBaseUrl"] as? String, "")
        }

        try app.testable().test(.GET, "/") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.body.string, "index")
        }

        try app.testable().test(.GET, "/downloads/anything") { response in
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.body.string, "index")
        }

        try app.testable().test(.GET, "/assets/missing.js") { response in
            XCTAssertEqual(response.status, .notFound)
        }
    }
}

private final class WebTestContext {
    let root: URL
    let dataDirectory: URL
    let publicDirectory: URL
    let config: WebConfig

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfaird-web-tests-\(UUID().uuidString)", isDirectory: true)
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        publicDirectory = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        try Data("index".utf8).write(to: publicDirectory.appendingPathComponent("index.html"))

        config = WebConfig(
            port: 18080,
            dataDirectory: dataDirectory,
            publicDirectory: publicDirectory,
            publicBaseURL: "",
            disableHTTPSRedirect: true,
            autoCleanupDays: 0,
            autoCleanupMaxMB: 0,
            maxDownloadMB: 0,
            downloadThreads: 8,
            accessPasswordHash: ""
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
