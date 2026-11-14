import Foundation
import Darwin
import SQLite3

/// Background engine behind T3Store. Owns the read-only SQLite connection, the file-system
/// watchers and the fallback timer. All mutable state is confined to `queue`.
///
/// Change detection: vnode sources on statev2.sqlite and statev2.sqlite-wal (re-opened when the
/// file is deleted/renamed, e.g. WAL truncation/recreation), a vnode source on the userdata
/// directory (files appearing/disappearing), a process-exit source on the T3 server pid, and a
/// 5 s fallback timer that only queries when file signatures or server liveness changed.
/// Refreshes are coalesced: ~300 ms after the first event, and at most one per second.
final class T3Monitor: @unchecked Sendable {
    struct Paths: Sendable {
        let directory: String
        let database: String
        let wal: String
        let runtime: String
        let environmentId: String

        static func resolve() -> Paths {
            let environment = ProcessInfo.processInfo.environment
            let base: String
            if let custom = environment["T3CODE_HOME"], !custom.isEmpty {
                base = (custom as NSString).expandingTildeInPath
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3").path
            }
            let directory = (base as NSString).appendingPathComponent("userdata")
            let database = (directory as NSString).appendingPathComponent("statev2.sqlite")
            return Paths(
                directory: directory,
                database: database,
                wal: database + "-wal",
                runtime: (directory as NSString).appendingPathComponent("server-runtime.json"),
                environmentId: (directory as NSString).appendingPathComponent("environment-id")
            )
        }
    }

    private enum MonitorError: Error {
        case databaseMissing
    }

    private struct FileStamp: Equatable {
        var inode: UInt64 = 0
        var size: Int64 = -1
        var mtimeSec: Int = 0
        var mtimeNsec: Int = 0
    }

    private struct Signature: Equatable {
        var database: FileStamp
        var wal: FileStamp
        var runtime: FileStamp
        var serverOnline: Bool
    }

    let paths: Paths
    private let queue = DispatchQueue(label: "notchpulse.t3.monitor", qos: .utility)
    private let reader = T3StateReader()

    // MARK: queue-confined state
    private var handler: (@Sendable (AgentsSnapshot) -> Void)?
    private var isRunning = false
    private var generation = 0
    private var connection: T3SQLiteConnection?
    private var connectionInode: UInt64 = 0
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSources: [String: DispatchSourceFileSystemObject] = [:]
    private var processSource: DispatchSourceProcess?
    private var watchedPid: pid_t = 0
    private var fallbackTimer: DispatchSourceTimer?
    private var refreshScheduled = false
    private var lastRefreshAt = DispatchTime(uptimeNanoseconds: 0)
    private var lastSignature: Signature?
    private var lastSnapshot: AgentsSnapshot?
    private var lastRefreshFailed = false

    static let debounce: DispatchTimeInterval = .milliseconds(300)
    static let minimumSpacing: DispatchTimeInterval = .milliseconds(1000)
    static let fallbackInterval: DispatchTimeInterval = .seconds(5)

    init(paths: Paths = .resolve()) {
        self.paths = paths
    }

    deinit {
        // Sources hold only weak references to self, so they can be torn down here safely.
        fallbackTimer?.cancel()
        directorySource?.cancel()
        fileSources.values.forEach { $0.cancel() }
        processSource?.cancel()
        connection?.close()
    }

    /// Called on the monitor queue whenever the snapshot changes.
    func setHandler(_ handler: @escaping @Sendable (AgentsSnapshot) -> Void) {
        queue.async { self.handler = handler }
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    /// Forces a refresh (still coalesced with pending ones).
    func refreshSoon() {
        queue.async { self.scheduleRefresh() }
    }

    // MARK: - Lifecycle

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        lastSnapshot = nil // always deliver the first snapshot after (re)start
        lastSignature = nil
        armWatchers()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.fallbackInterval, repeating: Self.fallbackInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.fallbackTick() }
        timer.resume()
        fallbackTimer = timer

