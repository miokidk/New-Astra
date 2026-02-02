import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import UserNotifications
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
import LocalAuthentication

private let linePadding: CGFloat = 6
private let textEntryChunkMaxLength = 2000
private let textEntryChunkSpacing: CGFloat = 16

enum PanelKind {
    case chat, chatArchive, log, memories, shapeStyle, settings, notes, reminder

    static let defaultZOrder: [PanelKind] = [
        .chat,
        .chatArchive,
        .log,
        .memories,
        .shapeStyle,
        .settings,
        .notes,
        .reminder
    ]
}

@MainActor
final class BoardStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let hudSize = CGSize(width: 780, height: 83)
    static let panelMinSize = CGSize(width: 260, height: 200)
    private static let settingsPanelMinSize = CGSize(width: 460, height: 520)
    static func panelMinSize(for kind: PanelKind) -> CGSize {
        switch kind {
        case .settings:
            return settingsPanelMinSize
        default:
            return panelMinSize
        }
    }
    static let panelPadding: CGFloat = 16
    
    private var isInitializing = true
    
    private var lastSavedGlobals: AppGlobalSettings = .default

    private var activityLabelIndexByKey: [String: Int] = [:]
    private var lastReminderRecallIds: [UUID] = []
    private var lastReminderRecallAt: Double = 0
    private let lastReminderRecallTTL: TimeInterval = 600
    private var replyIdsWithNoteMutations: Set<UUID> = []
    private let chatService = OllamaChatService()
    private var chatReplyTask: Task<Void, Never>?
    private let chatModelName = "astra:oss20b"

    @Published var doc: BoardDoc {
        didSet {
            guard !isInitializing else { return }
            scheduleAutosave()
        }
    }
    @Published var selection: Set<UUID> = [] {
        didSet {
            guard !isRestoringSnapshot else { return }
            closeStylePanelIfNeeded()
        }
    }
    @Published var editingEntryID: UUID?
    @Published var currentTool: BoardTool = .select
    @Published var pendingShapeKind: ShapeKind = .rect
    // MARK: - Context Tool Menu (popup tool palette)
    @Published var isToolMenuVisible: Bool = false
    @Published var toolMenuScreenPosition: CGPoint = .zero
    
    @Published private(set) var unlockedNoteIDs: Set<UUID> = []
    
    // Last known pointer location in viewport (screen) coordinates.
    // Used to anchor pinch-zoom toward the mouse even when the gesture doesn't provide a location.
    private(set) var lastPointerLocationInViewport: CGPoint? = nil

    func notePointerLocation(_ p: CGPoint) {
        guard viewportSize != .zero else {
            lastPointerLocationInViewport = p
            return
        }
        // Only keep the location if it is within the viewport bounds.
        if p.x >= 0, p.y >= 0, p.x <= viewportSize.width, p.y <= viewportSize.height {
            lastPointerLocationInViewport = p
        }
    }

    func showToolMenu(at screenPoint: CGPoint) {
        if suppressNextToolMenuShow {
            suppressNextToolMenuShow = false
            return
        }
        toolMenuScreenPosition = screenPoint
        isToolMenuVisible = true
    }

    func hideToolMenu(suppressNextShow: Bool = false) {
        isToolMenuVisible = false
        if suppressNextShow {
            suppressNextToolMenuShow = true
            // Clear on next runloop so normal clicks can open again
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextToolMenuShow = false
            }
        }
    }
    
    // MARK: - Quick insert from Tool Palette
    private func resolvedPaletteInsertScreenPoint(_ screenPoint: CGPoint) -> CGPoint {
        // If the palette was shown before we had a real anchor, fall back to viewport center.
        if viewportSize != .zero && screenPoint == .zero {
            return CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        }
        return screenPoint
    }

    @MainActor
    @discardableResult
    func paletteInsertText(at screenPoint: CGPoint) -> UUID {
        let p = resolvedPaletteInsertScreenPoint(screenPoint)
        let world = worldPoint(from: p)
        let rect = CGRect(x: world.x - 120, y: world.y - 80, width: 240, height: 160)
        let id = createEntry(type: .text, frame: rect, data: .text(""), createdBy: .user)
        selection = [id]
        beginEditing(id)
        currentTool = .select
        return id
    }

    @MainActor
    @discardableResult
    func paletteInsertShape(kind: ShapeKind, at screenPoint: CGPoint) -> UUID {
        let p = resolvedPaletteInsertScreenPoint(screenPoint)
        let world = worldPoint(from: p)

        let rect: CGRect
        switch kind {
        case .rect:
            rect = CGRect(x: world.x - 120, y: world.y - 80, width: 240, height: 160)
        case .circle:
            rect = CGRect(x: world.x - 100, y: world.y - 100, width: 200, height: 200)
        case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
            rect = CGRect(x: world.x - 120, y: world.y - 80, width: 240, height: 160)
        }

        let id = createEntry(type: .shape, frame: rect, data: .shape(kind), createdBy: .user)
        selection = [id]
        currentTool = .select
        return id
    }

    @MainActor
    func paletteInsertImage(at screenPoint: CGPoint) {
        #if os(macOS)
        let p = resolvedPaletteInsertScreenPoint(screenPoint)
        let world = worldPoint(from: p)

        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "heic", "gif"]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url, let ref = copyImage(at: url) {
            let rect = imageRect(for: ref, centeredAt: world, maxSide: 320)
            let id = createEntry(type: .image, frame: rect, data: .image(ref), createdBy: .user)
            selection = [id]
        }
        currentTool = .select
        #endif
    }
    
    @Published var marqueeRect: CGRect?
    @Published var highlightEntryId: UUID?
    @Published var viewportSize: CGSize = .zero {
        didSet {
            clampHUDPosition()
            clampAllPanels()
        }
    }
    
    @Published var lineBuilder: [CGPoint] = []
    @Published var isDraggingOverlay: Bool = false
    @Published var chatWarning: String?
    @Published var chatDraftImages: [ImageRef] = []
    @Published var chatDraftFiles: [FileRef] = []
    @Published var pendingChatReplies: Int = 0
    private var queuedUserMessageIDs: [UUID] = []
    @Published private(set) var chatActivityStatus: String?
    @Published private(set) var chatThinkingText: String?
    @Published var chatThinkingExpanded: Bool = false
    @Published var chatNeedsAttention: Bool = false
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var isVoiceConversationActive: Bool = false
    @Published private(set) var voiceConversationResumeToken: UUID = UUID()
    @Published private(set) var boards: [BoardMeta] = []
    @Published var hudExtraHeight: CGFloat = 0 {
        didSet { clampHUDPosition() }
    }
    @Published var activeArchivedChatId: UUID?
    @Published private(set) var panelZOrder: [PanelKind] = PanelKind.defaultZOrder
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published var activeReminderPanelId: UUID? // New property for active reminder panel

    private struct BoardSnapshot {
        let doc: BoardDoc
        let selection: Set<UUID>
        let chatWarning: String?
        let chatDraftImages: [ImageRef]
        let chatDraftFiles: [FileRef]
        let pendingChatReplies: Int
        let chatNeedsAttention: Bool
        let activeArchivedChatId: UUID?
    }
    private var undoStack: [BoardSnapshot] = []
    private var redoStack: [BoardSnapshot] = []
    private var isRestoringSnapshot = false
    private var undoDepth = 0
    private var lastCoalescingKey: String?
    private var lastCoalescingTime: TimeInterval = 0
    private let undoCoalesceInterval: TimeInterval = 0.35
    private let maxUndoSteps = 200
    
    private var globalSettings: AppGlobalSettings
    private var lastSyncedGlobalSettings: AppGlobalSettings
    
    private var suppressNextToolMenuShow = false
    private var persistenceObserver: NSObjectProtocol?

    let persistence: PersistenceService
    let authService: AuthService
    private static let defaultDeviceSyncEnabled: Bool = {
        let flag = ProcessInfo.processInfo.environment["ASTRA_DISABLE_DEVICE_SYNC"]
        return flag?.lowercased() != "1"
    }()

    private static let deviceSyncEnabledDefaultsKey = "astra.syncAcrossDevices.enabled"

    /// Initial value for the "Sync across devices" toggle.
    ///
    /// Priority:
    /// 1) If ASTRA_DISABLE_DEVICE_SYNC=1, always return false (forced off).
    /// 2) If the user has a saved preference, use it.
    /// 3) Otherwise default to `defaultDeviceSyncEnabled`.
    private static func initialDeviceSyncEnabled() -> Bool {
        guard defaultDeviceSyncEnabled else { return false }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: deviceSyncEnabledDefaultsKey) != nil {
            return defaults.bool(forKey: deviceSyncEnabledDefaultsKey)
        }
        return defaultDeviceSyncEnabled
    }

    @Published private(set) var isDeviceSyncEnabled: Bool = BoardStore.initialDeviceSyncEnabled()
    private var pendingDeletionsWhileSyncDisabled: Set<UUID> = []
    private var authStateObserver: AnyCancellable?
    lazy var syncService: BoardSyncService = BoardSyncService(authService: authService, boardStore: self)

    func setDeviceSyncEnabled(_ enabled: Bool) {
        // If sync is force-disabled via env var, don't allow enabling.
        if enabled, !BoardStore.defaultDeviceSyncEnabled {
            UserDefaults.standard.set(false, forKey: BoardStore.deviceSyncEnabledDefaultsKey)
            if isDeviceSyncEnabled {
                isDeviceSyncEnabled = false
                syncService.stop()
            }
            return
        }

        guard isDeviceSyncEnabled != enabled else { return }
        isDeviceSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: BoardStore.deviceSyncEnabledDefaultsKey)

        if enabled {
            syncService.start()
            flushPendingBoardDeletionsIfPossible()
            syncService.syncNow(reason: "sync-resume")
        } else {
            syncService.stop()
        }
    }

    private func flushPendingBoardDeletionsIfPossible() {
        guard !pendingDeletionsWhileSyncDisabled.isEmpty else { return }
        guard authService.currentUser() != nil else { return }
        pendingDeletionsWhileSyncDisabled.forEach { syncService.noteBoardDeleted(id: $0) }
        pendingDeletionsWhileSyncDisabled.removeAll()
    }
    private var autosaveWorkItem: DispatchWorkItem?
    private let autosaveInterval: TimeInterval = 0.5
    private var didRequestNotificationAuthorization = false
    private var reminderTimer: Timer? // New property for reminder timer

    init(boardID: UUID,
         persistence: PersistenceService,
         authService: AuthService) {
        self.persistence = persistence
        self.authService = authService

        // Work with locals first (no self/doc property access before super.init)
        let loadedDoc = persistence.loadOrCreateBoard(id: boardID)
        var workingDoc = loadedDoc

        let loadedGlobals = persistence.loadGlobalSettings()
        var globals = loadedGlobals

        var didMutateGlobals = false
        var didMutateDoc = false

        // --- MERGE (Doc -> Globals if globals empty, else Globals -> Doc if doc empty) ---

        // User name
        if globals.userName.isEmpty && !workingDoc.chatSettings.userName.isEmpty {
            globals.userName = workingDoc.chatSettings.userName
            didMutateGlobals = true
        } else if workingDoc.chatSettings.userName.isEmpty && !globals.userName.isEmpty {
            workingDoc.chatSettings.userName = globals.userName
            didMutateDoc = true
        }

        // Notes
        if globals.notes.isEmpty && !workingDoc.chatSettings.notes.isEmpty {
            globals.notes = workingDoc.chatSettings.notes
            didMutateGlobals = true
        } else if workingDoc.chatSettings.notes.isEmpty && !globals.notes.isEmpty {
            workingDoc.chatSettings.notes = globals.notes
            didMutateDoc = true
        }

        // Voice
        let defaultVoice = ChatSettings.defaultVoice
        if globals.voice == defaultVoice && workingDoc.chatSettings.voice != defaultVoice {
            globals.voice = workingDoc.chatSettings.voice
            didMutateGlobals = true
        } else if workingDoc.chatSettings.voice == defaultVoice && globals.voice != defaultVoice {
            workingDoc.chatSettings.voice = globals.voice
            didMutateDoc = true
        }

        // Always Listening
        let defaultAlwaysListening = ChatSettings.defaultAlwaysListening
        if globals.alwaysListening == defaultAlwaysListening
            && workingDoc.chatSettings.alwaysListening != defaultAlwaysListening {
            globals.alwaysListening = workingDoc.chatSettings.alwaysListening
            didMutateGlobals = true
        } else if workingDoc.chatSettings.alwaysListening == defaultAlwaysListening
                    && globals.alwaysListening != defaultAlwaysListening {
            workingDoc.chatSettings.alwaysListening = globals.alwaysListening
            didMutateDoc = true
        }

        // Memories
        if globals.memories.isEmpty && !workingDoc.memories.isEmpty {
            globals.memories = workingDoc.memories
            didMutateGlobals = true
        } else if workingDoc.memories.isEmpty && !globals.memories.isEmpty {
            workingDoc.memories = globals.memories
            didMutateDoc = true
        }
        
        // Log
        if globals.log.isEmpty && !workingDoc.log.isEmpty {
            globals.log = workingDoc.log
            didMutateGlobals = true
        } else if workingDoc.log.isEmpty && !globals.log.isEmpty {
            workingDoc.log = globals.log
            didMutateDoc = true
        }
        
        // Chat History (global chat log)
        if globals.chatHistory.isEmpty && !workingDoc.chatHistory.isEmpty {
            globals.chatHistory = workingDoc.chatHistory
            didMutateGlobals = true
        } else if workingDoc.chatHistory.isEmpty && !globals.chatHistory.isEmpty {
            workingDoc.chatHistory = globals.chatHistory
            didMutateDoc = true
        } else if !globals.chatHistory.isEmpty || !workingDoc.chatHistory.isEmpty {
            var map: [UUID: ChatThread] = [:]

            for c in globals.chatHistory {
                map[c.id] = c
            }

            for c in workingDoc.chatHistory {
                if let existing = map[c.id] {
                    let existingTs = existing.messages.last?.ts ?? 0
                    let candidateTs = c.messages.last?.ts ?? 0
                    if candidateTs > existingTs || (candidateTs == existingTs && c.messages.count > existing.messages.count) {
                        map[c.id] = c
                    }
                } else {
                    map[c.id] = c
                }
            }

            let merged = map.values
                .filter { !$0.messages.isEmpty }
                .sorted { ($0.messages.last?.ts ?? 0) > ($1.messages.last?.ts ?? 0) }

            globals.chatHistory = merged
            workingDoc.chatHistory = merged
            didMutateGlobals = true
            didMutateDoc = true
        }
        
        // Reminders
        if globals.reminders.isEmpty && !workingDoc.reminders.isEmpty {
            // migrate older boards that had reminders into globals
            globals.reminders = workingDoc.reminders
            didMutateGlobals = true
        } else if workingDoc.reminders.isEmpty && !globals.reminders.isEmpty {
            // new tab/board picks up global reminders
            workingDoc.reminders = globals.reminders
            didMutateDoc = true
        } else if !globals.reminders.isEmpty && !workingDoc.reminders.isEmpty {
            // merge by id so nothing is lost
            var map: [UUID: ReminderItem] = [:]
            for r in globals.reminders { map[r.id] = r }
            for r in workingDoc.reminders { map[r.id] = r }
            let merged = map.values.sorted(by: { $0.dueAt < $1.dueAt })

            globals.reminders = merged
            workingDoc.reminders = merged
            didMutateGlobals = true
            didMutateDoc = true
        }

        // Initialize stored properties (safe before super.init; doc didSet is disabled by isInitializing)
        self.globalSettings = globals
        self.lastSyncedGlobalSettings = globals
        self.lastSavedGlobals = globals
        self.doc = workingDoc

        super.init()
        self.isInitializing = false

        // Persist any migrations AFTER super.init
        if didMutateGlobals {
            persistence.saveGlobalSettings(globals)
            self.globalSettings = globals
            self.lastSyncedGlobalSettings = globals
        }

        if didMutateDoc {
            persistence.save(doc: workingDoc)
        }

        // Track last active board, etc.
        persistence.setActiveBoard(id: boardID)
        UNUserNotificationCenter.current().delegate = self
        requestNotificationAuthorizationIfNeeded()

        setupReminderScheduler() // Call the new scheduler setup method

        refreshBoards()
        startObservingPersistence()
        authStateObserver = authService.$user
            .receive(on: RunLoop.main)
            .sink { [weak self] user in
                guard let self else { return }
                guard user != nil, self.isDeviceSyncEnabled else { return }
                self.flushPendingBoardDeletionsIfPossible()
                self.syncService.syncNow(reason: "sync-resume")
            }
        if isDeviceSyncEnabled {
            syncService.start()
        }
    }

    deinit {
        if let observer = persistenceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        authStateObserver?.cancel()
    }
    
    private func closeStylePanelIfNeeded() {
        guard doc.ui.panels.shapeStyle.isOpen else { return }
        guard !hasStyleSelection else { return }
        doc.ui.panels.shapeStyle.isOpen = false
    }

    // MARK: - Board switching
    var currentBoardId: UUID { doc.id }

    func refreshBoards() {
        boards = persistence.listBoards()
    }

    @MainActor
    func switchBoard(id: UUID) {
        guard id != doc.id else { return }
        stopChatReplies()
        autosaveWorkItem?.cancel()
        persistGlobalsNow()
        persistence.save(doc: doc)
        let loadedDoc = persistence.loadOrCreateBoard(id: id)
        applyBoardChange(using: loadedDoc)
    }

    @MainActor
    func createBoard() {
        stopChatReplies()
        autosaveWorkItem?.cancel()
        persistGlobalsNow()
        persistence.save(doc: doc)
        let newDoc = persistence.createBoard()
        applyBoardChange(using: newDoc)
        if isDeviceSyncEnabled {
            syncService.noteLocalChange(boardID: newDoc.id)
            syncService.syncNow(reason: "board-create")
        }
    }

    @MainActor
    func deleteBoard(id: UUID) {
        let deletedId = id
        if id == doc.id {
            stopChatReplies()
            autosaveWorkItem?.cancel()
            persistGlobalsNow()
            persistence.save(doc: doc)
            let nextId = persistence.deleteBoard(id: id)
            if let nextId {
                let loadedDoc = persistence.loadOrCreateBoard(id: nextId)
                applyBoardChange(using: loadedDoc)
            } else {
                refreshBoards()
            }
        } else {
            _ = persistence.deleteBoard(id: id)
            refreshBoards()
        }
        if isDeviceSyncEnabled {
            syncService.noteBoardDeleted(id: deletedId)
            syncService.syncNow(reason: "board-delete")
        } else {
            pendingDeletionsWhileSyncDisabled.insert(deletedId)
        }
    }

    @MainActor
    func renameBoard(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Untitled" : trimmed

        if id == doc.id {
            // Current board: mutate in-memory doc and persist.
            if doc.title != finalTitle {
                doc.title = finalTitle
                doc.updatedAt = Date().timeIntervalSince1970
                persistence.save(doc: doc, markDirty: true, updateActive: true)
            }
            refreshBoards()
        } else {
            // Non-active board: load, mutate, persist without switching active board.
            guard var other = persistence.loadBoardIfExists(id: id) else { return }
            if other.title == finalTitle { return }
            other.title = finalTitle
            other.updatedAt = Date().timeIntervalSince1970
            persistence.save(doc: other, markDirty: true, updateActive: false)
            refreshBoards()
        }

        if isDeviceSyncEnabled {
            syncService.noteLocalChange(boardID: id)
            syncService.syncNow(reason: "board-rename")
        }
    }

    private func applyBoardChange(using loadedDoc: BoardDoc) {
        var workingDoc = loadedDoc

        var globals = persistence.loadGlobalSettings()
        var didMutateGlobals = false
        var didMutateDoc = false

        // --- MERGE (Doc -> Globals if globals empty, else Globals -> Doc if doc empty) ---
        if globals.userName.isEmpty && !workingDoc.chatSettings.userName.isEmpty {
            globals.userName = workingDoc.chatSettings.userName
            didMutateGlobals = true
        } else if workingDoc.chatSettings.userName.isEmpty && !globals.userName.isEmpty {
            workingDoc.chatSettings.userName = globals.userName
            didMutateDoc = true
        }

        if globals.notes.isEmpty && !workingDoc.chatSettings.notes.isEmpty {
            globals.notes = workingDoc.chatSettings.notes
            didMutateGlobals = true
        } else if workingDoc.chatSettings.notes.isEmpty && !globals.notes.isEmpty {
            workingDoc.chatSettings.notes = globals.notes
            didMutateDoc = true
        }

        if globals.memories.isEmpty && !workingDoc.memories.isEmpty {
            globals.memories = workingDoc.memories
            didMutateGlobals = true
        } else if workingDoc.memories.isEmpty && !globals.memories.isEmpty {
            workingDoc.memories = globals.memories
            didMutateDoc = true
        }

        if globals.log.isEmpty && !workingDoc.log.isEmpty {
            globals.log = workingDoc.log
            didMutateGlobals = true
        } else if workingDoc.log.isEmpty && !globals.log.isEmpty {
            workingDoc.log = globals.log
            didMutateDoc = true
        }

        if globals.chatHistory.isEmpty && !workingDoc.chatHistory.isEmpty {
            globals.chatHistory = workingDoc.chatHistory
            didMutateGlobals = true
        } else if workingDoc.chatHistory.isEmpty && !globals.chatHistory.isEmpty {
            workingDoc.chatHistory = globals.chatHistory
            didMutateDoc = true
        } else if !globals.chatHistory.isEmpty || !workingDoc.chatHistory.isEmpty {
            var map: [UUID: ChatThread] = [:]

            for c in globals.chatHistory {
                map[c.id] = c
            }

            for c in workingDoc.chatHistory {
                if let existing = map[c.id] {
                    let existingTs = existing.messages.last?.ts ?? 0
                    let candidateTs = c.messages.last?.ts ?? 0
                    if candidateTs > existingTs || (candidateTs == existingTs && c.messages.count > existing.messages.count) {
                        map[c.id] = c
                    }
                } else {
                    map[c.id] = c
                }
            }

            let merged = map.values
                .filter { !$0.messages.isEmpty }
                .sorted { ($0.messages.last?.ts ?? 0) > ($1.messages.last?.ts ?? 0) }

            globals.chatHistory = merged
            workingDoc.chatHistory = merged
            didMutateGlobals = true
            didMutateDoc = true
        }

        if globals.reminders.isEmpty && !workingDoc.reminders.isEmpty {
            globals.reminders = workingDoc.reminders
            didMutateGlobals = true
        } else if workingDoc.reminders.isEmpty && !globals.reminders.isEmpty {
            workingDoc.reminders = globals.reminders
            didMutateDoc = true
        } else if !globals.reminders.isEmpty && !workingDoc.reminders.isEmpty {
            var map: [UUID: ReminderItem] = [:]
            for r in globals.reminders { map[r.id] = r }
            for r in workingDoc.reminders { map[r.id] = r }
            let merged = map.values.sorted(by: { $0.dueAt < $1.dueAt })

            globals.reminders = merged
            workingDoc.reminders = merged
            didMutateGlobals = true
            didMutateDoc = true
        }

        isInitializing = true
        doc = workingDoc
        isInitializing = false

        resetTransientStateForBoardSwitch()
        resetUndoHistory()
        globalSettings = globals
        lastSyncedGlobalSettings = globals
        lastSavedGlobals = globals

        if didMutateGlobals {
            persistence.saveGlobalSettings(globals)
            lastSavedGlobals = globals
        }

        if didMutateDoc {
            persistence.save(doc: workingDoc)
        }

        persistence.setActiveBoard(id: workingDoc.id)
        setupReminderScheduler()

        refreshBoards()
    }

    private func resetTransientStateForBoardSwitch() {
        selection.removeAll()
        editingEntryID = nil
        marqueeRect = nil
        highlightEntryId = nil
        lineBuilder.removeAll()
        isDraggingOverlay = false
        chatWarning = nil
        chatDraftImages.removeAll()
        chatDraftFiles.removeAll()
        pendingChatReplies = 0
        chatActivityStatus = nil
        chatNeedsAttention = false
        hudExtraHeight = 0
        activeArchivedChatId = nil
        activeReminderPanelId = nil
        panelZOrder = PanelKind.defaultZOrder
        currentTool = .select
        isToolMenuVisible = false
        toolMenuScreenPosition = .zero
        suppressNextToolMenuShow = false
        lastPointerLocationInViewport = nil
    }

    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !didRequestNotificationAuthorization else { return }
        didRequestNotificationAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func enqueueNotification(center: UNUserNotificationCenter, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: trigger)
        center.add(request) { error in
            if let error {
                print("Failed to add notification request: \\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Reminders
extension BoardStore {

    // Parses strings WITH fractional seconds and (optionally) timezone offsets.
    private static let iso8601FormatterFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // ✅ If the string has NO timezone offset, interpret it in the user's current timezone.
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    // Parses strings WITHOUT fractional seconds (common timestamp format).
    private static let iso8601FormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        // ✅ Same rule: missing offset => user's current timezone
        f.timeZone = .autoupdatingCurrent
        return f
    }()

    /// Accept both ISO formats and default to user's current timezone when offset is missing.
    private static func parseISO8601(_ s: String) -> Date? {
        // Try fractional first, then non-fractional
        if let d = iso8601FormatterFrac.date(from: s) { return d }
        if let d = iso8601FormatterNoFrac.date(from: s) { return d }

        if s.count >= 16, s.contains("T"), !s.contains(":") == false {
            // naive normalization: insert ":00" seconds if missing
            let normalized = s.replacingOccurrences(
                of: #"T(\d{2}:\d{2})([Z\+\-].*)?$"#,
                with: "T$1:00$2",
                options: .regularExpression
            )
            if normalized != s {
                if let d = iso8601FormatterFrac.date(from: normalized) { return d }
                if let d = iso8601FormatterNoFrac.date(from: normalized) { return d }
            }
        }

        return nil
    }

    private static let userVisibleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static let userVisibleDateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    private static let dayOfWeekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE" // e.g., "Mon"
        return formatter
    }()

    func addReminder(item: ReminderItem) {
        performUndoable {
            doc.reminders.append(item)
            persistGlobalsNow()
            touch()
            addLog("Created reminder: \"\(item.title)\"")
        }
    }
    
    private func persistGlobalsNow() {
        let globalsNow = AppGlobalSettings(
            userName: doc.chatSettings.userName,
            notes: doc.chatSettings.notes,
            voice: doc.chatSettings.voice,
            alwaysListening: doc.chatSettings.alwaysListening,
            memories: doc.memories,
            log: doc.log,
            chatHistory: doc.chatHistory,
            reminders: doc.reminders
        )
        persistence.saveGlobalSettings(globalsNow)
        lastSavedGlobals = globalsNow
    }

    func updateReminder(item: ReminderItem) {
        performUndoable {
            guard let index = doc.reminders.firstIndex(where: { $0.id == item.id }) else { return }
            doc.reminders[index] = item
            persistGlobalsNow()
            touch()
            addLog("Updated reminder: \"\(item.title)\"")
        }
    }

    func removeReminder(id: UUID) {
        performUndoable {
            doc.reminders.removeAll(where: { $0.id == id })
            persistGlobalsNow()
            touch()
            addLog("Removed reminder ID: \(id.uuidString)")
        }
    }

    func getReminder(id: UUID) -> ReminderItem? {
        doc.reminders.first(where: { $0.id == id })
    }
    
    private func basicActiveRemindersText(_ reminders: [ReminderItem]) -> String {
        if reminders.isEmpty { return "You don't have any active reminders set." }

        var response = "Here are your active reminders:\n"
        for r in reminders {
            let formattedDate = BoardStore.userVisibleDateFormatter.string(from: Date(timeIntervalSince1970: r.dueAt))
            response += "- '\(r.title)' due on \(formattedDate)"
            if let rec = r.recurrence {
                response += " (repeats \(rec.frequency.rawValue))"
            }
            response += "\n"
        }
        return response
    }

    private func smartReminderListResponse(userQuery: String, reminders: [ReminderItem]) async throws -> String {
        _ = userQuery
        return basicActiveRemindersText(reminders)
    }

    func setupReminderScheduler() {
        reminderTimer?.invalidate() // Invalidate any existing timer
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkDueReminders()
        }
    }

    @MainActor
    private func checkDueReminders() {
        let now = Date().timeIntervalSince1970
        var updatedReminders = doc.reminders

        for i in 0..<updatedReminders.count {
            var reminder = updatedReminders[i]

            guard reminder.status == .scheduled else { continue }
            guard reminder.dueAt <= now else { continue }

            reminder.status = .preparing
            updatedReminders[i] = reminder
            doc.reminders = updatedReminders // Update doc immediately to reflect status change

            Task {
                var currentReminder = reminder // Make a mutable copy for the async block
                if currentReminder.preparedMessage == nil || currentReminder.recurrence != nil {
                    let trimmed = currentReminder.work.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentReminder.preparedMessage = trimmed.isEmpty ? "Reminder: \(currentReminder.title)" : trimmed
                }

                currentReminder.status = .ready
                await MainActor.run {
                    // Update the reminder in the main actor context
                    if let index = self.doc.reminders.firstIndex(where: { $0.id == currentReminder.id }) {
                        self.doc.reminders[index] = currentReminder
                        self.touch() // Trigger autosave
                        
                        // Trigger macOS notification
                        let notificationBody = currentReminder.preparedMessage ?? currentReminder.work
                        self.enqueueNotification(center: UNUserNotificationCenter.current(),
                                                 title: "From Astra:",
                                                 body: currentReminder.title)
                        
                        // Set active reminder for panel display
                        self.activeReminderPanelId = currentReminder.id

                        // Handle recurrence or mark as fired
                        if let recurrence = currentReminder.recurrence {
                            self.calculateNextDueAt(for: &currentReminder, recurrence: recurrence, now: now)

                            currentReminder.status = .scheduled

                            self.updateReminder(item: currentReminder)
                            self.addLog("Recurring reminder '\(currentReminder.title)' re-scheduled for \(Date(timeIntervalSince1970: currentReminder.dueAt)).")
                        } else {
                            currentReminder.status = .fired
                            self.updateReminder(item: currentReminder)
                            self.addLog("Reminder '\(currentReminder.title)' fired.")
                        }
                    }
                }
            }
        }
    }
    
    // Helper to calculate next due date for recurring reminders
    // Helper to calculate next due date for recurring reminders
    private func calculateNextDueAt(for reminder: inout ReminderItem, recurrence: ReminderRecurrence, now: Double) {
        let calendar = Calendar.current
        let now = Date().timeIntervalSince1970

        let current = Date(timeIntervalSince1970: reminder.dueAt)

        // Preserve the original time-of-day
        let hour = calendar.component(.hour, from: current)
        let minute = calendar.component(.minute, from: current)
        let second = calendar.component(.second, from: current)

        func clampDay(year: Int, month: Int, day: Int) -> Int {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = 1
            guard let firstOfMonth = calendar.date(from: comps),
                  let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
                return day
            }
            return min(day, range.count)
        }

        func addMonthsClamped(from date: Date, months: Int) -> Date {
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            var y = comps.year ?? 1970
            var m = comps.month ?? 1
            let d = comps.day ?? 1

            // add months with carry
            var total = (y * 12 + (m - 1)) + months
            y = total / 12
            m = (total % 12) + 1

            let clamped = clampDay(year: y, month: m, day: d)

            var out = DateComponents()
            out.year = y
            out.month = m
            out.day = clamped
            out.hour = hour
            out.minute = minute
            out.second = second
            return calendar.date(from: out) ?? date
        }

        func addYearsClamped(from date: Date, years: Int) -> Date {
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let y = (comps.year ?? 1970) + years
            let m = comps.month ?? 1
            let d = comps.day ?? 1

            let clamped = clampDay(year: y, month: m, day: d)

            var out = DateComponents()
            out.year = y
            out.month = m
            out.day = clamped
            out.hour = hour
            out.minute = minute
            out.second = second
            return calendar.date(from: out) ?? date
        }

        func weeklyNext(after occurrence: Date, intervalWeeks: Int, weekdays: [Int]) -> Date {
            // "Every N weeks on these weekdays" behavior:
            // - within the same active week: move to the next weekday remaining in that week
            // - after finishing that week: jump N weeks, then pick the first weekday in that week
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: occurrence)?.start ?? occurrence
            let timeComps = DateComponents(hour: hour, minute: minute, second: second)

            // Build occurrences inside this week
            var datesThisWeek: [Date] = []
            for wd in weekdays.sorted() {
                // weekday is 1...7, find that day in this week
                // We can do this by adding offset days from weekStart until weekday matches.
                var candidate = weekStart
                for _ in 0..<7 {
                    if calendar.component(.weekday, from: candidate) == wd {
                        if let withTime = calendar.date(bySettingHour: hour, minute: minute, second: second, of: candidate) {
                            datesThisWeek.append(withTime)
                        }
                        break
                    }
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            }
            datesThisWeek.sort()

            // If there's another day in THIS SAME week after the current occurrence, take it
            if let nextInWeek = datesThisWeek.first(where: { $0 > occurrence }) {
                return nextInWeek
            }

            // Otherwise jump intervalWeeks weeks ahead (to the next active week)
            let nextWeekStart = calendar.date(byAdding: .weekOfYear, value: max(1, intervalWeeks), to: weekStart) ?? weekStart
            // Pick first weekday in the list in that next active week
            for wd in weekdays.sorted() {
                var candidate = nextWeekStart
                for _ in 0..<7 {
                    if calendar.component(.weekday, from: candidate) == wd {
                        if let withTime = calendar.date(bySettingHour: hour, minute: minute, second: second, of: candidate) {
                            return withTime
                        }
                        break
                    }
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            }

            // Fallback: just add weeks
            return calendar.date(byAdding: .weekOfYear, value: max(1, intervalWeeks), to: occurrence) ?? occurrence
        }

        func nextOccurrence(after date: Date) -> Date {
            switch recurrence.frequency {
            case .hourly:
                return calendar.date(byAdding: .hour, value: max(1, recurrence.interval), to: date) ?? date

            case .daily:
                return calendar.date(byAdding: .day, value: max(1, recurrence.interval), to: date) ?? date

            case .weekly:
                if let wds = recurrence.weekdays, !wds.isEmpty {
                    return weeklyNext(after: date, intervalWeeks: max(1, recurrence.interval), weekdays: wds)
                } else {
                    return calendar.date(byAdding: .weekOfYear, value: max(1, recurrence.interval), to: date) ?? date
                }

            case .monthly:
                return addMonthsClamped(from: date, months: max(1, recurrence.interval))

            case .yearly:
                return addYearsClamped(from: date, years: max(1, recurrence.interval))
            }
        }

        var candidate = current
        var safety = 0

        // Catch up until it's in the future (prevents spam after downtime)
        while candidate.timeIntervalSince1970 <= now && safety < 5000 {
            candidate = nextOccurrence(after: candidate)
            safety += 1
        }

        reminder.dueAt = candidate.timeIntervalSince1970
    }

    func clearActiveReminderPanel() {
        activeReminderPanelId = nil
    }
}

