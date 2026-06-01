import Foundation
import Vapor

final class WebDownloadManager {
    private final class TaskRecord {
        var task: DownloadTask
        var sessionTask: URLSessionTask?

        init(task: DownloadTask) {
            self.task = task
        }
    }

    private let config: WebConfig
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "wiki.qaq.unfaird.assppweb-downloads", attributes: .concurrent)
    private var tasks: [String: TaskRecord] = [:]

    init(config: WebConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: packagesDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.dataDirectory, withIntermediateDirectories: true)
        try loadCompletedTasks()
        cleanOrphanedPackages()
    }

    func allTasks() -> [DownloadTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values.map { sanitized($0.task) }
    }

    func task(id: String) -> DownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = tasks[id] else {
            return nil
        }
        return sanitized(record.task)
    }

    func completedTask(id: String) -> DownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        guard let task = tasks[id]?.task,
              task.status == DownloadStatus.completed.rawValue,
              let filePath = task.filePath,
              fileExists(filePath)
        else {
            return nil
        }
        return task
    }

    func packageInfos(accountHashes: Set<String>) -> [PackageInfo] {
        lock.lock()
        let values = tasks.values.map(\.task)
        lock.unlock()

        return values.compactMap { task in
            guard task.status == DownloadStatus.completed.rawValue,
                  let filePath = task.filePath,
                  accountHashes.contains(task.accountHash)
            else {
                return nil
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let fileSize = attributes[.size] as? NSNumber
            else {
                return nil
            }
            return PackageInfo(
                id: task.id,
                software: task.software,
                accountHash: task.accountHash,
                fileSize: fileSize.int64Value,
                createdAt: task.createdAt
            )
        }
    }

    func createTask(_ request: CreateDownloadRequest) throws -> DownloadTask {
        try validateDownloadURL(request.downloadURL)
        _ = try sanitizePathSegment(request.accountHash, label: "accountHash")
        _ = try sanitizePathSegment(request.software.bundleID, label: "bundleID")
        _ = try sanitizePathSegment(request.software.version, label: "version")

        if config.maxDownloadMB > 0 {
            let size = try fetchDownloadSizeBytes(request.downloadURL)
            guard size > 0 else {
                throw Abort(.badRequest, reason: "Unable to verify file size from Apple")
            }
            guard size <= Int64(config.maxDownloadMB) * 1024 * 1024 else {
                throw Abort(.payloadTooLarge, reason: "File size exceeds the maximum limit of \(config.maxDownloadMB) MB")
            }
        }

        let id = UUID().uuidString
        let task = DownloadTask(
            id: id,
            software: request.software,
            accountHash: request.accountHash,
            downloadURL: request.downloadURL,
            sinfs: request.sinfs,
            iTunesMetadata: request.iTunesMetadata,
            status: DownloadStatus.pending.rawValue,
            progress: 0,
            speed: "0 B/s",
            error: nil,
            filePath: nil,
            createdAt: currentTimestampString(),
            hasFile: nil
        )

        lock.lock()
        tasks[id] = TaskRecord(task: task)
        lock.unlock()

        startDownload(id: id)
        return self.task(id: id) ?? task
    }

    func deleteTask(id: String) -> Bool {
        lock.lock()
        guard let record = tasks[id] else {
            lock.unlock()
            return false
        }
        record.sessionTask?.cancel()
        let filePath = record.task.filePath
        tasks.removeValue(forKey: id)
        lock.unlock()

        deletePackageFile(path: filePath)
        persistCompletedTasks()
        return true
    }

    func pauseTask(id: String) -> Bool {
        lock.lock()
        guard let record = tasks[id],
              record.task.status == DownloadStatus.downloading.rawValue
        else {
            lock.unlock()
            return false
        }
        record.sessionTask?.cancel()
        record.sessionTask = nil
        record.task.status = DownloadStatus.paused.rawValue
        record.task.speed = "0 B/s"
        lock.unlock()
        return true
    }

    func resumeTask(id: String) -> Bool {
        lock.lock()
        guard let record = tasks[id],
              record.task.status == DownloadStatus.paused.rawValue
        else {
            lock.unlock()
            return false
        }
        lock.unlock()
        startDownload(id: id)
        return true
    }

    func deletePackageFile(id: String) -> Bool {
        lock.lock()
        let path = tasks[id]?.task.filePath
        lock.unlock()
        guard let path = path else {
            return false
        }
        deletePackageFile(path: path)
        return true
    }

    var packagesDirectory: URL {
        config.dataDirectory.appendingPathComponent("packages", isDirectory: true)
    }

    private var tasksFile: URL {
        config.dataDirectory.appendingPathComponent("tasks.json")
    }

    private func startDownload(id: String) {
        runTimeCleanup()
        runSpaceCleanup()

        lock.lock()
        guard let record = tasks[id],
              let downloadURL = record.task.downloadURL
        else {
            lock.unlock()
            return
        }

        do {
            record.task.status = DownloadStatus.downloading.rawValue
            record.task.progress = 0
            record.task.speed = "0 B/s"
            record.task.error = nil
            record.task.filePath = try taskFileURL(for: record.task).path
        } catch {
            record.task.status = DownloadStatus.failed.rawValue
            record.task.error = String(describing: error)
            lock.unlock()
            return
        }

        let filePath = record.task.filePath ?? ""
        let sinfs = record.task.sinfs ?? []
        let iTunesMetadata = record.task.iTunesMetadata
        lock.unlock()

        queue.async {
            var stage = "Download"
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: filePath).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try self.download(urlString: downloadURL, to: URL(fileURLWithPath: filePath), taskID: id)

                if sinfs.isEmpty == false {
                    stage = "SINF injection"
                    self.updateTask(id: id) { task in
                        task.status = DownloadStatus.injecting.rawValue
                        task.progress = 100
                        task.speed = "0 B/s"
                    }
                    try SinfInjector.inject(sinfs: sinfs, ipaURL: URL(fileURLWithPath: filePath), iTunesMetadata: iTunesMetadata)
                }

                stage = "Decrypt"
                self.updateTask(id: id) { task in
                    task.status = DownloadStatus.decrypting.rawValue
                    task.progress = 100
                    task.speed = "0 B/s"
                }
                try self.decryptInPlace(URL(fileURLWithPath: filePath), taskID: id)

                self.updateTask(id: id) { task in
                    task.status = DownloadStatus.completed.rawValue
                    task.progress = 100
                    task.speed = "0 B/s"
                    task.downloadURL = nil
                    task.sinfs = nil
                    task.iTunesMetadata = nil
                    task.sessionFieldsCleared()
                }
                self.persistCompletedTasks()
            } catch {
                if self.isPaused(id: id) {
                    return
                }
                self.updateTask(id: id) { task in
                    task.status = DownloadStatus.failed.rawValue
                    task.error = "\(stage) failed: \(self.errorDescription(error))"
                    task.speed = "0 B/s"
                    task.sessionFieldsCleared()
                }
            }
        }
    }

    private func download(urlString: String, to destination: URL, taskID: String) throws {
        guard let url = URL(string: urlString) else {
            throw Abort(.badRequest, reason: "invalid download URL")
        }

        let delegate = WebDownloadDelegate(
            destination: destination,
            maxBytes: WebConfig.maxDownloadBytes,
            progress: { [weak self] written, expected, elapsed, delta in
                self?.reportProgress(id: taskID, downloaded: written, total: expected, elapsed: elapsed, delta: delta)
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = TimeInterval(WebConfig.downloadTimeoutSeconds)
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: operationQueue)
        defer {
            session.invalidateAndCancel()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("unfaird/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        lock.lock()
        tasks[taskID]?.sessionTask = task
        lock.unlock()
        task.resume()
        try delegate.wait()
        lock.lock()
        tasks[taskID]?.sessionTask = nil
        lock.unlock()
    }

    private func decryptInPlace(_ ipaURL: URL, taskID: String) throws {
        let decryptID = UUID()
        let jobsRoot = URL(fileURLWithPath: "/var/tmp/unfaird/jobs", isDirectory: true)
        let jobDirectory = jobsRoot.appendingPathComponent(decryptID.uuidString, isDirectory: true)
        let packageWorkingDirectory = try PackageRunnerSandbox.packageWorkingDirectory(for: decryptID)
        let outputURL = ipaURL.deletingLastPathComponent()
            .appendingPathComponent(".\(taskID).decrypted.ipa")

        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageWorkingDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: jobDirectory)
            try? FileManager.default.removeItem(at: packageWorkingDirectory)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let sandboxProfileURL = try PackageRunnerSandbox.writeProfile(jobDirectory: jobDirectory)
        let result = try PosixSpawn.run(
            executablePath: currentExecutablePath(),
            arguments: [
                "package",
                "--input", ipaURL.path,
                "--output", outputURL.path,
                "--working-directory", packageWorkingDirectory.path,
                "--verbose",
            ],
            workingDirectory: jobDirectory,
            sandboxProfileURL: sandboxProfileURL,
            timeoutSeconds: WebConfig.decryptTimeoutSeconds
        )

        guard result.exitCode == 0, fileExists(outputURL.path) else {
            let message = result.stderrString.isEmpty ? "decrypt runner exited with code \(result.exitCode)" : result.stderrString
            throw Abort(.internalServerError, reason: message)
        }

        try FileManager.default.removeItem(at: ipaURL)
        try FileManager.default.moveItem(at: outputURL, to: ipaURL)
    }

    private func reportProgress(id: String, downloaded: Int64, total: Int64, elapsed: TimeInterval, delta: Int64) {
        let speed = elapsed > 0 && delta > 0 ? formatSpeed(bytesPerSecond: Double(delta) / elapsed) : "0 B/s"
        let progress = total > 0 ? Int(Double(downloaded) / Double(total) * 100) : 0
        updateTask(id: id) { task in
            task.progress = progress
            task.speed = speed
        }
    }

    private func updateTask(id: String, _ update: (inout DownloadTask) -> Void) {
        lock.lock()
        if let record = tasks[id] {
            update(&record.task)
        }
        lock.unlock()
    }

    private func isPaused(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks[id]?.task.status == DownloadStatus.paused.rawValue
    }

    private func sanitized(_ task: DownloadTask) -> DownloadTask {
        var output = task
        output.downloadURL = nil
        output.sinfs = nil
        output.iTunesMetadata = nil
        output.filePath = nil
        if let path = task.filePath {
            output.hasFile = fileExists(path)
        }
        return output
    }

    private func taskFileURL(for task: DownloadTask) throws -> URL {
        packagesDirectory
            .appendingPathComponent(try sanitizePathSegment(task.accountHash, label: "accountHash"), isDirectory: true)
            .appendingPathComponent(try sanitizePathSegment(task.software.bundleID, label: "bundleID"), isDirectory: true)
            .appendingPathComponent(try sanitizePathSegment(task.software.version, label: "version"), isDirectory: true)
            .appendingPathComponent("\(task.id).ipa")
    }

    private func loadCompletedTasks() throws {
        guard FileManager.default.fileExists(atPath: tasksFile.path) else {
            return
        }
        let data = try Data(contentsOf: tasksFile)
        let persisted = try JSONDecoder().decode([DownloadTask].self, from: data)
        for var task in persisted where task.status == DownloadStatus.completed.rawValue {
            if let path = task.filePath, fileExists(path) {
                task.progress = 100
                task.speed = "0 B/s"
                tasks[task.id] = TaskRecord(task: task)
            }
        }
    }

    private func persistCompletedTasks() {
        lock.lock()
        let completed = tasks.values.compactMap { record -> DownloadTask? in
            guard record.task.status == DownloadStatus.completed.rawValue,
                  record.task.filePath != nil
            else {
                return nil
            }
            var task = record.task
            task.downloadURL = nil
            task.sinfs = nil
            task.iTunesMetadata = nil
            return task
        }
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(completed)
            try data.write(to: tasksFile, options: .atomic)
        } catch {
            fputs("unfaird persist completed tasks failed: \(error)\n", stderr)
        }
    }

    private func cleanOrphanedPackages() {
        let known = Set(tasks.values.compactMap { $0.task.filePath }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard let enumerator = FileManager.default.enumerator(at: packagesDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else {
                continue
            }
            if known.contains(url.standardizedFileURL.path) == false {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func runTimeCleanup() {
        guard config.autoCleanupDays > 0 else {
            return
        }
        let cutoff = Date().addingTimeInterval(-TimeInterval(config.autoCleanupDays) * 24 * 60 * 60)
        for task in completedTaskSnapshots() {
            guard let path = task.filePath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  modificationDate < cutoff
            else {
                continue
            }
            _ = deleteTask(id: task.id)
        }
    }

    private func runSpaceCleanup() {
        guard config.autoCleanupMaxMB > 0 else {
            return
        }

        let limit = Int64(config.autoCleanupMaxMB) * 1024 * 1024
        let files = completedTaskSnapshots().compactMap { task -> (id: String, size: Int64, modificationDate: Date)? in
            guard let path = task.filePath,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber,
                  let modificationDate = attributes[.modificationDate] as? Date
            else {
                return nil
            }
            return (task.id, size.int64Value, modificationDate)
        }.sorted { $0.modificationDate < $1.modificationDate }

        var total = files.reduce(Int64(0)) { $0 + $1.size }
        for file in files where total > limit {
            _ = deleteTask(id: file.id)
            total -= file.size
        }
    }

    private func completedTaskSnapshots() -> [DownloadTask] {
        lock.lock()
        defer { lock.unlock() }
        return tasks.values.map(\.task).filter { $0.status == DownloadStatus.completed.rawValue && $0.filePath != nil }
    }

    private func deletePackageFile(path: String?) {
        guard let path = path else {
            return
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let base = packagesDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: resolved)
    }

    private func validateDownloadURL(_ rawValue: String) throws {
        guard let components = URLComponents(string: rawValue),
              components.scheme == "https",
              let host = components.host,
              host.isEmpty == false,
              URL(string: rawValue) != nil
        else {
            throw Abort(.badRequest, reason: "invalid download URL")
        }
        guard isIPAddressHost(host) == false else {
            throw Abort(.badRequest, reason: "download URL must use a hostname")
        }
        guard host.lowercased().hasSuffix(".apple.com") else {
            throw Abort(.badRequest, reason: "download URL must be from an Apple domain (*.apple.com)")
        }
    }

    private func fetchDownloadSizeBytes(_ rawValue: String) throws -> Int64 {
        guard let url = URL(string: rawValue) else {
            throw Abort(.badRequest, reason: "invalid download URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response = try HTTPSyncClient.shared.send(request)
        guard (200...299).contains(response.statusCode) else {
            throw Abort(.badGateway, reason: "Failed to verify file size from Apple")
        }
        return response.response.expectedContentLength
    }

    private func errorDescription(_ error: Error) -> String {
        if let abort = error as? AbortError {
            return abort.reason
        }
        return String(describing: error)
    }
}

private enum DownloadStatus: String {
    case pending
    case downloading
    case paused
    case injecting
    case decrypting
    case completed
    case failed
}

private extension DownloadTask {
    mutating func sessionFieldsCleared() {
        downloadURL = nil
        sinfs = nil
        iTunesMetadata = nil
    }
}

private final class WebDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let maxBytes: Int64
    private let progress: (Int64, Int64, TimeInterval, Int64) -> Void
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var pendingError: Error?
    private var completed = false
    private var lastTime = Date()
    private var lastBytes: Int64 = 0

    init(destination: URL, maxBytes: Int64, progress: @escaping (Int64, Int64, TimeInterval, Int64) -> Void) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func wait() throws {
        semaphore.wait()
        switch result {
        case .success:
            return
        case .failure(let error):
            throw error
        case nil:
            throw Abort(.internalServerError, reason: "download finished without result")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maxBytes {
            pendingError = Abort(.payloadTooLarge, reason: "remote ipa limit is 8GB")
            downloadTask.cancel()
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        if elapsed >= 0.5 {
            progress(totalBytesWritten, totalBytesExpectedToWrite, elapsed, totalBytesWritten - lastBytes)
            lastTime = now
            lastBytes = totalBytesWritten
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            pendingError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse,
           (200...299).contains(http.statusCode) == false {
            cleanupDestination()
            finish(.failure(Abort(.badGateway, reason: "IPA download returned HTTP \(http.statusCode)")))
            return
        }
        if let expectedLength = task.response?.expectedContentLength,
           expectedLength > maxBytes {
            cleanupDestination()
            finish(.failure(Abort(.payloadTooLarge, reason: "remote ipa limit is 8GB")))
            return
        }
        if let pendingError = pendingError {
            cleanupDestination()
            finish(.failure(pendingError))
            return
        }
        if let error = error {
            cleanupDestination()
            finish(.failure(error))
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard completed == false else {
            return
        }
        completed = true
        self.result = result
        semaphore.signal()
    }

    private func cleanupDestination() {
        try? FileManager.default.removeItem(at: destination)
    }
}

final class HTTPSyncClient {
    static let shared = HTTPSyncClient()

    struct Result {
        let response: URLResponse
        let data: Data

        var statusCode: Int {
            (response as? HTTPURLResponse)?.statusCode ?? 0
        }
    }

    func send(_ request: URLRequest, timeout: TimeInterval = 30) throws -> Result {
        let semaphore = DispatchSemaphore(value: 0)
        var output: Swift.Result<Result, Error>?
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                output = .failure(error)
                return
            }
            guard let response = response else {
                output = .failure(Abort(.badGateway, reason: "empty upstream response"))
                return
            }
            output = .success(Result(response: response, data: data ?? Data()))
        }
        task.resume()
        semaphore.wait()
        session.invalidateAndCancel()
        guard let output = output else {
            throw Abort(.requestTimeout, reason: "upstream request timed out")
        }
        return try output.get()
    }
}