        refresh()
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        refreshScheduled = false
        fallbackTimer?.cancel()
        fallbackTimer = nil
        directorySource?.cancel()
        directorySource = nil
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        processSource?.cancel()
        processSource = nil
        watchedPid = 0
        closeConnection()
    }

    // MARK: - Scheduling

    private func scheduleRefresh() {
        guard isRunning, !refreshScheduled else { return }
        refreshScheduled = true
        var deadline = DispatchTime.now() + Self.debounce
        let earliest = lastRefreshAt + Self.minimumSpacing
        if earliest > deadline { deadline = earliest }
        let scheduledGeneration = generation
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.isRunning, self.generation == scheduledGeneration else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func fallbackTick() {
        guard isRunning else { return }
        armWatchers()
        let server = readServerStatus()
        let signature = currentSignature(serverOnline: server.online)
        if lastRefreshFailed || signature != lastSignature {
            scheduleRefresh()
        }
    }

    // MARK: - Refresh

    private func refresh() {
        guard isRunning else { return }
        lastRefreshAt = .now()
        let server = readServerStatus()
        updateProcessWatch(server)
        // Taken before reading so any write landing mid-read triggers another pass.
        lastSignature = currentSignature(serverOnline: server.online)

        var snapshot = AgentsSnapshot(threads: [], runningCount: 0, needsInputCount: 0,
                                      serverOnline: server.online, lastError: nil)
        do {
            let db = try openConnectionIfNeeded()
            let result = try reader.read(db, serverOnline: server.online)
            snapshot.threads = result.threads
            snapshot.runningCount = result.runningCount
            snapshot.needsInputCount = result.needsInputCount
            if !server.online {
                snapshot.lastError = "T3 Code server is not running"
            }
            lastRefreshFailed = false
        } catch {
            lastRefreshFailed = true
            var transient = false
            if let sqliteError = error as? T3SQLiteError {
                if sqliteError.invalidatesConnection { closeConnection() }
                let primary = sqliteError.code & 0xFF
                transient = primary == SQLITE_BUSY || primary == SQLITE_LOCKED
            }
            if transient, let previous = lastSnapshot {
                // Keep showing the last good data through brief lock contention.
                snapshot.threads = previous.threads
                snapshot.runningCount = previous.runningCount
                snapshot.needsInputCount = previous.needsInputCount
            }
            snapshot.lastError = describe(error)
        }
        publish(snapshot)
    }

    private func publish(_ snapshot: AgentsSnapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        handler?(snapshot)
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case MonitorError.databaseMissing:
            return "T3 Code database not found at \(abbreviate(paths.database))"
        case let sqliteError as T3SQLiteError:
            if sqliteError.message.hasPrefix("no such table") || sqliteError.message.hasPrefix("no such column") {
                return "Unrecognised T3 database schema (\(sqliteError.message))"
            }
            return "Cannot read T3 database: \(sqliteError.message)"
        default:
            return "Cannot read T3 database: \(error.localizedDescription)"
        }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Connection

    private func openConnectionIfNeeded() throws -> T3SQLiteConnection {
        var info = stat()
        guard stat(paths.database, &info) == 0, info.st_size > 0 else {
            closeConnection()
            throw MonitorError.databaseMissing
        }
        let inode = UInt64(info.st_ino)
        if let connection, connectionInode == inode { return connection }
        closeConnection()
        let opened = try T3SQLiteConnection(readOnlyPath: paths.database)
        connection = opened
        connectionInode = inode
        return opened
    }

    private func closeConnection() {
        connection?.close()
        connection = nil
        connectionInode = 0
    }

    // MARK: - Server liveness

    private struct ServerStatus {
        var online: Bool
        var pid: pid_t?
    }

    private func readServerStatus() -> ServerStatus {
        guard let data = FileManager.default.contents(atPath: paths.runtime),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pidNumber = object["pid"] as? NSNumber else {
            return ServerStatus(online: false, pid: nil)
        }
        let pid = pid_t(truncatingIfNeeded: pidNumber.int64Value)
        guard pid > 0 else { return ServerStatus(online: false, pid: nil) }
        let alive = kill(pid, 0) == 0 || errno == EPERM
        return ServerStatus(online: alive, pid: alive ? pid : nil)
    }

    private func updateProcessWatch(_ server: ServerStatus) {
        let pid = server.pid ?? 0
        guard pid != watchedPid else { return }
        processSource?.cancel()
        processSource = nil
        watchedPid = pid
        guard pid > 0 else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.processSource?.cancel()
            self.processSource = nil
            self.watchedPid = 0
            self.scheduleRefresh()
        }
        source.resume()
        processSource = source
    }

    // MARK: - File watching

    private func armWatchers() {
        guard isRunning else { return }
        if directorySource == nil {
            directorySource = makeSource(path: paths.directory, mask: [.write, .delete, .rename, .revoke]) { [weak self] events in
                guard let self else { return }
                if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                    self.directorySource?.cancel()
                    self.directorySource = nil
                }
                self.armWatchers()
                self.scheduleRefresh()
            }
        }
        for path in [paths.database, paths.wal] where fileSources[path] == nil {
            fileSources[path] = makeSource(path: path, mask: [.write, .extend, .delete, .rename, .revoke]) { [weak self] events in
                guard let self else { return }
                if !events.isDisjoint(with: [.delete, .rename, .revoke]) {
                    // WAL truncated/recreated or DB replaced: watch the new file (if any).
                    self.fileSources[path]?.cancel()
                    self.fileSources[path] = nil
                    self.armWatchers()
                }
                self.scheduleRefresh()
            }
        }
    }

    private func makeSource(
        path: String,
        mask: DispatchSource.FileSystemEvent,
        onEvent: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onEvent(source.data)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func currentSignature(serverOnline: Bool) -> Signature {
        Signature(database: stamp(paths.database), wal: stamp(paths.wal),
                  runtime: stamp(paths.runtime), serverOnline: serverOnline)
    }

    private func stamp(_ path: String) -> FileStamp {
        var info = stat()
        guard stat(path, &info) == 0 else { return FileStamp() }
        return FileStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         mtimeSec: Int(info.st_mtimespec.tv_sec), mtimeNsec: Int(info.st_mtimespec.tv_nsec))
    }
}