// MARK: - Sync
extension BoardStore {
    private func startObservingPersistence() {
        persistenceObserver = NotificationCenter.default.addObserver(
            forName: .persistenceDidChange,
            object: persistence,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let event = notification.userInfo?[PersistenceService.changeNotificationUserInfoKey]
                as? PersistenceService.ChangeEvent else { return }
            handlePersistenceChange(event)
        }
    }

    private func handlePersistenceChange(_ event: PersistenceService.ChangeEvent) {
        switch event {
        case .globalSettings:
            handleExternalGlobalSettingsChange()
        case .boardsIndex, .root:
            refreshBoards()
            if persistence.boardMeta(id: doc.id) == nil {
                let nextId = persistence.defaultBoardId()
                let loaded = persistence.loadOrCreateBoard(id: nextId)
                applyBoardChange(using: loaded)
            }
        case .board(let id):
            handleExternalBoardChange(id: id)
        case .assets:
            objectWillChange.send()
        }
    }

    private func handleExternalBoardChange(id: UUID) {
        if id != doc.id {
            refreshBoards()
            return
        }
        guard let loaded = persistence.loadBoardIfExists(id: id) else { return }
        guard loaded.updatedAt > doc.updatedAt else { return }
        var merged = loaded
        merged.viewport = doc.viewport
        merged.ui = doc.ui
        applyBoardChange(using: merged)
    }

    private func handleExternalGlobalSettingsChange() {
        let loadedGlobals = persistence.loadGlobalSettings()
        if globalsEqual(loadedGlobals, lastSavedGlobals) {
            globalSettings = loadedGlobals
            lastSyncedGlobalSettings = loadedGlobals
            return
        }

        let currentGlobals = globalsFromDoc()
        if globalsEqual(loadedGlobals, currentGlobals) {
            globalSettings = loadedGlobals
            lastSyncedGlobalSettings = loadedGlobals
            lastSavedGlobals = loadedGlobals
            return
        }

        isInitializing = true
        doc.chatSettings.userName = loadedGlobals.userName
        doc.chatSettings.notes = loadedGlobals.notes
        doc.chatSettings.voice = loadedGlobals.voice
        doc.chatSettings.alwaysListening = loadedGlobals.alwaysListening
        doc.memories = loadedGlobals.memories
        doc.log = loadedGlobals.log
        doc.chatHistory = loadedGlobals.chatHistory
        doc.reminders = loadedGlobals.reminders
        isInitializing = false

        globalSettings = loadedGlobals
        lastSyncedGlobalSettings = loadedGlobals
        lastSavedGlobals = loadedGlobals
        setupReminderScheduler()
    }

    private func globalsFromDoc() -> AppGlobalSettings {
        AppGlobalSettings(
            userName: doc.chatSettings.userName,
            notes: doc.chatSettings.notes,
            voice: doc.chatSettings.voice,
            alwaysListening: doc.chatSettings.alwaysListening,
            memories: doc.memories,
            log: doc.log,
            chatHistory: doc.chatHistory,
            reminders: doc.reminders
        )
    }

    private func globalsEqual(_ lhs: AppGlobalSettings, _ rhs: AppGlobalSettings) -> Bool {
        guard let lhsData = lhs.stableData(), let rhsData = rhs.stableData() else { return false }
        return lhsData == rhsData
    }
}

// MARK: - Persistence helpers
extension BoardStore {
    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let globalsNow = AppGlobalSettings(
                userName: doc.chatSettings.userName,
                notes: doc.chatSettings.notes,
                voice: doc.chatSettings.voice,
                alwaysListening: doc.chatSettings.alwaysListening,
                memories: doc.memories,
                log: doc.log,
                chatHistory: doc.chatHistory,
                reminders: doc.reminders
            )
            
            let remindersSigNow = globalsNow.reminders
                .map { "\($0.id.uuidString)|\($0.dueAt)|\($0.status.rawValue)|\($0.preparedMessage ?? "")" }
                .joined(separator: ";;")
            
            let chatsSigNow = globalsNow.chatHistory
                .map { "\($0.id.uuidString)|\($0.messages.count)|\($0.messages.last?.ts ?? 0)|\($0.title ?? "")" }
                .joined(separator: ";;")

            let chatsSigSaved = self.lastSavedGlobals.chatHistory
                .map { "\($0.id.uuidString)|\($0.messages.count)|\($0.messages.last?.ts ?? 0)|\($0.title ?? "")" }
                .joined(separator: ";;")

            let remindersSigSaved = self.lastSavedGlobals.reminders
                .map { "\($0.id.uuidString)|\($0.dueAt)|\($0.status.rawValue)|\($0.preparedMessage ?? "")" }
                .joined(separator: ";;")

            let globalsChanged =
                globalsNow.userName != self.lastSavedGlobals.userName ||
                globalsNow.notes != self.lastSavedGlobals.notes ||
                globalsNow.voice != self.lastSavedGlobals.voice ||
                globalsNow.alwaysListening != self.lastSavedGlobals.alwaysListening ||
                globalsNow.memories != self.lastSavedGlobals.memories ||
                globalsNow.log.count != self.lastSavedGlobals.log.count ||
                (globalsNow.log.last?.id != self.lastSavedGlobals.log.last?.id) ||
                (chatsSigNow != chatsSigSaved) ||
                (remindersSigNow != remindersSigSaved)

