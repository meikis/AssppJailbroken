import AsyncHTTPClient
import Foundation
import Vapor

enum AppleProtocolService {
    private static let userAgent = "Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6"
    private static let defaultAuthEndpoint = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
    private static let rateLimitCode = "rate_limited"
    private static let rateLimitMessage = "Apple rate limit reached. Wait before trying again."

    static func authenticate(_ request: AppleAuthenticateRequest) async throws -> AppleAccount {
        var cookies = request.existingCookies ?? []
        var storeFront = ""
        var pod: String?
        var endpoint = try await authEndpoint(deviceIdentifier: request.deviceIdentifier)
        var currentAttempt = 0
        var redirectAttempt = 0
        var lastError: Error?

        while currentAttempt < 2 && redirectAttempt <= 3 {
            currentAttempt += 1
            do {
                let body = try plistData([
                    "appleId": request.email,
                    "attempt": (request.code ?? "").isEmpty ? "4" : "2",
                    "guid": request.deviceIdentifier,
                    "password": request.password + (request.code ?? ""),
                    "rmp": "0",
                    "why": "signIn",
                ])

                let response = try await sendAppleRequest(
                    url: endpoint,
                    method: .POST,
                    headers: [("Content-Type", "application/x-apple-plist")],
                    body: body,
                    cookies: cookies
                )

                cookies.merge(response.cookies)

                if let storeValue = response.firstHeader("x-set-apple-store-front")?
                    .split(separator: "-")
                    .first
                {
                    storeFront = String(storeValue)
                }
                if let podValue = response.firstHeader("pod"), podValue.isEmpty == false {
                    pod = podValue
                }

                if response.statusCode == 302 {
                    guard let location = response.firstHeader("location"),
                          let redirectURL = URL(string: location)
                    else {
                        throw AppleProtocolError(message: "failed to retrieve redirect location")
                    }
                    endpoint = redirectURL
                    currentAttempt -= 1
                    redirectAttempt += 1
                    continue
                }

                try throwRateLimitIfNeeded(response)
                guard response.data.isEmpty == false else {
                    throw AppleProtocolError(message: "response body is empty (code: \(response.statusCode))")
                }

                let dict = try parsePlist(response.data)
                if let failureType = dict["failureType"] as? String,
                   failureType.isEmpty,
                   (request.code ?? "").isEmpty,
                   dict["customerMessage"] as? String == "MZFinance.BadLogin.Configurator_message"
                {
                    throw AppleProtocolError(
                        status: .conflict,
                        message: "Authentication requires verification code",
                        codeRequired: true
                    )
                }

                if stringValue(dict["failureType"]) == "5005" {
                    throw AppleProtocolError(status: .conflict, message: "invalid or expired 2FA code", code: "5005")
                }

                let failureMessage = ((dict["dialog"] as? [String: Any])?["explanation"] as? String) ??
                    (dict["customerMessage"] as? String)
                guard let accountInfo = dict["accountInfo"] as? [String: Any] else {
                    throw AppleProtocolError(message: failureMessage ?? "missing accountInfo")
                }
                guard let address = accountInfo["address"] as? [String: Any] else {
                    throw AppleProtocolError(message: failureMessage ?? "missing address")
                }

                return AppleAccount(
                    email: request.email,
                    password: request.password,
                    appleId: stringValue(accountInfo["appleId"]) ?? "",
                    store: storeFront,
                    firstName: stringValue(address["firstName"]) ?? "",
                    lastName: stringValue(address["lastName"]) ?? "",
                    passwordToken: stringValue(dict["passwordToken"]) ?? "",
                    directoryServicesIdentifier: stringValue(dict["dsPersonId"]) ?? "",
                    cookies: cookies,
                    deviceIdentifier: request.deviceIdentifier,
                    pod: pod
                )
            } catch let error as AppleProtocolError {
                throw error
            } catch {
                lastError = error
            }
        }

        if let error = lastError as? AppleProtocolError {
            throw error
        }
        if let error = lastError {
            throw AppleProtocolError(message: String(describing: error))
        }
        throw AppleProtocolError(message: "authentication failed for an unknown reason")
    }

    static func purchase(account: AppleAccount, software: Software) async throws -> AppleAccount {
        guard (software.price ?? 0) <= 0 else {
            throw AppleProtocolError(status: .badRequest, message: "purchasing paid apps is not supported")
        }

        return try await purchaseWithTokenRefresh(account: account, software: software)
    }

