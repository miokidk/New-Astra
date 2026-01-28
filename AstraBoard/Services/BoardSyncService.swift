import Foundation
import Combine
import Supabase
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

private struct SupabaseBoardRow: Codable {
    var id: UUID
    var userId: UUID
    var title: String
    var payload: AnyJSON
    var version: Int64
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case payload
        case version
        case updatedAt = "updated_at"
    }
}

private struct SupabaseBoardIdRow: Codable {
    var id: UUID
}

@MainActor
final class BoardSyncService: ObservableObject {
    struct SyncLogEntry: Equatable {
        var timestamp: Date
        var success: Bool
        var count: Int
        var conflicts: Int?
        var message: String?
    }

    enum SyncError: LocalizedError {
        case notConfigured
        case notSignedIn
        case invalidPayload

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Supabase is not configured."
            case .notSignedIn:
                return "No signed-in user."
            case .invalidPayload:
                return "Invalid board payload."
            }
        }
    }

    @Published private(set) var lastPull: SyncLogEntry?
    @Published private(set) var lastPush: SyncLogEntry?

    private let authService: AuthService
    private let persistence: PersistenceService

    private var cancellables = Set<AnyCancellable>()
    private var pullTimer: Timer?
    private var syncTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var pushTaskToken = UUID()
    private var isPushInProgress = false
    private var needsPushAfterCurrent = false
    private var hasStarted = false
    private var lastPullAt: Date?
    private var pendingDeletionIds = Set<UUID>()
    private var assetDownloadTasks: [String: Task<Void, Never>] = [:]

    private static let lastPullKey = "AstraBoard.SupabaseLastPullAt"
    private static let assetsBucketKey = "SUPABASE_ASSETS_BUCKET"
    private static let defaultAssetsBucket = "board-assets"
    private static let pullInterval: TimeInterval = 5
    private static let debounceIntervalNanos: UInt64 = 500_000_000

    init(authService: AuthService, boardStore: BoardStore) {
        self.authService = authService
        self.persistence = boardStore.persistence
        self.lastPullAt = Self.loadLastPullAt()
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        observeAuthChanges()
        observeAppLifecycle()

        if authService.currentUser() != nil {
            startPeriodicPull()
            syncNow(reason: "launch")
        }
    }

    func stop() {
        guard hasStarted else { return }
        stopPeriodicPull()
        syncTask?.cancel()
        syncTask = nil
        pushTask?.cancel()
        pushTask = nil
        needsPushAfterCurrent = false
        isPushInProgress = false
        pushTaskToken = UUID()
        assetDownloadTasks.values.forEach { $0.cancel() }
        assetDownloadTasks.removeAll()
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        hasStarted = false
    }

    var pullStatusText: String {
        statusText(for: lastPull)
    }

    var pushStatusText: String {
        statusText(for: lastPush)
    }

    func noteLocalChange(boardID _: UUID) {
        guard authService.currentUser() != nil else { return }
        scheduleDebouncedPush()
    }

    func noteBoardDeleted(id: UUID) {
        guard authService.currentUser() != nil else { return }
        pendingDeletionIds.insert(id)
        scheduleDebouncedPush()
    }

    func requestAssetDownload(filename: String) {
        guard authService.currentUser() != nil else { return }
        guard !filename.isEmpty else { return }
        guard !persistence.assetExists(filename: filename) else { return }
        guard assetDownloadTasks[filename] == nil else { return }

        let task = Task { [weak self] in
            defer { self?.assetDownloadTasks[filename] = nil }
            guard let self,
                  let user = self.authService.currentUser(),
                  let client = self.authService.client else { return }
            await self.downloadAssetIfNeeded(filename: filename, userId: user.id, client: client)
        }
        assetDownloadTasks[filename] = task
    }

    func syncNow(reason _: String) {
        guard authService.currentUser() != nil else { return }
        guard syncTask == nil else { return }

        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.syncTask = nil
                if self.needsPushAfterCurrent {
                    self.needsPushAfterCurrent = false
                    self.scheduleDebouncedPush()
                }
            }

            do {
                let since = self.lastPullAt ?? Date.distantPast
                let result = try await self.pullRemoteUpdates(since: since)
                self.recordPullSuccess(count: result.pulled, conflicts: result.conflicts)
                self.updateLastPullAt(from: result.latestRemote)
            } catch {
                self.recordPullFailure(error: error)
                return
            }

            do {
                let pushed = try await self.pushLocalChanges()
                self.recordPushSuccess(count: pushed)
            } catch {
                self.recordPushFailure(error: error)
            }
        }
    }

    func pullRemoteUpdates(since: Date) async throws -> (pulled: Int, conflicts: Int, latestRemote: Date?) {
        guard let client = authService.client else { throw SyncError.notConfigured }
        guard let user = authService.currentUser() else { throw SyncError.notSignedIn }

        let response: PostgrestResponse<[SupabaseBoardRow]> = try await client
            .from("boards")
            .select("id,user_id,title,payload,version,updated_at")
            .eq("user_id", value: user.id)
            .gt("updated_at", value: since)
            .order("updated_at", ascending: true)
            .execute()

        let rows = response.value
        var pulled = 0
        var conflicts = 0
        var latestRemote: Date?

        for row in rows {
            if pendingDeletionIds.contains(row.id) {
                continue
            }
            latestRemote = max(latestRemote ?? row.updatedAt, row.updatedAt)
            let localMeta = persistence.boardMeta(id: row.id)
            if let localMeta {
                if localMeta.isDirty && row.version > localMeta.version {
                    conflicts += 1
                    if let localDoc = persistence.loadBoardIfExists(id: row.id),
                       var mergedDoc = mergedDoc(local: localDoc, remoteRow: row) {
                        mergedDoc.updatedAt = Date().timeIntervalSince1970
                        _ = persistence.save(doc: mergedDoc, markDirty: true, updateActive: false)
                        persistence.setBoardVersion(id: row.id, version: row.version)
                        pulled += 1
                        await syncAssets(for: mergedDoc, userId: user.id, client: client, mode: .pull)
                        continue
                    }
                    createConflictCopy(for: row.id)
                }

                if !localMeta.isDirty || row.version > localMeta.version {
                    if let doc = saveRemoteBoard(row) {
                        pulled += 1
                        await syncAssets(for: doc, userId: user.id, client: client, mode: .pull)
                    }
                }
            } else {
                if let doc = saveRemoteBoard(row) {
                    pulled += 1
                    await syncAssets(for: doc, userId: user.id, client: client, mode: .pull)
                }
            }
        }

        if pulled > 0 || conflicts > 0 {
            NSLog("Supabase sync: pulled \(pulled) boards, conflicts \(conflicts)")
        }

        do {
            let removed = try await reconcileRemoteDeletions(userId: user.id, client: client)
            if removed > 0 {
                NSLog("Supabase sync: removed \(removed) boards deleted remotely")
            }
        } catch {
            NSLog("Supabase sync: failed to reconcile deletions: \(error)")
        }

        return (pulled, conflicts, latestRemote)
    }

    func pushLocalChanges() async throws -> Int {
        guard let client = authService.client else { throw SyncError.notConfigured }
        guard let user = authService.currentUser() else { throw SyncError.notSignedIn }

        if !pendingDeletionIds.isEmpty {
            let ids = pendingDeletionIds
            pendingDeletionIds.removeAll()
            var failed: [UUID] = []
            for id in ids {
                do {
                    try await deleteRemoteBoard(id: id, userId: user.id, client: client)
                } catch {
                    failed.append(id)
                    NSLog("Supabase sync: failed to delete board \(id): \(error)")
                }
            }
            if !failed.isEmpty {
                pendingDeletionIds.formUnion(failed)
            }
        }

        let dirtyBoards = persistence.listBoards().filter { $0.isDirty }
        guard !dirtyBoards.isEmpty else { return 0 }

        var pushed = 0

        for meta in dirtyBoards {
            guard var doc = persistence.loadBoardIfExists(id: meta.id) else { continue }
            let remoteRow = try await fetchRemoteBoardRow(id: meta.id, userId: user.id, client: client)
            if let remoteRow, remoteRow.version > meta.version {
                if let mergedDoc = mergedDoc(local: doc, remoteRow: remoteRow) {
                    NSLog("Supabase sync: merged board \(meta.id) (remote version \(remoteRow.version) > local \(meta.version))")
                    await syncAssets(for: mergedDoc, userId: user.id, client: client, mode: .push)

                    let newVersion = remoteRow.version + 1
                    let now = Date()
                    var docToPush = mergedDoc
                    docToPush.updatedAt = now.timeIntervalSince1970
                    let payload = try makePayload(from: docToPush)

                    let row = SupabaseBoardRow(
                        id: meta.id,
                        userId: user.id,
                        title: docToPush.title,
                        payload: payload,
                        version: newVersion,
                        updatedAt: now
                    )

                    _ = try await client
                        .from("boards")
                        .upsert(row, onConflict: "id", returning: .minimal)
                        .execute()

                    _ = persistence.save(doc: docToPush, markDirty: false, updateActive: false)
                    persistence.setBoardVersion(id: meta.id, version: newVersion)
                    pushed += 1
                    continue
                }
                NSLog("Supabase sync: skipped push for board \(meta.id) (remote version \(remoteRow.version) > local \(meta.version))")
                createConflictCopy(for: meta.id)
                if let pulledDoc = saveRemoteBoard(remoteRow) {
                    await syncAssets(for: pulledDoc, userId: user.id, client: client, mode: .pull)
                }
                continue
            }
            await syncAssets(for: doc, userId: user.id, client: client, mode: .push)

            let newVersion = max(meta.version, remoteRow?.version ?? meta.version) + 1
            let now = Date()
            doc.updatedAt = now.timeIntervalSince1970
            let payload = try makePayload(from: doc)

            let row = SupabaseBoardRow(
                id: meta.id,
                userId: user.id,
                title: doc.title,
                payload: payload,
                version: newVersion,
                updatedAt: now
            )

            _ = try await client
                .from("boards")
                .upsert(row, onConflict: "id", returning: .minimal)
                .execute()

            _ = persistence.save(doc: doc, markDirty: false, updateActive: false)
            persistence.setBoardVersion(id: meta.id, version: newVersion)
            pushed += 1
        }

        if pushed > 0 {
            NSLog("Supabase sync: pushed \(pushed) boards")
        }

        return pushed
    }

    private func saveRemoteBoard(_ row: SupabaseBoardRow) -> BoardDoc? {
        guard var doc = decodeBoardDoc(from: row.payload) else {
            NSLog("Supabase sync: failed to decode payload for board \(row.id)")
            return nil
        }
        if let local = persistence.loadBoardIfExists(id: row.id) {
            doc.viewport = local.viewport
            doc.ui = local.ui
        }
        doc.id = row.id
        doc.title = row.title
        doc.updatedAt = row.updatedAt.timeIntervalSince1970
        _ = persistence.save(doc: doc, markDirty: false, updateActive: false)
        persistence.setBoardVersion(id: row.id, version: row.version)
        return doc
    }

    private func remoteDoc(from row: SupabaseBoardRow) -> BoardDoc? {
        guard var doc = decodeBoardDoc(from: row.payload) else {
            NSLog("Supabase sync: failed to decode payload for board \(row.id)")
            return nil
        }
        doc.id = row.id
        doc.title = row.title
        doc.updatedAt = row.updatedAt.timeIntervalSince1970
        return doc
    }

    private func mergedDoc(local: BoardDoc, remoteRow: SupabaseBoardRow) -> BoardDoc? {
        guard let remoteDoc = remoteDoc(from: remoteRow) else { return nil }
        return mergeBoardDocs(local: local, remote: remoteDoc)
    }

    private func mergeBoardDocs(local: BoardDoc, remote: BoardDoc) -> BoardDoc {
        var merged = remote
        merged.entries = mergeEntries(local: local.entries, remote: remote.entries)
        merged.zOrder = mergeZOrder(primary: remote.zOrder,
                                    secondary: local.zOrder,
                                    entries: merged.entries)
        merged.createdAt = min(local.createdAt, remote.createdAt)
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        merged.viewport = local.viewport
        merged.ui = local.ui
        return merged
    }

    private func mergeEntries(local: [UUID: BoardEntry], remote: [UUID: BoardEntry]) -> [UUID: BoardEntry] {
        var merged = remote
        for (id, localEntry) in local {
            if let remoteEntry = merged[id] {
                if localEntry.updatedAt >= remoteEntry.updatedAt {
                    merged[id] = localEntry
                }
            } else {
                merged[id] = localEntry
            }
        }
        return merged
    }

    private func mergeZOrder(primary: [UUID],
                             secondary: [UUID],
                             entries: [UUID: BoardEntry]) -> [UUID] {
        var seen = Set<UUID>()
        var merged: [UUID] = []

        for id in primary where entries[id] != nil {
            if seen.insert(id).inserted {
                merged.append(id)
            }
        }
        for id in secondary where entries[id] != nil {
            if seen.insert(id).inserted {
                merged.append(id)
            }
        }
        if merged.count < entries.count {
            let remaining = entries.keys.filter { !seen.contains($0) }
            let sorted = remaining.sorted {
                (entries[$0]?.createdAt ?? 0) < (entries[$1]?.createdAt ?? 0)
            }
            merged.append(contentsOf: sorted)
        }
        return merged
    }

    private func fetchRemoteBoardRow(id: UUID, userId: UUID, client: SupabaseClient) async throws -> SupabaseBoardRow? {
        let response: PostgrestResponse<[SupabaseBoardRow]> = try await client
            .from("boards")
            .select("id,user_id,title,payload,version,updated_at")
            .eq("user_id", value: userId)
            .eq("id", value: id)
            .execute()

        return response.value.first
    }

    private func deleteRemoteBoard(id: UUID, userId: UUID, client: SupabaseClient) async throws {
        _ = try await client
            .from("boards")
            .delete()
            .eq("user_id", value: userId)
            .eq("id", value: id)
            .execute()
    }

    private func reconcileRemoteDeletions(userId: UUID, client: SupabaseClient) async throws -> Int {
        let response: PostgrestResponse<[SupabaseBoardIdRow]> = try await client
            .from("boards")
            .select("id")
            .eq("user_id", value: userId)
            .execute()

        let remoteIds = Set(response.value.map { $0.id })
        let localBoards = persistence.listBoards()
        var removed = 0

        for meta in localBoards where !meta.isDirty {
            if !remoteIds.contains(meta.id) {
                _ = persistence.deleteBoard(id: meta.id)
                removed += 1
            }
        }

        if removed > 0 {
            NotificationCenter.default.post(
                name: .persistenceDidChange,
                object: persistence,
                userInfo: [PersistenceService.changeNotificationUserInfoKey: PersistenceService.ChangeEvent.boardsIndex]
            )
        }

        return removed
    }

    private func createConflictCopy(for boardId: UUID) {
        guard var doc = persistence.loadBoardIfExists(id: boardId) else { return }
        let now = Date()
        let baseTitle = doc.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = baseTitle.isEmpty ? "Untitled Board" : baseTitle
        doc.id = UUID()
        doc.title = "\(title) (Conflicted copy)"
        doc.createdAt = now.timeIntervalSince1970
        doc.updatedAt = now.timeIntervalSince1970
        _ = persistence.save(doc: doc, markDirty: true, updateActive: false)
    }

    private func scheduleDebouncedPush() {
        if isPushInProgress {
            needsPushAfterCurrent = true
            return
        }
        pushTask?.cancel()
        let token = UUID()
        pushTaskToken = token
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceIntervalNanos)
            guard let self, self.pushTaskToken == token else { return }
            guard !Task.isCancelled else {
                if self.pushTaskToken == token {
                    self.pushTask = nil
                }
                return
            }
            guard self.syncTask == nil else {
                self.needsPushAfterCurrent = true
                if self.pushTaskToken == token {
                    self.pushTask = nil
                }
                return
            }

            self.isPushInProgress = true
            do {
                let pushed = try await self.pushLocalChanges()
                self.recordPushSuccess(count: pushed)
            } catch {
                self.recordPushFailure(error: error)
            }
            self.isPushInProgress = false
            if self.pushTaskToken == token {
                self.pushTask = nil
            }

            if self.needsPushAfterCurrent {
                self.needsPushAfterCurrent = false
                self.scheduleDebouncedPush()
            }
        }
    }

    private func observeAuthChanges() {
        authService.$user
            .receive(on: RunLoop.main)
            .sink { [weak self] user in
                guard let self else { return }
                if user != nil {
                    self.startPeriodicPull()
                    self.syncNow(reason: "auth")
                } else {
                    self.stopPeriodicPull()
                }
            }
            .store(in: &cancellables)
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let notification = UIApplication.didBecomeActiveNotification
        #elseif canImport(AppKit)
        let notification = NSApplication.didBecomeActiveNotification
        #else
        let notification = Notification.Name("AstraBoardAppDidBecomeActive")
        #endif

        NotificationCenter.default.publisher(for: notification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncNow(reason: "foreground")
            }
            .store(in: &cancellables)
    }

    private func startPeriodicPull() {
        guard pullTimer == nil else { return }
        pullTimer = Timer.scheduledTimer(withTimeInterval: Self.pullInterval, repeats: true) { [weak self] _ in
            self?.syncNow(reason: "timer")
        }
    }

    private func stopPeriodicPull() {
        pullTimer?.invalidate()
        pullTimer = nil
    }

    private func recordPullSuccess(count: Int, conflicts: Int) {
        lastPull = SyncLogEntry(timestamp: Date(), success: true, count: count, conflicts: conflicts, message: nil)
    }

    private func recordPullFailure(error: Error) {
        if isCancellation(error) { return }
        lastPull = SyncLogEntry(timestamp: Date(), success: false, count: 0, conflicts: nil, message: error.localizedDescription)
        NSLog("Supabase sync: pull failed: \(error)")
    }

    private func recordPushSuccess(count: Int) {
        lastPush = SyncLogEntry(timestamp: Date(), success: true, count: count, conflicts: nil, message: nil)
    }

    private func recordPushFailure(error: Error) {
        if isCancellation(error) { return }
        lastPush = SyncLogEntry(timestamp: Date(), success: false, count: 0, conflicts: nil, message: error.localizedDescription)
        NSLog("Supabase sync: push failed: \(error)")
    }

    private func updateLastPullAt(from latestRemote: Date?) {
        guard let latestRemote else { return }
        lastPullAt = latestRemote
        UserDefaults.standard.set(latestRemote.timeIntervalSince1970, forKey: Self.lastPullKey)
    }

    private func statusText(for entry: SyncLogEntry?) -> String {
        guard let entry else { return "Never" }
        let time = Self.timeFormatter.string(from: entry.timestamp)
        if entry.success {
            var detail = "Success \(time)"
            if entry.count > 0 {
                detail += " (\(entry.count))"
            }
            if let conflicts = entry.conflicts, conflicts > 0 {
                detail += " | \(conflicts) conflict(s)"
            }
            return detail
        }
        let message = entry.message ?? "Unknown error"
        return "Failed \(time): \(message)"
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func loadLastPullAt() -> Date? {
        let value = UserDefaults.standard.double(forKey: lastPullKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private func makePayload(from doc: BoardDoc) throws -> AnyJSON {
        let encoder = JSONEncoder()
        let data = try encoder.encode(doc)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        let sanitized = sanitizeJSONValue(object)
        guard let payload = anyJSON(from: sanitized) else {
            throw SyncError.invalidPayload
        }
        return payload
    }

    private enum AssetSyncMode {
        case push
        case pull
    }

    private func syncAssets(for doc: BoardDoc, userId: UUID, client: SupabaseClient, mode: AssetSyncMode) async {
        guard let bucketId = assetsBucketId() else { return }
        let filenames = collectAssetFilenames(from: doc)
        guard !filenames.isEmpty else { return }

        let storage = client.storage.from(bucketId)

        for filename in filenames where !filename.isEmpty {
            let remotePath = assetPath(userId: userId, filename: filename)
            switch mode {
            case .push:
                guard let localURL = persistence.assetURL(for: filename) else { continue }
                do {
                    let exists = try await storage.exists(path: remotePath)
                    guard !exists else { continue }
                    let options = FileOptions(contentType: contentType(for: filename))
                    _ = try await storage.upload(remotePath, fileURL: localURL, options: options)
                } catch {
                    do {
                        let options = FileOptions(contentType: contentType(for: filename))
                        _ = try await storage.upload(remotePath, fileURL: localURL, options: options)
                    } catch {
                        NSLog("Supabase sync: asset upload failed for \(filename): \(error)")
                    }
                }
            case .pull:
                guard !persistence.assetExists(filename: filename) else { continue }
                do {
                    let data = try await storage.download(path: remotePath)
                    if !persistence.saveAsset(data: data, filename: filename) {
                        NSLog("Supabase sync: failed to save asset \(filename)")
                    }
                } catch {
                    NSLog("Supabase sync: asset download failed for \(filename): \(error)")
                }
            }
        }
    }

    private func downloadAssetIfNeeded(filename: String, userId: UUID, client: SupabaseClient) async {
        guard !persistence.assetExists(filename: filename) else { return }
        guard let bucketId = assetsBucketId() else { return }
        let storage = client.storage.from(bucketId)
        let remotePath = assetPath(userId: userId, filename: filename)
        do {
            let data = try await storage.download(path: remotePath)
            if !persistence.saveAsset(data: data, filename: filename) {
                NSLog("Supabase sync: failed to save asset \(filename)")
            }
        } catch {
            NSLog("Supabase sync: asset download failed for \(filename): \(error)")
        }
    }

    private func assetsBucketId() -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: Self.assetsBucketKey) as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        return Self.defaultAssetsBucket
    }

    private func assetPath(userId: UUID, filename: String) -> String {
        "\(userId.uuidString)/\(filename)"
    }

    private func contentType(for filename: String) -> String? {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    private func collectAssetFilenames(from doc: BoardDoc) -> Set<String> {
        var filenames = Set<String>()

        for entry in doc.entries.values {
            switch entry.data {
            case .image(let ref):
                filenames.insert(ref.filename)
            case .file(let ref):
                filenames.insert(ref.filename)
            default:
                break
            }
        }

        for message in doc.chat.messages {
            message.images.forEach { filenames.insert($0.filename) }
            message.files.forEach { filenames.insert($0.filename) }
        }

        for thread in doc.chatHistory {
            for message in thread.messages {
                message.images.forEach { filenames.insert($0.filename) }
                message.files.forEach { filenames.insert($0.filename) }
            }
        }

        if let pending = doc.pendingClarification {
            pending.originalImages.forEach { filenames.insert($0.filename) }
            pending.originalFiles.forEach { filenames.insert($0.filename) }
        }

        for memory in doc.memories {
            if let image = memory.image {
                filenames.insert(image.filename)
            }
        }

        return filenames
    }

    private func decodeBoardDoc(from payload: AnyJSON) -> BoardDoc? {
        let value = payload.value
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [])
            return try JSONDecoder().decode(BoardDoc.self, from: data)
        } catch {
            NSLog("Supabase sync: decode error \(error)")
            return nil
        }
    }

    private func sanitizeJSONValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string.replacingOccurrences(of: "\u{0000}", with: "")
        case let array as [Any]:
            return array.map { sanitizeJSONValue($0) }
        case let dict as [String: Any]:
            var sanitized: [String: Any] = [:]
            sanitized.reserveCapacity(dict.count)
            for (key, value) in dict {
                sanitized[key] = sanitizeJSONValue(value)
            }
            return sanitized
        default:
            return value
        }
    }

    private func anyJSON(from value: Any) -> AnyJSON? {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let doubleValue = number.doubleValue
            let intValue = number.intValue
            if doubleValue == Double(intValue) {
                return .integer(intValue)
            }
            return .double(doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case let array as [Any]:
            let converted = array.compactMap { anyJSON(from: $0) }
            guard converted.count == array.count else { return nil }
            return .array(converted)
        case let dict as [String: Any]:
            var converted: [String: AnyJSON] = [:]
            converted.reserveCapacity(dict.count)
            for (key, value) in dict {
                guard let convertedValue = anyJSON(from: value) else { return nil }
                converted[key] = convertedValue
            }
            return .object(converted)
        default:
            return nil
        }
    }
}