            if globalsChanged {
                self.persistence.saveGlobalSettings(globalsNow)
                self.lastSavedGlobals = globalsNow
            }
            let didMarkDirty = persistence.save(doc: doc)
            if didMarkDirty && isDeviceSyncEnabled {
                syncService.noteLocalChange(boardID: doc.id)
            }
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveInterval, execute: work)
    }

    func exportDocument() {
        persistence.export(doc: doc)
    }

    func importDocument() {
        guard let newDoc = persistence.importDoc() else { return }
        DispatchQueue.main.async {
            // Keep this window/tab bound to its current board id.
            var imported = newDoc
            imported.id = self.doc.id
            imported.updatedAt = Date().timeIntervalSince1970

            self.doc = imported
            self.selection.removeAll()
            self.resetUndoHistory()
        }
    }

    func copyImage(at url: URL) -> ImageRef? {
        persistence.copyImage(url: url)
    }

    func copyFile(at url: URL) -> FileRef? {
        persistence.copyFile(url: url)
    }

    func saveImage(data: Data, ext: String = "png") -> ImageRef? {
        persistence.saveImage(data: data, ext: ext)
    }

    func imageURL(for ref: ImageRef) -> URL? {
        if let url = persistence.imageURL(for: ref) {
            return url
        }
        if isDeviceSyncEnabled {
            syncService.requestAssetDownload(filename: ref.filename)
        }
        return nil
    }

    func fileURL(for ref: FileRef) -> URL? {
        if let url = persistence.fileURL(for: ref) {
            return url
        }
        if isDeviceSyncEnabled {
            syncService.requestAssetDownload(filename: ref.filename)
        }
        return nil
    }
    
    #if os(macOS)
    /// Exports an image entry to a user-chosen location via an NSSavePanel.
    /// This copies the original asset bytes (no re-encoding).
    func saveImageEntryToDisk(id: UUID) {
        guard let entry = doc.entries[id],
              case .image(let ref) = entry.data,
              let sourceURL = imageURL(for: ref) else { return }

        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
        let shortId = String(id.uuidString.prefix(6))

        let panel = NSSavePanel()
        panel.allowedFileTypes = [ext]
        panel.nameFieldStringValue = "AstraImage-\(shortId).\(ext)"
        panel.prompt = "Save"

        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                let scoped = destURL.startAccessingSecurityScopedResource()
                defer { if scoped { destURL.stopAccessingSecurityScopedResource() } }

                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destURL, options: [.atomic])
            } catch {
                NSLog("Failed to save image to disk: \(error)")
            }
        }
    }

    func openFile(_ ref: FileRef) {
        guard let url = fileURL(for: ref) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealFile(_ ref: FileRef) {
        guard let url = fileURL(for: ref) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func importFileFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.performUndoable {
                guard let self else { return }
                guard let ref = self.copyFile(at: url) else { return }

                // Default size and position in the center of the viewport
                let defaultSize = CGSize(width: 200, height: 120)
                let screenCenter = CGPoint(x: self.viewportSize.width / 2, y: self.viewportSize.height / 2)
                let worldCenter = self.worldPoint(from: screenCenter)
                let frame = CGRect(x: worldCenter.x - defaultSize.width / 2,
                                   y: worldCenter.y - defaultSize.height / 2,
                                   width: defaultSize.width,
                                   height: defaultSize.height)

                self.createEntry(type: .file, frame: frame, data: .file(ref))
            }
        }
    }
    #elseif os(iOS)
    func openFile(_ ref: FileRef) {
        guard let url = fileURL(for: ref) else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    func revealFile(_ ref: FileRef) {
        _ = ref
    }
    #endif
}

// MARK: - Undo / Redo
extension BoardStore {
    private func makeSnapshot() -> BoardSnapshot {
        BoardSnapshot(doc: doc,
                      selection: selection,
                      chatWarning: chatWarning,
                      chatDraftImages: chatDraftImages,
                      chatDraftFiles: chatDraftFiles,
                      pendingChatReplies: pendingChatReplies,
                      chatNeedsAttention: chatNeedsAttention,
                      activeArchivedChatId: activeArchivedChatId)
    }

    private func updateUndoAvailability() {
        let nextUndo = !undoStack.isEmpty
        let nextRedo = !redoStack.isEmpty
        if canUndo != nextUndo {
            canUndo = nextUndo
        }
        if canRedo != nextRedo {
            canRedo = nextRedo
        }
    }

    private func recordUndoSnapshot(coalescingKey: String? = nil) {
        guard !isRestoringSnapshot else { return }
        guard undoDepth == 0 else { return }
        let now = Date().timeIntervalSince1970
        if let key = coalescingKey,
           key == lastCoalescingKey,
           now - lastCoalescingTime < undoCoalesceInterval {
            lastCoalescingTime = now
            if !redoStack.isEmpty {
                redoStack.removeAll()
                updateUndoAvailability()
            }
            return
        }
        undoStack.append(makeSnapshot())
        if undoStack.count > maxUndoSteps {
            undoStack.removeFirst(undoStack.count - maxUndoSteps)
        }
        redoStack.removeAll()
        lastCoalescingKey = coalescingKey
        lastCoalescingTime = now
        updateUndoAvailability()
    }

    private func performUndoable(coalescingKey: String? = nil, _ action: () -> Void) {
        if undoDepth == 0 {
            recordUndoSnapshot(coalescingKey: coalescingKey)
        }
        undoDepth += 1
        action()
        undoDepth -= 1
    }

    private func restore(snapshot: BoardSnapshot) {
        isRestoringSnapshot = true
        doc = snapshot.doc
        selection = snapshot.selection
        editingEntryID = nil
        chatWarning = snapshot.chatWarning
        chatDraftImages = snapshot.chatDraftImages
        chatDraftFiles = snapshot.chatDraftFiles
        pendingChatReplies = snapshot.pendingChatReplies
        chatNeedsAttention = snapshot.chatNeedsAttention
        activeArchivedChatId = snapshot.activeArchivedChatId
        isRestoringSnapshot = false
    }

    func resetUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastCoalescingKey = nil
        lastCoalescingTime = 0
        updateUndoAvailability()
    }

    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoStack.popLast() else { return false }
        let redoSnapshot = makeSnapshot()
        redoStack.append(redoSnapshot)
        restore(snapshot: snapshot)
        lastCoalescingKey = nil
        lastCoalescingTime = 0
        updateUndoAvailability()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let snapshot = redoStack.popLast() else { return false }
        let undoSnapshot = makeSnapshot()
        undoStack.append(undoSnapshot)
        restore(snapshot: snapshot)
        lastCoalescingKey = nil
        lastCoalescingTime = 0
        updateUndoAvailability()
        return true
    }
}

// MARK: - Doc + logging helpers
extension BoardStore {
    private func touch() {
        doc.updatedAt = Date().timeIntervalSince1970
    }

    func addLog(_ summary: String, actor: Actor = .user, related: [UUID]? = nil, relatedChatId: UUID? = nil) {
        let item = LogItem(id: UUID(),
                           ts: Date().timeIntervalSince1970,
                           actor: actor,
                           summary: summary,
                           relatedEntryIds: related,
                           relatedChatId: relatedChatId)
        doc.log.append(item)
        doc.log.sort { $0.ts < $1.ts }
    }
}

// MARK: - Memories
extension BoardStore {
    @MainActor
    func deleteMemory(id: UUID) {
        performUndoable {
            doc.memories.removeAll { $0.id == id }
            persistGlobalsNow()
            touch()
        }
    }
}

// MARK: - Viewport
extension BoardStore {
    var pan: CGPoint {
        get { CGPoint(x: doc.viewport.offsetX.cg, y: doc.viewport.offsetY.cg) }
        set {
            doc.viewport.offsetX = newValue.x.double
            doc.viewport.offsetY = newValue.y.double
        }
    }

    var zoom: CGFloat {
        get { doc.viewport.zoom.cg }
        set { doc.viewport.zoom = newValue.double }
    }

    func applyPan(translation: CGSize) {
        guard translation != .zero else { return }
        recordUndoSnapshot(coalescingKey: "pan")
        // Direct 1:1 pan (screen pixels to viewport offset)
        doc.viewport.offsetX += translation.width.double
        doc.viewport.offsetY += translation.height.double
    }

    func applyZoom(delta: CGFloat, focus: CGPoint?) {
        let oldZoom = doc.viewport.zoom
        
        // Revised limits: 0.02 (very far out) to 25.0 (microscope)
        let newZoom = max(0.02, min(25.0, oldZoom * delta.double))
        
        guard newZoom != oldZoom else { return }
        recordUndoSnapshot(coalescingKey: "zoom")

        // If a focus point (mouse location) is provided, anchor the zoom to it.
        // This ensures the point under the cursor stays under the cursor.
        let focusPoint = focus ?? lastPointerLocationInViewport ?? currentMouseLocationInViewport()
        if let focusPoint {
            let worldBefore = worldPoint(from: focusPoint, zoom: oldZoom)
            let screenAfter = screenPoint(fromWorld: worldBefore, zoom: newZoom)
            
            // Calculate how much the screen shifted due to zoom, and compensate the offset
            let offsetDelta = CGSize(width: (focusPoint.x - screenAfter.x), height: (focusPoint.y - screenAfter.y))
            doc.viewport.offsetX += offsetDelta.width.double
            doc.viewport.offsetY += offsetDelta.height.double
        } else {
            // Fallback to center zoom if no mouse point
            let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldBefore = worldPoint(from: center, zoom: oldZoom)
            let screenAfter = screenPoint(fromWorld: worldBefore, zoom: newZoom)
            let offsetDelta = CGSize(width: (center.x - screenAfter.x), height: (center.y - screenAfter.y))
            doc.viewport.offsetX += offsetDelta.width.double
            doc.viewport.offsetY += offsetDelta.height.double
        }
        
        doc.viewport.zoom = newZoom
    }

    #if os(macOS)
    private func currentMouseLocationInViewport() -> CGPoint? {
        guard viewportSize != .zero else { return nil }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPoint = contentView.convert(windowPoint, from: nil)
        guard localPoint.x >= 0,
              localPoint.y >= 0,
              localPoint.x <= viewportSize.width,
              localPoint.y <= viewportSize.height else {
            return nil
        }
        return localPoint
    }
    
    #else
    private func currentMouseLocationInViewport() -> CGPoint? { nil }
    #endif
    
    func worldPoint(from screen: CGPoint, zoom: Double? = nil) -> CGPoint {
        let z = zoom ?? doc.viewport.zoom
        let x = (screen.x - doc.viewport.offsetX.cg) / z.cg
        let y = (screen.y - doc.viewport.offsetY.cg) / z.cg
        return CGPoint(x: x, y: y)
    }

    func screenPoint(fromWorld point: Point, zoom: Double? = nil) -> CGPoint {
        let cgPoint = CGPoint(x: point.x.cg, y: point.y.cg)
        return screenPoint(fromWorld: cgPoint, zoom: zoom)
    }

    func screenPoint(fromWorld point: CGPoint, zoom: Double? = nil) -> CGPoint {
        let z = zoom ?? doc.viewport.zoom
        let x = point.x * z.cg + doc.viewport.offsetX.cg
        let y = point.y * z.cg + doc.viewport.offsetY.cg
        return CGPoint(x: x, y: y)
    }

    func screenRect(for entry: BoardEntry) -> CGRect {
        let zoom = doc.viewport.zoom.cg
        let origin = CGPoint(x: entry.x.cg * zoom + doc.viewport.offsetX.cg,
                             y: entry.y.cg * zoom + doc.viewport.offsetY.cg)
        let size = CGSize(width: entry.w.cg * zoom, height: entry.h.cg * zoom)
        return CGRect(origin: origin, size: size)
    }

    func jumpToEntry(id: UUID) {
        guard let entry = doc.entries[id] else { return }
        recordUndoSnapshot(coalescingKey: "jump")
        let center = CGPoint(x: (entry.x + entry.w / 2).cg, y: (entry.y + entry.h / 2).cg)
        let zoomTarget: Double = min(max(doc.viewport.zoom, 0.6), 1.5)
        doc.viewport.zoom = zoomTarget
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let offset = CGSize(width: screenCenter.x - center.x * zoomTarget.cg,
                            height: screenCenter.y - center.y * zoomTarget.cg)
        doc.viewport.offsetX = offset.width.double
        doc.viewport.offsetY = offset.height.double
        pulseHighlight(id: id)
    }

    private func pulseHighlight(id: UUID) {
        highlightEntryId = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.highlightEntryId == id else { return }
            self?.highlightEntryId = nil
        }
    }
}

// MARK: - Entry operations
extension BoardStore {
    func setSelection(_ ids: Set<UUID>) {
        selection = ids
    }

    func select(_ id: UUID?) {
        if let id {
            selection = [id]
        } else {
            selection.removeAll()
        }
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func beginEditingSelected() {
        editingEntryID = selection.first
    }

    func beginEditing(_ id: UUID) {
        editingEntryID = id
    }

    func endEditing() {
        editingEntryID = nil
    }

    @discardableResult
    func createEntry(type: EntryType, frame: CGRect, data: EntryData, createdBy: Actor = .user) -> UUID {
        recordUndoSnapshot()
        let now = Date().timeIntervalSince1970
        let shapeStyle: ShapeStyle?
        let textStyle: TextStyle?
        switch data {
        case .shape(let kind):
            shapeStyle = ShapeStyle.default(for: kind)
            textStyle = nil
        case .text:
            shapeStyle = nil
            textStyle = TextStyle.default()
        default:
            shapeStyle = nil
            textStyle = nil
        }
        let entry = BoardEntry(id: UUID(),
                                       groupID: nil,
                                       type: type,
                                       x: frame.origin.x.double,
                                       y: frame.origin.y.double,
                                       w: frame.size.width.double,
                                       h: frame.size.height.double,
                                       locked: false,
                                       createdBy: createdBy,
                                       createdAt: now,
                                       updatedAt: now,
                                       data: data,
                                       shapeStyle: shapeStyle,
                                       textStyle: textStyle)
        doc.entries[entry.id] = entry
        doc.zOrder.append(entry.id)
        touch()
        addLog("Created \(String(describing: type)) entry", related: [entry.id])
        return entry.id
    }

    func updateShapeKind(id: UUID, kind: ShapeKind, recordUndo: Bool = true) {
        guard var entry = doc.entries[id] else { return }
        guard case .shape = entry.data else { return }

        if recordUndo {
            recordUndoSnapshot(coalescingKey: "resize-\(id.uuidString)")
        }

        entry.data = .shape(kind)
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        touch()
    }

    func updateEntryFrame(id: UUID, rect: CGRect, recordUndo: Bool = true) {
        guard var entry = doc.entries[id] else { return }
        if recordUndo {
            recordUndoSnapshot(coalescingKey: "resize-\(id.uuidString)")
        }
        let clamped: CGRect
        if case .text(let text) = entry.data {
            let minWidth = TextEntryMetrics.minWidth
            let width = max(rect.size.width, minWidth)
            let font = TextEntryMetrics.font(for: textStyle(for: entry))
            let minHeight = TextEntryMetrics.height(for: text, maxWidth: width, font: font)
            let height = max(rect.size.height, minHeight)
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: width,
                             height: height)
        } else if case .line = entry.data {
            let minSize = linePadding * 2
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: max(rect.size.width, minSize),
                             height: max(rect.size.height, minSize))
        } else if case .file = entry.data {
            let minSize = CGSize(width: 160, height: 90)
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: max(rect.size.width, minSize.width),
                             height: max(rect.size.height, minSize.height))
        } else {
            let minSize = CGSize(width: 80, height: 60)
            clamped = CGRect(x: rect.origin.x,
                             y: rect.origin.y,
                             width: max(rect.size.width, minSize.width),
                             height: max(rect.size.height, minSize.height))
        }
        entry.x = clamped.origin.x.double
        entry.y = clamped.origin.y.double
        entry.w = clamped.size.width.double
        entry.h = clamped.size.height.double
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        touch()
    }
    
    private func expandedIDsIncludingGroups(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var out = ids

        var groupIDs: Set<UUID> = []
        for id in ids {
            if let gid = doc.entries[id]?.groupID {
                groupIDs.insert(gid)
            }
        }
        guard !groupIDs.isEmpty else { return out }

        for (eid, entry) in doc.entries {
            if let gid = entry.groupID, groupIDs.contains(gid) {
                out.insert(eid)
            }
        }
        return out
    }

    func moveSelected(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        recordUndoSnapshot(coalescingKey: "moveSelection")

        let idsToMove = expandedIDsIncludingGroups(selection)
        for id in idsToMove {
            if var entry = doc.entries[id] {
                translateEntry(&entry, delta: delta)
                doc.entries[id] = entry
            }
        }
        touch()
    }

    func setEntryOrigin(id: UUID, origin: CGPoint) {
        guard let baseEntry = doc.entries[id] else { return }
        recordUndoSnapshot(coalescingKey: "moveSelection")

        let delta = CGSize(width: origin.x - baseEntry.x.cg, height: origin.y - baseEntry.y.cg)

        let idsToMove: Set<UUID>
        if baseEntry.groupID != nil {
            idsToMove = expandedIDsIncludingGroups([id])
        } else {
            idsToMove = [id]
        }

        for moveID in idsToMove {
            guard var entry = doc.entries[moveID] else { continue }
            translateEntry(&entry, delta: delta)
            doc.entries[moveID] = entry
        }
        touch()
    }

    private func translateEntry(_ entry: inout BoardEntry, delta: CGSize) {
        if case .line(let data) = entry.data {
            let shiftedPoints = data.points.map {
                Point(x: $0.x + delta.width.double, y: $0.y + delta.height.double)
            }
            let rect = lineEntryRect(for: shiftedPoints.map { CGPoint(x: $0.x.cg, y: $0.y.cg) })
            entry.x = rect.origin.x.double
            entry.y = rect.origin.y.double
            entry.w = rect.size.width.double
            entry.h = rect.size.height.double
            entry.data = .line(LineData(points: shiftedPoints, arrow: data.arrow))
        } else {
            entry.x += delta.width.double
            entry.y += delta.height.double
        }
        entry.updatedAt = Date().timeIntervalSince1970
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        recordUndoSnapshot()
        let ids = selection
        for id in ids {
            doc.entries.removeValue(forKey: id)
            doc.zOrder.removeAll { $0 == id }
        }
        addLog("Deleted \(ids.count) entr\(ids.count == 1 ? "y" : "ies")")
        selection.removeAll()
        touch()
    }
    
    func deleteEntry(id: UUID) {
        guard doc.entries[id] != nil || doc.zOrder.contains(id) else { return }
        recordUndoSnapshot()
        doc.entries.removeValue(forKey: id)
        doc.zOrder.removeAll { $0 == id }
        touch()
    }

    func duplicateSelected() {
        let ids = selection
        guard !ids.isEmpty else { return }
        performUndoable {
            var newIds: [UUID] = []
            for id in ids {
                guard let entry = doc.entries[id] else { continue }
                var frame = CGRect(x: entry.x.cg + 20, y: entry.y.cg + 20, width: entry.w.cg, height: entry.h.cg)
                frame = frame.integral
                let newId = createEntry(type: entry.type, frame: frame, data: entry.data, createdBy: entry.createdBy)
                if var newEntry = doc.entries[newId] {
                    newEntry.data = entry.data
                    newEntry.shapeStyle = entry.shapeStyle
                    newEntry.textStyle = entry.textStyle
                    doc.entries[newId] = newEntry
                }
                newIds.append(newId)
            }
            selection = Set(newIds)
            addLog("Duplicated \(ids.count) entr\(ids.count == 1 ? "y" : "ies")", related: Array(ids))
        }
    }
    
    func groupSelectedItems() {
        let ids = selection
        guard ids.count >= 2 else { return }

        recordUndoSnapshot()
        let groupID = UUID()
        let now = Date().timeIntervalSince1970

        for id in ids {
            guard var entry = doc.entries[id] else { continue }
            entry.groupID = groupID
            entry.updatedAt = now
            doc.entries[id] = entry
        }

        addLog("Grouped \(ids.count) item\(ids.count == 1 ? "" : "s")", related: Array(ids))
        touch()
    }
    
    func ungroupGroup(_ groupID: UUID) {
        recordUndoSnapshot()
        let now = Date().timeIntervalSince1970

        let ids = Array(doc.entries.keys)
        var affected: [UUID] = []

        for id in ids {
            guard var entry = doc.entries[id] else { continue }
            guard entry.groupID == groupID else { continue }
            entry.groupID = nil
            entry.updatedAt = now
            doc.entries[id] = entry
            affected.append(id)
        }

        if !affected.isEmpty {
            addLog("Ungrouped \(affected.count) item\(affected.count == 1 ? "" : "s")", related: affected)
        }
        touch()
    }

    func ungroupSelectedGroups() {
        let groupIDs = Set(selection.compactMap { doc.entries[$0]?.groupID })
        guard !groupIDs.isEmpty else { return }

        recordUndoSnapshot()
        let now = Date().timeIntervalSince1970

        let ids = Array(doc.entries.keys)
        var affected: [UUID] = []

        for id in ids {
            guard var entry = doc.entries[id] else { continue }
            guard let gid = entry.groupID, groupIDs.contains(gid) else { continue }
            entry.groupID = nil
            entry.updatedAt = now
            doc.entries[id] = entry
            affected.append(id)
        }

        if !affected.isEmpty {
            addLog("Ungrouped \(affected.count) item\(affected.count == 1 ? "" : "s")", related: affected)
        }
        touch()
    }

    func clearBoard() {
        guard !doc.entries.isEmpty else { return }
        recordUndoSnapshot()
        doc.entries.removeAll()
        doc.zOrder.removeAll()
        selection.removeAll()
        lineBuilder.removeAll()
        marqueeRect = nil
        highlightEntryId = nil
        addLog("Cleared board")
        touch()
    }

    func bringToFront(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        recordUndoSnapshot()
        doc.zOrder.removeAll { ids.contains($0) }
        doc.zOrder.append(contentsOf: ids)
        touch()
    }

    func sendToBack(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        recordUndoSnapshot()
        doc.zOrder.removeAll { ids.contains($0) }
        doc.zOrder.insert(contentsOf: ids, at: 0)
        touch()
    }

    func updateText(id: UUID, text: String) {
        guard var entry = doc.entries[id] else { return }
        if case .text(let current) = entry.data, current == text { return }
        recordUndoSnapshot(coalescingKey: "text-\(id.uuidString)")
        entry.data = .text(text)
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        addLog("Edited text entry", related: [id])
        touch()
    }
}