    private static func purchaseWithPricingFallback(account: AppleAccount, software: Software) async throws -> AppleAccount {
        do {
            return try await purchaseWithParams(account: account, software: software, pricingParameters: "STDQ")
        } catch let error as AppleProtocolError {
            if error.code == "2059" {
                return try await purchaseWithParams(account: account, software: software, pricingParameters: "GAME")
            }
            throw error
        }
    }

    static func downloadInfo(
        account: AppleAccount,
        software: Software,
        externalVersionId: String?
    ) async throws -> (account: AppleAccount, output: AppleDownloadOutput) {
        let result = try await downloadProductResponseWithTokenRefresh(
            account: account,
            software: software,
            externalVersionId: externalVersionId
        )
        let dict = result.dict

        guard let items = dict["songList"] as? [[String: Any]], items.isEmpty == false else {
            throw AppleProtocolError(message: "no items in response")
        }
        let item = items[0]
        guard let downloadURL = item["URL"] as? String, downloadURL.isEmpty == false else {
            throw AppleProtocolError(message: "missing download URL")
        }
        guard var metadata = item["metadata"] as? [String: Any] else {
            throw AppleProtocolError(message: "missing metadata")
        }
        guard let version = stringValue(metadata["bundleShortVersionString"]),
              let bundleVersion = stringValue(metadata["bundleVersion"])
        else {
            throw AppleProtocolError(message: "missing required information")
        }

        metadata["apple-id"] = result.account.email
        metadata["userName"] = result.account.email
        metadata.removeValue(forKey: "passwordToken")

        let metadataData = try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        let sinfs = try parseSinfs(item["sinfs"])
        guard sinfs.isEmpty == false else {
            throw AppleProtocolError(message: "no sinf found in response")
        }

        return (
            account: result.account,
            output: AppleDownloadOutput(
                downloadURL: downloadURL,
                sinfs: sinfs,
                bundleShortVersionString: version,
                bundleVersion: bundleVersion,
                iTunesMetadata: metadataData.base64EncodedString()
            )
        )
    }

    static func listVersions(account: AppleAccount, software: Software) async throws -> (account: AppleAccount, versions: [String]) {
        let result = try await downloadProductResponseWithTokenRefresh(account: account, software: software, externalVersionId: nil)
        guard let items = result.dict["songList"] as? [[String: Any]], items.isEmpty == false else {
            throw AppleProtocolError(message: "no items in response")
        }
        guard let metadata = items[0]["metadata"] as? [String: Any],
              let identifiers = metadata["softwareVersionExternalIdentifiers"] as? [Any]
        else {
            throw AppleProtocolError(message: "missing version identifiers")
        }
        let versions = identifiers.map { "\($0)" }
        guard versions.isEmpty == false else {
            throw AppleProtocolError(message: "no versions found")
        }
        return (account: result.account, versions: versions)
    }

    static func versionMetadata(
        account: AppleAccount,
        software: Software,
        versionId: String
    ) async throws -> (account: AppleAccount, metadata: VersionMetadata) {
        let result = try await downloadProductResponseWithTokenRefresh(
            account: account,
            software: software,
            externalVersionId: versionId
        )
        guard let items = result.dict["songList"] as? [[String: Any]], items.isEmpty == false else {
            throw AppleProtocolError(message: "no items in response")
        }
        guard let metadata = items[0]["metadata"] as? [String: Any] else {
            throw AppleProtocolError(message: "missing metadata")
        }
        guard let displayVersion = stringValue(metadata["bundleShortVersionString"]) else {
            throw AppleProtocolError(message: "missing bundleShortVersionString")
        }
        guard let releaseDate = releaseDateString(metadata["releaseDate"]) else {
            throw AppleProtocolError(message: "missing or invalid releaseDate")
        }
        return (
            account: result.account,
            metadata: VersionMetadata(displayVersion: displayVersion, releaseDate: releaseDate)
        )
    }

    static func parsePlistForTesting(_ data: Data) throws -> [String: Any] {
        try parsePlist(data)
    }

    static func requestHeadersForTesting(
        url: URL,
        headers: [(String, String)] = [],
        cookies: [WebCookie] = []
    ) async throws -> [(String, String)] {
        try await requestHeaders(url: url, headers: headers, cookies: cookies)
    }