#if os(macOS)
// MARK: - Clipboard
extension BoardStore {
    static let boardEntriesPasteboardType = NSPasteboard.PasteboardType("com.astra.boardEntries.v1")

    private struct ClipboardRect: Codable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double

        init(x: Double, y: Double, w: Double, h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }

        init(_ rect: CGRect) {
            self.x = rect.origin.x.double
            self.y = rect.origin.y.double
            self.w = rect.size.width.double
            self.h = rect.size.height.double
        }

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private struct ClipboardEntry: Codable {
        var type: EntryType
        var rect: ClipboardRect
        var data: EntryData
        var shapeStyle: ShapeStyle?
        var textStyle: TextStyle?

        init(from entry: BoardEntry) {
            self.type = entry.type
            self.rect = ClipboardRect(CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg))
            self.data = entry.data
            self.shapeStyle = entry.shapeStyle
            self.textStyle = entry.textStyle
        }
    }

    private struct ClipboardPayload: Codable {
        var entries: [ClipboardEntry]
    }
    @discardableResult
    func copyImageToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id] else { return false }
        return copyImagesToPasteboard(entries: [entry])
    }
    
    @discardableResult
    func copyTextEntryToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id],
              case .text(let text) = entry.data else {
            return false
        }
        return copyBoardEntriesToPasteboard(entries: [entry], plainTextFallback: text)
    }

    @discardableResult
    func copyFileEntryToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id],
              case .file(let ref) = entry.data,
              let url = fileURL(for: ref) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }

    @discardableResult
    func copyEntryToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id] else { return false }
        switch entry.data {
        case .image:
            return copyImageToPasteboard(id: id)
        case .text:
            return copyTextEntryToPasteboard(id: id)
        case .file:
            return copyFileEntryToPasteboard(id: id)
        default:
            return copyBoardEntriesToPasteboard(entries: [entry], plainTextFallback: nil)
        }
    }

    private func copyBoardEntriesToPasteboard(entries: [BoardEntry], plainTextFallback: String?) -> Bool {
        guard !entries.isEmpty else { return false }
        let payload = ClipboardPayload(entries: entries.map { ClipboardEntry(from: $0) })
        guard let data = try? JSONEncoder().encode(payload) else { return false }

        let item = NSPasteboardItem()
        item.setData(data, forType: Self.boardEntriesPasteboardType)

        if let fallback = plainTextFallback, !fallback.isEmpty {
            item.setString(fallback, forType: .string)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private func pasteBoardEntries(from pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: Self.boardEntriesPasteboardType),
              let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data),
              !payload.entries.isEmpty else {
            return false
        }

        let rects = payload.entries.map { $0.rect.cgRect }
        guard let first = rects.first else { return false }
        let bounds = rects.dropFirst().reduce(first) { $0.union($1) }

        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)

        let dx = worldCenter.x - bounds.midX
        let dy = worldCenter.y - bounds.midY
        let nudge: CGFloat = 18

        performUndoable {
            var newIds: [UUID] = []
            for clip in payload.entries {
                let newRect = clip.rect.cgRect.offsetBy(dx: dx + nudge, dy: dy + nudge)
                let newId = createEntry(type: clip.type, frame: newRect, data: clip.data, createdBy: .user)

                if var created = doc.entries[newId] {
                    created.shapeStyle = clip.shapeStyle
                    created.textStyle = clip.textStyle
                    doc.entries[newId] = created
                }
                newIds.append(newId)
            }

            selection = Set(newIds)
            touch()
        }
        return true
    }

    @discardableResult
    func copySelectedImagesToPasteboard() -> Bool {
        let orderedIds = doc.zOrder.filter { selection.contains($0) }
        let entries = orderedIds.compactMap { doc.entries[$0] }
        return copyImagesToPasteboard(entries: entries)
    }

    @discardableResult
    func pasteFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if pasteBoardEntries(from: pasteboard) {
            return true
        }
        if pasteFiles(from: pasteboard) {
            return true
        }
        if pasteImages(from: pasteboard) {
            return true
        }
        if let text = pasteText(from: pasteboard) {
            return pasteText(text)
        }
        return false
    }

    @discardableResult
    func attachChatAttachmentsFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general

        // 1) File URLs (prefer these so we don't attach file icon images)
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            var imageRefs: [ImageRef] = []
            var fileRefs: [FileRef] = []
            for url in urls {
                if isLikelyImageURL(url) {
                    if let ref = copyImage(at: url) {
                        imageRefs.append(ref)
                        continue
                    }
                    if let image = NSImage(contentsOf: url),
                       let ref = savePasteboardImage(image) {
                        imageRefs.append(ref)
                    }
                } else if !url.hasDirectoryPath, let ref = copyFile(at: url) {
                    fileRefs.append(ref)
                }
            }
            if !imageRefs.isEmpty {
                appendChatDraftImages(imageRefs)
            }
            if !fileRefs.isEmpty {
                appendChatDraftFiles(fileRefs)
            }
            return !imageRefs.isEmpty || !fileRefs.isEmpty
        }

        // 2) Normal cases (raw image data, NSImage, etc.)
        var didAttach = false
        let imageRefs = chatImageRefs(from: pasteboard)
        if !imageRefs.isEmpty {
            appendChatDraftImages(imageRefs)
            didAttach = true
        }
        let fileRefs = chatFileRefs(from: pasteboard)
        if !fileRefs.isEmpty {
            appendChatDraftFiles(fileRefs)
            didAttach = true
        }
        if didAttach {
            return true
        }

        // 3) Promised files (screenshots "copy & delete", some browsers, etc.)
        if let receiver = firstImageFilePromiseReceiver(from: pasteboard) {
            receivePromisedImage(receiver)
            return true // swallow paste; we'll attach when the promise delivers
        }

        // 4) Promised files (non-images)
        if let receiver = firstFilePromiseReceiver(from: pasteboard) {
            receivePromisedFile(receiver)
            return true
        }

        return false
    }

    @discardableResult
    func pasteNoteImagesFromPasteboard(onPromise: @escaping (ImageRef) -> Void) -> ([ImageRef], Bool) {
        let pasteboard = NSPasteboard.general

        // 1) File URLs (prefer these so we don't attach file icon images)
        let urls = fileURLs(from: pasteboard)
        let imageURLs = urls.filter { isLikelyImageURL($0) }
        if !imageURLs.isEmpty {
            var imageRefs: [ImageRef] = []
            for url in imageURLs {
                if let ref = copyImage(at: url) {
                    imageRefs.append(ref)
                    continue
                }
                if let image = NSImage(contentsOf: url),
                   let ref = savePasteboardImage(image) {
                    imageRefs.append(ref)
                }
            }
            if !imageRefs.isEmpty {
                return (imageRefs, true)
            }
        }

        // 2) HTML inline image data
        if let ref = imageRefFromHTMLPasteboard(pasteboard) {
            return ([ref], true)
        }

        // 3) Remote image URL from HTML
        if let url = remoteURLFromHTMLPasteboard(pasteboard) {
            downloadImage(from: url, onImage: onPromise)
            return ([], true)
        }

        // 4) Normal cases (raw image data, NSImage, etc.)
        let imageRefs = chatImageRefs(from: pasteboard)
        if !imageRefs.isEmpty {
            return (imageRefs, true)
        }

        // 5) Promised files (screenshots "copy & delete", some browsers, etc.)
        if let receiver = firstImageFilePromiseReceiver(from: pasteboard) {
            receivePromisedImage(receiver, onImage: onPromise)
            return ([], true)
        }

        return ([], false)
    }
    
    private func firstImageFilePromiseReceiver(from pasteboard: NSPasteboard) -> NSFilePromiseReceiver? {
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]

        guard let receiver = receivers?.first else { return nil }

        // Only accept promises that look like images
        for type in receiver.fileTypes {
            let ut = UTType(type) ?? UTType(filenameExtension: type)
            if ut?.conforms(to: .image) == true {
                return receiver
            }
        }

        return nil
    }

    private func firstFilePromiseReceiver(from pasteboard: NSPasteboard) -> NSFilePromiseReceiver? {
        let receivers = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver]
        guard let receivers, !receivers.isEmpty else { return nil }

        for receiver in receivers {
            if receiver.fileTypes.isEmpty {
                return receiver
            }
            for type in receiver.fileTypes {
                let ut = UTType(type) ?? UTType(filenameExtension: type)
                if ut?.conforms(to: .image) != true {
                    return receiver
                }
            }
        }
        return nil
    }
    
    private func imageRefFromHTMLPasteboard(_ pasteboard: NSPasteboard) -> ImageRef? {
        guard let html = htmlString(from: pasteboard) else { return nil }

        // data:image/png;base64,...
        let pattern = "src=\\\"data:image/([^;\\\"]+);base64,([^\\\"]+)\\\""
        if let (mimeSub, b64) = firstRegexGroups(pattern: pattern, in: html),
           let data = Data(base64Encoded: b64) {
            let ext = mimeSub.lowercased() == "jpeg" ? "jpg" : mimeSub.lowercased()
            return persistence.saveImage(data: data, ext: ext)
        }
        return nil
    }

    private func remoteURLFromHTMLPasteboard(_ pasteboard: NSPasteboard) -> URL? {
        guard let html = htmlString(from: pasteboard) else { return nil }
        let pattern = "src=\\\"(https?://[^\\\"]+)\\\""
        if let (urlStr, _) = firstRegexGroups(pattern: pattern, in: html),
           let url = URL(string: urlStr) {
            return url
        }
        return nil
    }

    private func htmlString(from pasteboard: NSPasteboard) -> String? {
        let types: [NSPasteboard.PasteboardType] = [.html, NSPasteboard.PasteboardType("public.html")]
        for t in types {
            if let data = pasteboard.data(forType: t),
               let s = String(data: data, encoding: .utf8),
               !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Returns up to 2 capture groups from the first match.
    private func firstRegexGroups(pattern: String, in text: String) -> (String, String)? {
        do {
            let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
            guard m.numberOfRanges >= 3 else { return nil }
            let g1 = ns.substring(with: m.range(at: 1))
            let g2 = ns.substring(with: m.range(at: 2))
            return (g1, g2)
        } catch {
            return nil
        }
    }

    private func downloadAndAttachRemoteImage(from url: URL) {
        downloadImage(from: url) { [weak self] ref in
            self?.appendChatDraftImages([ref])
        }
    }

    private func downloadImage(from url: URL, onImage: @escaping (ImageRef) -> Void) {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { return }
            let mime = response?.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("image/") else { return }

            let ext = fileExtension(fromMimeType: mime, fallbackURL: url)
            DispatchQueue.main.async {
                if let ref = self.persistence.saveImage(data: data, ext: ext) {
                    onImage(ref)
                }
            }
        }.resume()
    }

    private func fileExtension(fromMimeType mime: String, fallbackURL: URL) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        default:
            let ext = fallbackURL.pathExtension
            return ext.isEmpty ? "png" : ext
        }
    }

    private func receivePromisedImage(_ receiver: NSFilePromiseReceiver) {
        receivePromisedImage(receiver) { [weak self] ref in
            self?.appendChatDraftImages([ref])
        }
    }

    private func receivePromisedImage(_ receiver: NSFilePromiseReceiver, onImage: @escaping (ImageRef) -> Void) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AstraPaste-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: .main) { [weak self] fileURL, error in
            guard let self else { return }
            guard error == nil else {
                return
            }

            if let ref = self.copyImage(at: fileURL) {
                onImage(ref)
            } else if let image = NSImage(contentsOf: fileURL),
                      let ref = self.savePasteboardImage(image) {
                onImage(ref)
            }

            // Cleanup
            try? fm.removeItem(at: tempDir)
        }
    }

    private func receivePromisedFile(_ receiver: NSFilePromiseReceiver) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AstraPaste-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: .main) { [weak self] fileURL, error in
            guard let self else { return }
            guard error == nil else {
                return
            }

            if let ref = self.copyFile(at: fileURL) {
                self.appendChatDraftFiles([ref])
            }

            // Cleanup
            try? fm.removeItem(at: tempDir)
        }
    }

    private func copyImagesToPasteboard(entries: [BoardEntry]) -> Bool {
        let images = entries.compactMap { entry -> NSImage? in
            guard case .image(let ref) = entry.data,
                  let url = imageURL(for: ref) else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
        guard !images.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects(images)
    }

    private func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = imageFileURLs(from: pasteboard)
        var refs: [ImageRef] = []
        for url in urls {
            if let ref = copyImage(at: url) {
                refs.append(ref)
                continue
            }
            if let image = NSImage(contentsOf: url),
               let ref = savePasteboardImage(image) {
                refs.append(ref)
            }
        }
        if refs.isEmpty,
           let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            for image in images {
                if let ref = savePasteboardImage(image) {
                    refs.append(ref)
                }
            }
        }
        guard !refs.isEmpty else { return false }
        performUndoable {
            let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldCenter = worldPoint(from: screenCenter)
            var ids: [UUID] = []
            let offsetStep: CGFloat = 20
            for (index, ref) in refs.enumerated() {
                let offset = CGFloat(index) * offsetStep
                let center = CGPoint(x: worldCenter.x + offset, y: worldCenter.y + offset)
                let rect = imageRect(for: ref, centeredAt: center, maxSide: 320)
                let id = createEntry(type: .image, frame: rect, data: .image(ref))
                ids.append(id)
            }
            selection = Set(ids)
        }
        return true
    }
    
    private func pasteFiles(from pasteboard: NSPasteboard) -> Bool {
        // Prefer file URLs so PDFs don’t turn into “icon images”
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }

        // Keep only non-image files
        let fileURLs = urls.filter { url in
            !url.hasDirectoryPath && !isLikelyImageURL(url)
        }
        guard !fileURLs.isEmpty else { return false }

        var refs: [FileRef] = []
        for url in fileURLs {
            if let ref = copyFile(at: url) {
                refs.append(ref)
            }
        }
        guard !refs.isEmpty else { return false }

        performUndoable {
            let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldCenter = worldPoint(from: screenCenter)

            var ids: [UUID] = []
            let offsetStep: CGFloat = 22

            for (index, ref) in refs.enumerated() {
                let offset = CGFloat(index) * offsetStep
                let center = CGPoint(x: worldCenter.x + offset, y: worldCenter.y + offset)
                let rect = fileRect(for: ref, centeredAt: center)
                let id = createEntry(type: .file, frame: rect, data: .file(ref))
                ids.append(id)
            }

            selection = Set(ids)
        }

        return true
    }

    private func chatImageRefs(from pasteboard: NSPasteboard) -> [ImageRef] {
        // Try file URLs first
        let urls = imageFileURLs(from: pasteboard)
        if !urls.isEmpty {
            var refs: [ImageRef] = []
            for url in urls {
                if let ref = copyImage(at: url) {
                    refs.append(ref)
                    continue
                }
                if let image = NSImage(contentsOf: url),
                   let ref = savePasteboardImage(image) {
                    refs.append(ref)
                }
            }
            if !refs.isEmpty {
                return refs
            }
        }

        // Try NSImage objects
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            var refs: [ImageRef] = []
            for image in images {
                if let ref = savePasteboardImage(image) {
                    refs.append(ref)
                }
            }
            if !refs.isEmpty {
                return refs
            }
        }

        // Try common image data types
        let dataTypes: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.png"),
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.jpg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("public.gif"),
            NSPasteboard.PasteboardType("public.bmp"),
            NSPasteboard.PasteboardType("com.apple.icns")
        ]
        for type in dataTypes {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data),
               let ref = savePasteboardImage(image) {
                return [ref]
            }
        }

        // Try all pasteboard items and check if they conform to image types
        if let items = pasteboard.pasteboardItems {
            var refs: [ImageRef] = []
            for item in items {
                for type in item.types {
                    if let data = item.data(forType: type),
                       let image = NSImage(data: data),
                       let ref = savePasteboardImage(image) {
                        refs.append(ref)
                    }
                }
            }
            if !refs.isEmpty {
                return refs
            }
        }

        // Final fallback: try NSImage's pasteboard initializer
        if let image = NSImage(pasteboard: pasteboard),
           let ref = savePasteboardImage(image) {
            return [ref]
        }

        return []
    }

    private func chatFileRefs(from pasteboard: NSPasteboard) -> [FileRef] {
        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return [] }
        var refs: [FileRef] = []
        for url in urls {
            guard !isLikelyImageURL(url) else { continue }
            guard !url.hasDirectoryPath else { continue }
            if let ref = copyFile(at: url) {
                refs.append(ref)
            }
        }
        return refs
    }

    private func pasteText(from pasteboard: NSPasteboard) -> String? {
        if let text = pasteboard.string(forType: .string) {
            return text
        }
        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            return attributed.string
        }
        return nil
    }

    private func pasteText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        performUndoable {
            let style = TextStyle.default()
            let font = TextEntryMetrics.font(for: style)
            let minWidth: CGFloat = 240
            let maxWidth: CGFloat = 360
            let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldCenter = worldPoint(from: screenCenter)
            let layouts = textEntryLayouts(for: trimmed, font: font, minWidth: minWidth, maxWidth: maxWidth)
            let ids = createTextEntries(from: layouts, centeredAt: worldCenter, createdBy: .user)
            selection = Set(ids)
        }
        return true
    }

    private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(from: pasteboard)
        return urls.filter { isLikelyImageURL($0) }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                if let data = item.data(forType: .fileURL),
                   let url = fileURL(fromPasteboardData: data) {
                    urls.append(url)
                }
                if let data = item.data(forType: .URL),
                   let url = fileURL(fromPasteboardData: data),
                   url.isFileURL {
                    urls.append(url)
                }
                if let urlString = item.string(forType: .fileURL),
                   let url = fileURL(fromPasteboardString: urlString) {
                    urls.append(url)
                }
                if let urlString = item.string(forType: .URL),
                   let url = fileURL(fromPasteboardString: urlString),
                   url.isFileURL {
                    urls.append(url)
                }
            }
        }
        if let fileList = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls.append(contentsOf: fileList.map { URL(fileURLWithPath: $0) })
        }
        var seen = Set<URL>()
        let unique = urls.filter { seen.insert($0).inserted }
        return unique
    }

    private func fileURL(fromPasteboardString string: String) -> URL? {
        if string.hasPrefix("file://") {
            return URL(string: string)
        }
        if string.hasPrefix("/") || string.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: string).expandingTildeInPath)
        }
        return nil
    }

    private func fileURL(fromPasteboardData data: Data) -> URL? {
        if let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = String(data: data, encoding: .utf8) {
            return fileURL(fromPasteboardString: string)
        }
        return nil
    }

    private func isLikelyImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"]
        if imageExts.contains(ext) {
            return true
        }
        guard let typeId = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
              let type = UTType(typeId) else {
            return false
        }
        return type.conforms(to: .image)
    }

    private func savePasteboardImage(_ image: NSImage) -> ImageRef? {
        guard let data = pngData(from: image) else { return nil }
        return saveImage(data: data, ext: "png")
    }

    fileprivate func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    fileprivate func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        let clamped = max(0.0, min(1.0, quality))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: clamped])
    }
    
    @discardableResult
    func copyTextToPasteboard(id: UUID) -> Bool {
        guard let entry = doc.entries[id],
              case .text(let text) = entry.data else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
#endif

// MARK: - Chat Drafts
extension BoardStore {
    func removeChatDraftImage(_ ref: ImageRef) {
        guard let index = chatDraftImages.firstIndex(of: ref) else { return }
        recordUndoSnapshot()
        chatDraftImages.remove(at: index)
    }

    func removeChatDraftFile(_ ref: FileRef) {
        guard let index = chatDraftFiles.firstIndex(of: ref) else { return }
        recordUndoSnapshot()
        chatDraftFiles.remove(at: index)
    }

    func clearChatDraftImages() {
        guard !chatDraftImages.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftImages.removeAll()
    }

    func clearChatDraftFiles() {
        guard !chatDraftFiles.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftFiles.removeAll()
    }

    func appendChatDraftImages(_ refs: [ImageRef]) {
        guard !refs.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftImages.append(contentsOf: refs)
    }

    func appendChatDraftFiles(_ refs: [FileRef]) {
        guard !refs.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftFiles.append(contentsOf: refs)
    }
}

#if os(iOS)
extension BoardStore {
    fileprivate func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }

    fileprivate func jpegData(from image: UIImage, quality: CGFloat) -> Data? {
        let clamped = max(0.0, min(1.0, quality))
        return image.jpegData(compressionQuality: clamped)
    }
}
#endif

// MARK: - HUD / Panels
extension BoardStore {
    func toggleHUD() {
        recordUndoSnapshot()
        doc.ui.hud.isVisible.toggle()
        clampHUDPosition()
    }

    func moveHUD(by delta: CGSize) {
        guard delta != .zero else { return }
        recordUndoSnapshot(coalescingKey: "hudMove")
        doc.ui.hud.x += delta.width.double
        doc.ui.hud.y += delta.height.double
    }

    func clampHUDPosition() {
        let size = Self.hudSize
        let maxX = max(0, viewportSize.width - size.width)
        let maxY = max(0, viewportSize.height - size.height)
        let clampedX = min(max(doc.ui.hud.x, 0), maxX.double)
        let clampedY = min(max(doc.ui.hud.y, 0), maxY.double)
        if clampedX != doc.ui.hud.x {
            doc.ui.hud.x = clampedX
        }
        if clampedY != doc.ui.hud.y {
            doc.ui.hud.y = clampedY
        }
    }

    func togglePanel(_ kind: PanelKind) {
        recordUndoSnapshot()
        switch kind {
        case .chat:
            doc.ui.panels.chat.isOpen.toggle()
            if doc.ui.panels.chat.isOpen {
                chatNeedsAttention = false
                chatWarning = nil
            }
        case .chatArchive:
            doc.ui.panels.chatArchive.isOpen.toggle()
        case .log:
            doc.ui.panels.log.isOpen.toggle()

        case .memories:
            doc.ui.panels.memories.isOpen.toggle()
        case .shapeStyle:
            doc.ui.panels.shapeStyle.isOpen.toggle()
        case .settings:
            doc.ui.panels.settings.isOpen.toggle()
        case .notes:
            doc.ui.panels.notes.isOpen.toggle()
        case .reminder: // Handle new reminder case
            doc.ui.panels.reminder.isOpen.toggle()
        }
        clampPanelIfNeeded(kind)
    }

    func updatePanel(_ kind: PanelKind, frame: CGRect) {
        recordUndoSnapshot(coalescingKey: "panel-\(kind)")
        let clamped = clampedPanelFrame(frame, kind: kind)
        switch kind {
        case .chat:
            doc.ui.panels.chat.x = clamped.origin.x.double
            doc.ui.panels.chat.y = clamped.origin.y.double
            doc.ui.panels.chat.w = clamped.size.width.double
            doc.ui.panels.chat.h = clamped.size.height.double
        case .chatArchive:
            doc.ui.panels.chatArchive.x = clamped.origin.x.double
            doc.ui.panels.chatArchive.y = clamped.origin.y.double
            doc.ui.panels.chatArchive.w = clamped.size.width.double
            doc.ui.panels.chatArchive.h = clamped.size.height.double
        case .log:
            doc.ui.panels.log.x = clamped.origin.x.double
            doc.ui.panels.log.y = clamped.origin.y.double
            doc.ui.panels.log.w = clamped.size.width.double
            doc.ui.panels.log.h = clamped.size.height.double

        case .memories:
            doc.ui.panels.memories.x = clamped.origin.x.double
            doc.ui.panels.memories.y = clamped.origin.y.double
            doc.ui.panels.memories.w = clamped.size.width.double
            doc.ui.panels.memories.h = clamped.size.height.double
        case .shapeStyle:
            doc.ui.panels.shapeStyle.x = clamped.origin.x.double
            doc.ui.panels.shapeStyle.y = clamped.origin.y.double
            doc.ui.panels.shapeStyle.w = clamped.size.width.double
            doc.ui.panels.shapeStyle.h = clamped.size.height.double
        case .settings:
            doc.ui.panels.settings.x = clamped.origin.x.double
            doc.ui.panels.settings.y = clamped.origin.y.double
            doc.ui.panels.settings.w = clamped.size.width.double
            doc.ui.panels.settings.h = clamped.size.height.double
        case .notes:
            doc.ui.panels.notes.x = clamped.origin.x.double
            doc.ui.panels.notes.y = clamped.origin.y.double
            doc.ui.panels.notes.w = clamped.size.width.double
            doc.ui.panels.notes.h = clamped.size.height.double
        case .reminder: // Handle new reminder case
            doc.ui.panels.reminder.x = clamped.origin.x.double
            doc.ui.panels.reminder.y = clamped.origin.y.double
            doc.ui.panels.reminder.w = clamped.size.width.double
            doc.ui.panels.reminder.h = clamped.size.height.double
        }
    }

    private func clampPanelIfNeeded(_ kind: PanelKind) {
        let isOpen: Bool
        switch kind {
        case .chat:
            isOpen = doc.ui.panels.chat.isOpen
        case .chatArchive:
            isOpen = doc.ui.panels.chatArchive.isOpen
        case .log:
            isOpen = doc.ui.panels.log.isOpen
        case .memories:
            isOpen = doc.ui.panels.memories.isOpen
        case .shapeStyle:
            isOpen = doc.ui.panels.shapeStyle.isOpen
        case .settings:
            isOpen = doc.ui.panels.settings.isOpen
        case .notes:
            isOpen = doc.ui.panels.notes.isOpen
        case .reminder:
            isOpen = doc.ui.panels.reminder.isOpen
        }
        guard isOpen else { return }
        clampPanel(kind)
    }

    private func clampAllPanels() {
        guard viewportSize != .zero else { return }
        for kind in PanelKind.defaultZOrder {
            clampPanel(kind)
        }
    }

    private func clampPanel(_ kind: PanelKind) {
        let box: PanelBox
        switch kind {
        case .chat:
            box = doc.ui.panels.chat
        case .chatArchive:
            box = doc.ui.panels.chatArchive
        case .log:
            box = doc.ui.panels.log
        case .memories:
            box = doc.ui.panels.memories
        case .shapeStyle:
            box = doc.ui.panels.shapeStyle
        case .settings:
            box = doc.ui.panels.settings
        case .notes:
            box = doc.ui.panels.notes
        case .reminder:
            box = doc.ui.panels.reminder
        }

        let frame = CGRect(x: box.x.cg, y: box.y.cg, width: box.w.cg, height: box.h.cg)
        let clamped = clampedPanelFrame(frame, kind: kind)
        let updated = PanelBox(isOpen: box.isOpen,
                               x: clamped.origin.x.double,
                               y: clamped.origin.y.double,
                               w: clamped.size.width.double,
                               h: clamped.size.height.double)

        switch kind {
        case .chat:
            doc.ui.panels.chat = updated
        case .chatArchive:
            doc.ui.panels.chatArchive = updated
        case .log:
            doc.ui.panels.log = updated
        case .memories:
            doc.ui.panels.memories = updated
        case .shapeStyle:
            doc.ui.panels.shapeStyle = updated
        case .settings:
            doc.ui.panels.settings = updated
        case .notes:
            doc.ui.panels.notes = updated
        case .reminder:
            doc.ui.panels.reminder = updated
        }
    }

    private func clampedPanelFrame(_ frame: CGRect, kind: PanelKind) -> CGRect {
        guard viewportSize != .zero else { return frame }
        let minSize = Self.panelMinSize(for: kind)
        let padding = Self.panelPadding
        let maxWidth = max(viewportSize.width - padding * 2, minSize.width)
        let maxHeight = max(viewportSize.height - padding * 2, minSize.height)
        let width = min(max(frame.width, minSize.width), maxWidth)
        let height = min(max(frame.height, minSize.height), maxHeight)
        let x = min(max(frame.origin.x, padding), viewportSize.width - width - padding)
        let y = min(max(frame.origin.y, padding), viewportSize.height - height - padding)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Styles
extension BoardStore {
    var hasStyleSelection: Bool {
        selection.contains { id in
            guard let entry = doc.entries[id] else { return false }
            return entry.type == .shape || entry.type == .text
        }
    }

    func selectedShapeEntry() -> BoardEntry? {
        for id in selection {
            if let entry = doc.entries[id], entry.type == .shape {
                return entry
            }
        }
        return nil
    }

    func selectedTextEntry() -> BoardEntry? {
        for id in selection {
            if let entry = doc.entries[id], entry.type == .text {
                return entry
            }
        }
        return nil
    }

    func syncStylePanelVisibility() {
        if doc.ui.panels.shapeStyle.isOpen != hasStyleSelection {
            doc.ui.panels.shapeStyle.isOpen = hasStyleSelection
        }
    }

    func shapeStyle(for entry: BoardEntry) -> ShapeStyle {
        if let style = entry.shapeStyle {
            return style
        }
        if case .shape(let kind) = entry.data {
            return ShapeStyle.default(for: kind)
        }
        return ShapeStyle.default(for: .rect)
    }

    func updateSelectedShapeStyles(_ update: (inout ShapeStyle) -> Void) {
        let targetIds = selection.filter { id in
            guard let entry = doc.entries[id] else { return false }
            return entry.type == .shape
        }
        guard !targetIds.isEmpty else { return }
        recordUndoSnapshot(coalescingKey: "shapeStyle")
        let now = Date().timeIntervalSince1970
        var didChange = false
        for id in targetIds {
            guard var entry = doc.entries[id], entry.type == .shape else { continue }
            var style = shapeStyle(for: entry)
            update(&style)
            entry.shapeStyle = style
            entry.updatedAt = now
            doc.entries[id] = entry
            didChange = true
        }
        if didChange {
            touch()
        }
    }

    func textStyle(for entry: BoardEntry) -> TextStyle {
        if let style = entry.textStyle {
            return style
        }
        return TextStyle.default()
    }

    func updateSelectedTextStyles(_ update: (inout TextStyle) -> Void) {
        let targetIds = selection.filter { id in
            guard let entry = doc.entries[id] else { return false }
            return entry.type == .text
        }
        guard !targetIds.isEmpty else { return }
        recordUndoSnapshot(coalescingKey: "textStyle")
        let now = Date().timeIntervalSince1970
        var didChange = false
        for id in targetIds {
            guard var entry = doc.entries[id], entry.type == .text else { continue }
            var style = textStyle(for: entry)
            update(&style)
            entry.textStyle = style
            entry.updatedAt = now
            doc.entries[id] = entry
            didChange = true
        }
        if didChange {
            touch()
        }
    }
}

// MARK: - Chat Settings
extension BoardStore {
    @MainActor
    func updateChatSettings(_ update: (inout ChatSettings) -> Void) {
        performUndoable(coalescingKey: "chatSettings") {
            var next = doc.chatSettings
            update(&next)
            doc.chatSettings = next
            touch()
        }
    }
}

// MARK: - HUD Settings
extension BoardStore {
    #if os(macOS)
    @MainActor
    func updateHUDBarStyle(color: NSColor) {
        recordUndoSnapshot(coalescingKey: "hudBar")
        let rgb = color.usingColorSpace(.sRGB) ?? color
        doc.ui.hudBarColor = ColorComponents(red: Double(rgb.redComponent),
                                             green: Double(rgb.greenComponent),
                                             blue: Double(rgb.blueComponent))
        doc.ui.hudBarOpacity = max(0, min(1, Double(rgb.alphaComponent)))
    }
    #endif
}

// MARK: - Chat (disabled)
extension BoardStore {
    @MainActor
    func startNewChat(reason: String? = nil) {
        guard !doc.chat.messages.isEmpty || chatWarning != nil else { return }
        stopChatReplies()
        recordUndoSnapshot()
        doc.chat = ChatThread(id: UUID(), messages: [], title: nil)
        chatWarning = reason
        chatActivityStatus = nil
        chatThinkingText = nil
        chatThinkingExpanded = false
        chatDraftImages.removeAll()
        chatDraftFiles.removeAll()
        doc.pendingClarification = nil
        chatNeedsAttention = false
        pendingChatReplies = 0
        queuedUserMessageIDs.removeAll()
        touch()
    }

    @MainActor
    func stopChatReplies() {
        chatReplyTask?.cancel()
        chatReplyTask = nil
        pendingChatReplies = 0
        queuedUserMessageIDs.removeAll()
        chatActivityStatus = nil
        chatWarning = nil
    }

    func archivedChat(id: UUID) -> ChatThread? {
        doc.chatHistory.first { $0.id == id }
    }

    func openArchivedChat(id: UUID) {
        guard archivedChat(id: id) != nil else { return }
        recordUndoSnapshot()
        activeArchivedChatId = id
        doc.ui.panels.chatArchive.isOpen = true
    }

    @MainActor
    func resumeArchivedChat(id: UUID) {
        recordUndoSnapshot()
        activeArchivedChatId = nil
        if !doc.ui.panels.chat.isOpen { doc.ui.panels.chat.isOpen = true }
        touch()
    }

    @MainActor
    func deleteArchivedChat(id: UUID) {
        recordUndoSnapshot()
        doc.chatHistory.removeAll { $0.id == id }
        doc.log.removeAll { $0.relatedChatId == id }
        touch()
    }

    @MainActor
    func sendChat(text: String, images: [ImageRef] = [], files: [FileRef] = [], voiceInput: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty
        let hasImages = !images.isEmpty
        let hasFiles = !files.isEmpty
        guard hasText || hasImages || hasFiles else {
            if voiceInput { endVoiceConversation() }
            return false
        }

        chatWarning = nil
        chatThinkingText = nil
        chatThinkingExpanded = false
        
        let now = Date().timeIntervalSince1970
        
        // Create user message with attachments included
        let userMessage = ChatMsg(
            id: UUID(),
            role: .user,
            text: trimmed,
            images: images,  // Include images in message
            files: files,    // Include files in message
            ts: now
        )
        
        doc.chat.messages.append(userMessage)
        touch()
        queuedUserMessageIDs.append(userMessage.id)

        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }

        startChatReplyIfIdle()

        if voiceInput {
            endVoiceConversation()
        }
        
        return true
    }

    @MainActor
    private func startChatReplyIfIdle() {
        guard pendingChatReplies == 0 else { return }

        while !queuedUserMessageIDs.isEmpty {
            let nextMessageID = queuedUserMessageIDs.removeFirst()

            guard let messageIndex = doc.chat.messages.firstIndex(where: { $0.id == nextMessageID }) else {
                continue
            }

            guard doc.chat.messages[messageIndex].role == .user else {
                continue
            }

            pendingChatReplies = 1
            processChatReply(forUserMessageID: nextMessageID)
            return
        }
    }

    private func requestMessagesForCurrentChat() -> [OllamaChatService.Message] {
        guard doc.chat.messages.count > 1 else { return [] }
        return doc.chat.messages.dropLast().compactMap { message in
            // Convert images to base64
            var imageData: [[String: String]] = []
            for imageRef in message.images {
                if let url = imageURL(for: imageRef),
                   let data = try? Data(contentsOf: url) {
                    let base64 = data.base64EncodedString()
                    let ext = url.pathExtension.lowercased()
                    let mimeType: String
                    switch ext {
                    case "png": mimeType = "image/png"
                    case "jpg", "jpeg": mimeType = "image/jpeg"
                    case "gif": mimeType = "image/gif"
                    case "webp": mimeType = "image/webp"
                    case "heic": mimeType = "image/heic"
                    default: mimeType = "image/png"
                    }
                    imageData.append([
                        "type": "image",
                        "data": base64,
                        "mimeType": mimeType
                    ])
                }
            }
            
            // Convert files to base64
            var fileData: [[String: String]] = []
            for fileRef in message.files {
                if let url = fileURL(for: fileRef),
                   let data = try? Data(contentsOf: url) {
                    let base64 = data.base64EncodedString()
                    let ext = url.pathExtension.lowercased()
                    let mimeType: String
                    switch ext {
                    case "pdf": mimeType = "application/pdf"
                    case "txt": mimeType = "text/plain"
                    case "swift": mimeType = "text/x-swift"
                    case "py": mimeType = "text/x-python"
                    case "js": mimeType = "text/javascript"
                    case "json": mimeType = "application/json"
                    case "xml": mimeType = "application/xml"
                    case "html": mimeType = "text/html"
                    case "css": mimeType = "text/css"
                    case "csv": mimeType = "text/csv"
                    case "md": mimeType = "text/markdown"
                    case "doc", "docx": mimeType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    case "xls", "xlsx": mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                    default: mimeType = "application/octet-stream"
                    }
                    print("DEBUG BoardStore: Adding file \(fileRef.displayName) with MIME \(mimeType) and \(data.count) bytes")
                    fileData.append([
                        "type": "file",
                        "data": base64,
                        "mimeType": mimeType,
                        "filename": fileRef.displayName
                    ])
                }
            }
            
            return OllamaChatService.Message(
                role: message.role.rawValue,
                content: message.text,
                images: imageData.isEmpty ? nil : imageData,
                files: fileData.isEmpty ? nil : fileData
            )
        }
    }

    @MainActor
    private func updateChatMessageText(id: UUID, text: String) {
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == id }) else { return }
        guard doc.chat.messages[index].text != text else { return }
        doc.chat.messages[index].text = text
        touch()
    }

    private func startAssistantReply(assistantMessageID: UUID) {
        let requestMessages = requestMessagesForCurrentChat()
        chatReplyTask?.cancel()
        chatReplyTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var thinkingAccumulated = ""
            do {
                var conversation = requestMessages
                var toolRoundTrips = 0
                let maxToolRoundTrips = 5

                while true {
                    var capturedToolCall: ToolCall? = nil

                    try await self.chatService.stream(model: self.chatModelName, messages: conversation) { chunk in
                        // Normal assistant content streaming
                        let delta = chunk.message?.content ?? ""
                        if !delta.isEmpty {
                            accumulated += delta
                            await MainActor.run {
                                self.updateChatMessageText(id: assistantMessageID, text: accumulated)
                                if self.chatActivityStatus != nil {
                                    self.chatActivityStatus = nil
                                }
                            }
                        }

                        // Thinking streaming
                        if let thinking = chunk.message?.thinking ?? chunk.thinking {
                            thinkingAccumulated += thinking
                            await MainActor.run {
                                self.chatThinkingText = thinkingAccumulated
                            }
                        }

                        // Tool call capture
                        if let tc = chunk.toolCall {
                            capturedToolCall = tc
                            await MainActor.run {
                                self.chatActivityStatus = "Using tool: \(tc.name)…"
                            }
                        }
                    }

                    // If no tool call happened, we're done.
                    guard let toolCall = capturedToolCall else { break }

                    toolRoundTrips += 1
                    if toolRoundTrips > maxToolRoundTrips {
                        await MainActor.run {
                            self.updateChatMessageText(
                                id: assistantMessageID,
                                text: accumulated.isEmpty ? "Error: Tool loop exceeded safe limit." : accumulated
                            )
                        }
                        break
                    }

                    // Execute tool
                    let result = await ToolExecutor.execute(toolCall)

                    // Feed tool result back into the model (your service already formats Tool Results into content)
                    conversation.append(
                        OllamaChatService.Message(
                            role: "user",
                            content: "Tool result for \(toolCall.name) (id: \(toolCall.id)):\n\(result.success ? result.result : (result.error ?? "Unknown error"))"
                        )
                    )
                }

                await MainActor.run {
                    self.finishChatReply()
                }
            } catch {
                if error is CancellationError {
                    await MainActor.run { self.finishChatReply(canceled: true) }
                } else {
                    await MainActor.run { self.handleChatReplyError(for: assistantMessageID, error: error) }
                }
            }
        }
    }

    @MainActor
    private func finishChatReply(canceled: Bool = false) {
        pendingChatReplies = 0
        chatActivityStatus = nil
        // Don't clear chatThinkingText - keep it available to view
        // Don't reset chatThinkingExpanded - preserve user's choice
        if !canceled {
            chatWarning = nil
        }
        chatReplyTask = nil
        startChatReplyIfIdle()
    }

    @MainActor
    private func handleChatReplyError(for assistantMessageID: UUID, error: Error) {
        pendingChatReplies = 0
        chatActivityStatus = nil
        chatThinkingText = nil
        chatThinkingExpanded = false
        let message: String
        if let localized = (error as? LocalizedError)?.errorDescription {
            message = localized
        } else {
            message = error.localizedDescription
        }
        chatWarning = "Chat error: \(message)"
        updateChatMessageText(id: assistantMessageID, text: "Error: \(message)")
        chatReplyTask = nil
        startChatReplyIfIdle()
    }

    @MainActor
    func editChatMessageAndResend(messageId: UUID, text: String) {
        _ = messageId
        _ = text
        chatWarning = "Chat is disabled."
    }

    @MainActor
    func retryChatReply(messageId: UUID) {
        _ = messageId
        chatWarning = "Chat is disabled."
    }

    @MainActor
    func beginVoiceConversation() {
        if !isVoiceConversationActive {
            isVoiceConversationActive = true
        }
    }

    @MainActor
    func endVoiceConversation() {
        if isVoiceConversationActive {
            isVoiceConversationActive = false
        }
    }

    @MainActor
    func stopSpeechPlayback() {
        isSpeaking = false
        endVoiceConversation()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Quick add helpers
extension BoardStore {
    private struct TextEntryLayout {
        let text: String
        let width: CGFloat
        let height: CGFloat
    }

    private func textEntryLayouts(for text: String,
                                  font: PlatformFont,
                                  minWidth: CGFloat,
                                  maxWidth: CGFloat) -> [TextEntryLayout] {
        let chunks = chunkedText(text, maxLength: textEntryChunkMaxLength)
        return chunks.map { chunk in
            let contentSize = TextEntryMetrics.contentSize(for: chunk, font: font)
            let width = min(max(contentSize.width, minWidth), maxWidth)
            let height = TextEntryMetrics.height(for: chunk, maxWidth: width, font: font)
            return TextEntryLayout(text: chunk, width: width, height: height)
        }
    }

    private func chunkedText(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var chunks: [String] = []
        var current = ""
        var currentCount = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices {
            var line = String(lines[index])
            if index < lines.count - 1 {
                line.append("\n")
            }
            var lineIndex = line.startIndex
            while lineIndex < line.endIndex {
                let remaining = maxLength - currentCount
                if remaining == 0 {
                    if !current.isEmpty {
                        chunks.append(current)
                        current = ""
                        currentCount = 0
                    }
                    continue
                }
                let remainingInLine = line.distance(from: lineIndex, to: line.endIndex)
                if remainingInLine <= remaining {
                    current.append(contentsOf: line[lineIndex..<line.endIndex])
                    currentCount += remainingInLine
                    lineIndex = line.endIndex
                } else {
                    let splitIndex = line.index(lineIndex, offsetBy: remaining)
                    current.append(contentsOf: line[lineIndex..<splitIndex])
                    currentCount += remaining
                    chunks.append(current)
                    current = ""
                    currentCount = 0
                    lineIndex = splitIndex
                }
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func createTextEntries(from layouts: [TextEntryLayout],
                                   centeredAt worldCenter: CGPoint,
                                   createdBy: Actor) -> [UUID] {
        guard !layouts.isEmpty else { return [] }
        if layouts.count == 1 {
            let layout = layouts[0]
            let rect = CGRect(x: worldCenter.x - layout.width / 2,
                              y: worldCenter.y - layout.height / 2,
                              width: layout.width,
                              height: layout.height)
            return [createEntry(type: .text,
                                frame: rect,
                                data: .text(layout.text),
                                createdBy: createdBy)]
        }
        let totalHeight = layouts.reduce(0) { $0 + $1.height }
            + textEntryChunkSpacing * CGFloat(layouts.count - 1)
        var currentY = worldCenter.y - totalHeight / 2
        var ids: [UUID] = []
        for layout in layouts {
            let centerY = currentY + layout.height / 2
            let rect = CGRect(x: worldCenter.x - layout.width / 2,
                              y: centerY - layout.height / 2,
                              width: layout.width,
                              height: layout.height)
            let id = createEntry(type: .text,
                                 frame: rect,
                                 data: .text(layout.text),
                                 createdBy: createdBy)
            ids.append(id)
            currentY += layout.height + textEntryChunkSpacing
        }
        return ids
    }

    @MainActor
    func pinChatMessage(_ message: ChatMsg) {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageRefs = message.images
        let hasImages = !imageRefs.isEmpty
        let fileRefs = message.files
        let hasFiles = !fileRefs.isEmpty
        guard !trimmed.isEmpty || hasImages || hasFiles else { return }
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)

        var attachmentIds: [UUID] = []
        if !imageRefs.isEmpty {
            let offsetStep: CGFloat = 20
            for (index, imageRef) in imageRefs.enumerated() {
                let offset = CGFloat(index) * offsetStep
                let center = CGPoint(x: worldCenter.x + offset, y: worldCenter.y + offset)
                let rect = imageRect(for: imageRef, centeredAt: center, maxSide: 320)
                let id = createEntry(type: .image, frame: rect, data: .image(imageRef), createdBy: message.role)
                attachmentIds.append(id)
            }
        }

        if !fileRefs.isEmpty {
            let offsetStep: CGFloat = 22
            for (index, fileRef) in fileRefs.enumerated() {
                let offset = CGFloat(index) * offsetStep
                let center = CGPoint(x: worldCenter.x + offset, y: worldCenter.y + offset)
                let rect = fileRect(for: fileRef, centeredAt: center)
                let id = createEntry(type: .file, frame: rect, data: .file(fileRef), createdBy: message.role)
                attachmentIds.append(id)
            }
        }

        if !attachmentIds.isEmpty {
            selection = Set(attachmentIds)
            return
        }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let layouts = textEntryLayouts(for: trimmed, font: font, minWidth: minWidth, maxWidth: maxWidth)
        let ids = createTextEntries(from: layouts, centeredAt: worldCenter, createdBy: message.role)
        selection = Set(ids)
    }

    @MainActor
    @discardableResult
    func pinChatInputText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)
        let layouts = textEntryLayouts(for: trimmed, font: font, minWidth: minWidth, maxWidth: maxWidth)
        let ids = createTextEntries(from: layouts, centeredAt: worldCenter, createdBy: .user)
        selection = Set(ids)
        return !ids.isEmpty
    }

    private func imageRect(for ref: ImageRef, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        if let url = imageURL(for: ref) {
            #if os(macOS)
            if let image = NSImage(contentsOf: url) {
                let size = image.size
                if size.width > 0 && size.height > 0 {
                    let aspect = size.width / size.height
                    let width: CGFloat
                    let height: CGFloat
                    if aspect >= 1 {
                        width = maxSide
                        height = maxSide / aspect
                    } else {
                        height = maxSide
                        width = maxSide * aspect
                    }
                    return CGRect(x: point.x - width / 2,
                                  y: point.y - height / 2,
                                  width: width,
                                  height: height)
                }
            }
            #else
            if let image = UIImage(contentsOfFile: url.path) {
                let size = image.size
                if size.width > 0 && size.height > 0 {
                    let aspect = size.width / size.height
                    let width: CGFloat
                    let height: CGFloat
                    if aspect >= 1 {
                        width = maxSide
                        height = maxSide / aspect
                    } else {
                        height = maxSide
                        width = maxSide * aspect
                    }
                    return CGRect(x: point.x - width / 2,
                                  y: point.y - height / 2,
                                  width: width,
                                  height: height)
                }
            }
            #endif
        }
        return CGRect(x: point.x - maxSide / 2,
                      y: point.y - maxSide / 2,
                      width: maxSide,
                      height: maxSide)
    }

    private func fileRect(for _: FileRef, centeredAt point: CGPoint) -> CGRect {
        let width: CGFloat = 260
        let height: CGFloat = 120
        return CGRect(x: point.x - width / 2,
                      y: point.y - height / 2,
                      width: width,
                      height: height)
    }
}

// MARK: - Line builder
extension BoardStore {
    func createLineEntry(start: CGPoint, end: CGPoint, arrow: Bool = false) -> UUID {
        let points = [
            Point(x: start.x.double, y: start.y.double),
            Point(x: end.x.double, y: end.y.double)
        ]
        let rect = lineEntryRect(for: [start, end])
        let data = LineData(points: points, arrow: arrow)
        return createEntry(type: .line, frame: rect, data: .line(data))
    }

    func updateLine(id: UUID, start: CGPoint? = nil, end: CGPoint? = nil, recordUndo: Bool = true) {
        guard var entry = doc.entries[id] else { return }
        guard case .line(let data) = entry.data else { return }

        let currentStart = data.points.first ?? Point(x: entry.x, y: entry.y)
        let currentEnd = data.points.last ?? Point(x: entry.x + entry.w, y: entry.y + entry.h)

        let newStart = start.map { Point(x: $0.x.double, y: $0.y.double) } ?? currentStart
        let newEnd = end.map { Point(x: $0.x.double, y: $0.y.double) } ?? currentEnd

        let startPoint = CGPoint(x: newStart.x.cg, y: newStart.y.cg)
        let endPoint = CGPoint(x: newEnd.x.cg, y: newEnd.y.cg)
        let rect = lineEntryRect(for: [startPoint, endPoint])

        if recordUndo {
            recordUndoSnapshot(coalescingKey: "line-\(id.uuidString)")
        }
        entry.x = rect.origin.x.double
        entry.y = rect.origin.y.double
        entry.w = rect.size.width.double
        entry.h = rect.size.height.double
        entry.data = .line(LineData(points: [newStart, newEnd], arrow: data.arrow))
        entry.updatedAt = Date().timeIntervalSince1970
        doc.entries[id] = entry
        touch()
    }

    func appendLinePoint(_ point: CGPoint) {
        lineBuilder.append(point)
    }

    func finishLine(arrow: Bool = true) {
        guard lineBuilder.count > 1 else {
            lineBuilder.removeAll()
            currentTool = .select
            return
        }
        let points = lineBuilder.map { Point(x: $0.x.double, y: $0.y.double) }
        let rect = lineEntryRect(for: lineBuilder)
        let data = LineData(points: points, arrow: arrow)
        let id = createEntry(type: .line, frame: rect, data: .line(data))
        selection = [id]
        lineBuilder.removeAll()
        currentTool = .select
    }

    fileprivate func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    fileprivate func lineEntryRect(for points: [CGPoint]) -> CGRect {
        let rect = boundingRect(for: points)
        return rect.insetBy(dx: -linePadding, dy: -linePadding)
    }

    func topEntry(at worldPoint: CGPoint) -> UUID? {
        for id in doc.zOrder.reversed() {
            guard let entry = doc.entries[id] else { continue }
            if entryContainsPoint(entry, worldPoint: worldPoint) {
                return id
            }
        }
        return nil
    }

    func topEntryAtScreenPoint(_ screenPoint: CGPoint) -> UUID? {
        let worldPoint = worldPoint(from: screenPoint)
        for id in doc.zOrder.reversed() {
            guard let entry = doc.entries[id] else { continue }
            if entryContainsPoint(entry, worldPoint: worldPoint) {
                return id
            }
        }
        return nil
    }

    private func entryContainsPoint(_ entry: BoardEntry, worldPoint: CGPoint) -> Bool {
        let rect = CGRect(x: entry.x.cg, y: entry.y.cg, width: entry.w.cg, height: entry.h.cg)

        guard case .shape(let kind) = entry.data else {
            return rect.contains(worldPoint)
        }

        switch kind {
        case .circle:
            let rx = rect.width / 2
            let ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = (worldPoint.x - center.x) / rx
            let dy = (worldPoint.y - center.y) / ry
            return (dx * dx + dy * dy) <= 1.0

        case .triangleUp, .triangleDown, .triangleLeft, .triangleRight:
            let (a, b, c) = triangleVertices(kind: kind, in: rect)
            return pointInTriangle(worldPoint, a, b, c)

        case .rect:
            return rect.contains(worldPoint)
        }
    }

    private func triangleVertices(kind: ShapeKind, in rect: CGRect) -> (CGPoint, CGPoint, CGPoint) {
        let minX = rect.minX, midX = rect.midX, maxX = rect.maxX
        let minY = rect.minY, midY = rect.midY, maxY = rect.maxY

        switch kind {
        case .triangleUp:
            return (CGPoint(x: midX, y: minY),
                    CGPoint(x: maxX, y: maxY),
                    CGPoint(x: minX, y: maxY))
        case .triangleDown:
            return (CGPoint(x: midX, y: maxY),
                    CGPoint(x: minX, y: minY),
                    CGPoint(x: maxX, y: minY))
        case .triangleLeft:
            return (CGPoint(x: minX, y: midY),
                    CGPoint(x: maxX, y: minY),
                    CGPoint(x: maxX, y: maxY))
        case .triangleRight:
            return (CGPoint(x: maxX, y: midY),
                    CGPoint(x: minX, y: minY),
                    CGPoint(x: minX, y: maxY))
        default:
            // Not used here
            return (CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.minX, y: rect.maxY))
        }
    }

    private func pointInTriangle(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        func sign(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }

        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)

        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)

        return !(hasNeg && hasPos)
    }
}