    private static func purchaseWithTokenRefresh(account: AppleAccount, software: Software) async throws -> AppleAccount {
        do {
            return try await purchaseWithPricingFallback(account: account, software: software)
        } catch let error as AppleProtocolError where error.isPasswordTokenExpired {
            let refreshedAccount = try await refreshAccount(account)
            return try await purchaseWithPricingFallback(account: refreshedAccount, software: software)
        }
    }

    private static func downloadProductResponseWithTokenRefresh(
        account: AppleAccount,
        software: Software,
        externalVersionId: String?
    ) async throws -> (account: AppleAccount, dict: [String: Any]) {
        do {
            return try await downloadProductResponse(account: account, software: software, externalVersionId: externalVersionId)
        } catch let error as AppleProtocolError where error.isPasswordTokenExpired {
            let refreshedAccount = try await refreshAccount(account)
            return try await downloadProductResponse(
                account: refreshedAccount,
                software: software,
                externalVersionId: externalVersionId
            )
        }
    }

    private static func refreshAccount(_ account: AppleAccount) async throws -> AppleAccount {
        try await authenticate(AppleAuthenticateRequest(
            email: account.email,
            password: account.password,
            code: nil,
            existingCookies: account.cookies,
            deviceIdentifier: account.deviceIdentifier
        ))
    }

    private static func purchaseWithParams(
        account: AppleAccount,
        software: Software,
        pricingParameters: String
    ) async throws -> AppleAccount {
        var updatedAccount = account
        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": account.deviceIdentifier,
            "needDiv": "0",
            "origPage": "Software-\(software.id)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricingParameters,
            "productType": "C",
            "salableAdamId": software.id,
        ]
        let body = try plistData(payload)
        let url = URL(string: "https://\(purchaseAPIHost(pod: account.pod))/WebObjects/MZFinance.woa/wa/buyProduct")!
        let response = try await sendAppleRequest(
            url: url,
            method: .POST,
            headers: [
                ("Content-Type", "application/x-apple-plist"),
                ("iCloud-DSID", account.directoryServicesIdentifier),
                ("X-Dsid", account.directoryServicesIdentifier),
                ("X-Apple-Store-Front", "\(account.store)-1"),
                ("X-Token", account.passwordToken),
            ],
            body: body,
            cookies: account.cookies
        )
        updatedAccount.cookies.merge(response.cookies)

        try throwRateLimitIfNeeded(response)
        guard response.statusCode == 200 else {
            throw AppleProtocolError(message: "request failed with status \(response.statusCode)")
        }
        let dict = try parsePlist(response.data)

        if let action = dict["action"] as? [String: Any],
           let urlString = (action["url"] as? String) ?? (action["URL"] as? String),
           urlString.hasSuffix("termsPage")
        {
            throw AppleProtocolError(status: .conflict, message: "purchase requires accepting terms first, visit: \(urlString)")
        }

        if let failureType = stringValue(dict["failureType"]), failureType.isEmpty == false {
            let customerMessage = stringValue(dict["customerMessage"])
            switch failureType {
            case "2034", "2042":
                throw AppleProtocolError(status: .unauthorized, message: "password token is expired", code: failureType)
            default:
                if customerMessage == "Your password has changed." {
                    throw AppleProtocolError(status: .unauthorized, message: "password token is expired", code: failureType)
                }
                if customerMessage == "Subscription Required" {
                    throw AppleProtocolError(status: .conflict, message: "subscription required", code: failureType)
                }
                throw AppleProtocolError(
                    status: .conflict,
                    message: purchaseFailureMessage(failureType: failureType, customerMessage: customerMessage),
                    code: failureType
                )
            }
        }