// MARK: - Notes: create items + selection

extension BoardStore {

    private var nowTS: Double { Date().timeIntervalSince1970 }
    
    // MARK: - Note Locking (Touch ID gate)

    func isNoteUnlockedInSession(_ noteID: UUID) -> Bool {
        unlockedNoteIDs.contains(noteID)
    }

    func isNoteLocked(_ noteID: UUID) -> Bool {
        guard let loc = locateNote(noteID) else { return false }
        let area = doc.notes.areas[loc.areaIndex]

        if let stackIndex = loc.stackIndex {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                return area.stacks[stackIndex]
                    .notebooks[nbIdx]
                    .sections[secIdx]
                    .notes[loc.noteIndex]
                    .isLocked
            } else if let nbIdx = loc.notebookIndex {
                return area.stacks[stackIndex]
                    .notebooks[nbIdx]
                    .notes[loc.noteIndex]
                    .isLocked
            } else {
                return area.stacks[stackIndex]
                    .notes[loc.noteIndex]
                    .isLocked
            }
        } else {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                return area
                    .notebooks[nbIdx]
                    .sections[secIdx]
                    .notes[loc.noteIndex]
                    .isLocked
            } else if let nbIdx = loc.notebookIndex {
                return area
                    .notebooks[nbIdx]
                    .notes[loc.noteIndex]
                    .isLocked
            } else {
                return area
                    .notes[loc.noteIndex]
                    .isLocked
            }
        }
    }

    private func biometricAuth(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?

        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }

        return await withCheckedContinuation { cont in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    /// Gate to *view* a locked note (does NOT unlock it permanently; just for this session).
    func ensureUnlockedForViewing(noteID: UUID) async -> Bool {
        guard isNoteLocked(noteID) else { return true }
        if unlockedNoteIDs.contains(noteID) { return true }

        let ok = await biometricAuth(reason: "Unlock this note")
        if ok { unlockedNoteIDs.insert(noteID) }
        return ok
    }

    @discardableResult
    private func setNoteLockedByID(noteID: UUID, locked: Bool) -> Bool {
        guard let loc = locateNote(noteID) else { return false }
        let ts = nowTS

        if let stackIndex = loc.stackIndex {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex] = note
            } else if let nbIdx = loc.notebookIndex {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notebooks[nbIdx].notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notebooks[nbIdx].notes[loc.noteIndex] = note
            } else {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex]
                    .notes[loc.noteIndex] = note
            }
        } else {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                var note = doc.notes.areas[loc.areaIndex]
                    .notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex]
                    .notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex] = note
            } else if let nbIdx = loc.notebookIndex {
                var note = doc.notes.areas[loc.areaIndex]
                    .notebooks[nbIdx].notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex]
                    .notebooks[nbIdx].notes[loc.noteIndex] = note
            } else {
                var note = doc.notes.areas[loc.areaIndex]
                    .notes[loc.noteIndex]
                note.isLocked = locked
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex]
                    .notes[loc.noteIndex] = note
            }
        }

        doc.updatedAt = ts

        // If it was locked, revoke session access immediately.
        if locked {
            unlockedNoteIDs.remove(noteID)
            if doc.notes.selection.noteID == noteID {
                doc.notes.selection.noteID = nil
            }
        }

        return true
    }

    func lockNoteWithAuth(noteID: UUID) async {
        let ok = await biometricAuth(reason: "Lock this note")
        guard ok else { return }
        _ = setNoteLockedByID(noteID: noteID, locked: true)
    }

    func unlockNoteWithAuth(noteID: UUID) async {
        let ok = await biometricAuth(reason: "Unlock this note")
        guard ok else { return }
        _ = setNoteLockedByID(noteID: noteID, locked: false)
        // Optional: keep it “session-unlocked” too (harmless)
        unlockedNoteIDs.insert(noteID)
    }

    func addArea(title: String = "New Area") {
        let area = NoteArea(id: UUID(), title: title, stacks: [], notebooks: [], notes: [])
        doc.notes.areas.append(area)
        doc.notes.selection = NotesSelection(areaID: area.id, stackID: nil, notebookID: nil, sectionID: nil, noteID: nil)
    }

    func addQuickNote() {
        let areaID = ensureQuickNotesAreaID()
        addNote(areaID: areaID, stackID: nil, notebookID: nil, sectionID: nil, title: "")
    }

    func addStack(areaID: UUID, title: String = "New Stack") {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        let stack = NoteStack(id: UUID(), title: title, notebooks: [], notes: [])
        doc.notes.areas[aIdx].stacks.append(stack)
        doc.notes.selection = NotesSelection(areaID: areaID, stackID: stack.id, notebookID: nil, sectionID: nil, noteID: nil)
    }

    func addNotebook(areaID: UUID, stackID: UUID?, title: String = "New Notebook") {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        let nb = NoteNotebook(id: UUID(), title: title, sections: [], notes: [])

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            doc.notes.areas[aIdx].stacks[sIdx].notebooks.append(nb)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: nb.id, sectionID: nil, noteID: nil)
        } else {
            doc.notes.areas[aIdx].notebooks.append(nb)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: nb.id, sectionID: nil, noteID: nil)
        }
    }

    func addSection(areaID: UUID, stackID: UUID?, notebookID: UUID, title: String = "New Section") {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }

            let section = NoteSection(id: UUID(), title: title, notes: [])
            doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.append(section)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: section.id, noteID: nil)
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        let section = NoteSection(id: UUID(), title: title, notes: [])
        doc.notes.areas[aIdx].notebooks[nbIdx].sections.append(section)
        doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: notebookID, sectionID: section.id, noteID: nil)
    }

    func addNote(
        areaID: UUID,
        stackID: UUID?,
        notebookID: UUID?,
        sectionID: UUID?,
        title: String = ""
    ) {
        let note = NoteItem(id: UUID(), title: title, body: "", createdAt: nowTS, updatedAt: nowTS)

        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

            // 1) Section note (stack)
            if let notebookID, let sectionID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: sectionID, noteID: note.id)
                return
            }

            // 2) Notebook root note (stack)
            if let notebookID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: nil, noteID: note.id)
                return
            }

            // 3) Stack root note
            doc.notes.areas[aIdx].stacks[sIdx].notes.append(note)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: nil, sectionID: nil, noteID: note.id)
            return
        }

        // Area-level notes
        if let notebookID, let sectionID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.append(note)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: notebookID, sectionID: sectionID, noteID: note.id)
            return
        }

        if let notebookID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            doc.notes.areas[aIdx].notebooks[nbIdx].notes.append(note)
            doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: notebookID, sectionID: nil, noteID: note.id)
            return
        }

        doc.notes.areas[aIdx].notes.append(note)
        doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: nil, sectionID: nil, noteID: note.id)
    }

    // Ensure the dedicated Quick Notes area exists and return its id.
    // This is keyed by doc.notes.quickNotesAreaID (not the title).
    private func ensureQuickNotesAreaID() -> UUID {
        let quickID = doc.notes.quickNotesAreaID
        if doc.notes.areas.contains(where: { $0.id == quickID }) {
            return quickID
        }

        if let existing = doc.notes.areas.first(where: { $0.title == "Quick Notes" }) {
            doc.notes.quickNotesAreaID = existing.id
            return existing.id
        }

        let new = NoteArea(id: UUID(), title: "Quick Notes", stacks: [], notebooks: [], notes: [])
        doc.notes.areas.insert(new, at: 0)
        doc.notes.quickNotesAreaID = new.id
        return new.id
    }

    // MARK: - Notes: rename / delete

    func renameArea(id: UUID, title: String) {
        let quickID = ensureQuickNotesAreaID()
        guard id != quickID else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Untitled" : trimmed
        guard let idx = doc.notes.areas.firstIndex(where: { $0.id == id }) else { return }
        doc.notes.areas[idx].title = finalTitle
    }

    func deleteArea(id: UUID) {
        let quickID = ensureQuickNotesAreaID()
        guard id != quickID else { return }
        guard let idx = doc.notes.areas.firstIndex(where: { $0.id == id }) else { return }

        doc.notes.areas.remove(at: idx)

        if doc.notes.selection.areaID == id {
            doc.notes.selection = NotesSelection(areaID: quickID, stackID: nil, notebookID: nil, sectionID: nil, noteID: nil)
        }
    }

    func renameStack(areaID: UUID, stackID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Untitled" : trimmed

        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
        doc.notes.areas[aIdx].stacks[sIdx].title = finalTitle
    }

    func deleteStack(areaID: UUID, stackID: UUID) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

        doc.notes.areas[aIdx].stacks.remove(at: sIdx)

        if doc.notes.selection.areaID == areaID && doc.notes.selection.stackID == stackID {
            doc.notes.selection.stackID = nil
            doc.notes.selection.notebookID = nil
            doc.notes.selection.sectionID = nil
            doc.notes.selection.noteID = nil
        }
    }

    func renameNotebook(areaID: UUID, stackID: UUID?, notebookID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Untitled" : trimmed

        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].title = finalTitle
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        doc.notes.areas[aIdx].notebooks[nbIdx].title = finalTitle
    }

    func deleteNotebook(areaID: UUID, stackID: UUID?, notebookID: UUID) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }

            doc.notes.areas[aIdx].stacks[sIdx].notebooks.remove(at: nbIdx)

            if doc.notes.selection.areaID == areaID &&
                doc.notes.selection.stackID == stackID &&
                doc.notes.selection.notebookID == notebookID {
                doc.notes.selection.notebookID = nil
                doc.notes.selection.sectionID = nil
                doc.notes.selection.noteID = nil
            }
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        doc.notes.areas[aIdx].notebooks.remove(at: nbIdx)

        if doc.notes.selection.areaID == areaID &&
            doc.notes.selection.stackID == nil &&
            doc.notes.selection.notebookID == notebookID {
            doc.notes.selection.notebookID = nil
            doc.notes.selection.sectionID = nil
            doc.notes.selection.noteID = nil
        }
    }

    // MARK: - Notes: move (drag/drop)

    /// Moves a note from one location to another (area / stack / notebook / section).
    ///
    /// - Parameters:
    ///   - fromAreaID: Source area
    ///   - fromStackID: Source stack (nil = area-level note)
    ///   - fromNotebookID: Source notebook (nil = stack- or area-level note)
    ///   - fromSectionID: Source section (nil = stack-, area-, or notebook-level note)
    ///   - noteID: The note being moved
    ///   - toAreaID: Destination area
    ///   - toStackID: Destination stack (nil = area-level destination)
    ///   - toNotebookID: Destination notebook (nil = stack- or area-level destination)
    ///   - toSectionID: Destination section (non-nil only when toNotebookID is non-nil)
    ///   - toIndex: Optional insertion index within the destination container (nil = append)
    func moveNote(
        fromAreaID: UUID,
        fromStackID: UUID?,
        fromNotebookID: UUID?,
        fromSectionID: UUID?,
        noteID: UUID,
        toAreaID: UUID,
        toStackID: UUID?,
        toNotebookID: UUID?,
        toSectionID: UUID?,
        toIndex: Int? = nil
    ) {
        let sameContainer = fromAreaID == toAreaID &&
            fromStackID == toStackID &&
            fromNotebookID == toNotebookID &&
            fromSectionID == toSectionID

        if sameContainer && toIndex == nil { return }

        // 1) Extract the note from the source container.
        guard let fromAIdx = doc.notes.areas.firstIndex(where: { $0.id == fromAreaID }) else { return }

        var moved: NoteItem? = nil
        var fromIndex: Int? = nil

        if let fromStackID {
            guard let fromSIdx = doc.notes.areas[fromAIdx].stacks.firstIndex(where: { $0.id == fromStackID }) else { return }

            if let fromNotebookID, let fromSectionID {
                // Section note (stack)
                guard let fromNBIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
                guard let fromSecIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].sections.firstIndex(where: { $0.id == fromSectionID }) else { return }
                guard let fromNIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].sections[fromSecIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].sections[fromSecIdx].notes.remove(at: fromNIdx)
            } else if let fromNotebookID {
                // Notebook root note (stack)
                guard let fromNBIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
                guard let fromNIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].notes.remove(at: fromNIdx)
            } else {
                // Stack root note
                guard let fromNIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].stacks[fromSIdx].notes.remove(at: fromNIdx)
            }
        } else {
            if let fromNotebookID, let fromSectionID {
                // Section note (area)
                guard let fromNBIdx = doc.notes.areas[fromAIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
                guard let fromSecIdx = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].sections.firstIndex(where: { $0.id == fromSectionID }) else { return }
                guard let fromNIdx = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].sections[fromSecIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].sections[fromSecIdx].notes.remove(at: fromNIdx)
            } else if let fromNotebookID {
                // Notebook root note (area)
                guard let fromNBIdx = doc.notes.areas[fromAIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
                guard let fromNIdx = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].notes.remove(at: fromNIdx)
            } else {
                // Area root note
                guard let fromNIdx = doc.notes.areas[fromAIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
                fromIndex = fromNIdx
                moved = doc.notes.areas[fromAIdx].notes.remove(at: fromNIdx)
            }
        }

        guard var note = moved else { return }
        note.updatedAt = nowTS

        // 2) Insert into destination container.
        guard let toAIdx = doc.notes.areas.firstIndex(where: { $0.id == toAreaID }) else {
            // Put it back if destination disappeared.
            reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
            return
        }

        let fromIndexForAdjust = insertionAdjustmentIndex(fromIndex: fromIndex, toIndex: toIndex, sameContainer: sameContainer)
        var inserted = false

        if let toStackID {
            guard let toSIdx = doc.notes.areas[toAIdx].stacks.firstIndex(where: { $0.id == toStackID }) else {
                reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                return
            }

            if let toNotebookID, let toSectionID {
                guard let toNBIdx = doc.notes.areas[toAIdx].stacks[toSIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                guard let toSecIdx = doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].sections.firstIndex(where: { $0.id == toSectionID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].sections[toSecIdx].notes.count)
                doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].sections[toSecIdx].notes.insert(note, at: insertIndex)
                inserted = true
            } else if let toNotebookID {
                guard let toNBIdx = doc.notes.areas[toAIdx].stacks[toSIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].notes.count)
                doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].notes.insert(note, at: insertIndex)
                inserted = true
            } else {
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks[toSIdx].notes.count)
                doc.notes.areas[toAIdx].stacks[toSIdx].notes.insert(note, at: insertIndex)
                inserted = true
            }
        } else {
            if let toNotebookID, let toSectionID {
                guard let toNBIdx = doc.notes.areas[toAIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                guard let toSecIdx = doc.notes.areas[toAIdx].notebooks[toNBIdx].sections.firstIndex(where: { $0.id == toSectionID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].notebooks[toNBIdx].sections[toSecIdx].notes.count)
                doc.notes.areas[toAIdx].notebooks[toNBIdx].sections[toSecIdx].notes.insert(note, at: insertIndex)
                inserted = true
            } else if let toNotebookID {
                guard let toNBIdx = doc.notes.areas[toAIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                    reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
                    return
                }
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].notebooks[toNBIdx].notes.count)
                doc.notes.areas[toAIdx].notebooks[toNBIdx].notes.insert(note, at: insertIndex)
                inserted = true
            } else {
                let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].notes.count)
                doc.notes.areas[toAIdx].notes.insert(note, at: insertIndex)
                inserted = true
            }
        }

        guard inserted else {
            reinsertNote(note, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, sectionID: fromSectionID, at: fromIndex)
            return
        }

        // 3) Keep selection on the moved note.
        doc.notes.selection = NotesSelection(
            areaID: toAreaID,
            stackID: toStackID,
            notebookID: toNotebookID,
            sectionID: toSectionID,
            noteID: note.id
        )
        doc.updatedAt = note.updatedAt
    }

    // MARK: - Notes: move areas / stacks / notebooks / sections (drag/drop)

    func moveArea(areaID: UUID, toIndex: Int) {
        guard let fromIndex = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        if fromIndex == toIndex { return }

        let area = doc.notes.areas.remove(at: fromIndex)
        let fromIndexForAdjust = insertionAdjustmentIndex(fromIndex: fromIndex, toIndex: toIndex, sameContainer: true)
        let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas.count)
        doc.notes.areas.insert(area, at: insertIndex)
        doc.updatedAt = nowTS
    }

    func moveStack(fromAreaID: UUID, stackID: UUID, toAreaID: UUID, toIndex: Int? = nil) {
        let sameContainer = fromAreaID == toAreaID
        if sameContainer && toIndex == nil { return }

        guard let fromAIdx = doc.notes.areas.firstIndex(where: { $0.id == fromAreaID }) else { return }
        guard let fromSIdx = doc.notes.areas[fromAIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

        let moved = doc.notes.areas[fromAIdx].stacks.remove(at: fromSIdx)

        guard let toAIdx = doc.notes.areas.firstIndex(where: { $0.id == toAreaID }) else {
            reinsertStack(moved, areaID: fromAreaID, at: fromSIdx)
            return
        }

        let fromIndexForAdjust = insertionAdjustmentIndex(fromIndex: fromSIdx, toIndex: toIndex, sameContainer: sameContainer)
        let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks.count)
        doc.notes.areas[toAIdx].stacks.insert(moved, at: insertIndex)

        if doc.notes.selection.areaID == fromAreaID && doc.notes.selection.stackID == stackID {
            doc.notes.selection.areaID = toAreaID
        }

        doc.updatedAt = nowTS
    }

    func moveNotebook(
        fromAreaID: UUID,
        fromStackID: UUID?,
        notebookID: UUID,
        toAreaID: UUID,
        toStackID: UUID?,
        toIndex: Int? = nil
    ) {
        let sameContainer = fromAreaID == toAreaID && fromStackID == toStackID
        if sameContainer && toIndex == nil { return }

        guard let fromAIdx = doc.notes.areas.firstIndex(where: { $0.id == fromAreaID }) else { return }

        var moved: NoteNotebook? = nil
        var fromNBIdx: Int? = nil

        if let fromStackID {
            guard let fromSIdx = doc.notes.areas[fromAIdx].stacks.firstIndex(where: { $0.id == fromStackID }) else { return }
            guard let nbIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            fromNBIdx = nbIdx
            moved = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks.remove(at: nbIdx)
        } else {
            guard let nbIdx = doc.notes.areas[fromAIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            fromNBIdx = nbIdx
            moved = doc.notes.areas[fromAIdx].notebooks.remove(at: nbIdx)
        }

        guard let notebook = moved else { return }

        guard let toAIdx = doc.notes.areas.firstIndex(where: { $0.id == toAreaID }) else {
            reinsertNotebook(notebook, areaID: fromAreaID, stackID: fromStackID, at: fromNBIdx ?? 0)
            return
        }

        let fromIndexForAdjust = insertionAdjustmentIndex(fromIndex: fromNBIdx, toIndex: toIndex, sameContainer: sameContainer)

        if let toStackID {
            guard let toSIdx = doc.notes.areas[toAIdx].stacks.firstIndex(where: { $0.id == toStackID }) else {
                reinsertNotebook(notebook, areaID: fromAreaID, stackID: fromStackID, at: fromNBIdx ?? 0)
                return
            }
            let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks[toSIdx].notebooks.count)
            doc.notes.areas[toAIdx].stacks[toSIdx].notebooks.insert(notebook, at: insertIndex)
        } else {
            let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].notebooks.count)
            doc.notes.areas[toAIdx].notebooks.insert(notebook, at: insertIndex)
        }

        if doc.notes.selection.areaID == fromAreaID &&
            doc.notes.selection.stackID == fromStackID &&
            doc.notes.selection.notebookID == notebookID {
            doc.notes.selection.areaID = toAreaID
            doc.notes.selection.stackID = toStackID
        }

        doc.updatedAt = nowTS
    }

    func moveSection(
        fromAreaID: UUID,
        fromStackID: UUID?,
        fromNotebookID: UUID,
        sectionID: UUID,
        toAreaID: UUID,
        toStackID: UUID?,
        toNotebookID: UUID,
        toIndex: Int? = nil
    ) {
        let sameContainer = fromAreaID == toAreaID && fromStackID == toStackID && fromNotebookID == toNotebookID
        if sameContainer && toIndex == nil { return }

        guard let fromAIdx = doc.notes.areas.firstIndex(where: { $0.id == fromAreaID }) else { return }

        var moved: NoteSection? = nil
        var fromSecIdx: Int? = nil

        if let fromStackID {
            guard let fromSIdx = doc.notes.areas[fromAIdx].stacks.firstIndex(where: { $0.id == fromStackID }) else { return }
            guard let fromNBIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
            guard let secIdx = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            fromSecIdx = secIdx
            moved = doc.notes.areas[fromAIdx].stacks[fromSIdx].notebooks[fromNBIdx].sections.remove(at: secIdx)
        } else {
            guard let fromNBIdx = doc.notes.areas[fromAIdx].notebooks.firstIndex(where: { $0.id == fromNotebookID }) else { return }
            guard let secIdx = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            fromSecIdx = secIdx
            moved = doc.notes.areas[fromAIdx].notebooks[fromNBIdx].sections.remove(at: secIdx)
        }

        guard let section = moved else { return }

        guard let toAIdx = doc.notes.areas.firstIndex(where: { $0.id == toAreaID }) else {
            reinsertSection(section, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, at: fromSecIdx ?? 0)
            return
        }

        let fromIndexForAdjust = insertionAdjustmentIndex(fromIndex: fromSecIdx, toIndex: toIndex, sameContainer: sameContainer)

        if let toStackID {
            guard let toSIdx = doc.notes.areas[toAIdx].stacks.firstIndex(where: { $0.id == toStackID }) else {
                reinsertSection(section, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, at: fromSecIdx ?? 0)
                return
            }
            guard let toNBIdx = doc.notes.areas[toAIdx].stacks[toSIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                reinsertSection(section, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, at: fromSecIdx ?? 0)
                return
            }
            let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].sections.count)
            doc.notes.areas[toAIdx].stacks[toSIdx].notebooks[toNBIdx].sections.insert(section, at: insertIndex)
        } else {
            guard let toNBIdx = doc.notes.areas[toAIdx].notebooks.firstIndex(where: { $0.id == toNotebookID }) else {
                reinsertSection(section, areaID: fromAreaID, stackID: fromStackID, notebookID: fromNotebookID, at: fromSecIdx ?? 0)
                return
            }
            let insertIndex = adjustedInsertIndex(fromIndex: fromIndexForAdjust, toIndex: toIndex, count: doc.notes.areas[toAIdx].notebooks[toNBIdx].sections.count)
            doc.notes.areas[toAIdx].notebooks[toNBIdx].sections.insert(section, at: insertIndex)
        }

        if doc.notes.selection.areaID == fromAreaID &&
            doc.notes.selection.stackID == fromStackID &&
            doc.notes.selection.notebookID == fromNotebookID &&
            doc.notes.selection.sectionID == sectionID {
            doc.notes.selection.areaID = toAreaID
            doc.notes.selection.stackID = toStackID
            doc.notes.selection.notebookID = toNotebookID
        }

        doc.updatedAt = nowTS
    }

    private func insertionAdjustmentIndex(fromIndex: Int?, toIndex: Int?, sameContainer: Bool) -> Int? {
        guard sameContainer, let fromIndex else { return nil }
        guard let toIndex else { return nil }
        if fromIndex < toIndex { return nil }
        return fromIndex
    }

    private func adjustedInsertIndex(fromIndex: Int?, toIndex: Int?, count: Int) -> Int {
        let base = toIndex ?? count
        var index = max(0, min(base, count))
        if let fromIndex, fromIndex < index {
            index -= 1
        }
        return index
    }

    private func insertNote(_ note: NoteItem, into notes: inout [NoteItem], at index: Int?) {
        if let index {
            let insertIndex = max(0, min(index, notes.count))
            notes.insert(note, at: insertIndex)
        } else {
            notes.append(note)
        }
    }

    private func reinsertNote(_ note: NoteItem, areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, at index: Int? = nil) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

            if let notebookID, let sectionID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
                insertNote(note, into: &doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes, at: index)
                return
            }

            if let notebookID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                insertNote(note, into: &doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes, at: index)
                return
            }

            insertNote(note, into: &doc.notes.areas[aIdx].stacks[sIdx].notes, at: index)
            return
        }

        if let notebookID, let sectionID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            insertNote(note, into: &doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes, at: index)
            return
        }

        if let notebookID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            insertNote(note, into: &doc.notes.areas[aIdx].notebooks[nbIdx].notes, at: index)
            return
        }

        insertNote(note, into: &doc.notes.areas[aIdx].notes, at: index)
    }

    private func reinsertStack(_ stack: NoteStack, areaID: UUID, at index: Int) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }
        let insertIndex = max(0, min(index, doc.notes.areas[aIdx].stacks.count))
        doc.notes.areas[aIdx].stacks.insert(stack, at: insertIndex)
    }

    private func reinsertNotebook(_ notebook: NoteNotebook, areaID: UUID, stackID: UUID?, at index: Int) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            let insertIndex = max(0, min(index, doc.notes.areas[aIdx].stacks[sIdx].notebooks.count))
            doc.notes.areas[aIdx].stacks[sIdx].notebooks.insert(notebook, at: insertIndex)
            return
        }

        let insertIndex = max(0, min(index, doc.notes.areas[aIdx].notebooks.count))
        doc.notes.areas[aIdx].notebooks.insert(notebook, at: insertIndex)
    }

    private func reinsertSection(_ section: NoteSection, areaID: UUID, stackID: UUID?, notebookID: UUID, at index: Int) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            let insertIndex = max(0, min(index, doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.count))
            doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.insert(section, at: insertIndex)
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        let insertIndex = max(0, min(index, doc.notes.areas[aIdx].notebooks[nbIdx].sections.count))
        doc.notes.areas[aIdx].notebooks[nbIdx].sections.insert(section, at: insertIndex)
    }

    // MARK: - Notes: sections + notes (rename / delete)

    func renameSection(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "Untitled" : trimmed

        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].title = finalTitle
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].title = finalTitle
    }

    func deleteSection(areaID: UUID, stackID: UUID?, notebookID: UUID, sectionID: UUID) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }
            guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.remove(at: secIdx)

            if doc.notes.selection.areaID == areaID &&
                doc.notes.selection.stackID == stackID &&
                doc.notes.selection.notebookID == notebookID &&
                doc.notes.selection.sectionID == sectionID {
                doc.notes.selection.sectionID = nil
                doc.notes.selection.noteID = nil
            }
            return
        }

        guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
        doc.notes.areas[aIdx].notebooks[nbIdx].sections.remove(at: secIdx)

        if doc.notes.selection.areaID == areaID &&
            doc.notes.selection.stackID == nil &&
            doc.notes.selection.notebookID == notebookID &&
            doc.notes.selection.sectionID == sectionID {
            doc.notes.selection.sectionID = nil
            doc.notes.selection.noteID = nil
        }
    }

    func deleteNote(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, noteID: UUID) {
        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return }

            // 1) Section note (stack)
            if let notebookID, let sectionID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
                guard let nIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.remove(at: nIdx)

                if doc.notes.selection.areaID == areaID,
                   doc.notes.selection.stackID == stackID,
                   doc.notes.selection.notebookID == notebookID,
                   doc.notes.selection.sectionID == sectionID,
                   doc.notes.selection.noteID == noteID {
                    doc.notes.selection.noteID = nil
                }
                return
            }

            // 2) Notebook root note (stack)
            if let notebookID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
                guard let nIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.remove(at: nIdx)

                if doc.notes.selection.areaID == areaID,
                   doc.notes.selection.stackID == stackID,
                   doc.notes.selection.notebookID == notebookID,
                   doc.notes.selection.sectionID == nil,
                   doc.notes.selection.noteID == noteID {
                    doc.notes.selection.noteID = nil
                }
                return
            }

            // 3) Stack root note
            guard let nIdx = doc.notes.areas[aIdx].stacks[sIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
            doc.notes.areas[aIdx].stacks[sIdx].notes.remove(at: nIdx)

            if doc.notes.selection.areaID == areaID,
               doc.notes.selection.stackID == stackID,
               doc.notes.selection.notebookID == nil,
               doc.notes.selection.sectionID == nil,
               doc.notes.selection.noteID == noteID {
                doc.notes.selection.noteID = nil
            }
            return
        }

        // Area-level
        if let notebookID, let sectionID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return }
            guard let nIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.remove(at: nIdx)

            if doc.notes.selection.areaID == areaID,
               doc.notes.selection.stackID == nil,
               doc.notes.selection.notebookID == notebookID,
               doc.notes.selection.sectionID == sectionID,
               doc.notes.selection.noteID == noteID {
                doc.notes.selection.noteID = nil
            }
            return
        }

        if let notebookID {
            guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
            guard let nIdx = doc.notes.areas[aIdx].notebooks[nbIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }

            doc.notes.areas[aIdx].notebooks[nbIdx].notes.remove(at: nIdx)

            if doc.notes.selection.areaID == areaID,
               doc.notes.selection.stackID == nil,
               doc.notes.selection.notebookID == notebookID,
               doc.notes.selection.sectionID == nil,
               doc.notes.selection.noteID == noteID {
                doc.notes.selection.noteID = nil
            }
            return
        }

        guard let nIdx = doc.notes.areas[aIdx].notes.firstIndex(where: { $0.id == noteID }) else { return }
        doc.notes.areas[aIdx].notes.remove(at: nIdx)

        if doc.notes.selection.areaID == areaID,
           doc.notes.selection.stackID == nil,
           doc.notes.selection.notebookID == nil,
           doc.notes.selection.sectionID == nil,
           doc.notes.selection.noteID == noteID {
            doc.notes.selection.noteID = nil
        }
    }

    // MARK: - Notes: CRUD by noteID

    private struct NoteLocator {
        let areaIndex: Int
        let stackIndex: Int?
        let notebookIndex: Int?
        let sectionIndex: Int?
        let noteIndex: Int
        let areaID: UUID
        let stackID: UUID?
        let notebookID: UUID?
        let sectionID: UUID?
    }

    private func locateNote(_ noteID: UUID) -> NoteLocator? {
        for (aIdx, area) in doc.notes.areas.enumerated() {

            // Area root notes
            if let nIdx = area.notes.firstIndex(where: { $0.id == noteID }) {
                return NoteLocator(
                    areaIndex: aIdx,
                    stackIndex: nil,
                    notebookIndex: nil,
                    sectionIndex: nil,
                    noteIndex: nIdx,
                    areaID: area.id,
                    stackID: nil,
                    notebookID: nil,
                    sectionID: nil
                )
            }

            // Area notebooks
            for (nbIdx, nb) in area.notebooks.enumerated() {
                if let nIdx = nb.notes.firstIndex(where: { $0.id == noteID }) {
                    return NoteLocator(
                        areaIndex: aIdx,
                        stackIndex: nil,
                        notebookIndex: nbIdx,
                        sectionIndex: nil,
                        noteIndex: nIdx,
                        areaID: area.id,
                        stackID: nil,
                        notebookID: nb.id,
                        sectionID: nil
                    )
                }

                for (secIdx, sec) in nb.sections.enumerated() {
                    if let nIdx = sec.notes.firstIndex(where: { $0.id == noteID }) {
                        return NoteLocator(
                            areaIndex: aIdx,
                            stackIndex: nil,
                            notebookIndex: nbIdx,
                            sectionIndex: secIdx,
                            noteIndex: nIdx,
                            areaID: area.id,
                            stackID: nil,
                            notebookID: nb.id,
                            sectionID: sec.id
                        )
                    }
                }
            }

            for (sIdx, stack) in area.stacks.enumerated() {
                // Stack root notes
                if let nIdx = stack.notes.firstIndex(where: { $0.id == noteID }) {
                    return NoteLocator(
                        areaIndex: aIdx,
                        stackIndex: sIdx,
                        notebookIndex: nil,
                        sectionIndex: nil,
                        noteIndex: nIdx,
                        areaID: area.id,
                        stackID: stack.id,
                        notebookID: nil,
                        sectionID: nil
                    )
                }

                for (nbIdx, nb) in stack.notebooks.enumerated() {
                    // Notebook root notes
                    if let nIdx = nb.notes.firstIndex(where: { $0.id == noteID }) {
                        return NoteLocator(
                            areaIndex: aIdx,
                            stackIndex: sIdx,
                            notebookIndex: nbIdx,
                            sectionIndex: nil,
                            noteIndex: nIdx,
                            areaID: area.id,
                            stackID: stack.id,
                            notebookID: nb.id,
                            sectionID: nil
                        )
                    }

                    // Section notes
                    for (secIdx, sec) in nb.sections.enumerated() {
                        if let nIdx = sec.notes.firstIndex(where: { $0.id == noteID }) {
                            return NoteLocator(
                                areaIndex: aIdx,
                                stackIndex: sIdx,
                                notebookIndex: nbIdx,
                                sectionIndex: secIdx,
                                noteIndex: nIdx,
                                areaID: area.id,
                                stackID: stack.id,
                                notebookID: nb.id,
                                sectionID: sec.id
                            )
                        }
                    }
                }
            }
        }
        return nil
    }

    @discardableResult
    func createNote(areaID: UUID, stackID: UUID?, notebookID: UUID?, sectionID: UUID?, title: String, body: String) -> UUID? {
        let ts = nowTS
        let note = NoteItem(id: UUID(), title: title, body: body, createdAt: ts, updatedAt: ts)

        guard let aIdx = doc.notes.areas.firstIndex(where: { $0.id == areaID }) else { return nil }

        if let stackID {
            guard let sIdx = doc.notes.areas[aIdx].stacks.firstIndex(where: { $0.id == stackID }) else { return nil }

            if let notebookID, let sectionID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                guard let secIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return nil }
                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].sections[secIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: sectionID, noteID: note.id)
            } else if let notebookID {
                guard let nbIdx = doc.notes.areas[aIdx].stacks[sIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                doc.notes.areas[aIdx].stacks[sIdx].notebooks[nbIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: notebookID, sectionID: nil, noteID: note.id)
            } else {
                doc.notes.areas[aIdx].stacks[sIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: stackID, notebookID: nil, sectionID: nil, noteID: note.id)
            }
        } else {
            if let notebookID, let sectionID {
                guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                guard let secIdx = doc.notes.areas[aIdx].notebooks[nbIdx].sections.firstIndex(where: { $0.id == sectionID }) else { return nil }
                doc.notes.areas[aIdx].notebooks[nbIdx].sections[secIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: notebookID, sectionID: sectionID, noteID: note.id)
            } else if let notebookID {
                guard let nbIdx = doc.notes.areas[aIdx].notebooks.firstIndex(where: { $0.id == notebookID }) else { return nil }
                doc.notes.areas[aIdx].notebooks[nbIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: notebookID, sectionID: nil, noteID: note.id)
            } else {
                doc.notes.areas[aIdx].notes.append(note)
                doc.notes.selection = NotesSelection(areaID: areaID, stackID: nil, notebookID: nil, sectionID: nil, noteID: note.id)
            }
        }

        doc.updatedAt = ts
        return note.id
    }

    @discardableResult
    func updateNote(noteID: UUID, title: String?, body: String?) -> Bool {
        guard let loc = locateNote(noteID) else { return false }
        let ts = nowTS

        if let stackIndex = loc.stackIndex {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex].notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex].notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex] = note
            } else if let nbIdx = loc.notebookIndex {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex].notebooks[nbIdx].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex].notebooks[nbIdx].notes[loc.noteIndex] = note
            } else {
                var note = doc.notes.areas[loc.areaIndex].stacks[stackIndex].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].stacks[stackIndex].notes[loc.noteIndex] = note
            }
        } else {
            if let nbIdx = loc.notebookIndex, let secIdx = loc.sectionIndex {
                var note = doc.notes.areas[loc.areaIndex].notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].notebooks[nbIdx].sections[secIdx].notes[loc.noteIndex] = note
            } else if let nbIdx = loc.notebookIndex {
                var note = doc.notes.areas[loc.areaIndex].notebooks[nbIdx].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].notebooks[nbIdx].notes[loc.noteIndex] = note
            } else {
                var note = doc.notes.areas[loc.areaIndex].notes[loc.noteIndex]
                if let title { note.title = title }
                if let body { note.body = body }
                note.updatedAt = ts
                doc.notes.areas[loc.areaIndex].notes[loc.noteIndex] = note
            }
        }

        doc.updatedAt = ts
        doc.notes.selection = NotesSelection(areaID: loc.areaID, stackID: loc.stackID, notebookID: loc.notebookID, sectionID: loc.sectionID, noteID: noteID)
        return true
    }

    @discardableResult
    func moveNoteByID(noteID: UUID, toAreaID: UUID, toStackID: UUID?, toNotebookID: UUID?, toSectionID: UUID?) -> Bool {
        guard let loc = locateNote(noteID) else { return false }
        moveNote(
            fromAreaID: loc.areaID,
            fromStackID: loc.stackID,
            fromNotebookID: loc.notebookID,
            fromSectionID: loc.sectionID,
            noteID: noteID,
            toAreaID: toAreaID,
            toStackID: toStackID,
            toNotebookID: toNotebookID,
            toSectionID: toSectionID
        )
        return true
    }

    @discardableResult
    func deleteNoteByID(noteID: UUID) -> Bool {
        guard let loc = locateNote(noteID) else { return false }
        deleteNote(areaID: loc.areaID, stackID: loc.stackID, notebookID: loc.notebookID, sectionID: loc.sectionID, noteID: noteID)
        return true
    }
}

// MARK: - Updated requestMessagesForCurrentChat with Tool Support

extension BoardStore {
    
    private func requestMessagesForCurrentChatWithTools(upTo messageIndex: Int) async -> [OllamaChatService.Message] {
        guard messageIndex > 0,
              doc.chat.messages.indices.contains(messageIndex - 1) else { return [] }

        // Only include the most recent message; Ollama keeps earlier turns in its own context.

        // 1) Snapshot (FAST, on MainActor): resolve URLs + mime types
        struct Snapshot: Sendable {
            struct ImageItem: Sendable { let url: URL; let mimeType: String }
            struct FileItem: Sendable { let url: URL; let filename: String; let mimeType: String }

            let role: String
            let content: String
            let images: [ImageItem]
            let files: [FileItem]
        }

        func mimeType(for ext: String, default fallback: String) -> String {
            switch ext.lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "heic": return "image/heic"
            case "pdf": return "application/pdf"
            case "txt": return "text/plain"
            case "swift": return "text/x-swift"
            case "py": return "text/x-python"
            case "js": return "text/javascript"
            case "json": return "application/json"
            case "xml": return "application/xml"
            case "html": return "text/html"
            case "css": return "text/css"
            case "csv": return "text/csv"
            case "md": return "text/markdown"
            case "doc", "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            case "xls", "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            default: return fallback
            }
        }