        guard stringValue(dict["jingleDocType"]) == "purchaseSuccess",
              intValue(dict["status"]) == 0
        else {
            throw AppleProtocolError(message: "failed to purchase app")
        }
        return updatedAccount
    }

    private static func downloadProductResponse(
        account: AppleAccount,
        software: Software,
        externalVersionId: String?
    ) async throws -> (account: AppleAccount, dict: [String: Any]) {
        var updatedAccount = account
        var url = try volumeStoreURL(deviceIdentifier: account.deviceIdentifier, pod: account.pod)
        var redirectAttempt = 0

        while redirectAttempt <= 3 {
            var payload: [String: Any] = [
                "creditDisplay": "",
                "guid": account.deviceIdentifier,
                "salableAdamId": software.id,
            ]
            if let externalVersionId = externalVersionId, externalVersionId.isEmpty == false {
                payload["externalVersionId"] = externalVersionId
            }

            let response = try await sendAppleRequest(
                url: url,
                method: .POST,
                headers: [
                    ("Content-Type", "application/x-apple-plist"),
                    ("iCloud-DSID", account.directoryServicesIdentifier),
                    ("X-Dsid", account.directoryServicesIdentifier),
                ],
                body: try plistData(payload),
                cookies: updatedAccount.cookies
            )
            updatedAccount.cookies.merge(response.cookies)

            if response.statusCode == 302 {
                guard let location = response.firstHeader("location"),
                      let redirectURL = URL(string: location)
                else {
                    throw AppleProtocolError(message: "failed to retrieve redirect location")
                }
                url = redirectURL
                redirectAttempt += 1
                continue
            }

            try throwRateLimitIfNeeded(response)
            guard response.statusCode == 200 else {
                throw AppleProtocolError(message: "request failed with status \(response.statusCode)")
            }
            let dict = try parsePlist(response.data)
            try throwDownloadFailureIfNeeded(dict)
            return (account: updatedAccount, dict: dict)
        }

        throw AppleProtocolError(message: "too many redirects")
    }

    private static func throwDownloadFailureIfNeeded(_ dict: [String: Any]) throws {
        guard let failureType = stringValue(dict["failureType"]), failureType.isEmpty == false else {
            return
        }
        let customerMessage = stringValue(dict["customerMessage"])
        switch failureType {
        case "2034", "2042":
            throw AppleProtocolError(status: .unauthorized, message: "password token is expired", code: failureType)
        case "9610":
            throw AppleProtocolError(status: .conflict, message: "license required - purchase the app first", code: failureType)
        default:
            if customerMessage == "Your password has changed." {
                throw AppleProtocolError(status: .unauthorized, message: "password token is expired", code: failureType)
            }
            throw AppleProtocolError(
                status: .conflict,
                message: customerMessage ?? "download failed: \(failureType)",
                code: failureType
            )
        }
    }

    private static func authEndpoint(deviceIdentifier: String) async throws -> URL {
        let bagOutput = try await fetchBag(deviceIdentifier: deviceIdentifier)
        guard var components = URLComponents(url: bagOutput, resolvingAgainstBaseURL: true) else {
            throw AppleProtocolError(message: "invalid auth endpoint URL")
        }
        components.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = components.url else {
            throw AppleProtocolError(message: "invalid auth endpoint URL")
        }
        return url
    }

    private static func fetchBag(deviceIdentifier: String) async throws -> URL {
        let fallback = URL(string: defaultAuthEndpoint)!
        var components = URLComponents()
        components.scheme = "https"
        components.host = "init.itunes.apple.com"
        components.path = "/bag.xml"
        components.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = components.url else {
            return fallback
        }

        do {
            let response = try await sendAppleRequest(
                url: url,
                method: .GET,
                headers: [("Accept", "application/xml")],
                followsRedirects: true
            )
            let plistData = extractPlistData(response.data)
            let plist = try parsePlist(plistData)
            let urlBag = (plist["urlBag"] as? [String: Any]) ?? plist
            guard let authURLString = urlBag["authenticateAccount"] as? String,
                  let authURL = URL(string: authURLString)
            else {
                return fallback
            }
            return authURL
        } catch {
            return fallback
        }
    }

    private static func sendAppleRequest(
        url: URL,
        method: HTTPMethod,
        headers: [(String, String)] = [],
        body: Data? = nil,
        cookies: [WebCookie] = [],
        followsRedirects: Bool = false
    ) async throws -> AppleHTTPResponse {
        let allHeaders = try await requestHeaders(
            url: url,
            headers: headers,
            cookies: cookies
        )
        let requestBody: HTTPClient.Body? = body.map { .data($0) }
        let request = try HTTPClient.Request(
            url: url.absoluteString,
            method: method,
            headers: .init(allHeaders),
            body: requestBody
        )
        return try await AppleHTTPClient.send(request, followsRedirects: followsRedirects)
    }

    private static func requestHeaders(
        url: URL,
        headers: [(String, String)],
        cookies: [WebCookie]
    ) async throws -> [(String, String)] {
        var allHeaders = [("User-Agent", userAgent)]
        allHeaders.append(contentsOf: headers)
        allHeaders.append(contentsOf: cookies.cookieHeaders(for: url))
        return allHeaders
    }

    private static func plistData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }

    private static func parsePlist(_ data: Data) throws -> [String: Any] {
        guard data.isEmpty == false else {
            throw AppleProtocolError(message: "response body is empty")
        }
        try throwRateLimitIfNeeded(data)
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw AppleProtocolError(message: "invalid response")
        }
        return plist
    }

    private static func throwRateLimitIfNeeded(_ response: AppleHTTPResponse) throws {
        if response.statusCode == 429 {
            throw rateLimitError()
        }
        try throwRateLimitIfNeeded(response.data)
    }

    private static func throwRateLimitIfNeeded(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false
        else {
            return
        }
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("rate") || lowercased.contains("rate limit") || lowercased.contains("too many requests") {
            throw rateLimitError()
        }
    }

    private static func rateLimitError() -> AppleProtocolError {
        AppleProtocolError(status: .tooManyRequests, message: rateLimitMessage, code: rateLimitCode)
    }

    private static func parseSinfs(_ value: Any?) throws -> [Sinf] {
        guard let sinfItems = value as? [[String: Any]] else {
            return []
        }
        return try sinfItems.map { item in
            guard let id = int64Value(item["id"]) else {
                throw AppleProtocolError(message: "invalid sinf item")
            }
            if let data = item["sinf"] as? Data {
                return Sinf(id: id, sinf: data.base64EncodedString())
            }
            if let text = item["sinf"] as? String, Data(base64Encoded: text) != nil {
                return Sinf(id: id, sinf: text)
            }
            throw AppleProtocolError(message: "invalid sinf item")
        }
    }

    private static func volumeStoreURL(deviceIdentifier: String, pod: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = storeAPIHost(pod: pod)
        components.path = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        components.queryItems = [URLQueryItem(name: "guid", value: deviceIdentifier)]
        guard let url = components.url else {
            throw AppleProtocolError(message: "invalid volume store URL")
        }
        return url
    }

    private static func storeAPIHost(pod: String?) -> String {
        guard let pod = pod, pod.isEmpty == false else {
            return "p25-buy.itunes.apple.com"
        }
        return "p\(pod)-buy.itunes.apple.com"
    }

    private static func purchaseAPIHost(pod: String?) -> String {
        guard let pod = pod, pod.isEmpty == false else {
            return "buy.itunes.apple.com"
        }
        return "p\(pod)-buy.itunes.apple.com"
    }

    private static func purchaseFailureMessage(failureType: String, customerMessage: String?) -> String {
        switch failureType {
        case "5002":
            return "app is already purchased (failureType: \(failureType))"
        case "2040":
            return "app is already purchased, unavailable, or delisted (failureType: \(failureType))"
        case "2059":
            return "app is unavailable, delisted, unavailable in this storefront, or not purchased (failureType: \(failureType))"
        case "1010":
            return "invalid store or app unavailable in this storefront (failureType: \(failureType))"
        case "2019":
            return "paid apps cannot be purchased directly (failureType: \(failureType))"
        case "9610":
            return "license not found or app id is invalid (failureType: \(failureType))"
        default:
            return "\((customerMessage?.isEmpty == false ? customerMessage : nil) ?? "purchase failed") (failureType: \(failureType))"
        }
    }

    private static func extractPlistData(_ data: Data) -> Data {
        guard let xmlString = String(data: data, encoding: .utf8),
              let startRange = xmlString.range(of: "<plist"),
              let endRange = xmlString.range(of: "</plist>")
        else {
            return data
        }
        return Data(xmlString[startRange.lowerBound ..< endRange.upperBound].utf8)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        if let value = value as? Date {
            return ISO8601DateFormatter().string(from: value)
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private static func releaseDateString(_ value: Any?) -> String? {
        if let date = value as? Date {
            return ISO8601DateFormatter().string(from: date)
        }
        if let text = value as? String, ISO8601DateFormatter().date(from: text) != nil {
            return text
        }
        return nil
    }
}