        let snapshots: [Snapshot] = [doc.chat.messages[messageIndex - 1]].compactMap { message in
            var images: [Snapshot.ImageItem] = []
            images.reserveCapacity(message.images.count)

            for imageRef in message.images {
                guard let url = imageURL(for: imageRef) else { continue }
                let ext = url.pathExtension
                let mt = mimeType(for: ext, default: "image/png")
                images.append(.init(url: url, mimeType: mt))
            }

            var files: [Snapshot.FileItem] = []
            files.reserveCapacity(message.files.count)

            for fileRef in message.files {
                guard let url = fileURL(for: fileRef) else { continue }
                let ext = url.pathExtension
                let mt = mimeType(for: ext, default: "application/octet-stream")
                files.append(.init(url: url, filename: fileRef.displayName, mimeType: mt))
            }

            return Snapshot(
                role: message.role.rawValue,
                content: message.text,
                images: images,
                files: files
            )
        }

        // 2) Heavy work OFF MainActor: Data(contentsOf:) + base64
        return await Task.detached(priority: .userInitiated) {
            return snapshots.map { snap in
                var imageData: [[String: String]] = []
                imageData.reserveCapacity(snap.images.count)

                for img in snap.images {
                    if let data = try? Data(contentsOf: img.url) {
                        imageData.append([
                            "type": "image",
                            "data": data.base64EncodedString(),
                            "mimeType": img.mimeType
                        ])
                    }
                }

                var fileData: [[String: String]] = []
                fileData.reserveCapacity(snap.files.count)

                for f in snap.files {
                    if let data = try? Data(contentsOf: f.url) {
                        fileData.append([
                            "type": "file",
                            "data": data.base64EncodedString(),
                            "mimeType": f.mimeType,
                            "filename": f.filename
                        ])
                    }
                }

                return OllamaChatService.Message(
                    role: snap.role,
                    content: snap.content,
                    images: imageData.isEmpty ? nil : imageData,
                    files: fileData.isEmpty ? nil : fileData
                )
            }
        }.value
    }
}

extension BoardStore {
    
    // MARK: - Modified Chat Reply with Async Tool Support
    
    /// Process chat replies with support for asynchronous tool execution
    private func processChatReply(forUserMessageID userMessageID: UUID) {
        chatReplyTask?.cancel()

        chatReplyTask = Task { @MainActor in
            let t_chatStart = CFAbsoluteTimeGetCurrent()
            print("TTFR(BoardStore) start processChatReply t=0")

            guard let userIndex = doc.chat.messages.firstIndex(where: { $0.id == userMessageID }) else {
                finishChatReply()
                return
            }
            guard doc.chat.messages[userIndex].role == .user else {
                finishChatReply()
                return
            }

            let assistantMessageID: UUID
            let assistantMessageIndex: Int
            var didInsertAssistantMessage = false

            if userIndex + 1 < doc.chat.messages.count,
               doc.chat.messages[userIndex + 1].role == .assistant {
                assistantMessageIndex = userIndex + 1
                assistantMessageID = doc.chat.messages[assistantMessageIndex].id
            } else {
                assistantMessageID = UUID()
                let now = Date().timeIntervalSince1970
                let assistantMessage = ChatMsg(
                    id: assistantMessageID,
                    role: .assistant,
                    text: "",
                    images: [],
                    files: [],
                    ts: now
                )
                assistantMessageIndex = userIndex + 1
                doc.chat.messages.insert(assistantMessage, at: assistantMessageIndex)
                didInsertAssistantMessage = true
            }
            if didInsertAssistantMessage {
                touch()
            }

            let t_buildStart = CFAbsoluteTimeGetCurrent()
            print("TTFR(BoardStore) building request messages...")

            let requestMessages = await requestMessagesForCurrentChatWithTools(upTo: assistantMessageIndex)
            
            var accumulated = ""
            var thinkingAccumulated = ""
            var detectedToolCall: ToolCall?

            let t_streamCall = CFAbsoluteTimeGetCurrent()
            var didLogFirstChunk = false

            do {
                try await self.chatService.stream(
                    model: self.chatModelName,
                    messages: requestMessages,
                    includeSystemPrompt: true
                ) { chunk in
                    if !didLogFirstChunk {
                        didLogFirstChunk = true
                    }
                    if let thinking = chunk.message?.thinking ?? chunk.thinking {
                        thinkingAccumulated += thinking
                        await MainActor.run {
                            self.chatThinkingText = thinkingAccumulated
                        }
                    }
                    
                    if detectedToolCall == nil, let toolCall = chunk.toolCall {
                        detectedToolCall = toolCall
                        print("DEBUG: Structured tool call detected: \(toolCall.name)")
                    }
                    
                    // Check for tool call in the streamed content (JSON format)
                    if detectedToolCall == nil {
                        if let toolCall = self.extractToolCall(from: accumulated) {
                            detectedToolCall = toolCall
                            print("DEBUG: JSON tool call detected: \(toolCall.name)")
                        }
                    }
                    
                    let delta = chunk.message?.content ?? ""
                    if !delta.isEmpty {
                        accumulated += delta
                        
                        // Check again after adding delta
                        if detectedToolCall == nil {
                            if let toolCall = self.extractToolCall(from: accumulated) {
                                detectedToolCall = toolCall
                            }
                        }
                        
                        // Don't display raw JSON tool calls to user
                        if !self.looksLikeToolCall(accumulated) {
                            await MainActor.run {
                                self.updateChatMessageText(id: assistantMessageID, text: accumulated)
                                if self.chatActivityStatus != nil {
                                    self.chatActivityStatus = nil
                                }
                            }
                        }
                    }
                }
                
                // If a tool was called, execute it asynchronously
                if let toolCall = detectedToolCall {
                    await self.handleAsyncToolCall(
                        toolCall: toolCall,
                        assistantMessageID: assistantMessageID,
                        previousMessages: requestMessages
                    )
                } else {
                    await MainActor.run {
                        self.finishChatReply()
                    }
                }
                
            } catch {
                if error is CancellationError {
                    await MainActor.run {
                        self.finishChatReply(canceled: true)
                    }
                } else {
                    await MainActor.run {
                        self.handleChatReplyError(for: assistantMessageID, error: error)
                    }
                }
            }
        }
    }
    
    // MARK: - Async Tool Call Handler
    
    /// Handle tool execution asynchronously with immediate user feedback
    private func handleAsyncToolCall(
        toolCall: ToolCall,
        assistantMessageID: UUID,
        previousMessages: [OllamaChatService.Message]
    ) async {
        // Extract the acknowledgment message from tool arguments
        let acknowledgment = toolCall.arguments["acknowledgment"] ?? "Let me look that up for you"
        
        // Immediately show the acknowledgment to the user
        await MainActor.run {
            self.updateChatMessageText(id: assistantMessageID, text: acknowledgment)
            self.chatActivityStatus = "Searching..."
        }
        
        // Kick off the search in the background
        Task {
            let toolResult = await ToolExecutor.execute(toolCall)
            
            // Once search completes, continue the conversation with results
            await self.processToolResults(
                toolResult: toolResult,
                toolCall: toolCall,
                assistantMessageID: assistantMessageID,
                previousMessages: previousMessages,
                acknowledgmentText: acknowledgment
            )
        }
    }
    
    // MARK: - Process Tool Results
    
    /// Process the results from an async tool execution
    private func processToolResults(
        toolResult: ToolResponse,
        toolCall: ToolCall,
        assistantMessageID: UUID,
        previousMessages: [OllamaChatService.Message],
        acknowledgmentText: String
    ) async {
        func finishWithFailure(_ message: String) async {
            await MainActor.run {
                self.updateChatMessageText(id: assistantMessageID, text: message)
                self.chatActivityStatus = nil
                self.finishChatReply()
            }
        }

        guard toolResult.success else {
            let errorMessage: String
            if let error = toolResult.error, error.contains("No internet connection") {
                errorMessage = acknowledgmentText + "\n\nI'm sorry, but I cannot perform a search right now because there's no internet connection available."
            } else {
                errorMessage = acknowledgmentText + "\n\nI encountered an error while searching: \(toolResult.error ?? "Unknown error")"
            }
            await finishWithFailure(errorMessage)
            return
        }

        await MainActor.run {
            self.chatActivityStatus = "Processing results..."
        }

        var conversation = previousMessages
        if !acknowledgmentText.isEmpty {
            conversation.append(
                OllamaChatService.Message(
                    role: "assistant",
                    content: acknowledgmentText
                )
            )
        }
        conversation.append(
            OllamaChatService.Message(
                role: "system",
                content: makeToolContextMessage(acknowledgment: acknowledgmentText, toolCall: toolCall),
                toolResults: [toolResult]
            )
        )

        var finalResponse = acknowledgmentText + "\n\n"
        var thinkingAccumulated = ""

        func runAnswerPass(extraSystemMessage: String?) async throws -> Bool {
            if let extraSystemMessage {
                conversation.append(
                    OllamaChatService.Message(
                        role: "system",
                        content: extraSystemMessage
                    )
                )
            }

            var detectedToolCall = false
            var detectionBuffer = ""
            var passDelta = ""

            try await self.chatService.stream(
                model: self.chatModelName,
                messages: conversation,
                includeSystemPrompt: false,
                includeTools: false
            ) { chunk in
                if let thinking = chunk.message?.thinking ?? chunk.thinking {
                    thinkingAccumulated += thinking
                    await MainActor.run {
                        self.chatThinkingText = thinkingAccumulated
                    }
                }

                if chunk.toolCall != nil {
                    detectedToolCall = true
                }

                let delta = chunk.message?.content ?? ""
                if !delta.isEmpty {
                    detectionBuffer += delta
                    if detectionBuffer.count > 4096 {
                        detectionBuffer = String(detectionBuffer.suffix(4096))
                    }

                    if !detectedToolCall,
                       let _ = self.extractToolCall(from: detectionBuffer) {
                        detectedToolCall = true
                    }

                    if !self.looksLikeToolCall(detectionBuffer) {
                        passDelta += delta
                        finalResponse += delta
                        await MainActor.run {
                            self.updateChatMessageText(id: assistantMessageID, text: finalResponse)
                            if self.chatActivityStatus != nil {
                                self.chatActivityStatus = nil
                            }
                        }
                    }
                }
            }

            if !passDelta.isEmpty {
                conversation.append(
                    OllamaChatService.Message(
                        role: "assistant",
                        content: passDelta
                    )
                )
            }

            return detectedToolCall && passDelta.isEmpty
        }

        do {
            let needsRetry = try await runAnswerPass(extraSystemMessage: nil)
            if needsRetry {
                _ = try await runAnswerPass(
                    extraSystemMessage: "Tool calls are disabled for this response. Answer directly using the provided search results."
                )
            }

            await MainActor.run {
                self.finishChatReply()
            }
        } catch {
            await MainActor.run {
                self.handleChatReplyError(for: assistantMessageID, error: error)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Extract tool call from accumulated text
    private func extractToolCall(from text: String) -> ToolCall? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") && trimmed.contains("\"tool_call\"") else {
            return nil
        }
        
        // Try to parse as JSON
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolCallDict = json["tool_call"] as? [String: Any],
              let id = toolCallDict["id"] as? String,
              let name = toolCallDict["name"] as? String,
              let argumentsDict = toolCallDict["arguments"] as? [String: Any] else {
            return nil
        }
        
        // Convert arguments to [String: String]
        var arguments: [String: String] = [:]
        for (key, value) in argumentsDict {
            arguments[key] = String(describing: value)
        }
        
        return ToolCall(id: id, name: name, arguments: arguments)
    }
    
    /// Check if accumulated text looks like a JSON tool call
    private func looksLikeToolCall(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.contains("\"tool_call\"")
    }

    /// Builds a contextual system prompt for the model based on the tool call
    private func makeToolContextMessage(acknowledgment: String, toolCall: ToolCall) -> String {
        """
        SEARCH RESULTS CONTEXT:
        You previously told the user: "\(acknowledgment)"

        Tool "\(toolCall.name)" (id: \(toolCall.id)) returned the search results below.
        Continue naturally from your prior reply using the information provided.
        Do NOT repeat yourself or restart the conversation.

        Search results are below:
        """
    }
}
