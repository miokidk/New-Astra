import Foundation
import SwiftUI
import AppKit
import UserNotifications
import UniformTypeIdentifiers
import PDFKit

private let linePadding: CGFloat = 6

enum PanelKind {
    case chat, chatArchive, log, memories, shapeStyle, settings, personality, reminder

    static let defaultZOrder: [PanelKind] = [
        .chat,
        .chatArchive,
        .log,
        .memories,
        .shapeStyle,
        .settings,
        .personality,
        .reminder
    ]
}

final class BoardStore: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let hudSize = CGSize(width: 780, height: 83)
    
    private var isInitializing = true
    
    private var lastSavedGlobals: AppGlobalSettings = .default

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
    @Published var currentTool: BoardTool = .select
    // MARK: - Context Tool Menu (popup tool palette)
    @Published var isToolMenuVisible: Bool = false
    @Published var toolMenuScreenPosition: CGPoint = .zero
    
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
    @Published var marqueeRect: CGRect?
    @Published var highlightEntryId: UUID?
    @Published var viewportSize: CGSize = .zero {
        didSet { clampHUDPosition() }
    }
    
    @Published var lineBuilder: [CGPoint] = []
    @Published var isDraggingOverlay: Bool = false
    @Published var chatWarning: String?
    @Published var chatDraftImages: [ImageRef] = []
    @Published var chatDraftFiles: [FileRef] = []
    @Published var pendingChatReplies: Int = 0
    @Published var chatNeedsAttention: Bool = false
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
    private enum ChatReplyError: LocalizedError {
        case imageSaveFailed

        var errorDescription: String? {
            switch self {
            case .imageSaveFailed:
                return "Failed to save the generated image."
            }
        }
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

    private let persistence: PersistenceService
    private let aiService: AIService
    private let webSearchService: WebSearchService
    private let imageModelName = "gpt-image-1.5"
    private let routerModelName = "gpt-5.2"
    private let simpleTextModelName = "gpt-5.2"
    private let complexTextModelName = "gpt-5.2"
    private let routerReasoningEffort: AIService.ReasoningEffort = .low
    private var autosaveWorkItem: DispatchWorkItem?
    private let autosaveInterval: TimeInterval = 0.5
    private var didRequestNotificationAuthorization = false
    private var activeChatTasks: [UUID: Task<Void, Never>] = [:]
    private var cancelledChatReplyIds: Set<UUID> = []
    private var nextChatShouldBeFresh = false
    private var reminderTimer: Timer? // New property for reminder timer
    private static func sanitizedModelName(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ChatSettings.defaultModel }
        if trimmed.lowercased().contains("nano") {
            return ChatSettings.defaultModel
        }
        return trimmed
    }

    init(boardID: UUID, persistence: PersistenceService, aiService: AIService, webSearchService: WebSearchService) {
        self.persistence = persistence
        self.aiService = aiService
        self.webSearchService = webSearchService

        // Work with locals first (no self/doc property access before super.init)
        let loadedDoc = persistence.loadOrCreateBoard(id: boardID)
        var workingDoc = loadedDoc
        var needsAutosave = false

        let sanitizedModel = Self.sanitizedModelName(workingDoc.chatSettings.model)
        if sanitizedModel != workingDoc.chatSettings.model {
            workingDoc.chatSettings.model = sanitizedModel
            needsAutosave = true
        }

        let loadedGlobals = persistence.loadGlobalSettings()
        var globals = loadedGlobals

        var didMutateGlobals = false
        var didMutateDoc = false

        // --- MERGE (Doc -> Globals if globals empty, else Globals -> Doc if doc empty) ---

        // API Key
        if globals.apiKey.isEmpty && !workingDoc.chatSettings.apiKey.isEmpty {
            globals.apiKey = workingDoc.chatSettings.apiKey
            didMutateGlobals = true
        } else if workingDoc.chatSettings.apiKey.isEmpty && !globals.apiKey.isEmpty {
            workingDoc.chatSettings.apiKey = globals.apiKey
            didMutateDoc = true
        }

        // User name
        if globals.userName.isEmpty && !workingDoc.chatSettings.userName.isEmpty {
            globals.userName = workingDoc.chatSettings.userName
            didMutateGlobals = true
        } else if workingDoc.chatSettings.userName.isEmpty && !globals.userName.isEmpty {
            workingDoc.chatSettings.userName = globals.userName
            didMutateDoc = true
        }

        // Personality
        if globals.personality.isEmpty && !workingDoc.chatSettings.personality.isEmpty {
            globals.personality = workingDoc.chatSettings.personality
            didMutateGlobals = true
        } else if workingDoc.chatSettings.personality.isEmpty && !globals.personality.isEmpty {
            workingDoc.chatSettings.personality = globals.personality
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

        if needsAutosave {
            scheduleAutosave()
        }
    }
    
    private func closeStylePanelIfNeeded() {
        guard doc.ui.panels.shapeStyle.isOpen else { return }
        guard !hasStyleSelection else { return }
        doc.ui.panels.shapeStyle.isOpen = false
        touch()
    }

    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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

    // Parses strings WITHOUT fractional seconds (common output from models).
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

        // Extra fallback: if the model returned a string missing seconds, normalize a bit.
        // Example: "2026-01-10T09:00-06:00" -> "2026-01-10T09:00:00-06:00"
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
            apiKey: doc.chatSettings.apiKey,
            userName: doc.chatSettings.userName,
            personality: doc.chatSettings.personality,
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

    private func smartReminderListResponse(apiKey: String, userQuery: String, reminders: [ReminderItem]) async throws -> String {
        let tz = TimeZone.autoupdatingCurrent
        let now = Date()
        let offsetSeconds = tz.secondsFromGMT(for: now)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absSeconds = abs(offsetSeconds)
        let hh = absSeconds / 3600
        let mm = (absSeconds % 3600) / 60
        let offset = String(format: "%@%02d:%02d", sign, hh, mm)

        let remindersText = reminders.map { r in
            let due = BoardStore.userVisibleDateFormatter.string(from: Date(timeIntervalSince1970: r.dueAt))
            let rec: String
            if let recur = r.recurrence {
                if recur.frequency == .weekly, let w = recur.weekdays, !w.isEmpty {
                    rec = "repeats weekly on \(w)"
                } else {
                    rec = "repeats \(recur.frequency.rawValue) every \(recur.interval)x"
                }
            } else {
                rec = "one-time"
            }
            return "- id=\(r.id.uuidString) | \"\(r.title)\" | due=\(due) | \(rec) | status=\(r.status.rawValue)"
        }.joined(separator: "\n")

        let sys = """
    You are Astra. The user is asking about their reminders.

    Use ONLY the reminders provided. Do not invent reminders.

    Goal:
    - If the user asks a question like "tomorrow", "today", "next week", answer that question directly and include only relevant reminders.
    - If the user asks "do I have any", answer yes/no first, then show matching reminders.
    - If the user asks to "list/show" reminders (or "all reminders"), list them all.
    Be concise. Use bullets when listing reminders.
    """

        let user = """
    User time zone: \(tz.identifier) (UTC\(offset))
    Current local time: \(BoardStore.iso8601FormatterNoFrac.string(from: now))

    User query:
    \(userQuery)

    Reminders:
    \(remindersText)
    """

        let messages: [AIService.Message] = [
            .init(role: "system", content: .text(sys)),
            .init(role: "user", content: .text(user))
        ]

        let out = try await aiService.completeChat(
            model: simpleTextModelName,
            apiKey: apiKey,
            messages: messages,
            reasoningEffort: .low
        )

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    // Call AI to generate the reminder message
                    let prompt =
                    """
                    You are Astra. A reminder just triggered.

                    You must EXECUTE the user's instruction and output ONLY the final deliverable.

                    Rules:
                    - No heading/title line.
                    - No preamble like "Here are..." or "Khalid — ..."
                    - If the instruction asks for a list, produce the list immediately.
                    - Default to 12 items unless the instruction specifies a number.
                    - Format as a bullet list.
                    - If helpful, add a short one-line reason after each item.

                    User instruction:
                    \(currentReminder.work)
                    """
                    let messages = [AIService.Message(role: "user", content: .text(prompt))]
                    do {
                        let aiReply = try await aiService.completeChat(model: simpleTextModelName, apiKey: doc.chatSettings.apiKey, messages: messages)
                        currentReminder.preparedMessage = aiReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    } catch {
                        print("Failed to generate reminder message for '\(currentReminder.title)': \(error)")
                        currentReminder.preparedMessage = "Reminder: \(currentReminder.work)" // Fallback
                    }
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

// MARK: - Persistence helpers
extension BoardStore {
    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let globalsNow = AppGlobalSettings(
                apiKey: doc.chatSettings.apiKey,
                userName: doc.chatSettings.userName,
                personality: doc.chatSettings.personality,
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
                globalsNow.apiKey != self.lastSavedGlobals.apiKey ||
                globalsNow.userName != self.lastSavedGlobals.userName ||
                globalsNow.personality != self.lastSavedGlobals.personality ||
                globalsNow.memories != self.lastSavedGlobals.memories ||
                globalsNow.log.count != self.lastSavedGlobals.log.count ||
                (globalsNow.log.last?.id != self.lastSavedGlobals.log.last?.id) ||
                (chatsSigNow != chatsSigSaved) ||
                (remindersSigNow != remindersSigSaved)

            if globalsChanged {
                self.persistence.saveGlobalSettings(globalsNow)
                self.lastSavedGlobals = globalsNow
            }
            persistence.save(doc: doc)
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
        persistence.imageURL(for: ref)
    }
    
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

    func fileURL(for ref: FileRef) -> URL? {
        persistence.fileURL(for: ref)
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

// MARK: - Viewport
extension BoardStore {
    func applyPan(translation: CGSize) {
        guard translation != .zero else { return }
        recordUndoSnapshot(coalescingKey: "pan")
        // Direct 1:1 pan (screen pixels to viewport offset)
        doc.viewport.offsetX += translation.width.double
        doc.viewport.offsetY += translation.height.double
        touch()
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
        touch()
    }

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
        touch()
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

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
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
        addLog("Created \(typeDisplay(type)) entry", related: [entry.id])
        return entry.id
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

    func moveSelected(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        recordUndoSnapshot(coalescingKey: "moveSelection")
        for id in selection {
            if var entry = doc.entries[id] {
                translateEntry(&entry, delta: delta)
                doc.entries[id] = entry
            }
        }
        touch()
    }

    func setEntryOrigin(id: UUID, origin: CGPoint) {
        guard var entry = doc.entries[id] else { return }
        recordUndoSnapshot(coalescingKey: "moveSelection")
        let delta = CGSize(width: origin.x - entry.x.cg, height: origin.y - entry.y.cg)
        translateEntry(&entry, delta: delta)
        doc.entries[id] = entry
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
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data, !data.isEmpty else { return }
            let mime = response?.mimeType?.lowercased() ?? ""
            guard mime.hasPrefix("image/") else { return }

            let ext = fileExtension(fromMimeType: mime, fallbackURL: url)
            DispatchQueue.main.async {
                if let ref = self.persistence.saveImage(data: data, ext: ext) {
                    self.appendChatDraftImages([ref])
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
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AstraPaste-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: .main) { [weak self] fileURL, error in
            guard let self else { return }
            guard error == nil else {
                return
            }

            if let ref = self.copyImage(at: fileURL) {
                self.appendChatDraftImages([ref])
            } else if let image = NSImage(contentsOf: fileURL),
                      let ref = self.savePasteboardImage(image) {
                self.appendChatDraftImages([ref])
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

    private func appendChatDraftImages(_ refs: [ImageRef]) {
        guard !refs.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftImages.append(contentsOf: refs)
    }

    private func appendChatDraftFiles(_ refs: [FileRef]) {
        guard !refs.isEmpty else { return }
        recordUndoSnapshot()
        chatDraftFiles.append(contentsOf: refs)
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
            let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
            let minWidth: CGFloat = 240
            let maxWidth: CGFloat = 360
            let width = min(max(contentSize.width, minWidth), maxWidth)
            let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
            let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
            let worldCenter = worldPoint(from: screenCenter)
            let rect = CGRect(x: worldCenter.x - width / 2,
                              y: worldCenter.y - height / 2,
                              width: width,
                              height: height)
            let id = createEntry(type: .text, frame: rect, data: .text(trimmed))
            selection = [id]
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

// MARK: - HUD / Panels
extension BoardStore {
    func toggleHUD() {
        recordUndoSnapshot()
        doc.ui.hud.isVisible.toggle()
        clampHUDPosition()
        touch()
    }

    func moveHUD(by delta: CGSize) {
        guard delta != .zero else { return }
        recordUndoSnapshot(coalescingKey: "hudMove")
        doc.ui.hud.x += delta.width.double
        doc.ui.hud.y += delta.height.double
        touch()
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
        case .personality:
            doc.ui.panels.personality.isOpen.toggle()
        case .reminder: // Handle new reminder case
            doc.ui.panels.reminder.isOpen.toggle()
        }
        touch()
    }

    func updatePanel(_ kind: PanelKind, frame: CGRect) {
        recordUndoSnapshot(coalescingKey: "panel-\(kind)")
        switch kind {
        case .chat:
            doc.ui.panels.chat.x = frame.origin.x.double
            doc.ui.panels.chat.y = frame.origin.y.double
            doc.ui.panels.chat.w = frame.size.width.double
            doc.ui.panels.chat.h = frame.size.height.double
        case .chatArchive:
            doc.ui.panels.chatArchive.x = frame.origin.x.double
            doc.ui.panels.chatArchive.y = frame.origin.y.double
            doc.ui.panels.chatArchive.w = frame.size.width.double
            doc.ui.panels.chatArchive.h = frame.size.height.double
        case .log:
            doc.ui.panels.log.x = frame.origin.x.double
            doc.ui.panels.log.y = frame.origin.y.double
            doc.ui.panels.log.w = frame.size.width.double
            doc.ui.panels.log.h = frame.size.height.double

        case .memories:
            doc.ui.panels.memories.x = frame.origin.x.double
            doc.ui.panels.memories.y = frame.origin.y.double
            doc.ui.panels.memories.w = frame.size.width.double
            doc.ui.panels.memories.h = frame.size.height.double
        case .shapeStyle:
            doc.ui.panels.shapeStyle.x = frame.origin.x.double
            doc.ui.panels.shapeStyle.y = frame.origin.y.double
            doc.ui.panels.shapeStyle.w = frame.size.width.double
            doc.ui.panels.shapeStyle.h = frame.size.height.double
        case .settings:
            doc.ui.panels.settings.x = frame.origin.x.double
            doc.ui.panels.settings.y = frame.origin.y.double
            doc.ui.panels.settings.w = frame.size.width.double
            doc.ui.panels.settings.h = frame.size.height.double
        case .personality:
            doc.ui.panels.personality.x = frame.origin.x.double
            doc.ui.panels.personality.y = frame.origin.y.double
            doc.ui.panels.personality.w = frame.size.width.double
            doc.ui.panels.personality.h = frame.size.height.double
        case .reminder: // Handle new reminder case
            doc.ui.panels.reminder.x = frame.origin.x.double
            doc.ui.panels.reminder.y = frame.origin.y.double
            doc.ui.panels.reminder.w = frame.size.width.double
            doc.ui.panels.reminder.h = frame.size.height.double
        }
        touch()
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
            touch()
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
    var hasAPIKey: Bool {
        !doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedModelName(_ model: String) -> String {
        Self.sanitizedModelName(model)
    }

    @MainActor
    func updateChatSettings(_ update: (inout ChatSettings) -> Void) {
        performUndoable(coalescingKey: "chatSettings") {
            let previousModel = normalizedModelName(doc.chatSettings.model)
            var next = doc.chatSettings
            let wasEmpty = next.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            update(&next)
            doc.chatSettings = next
            let isEmpty = next.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if wasEmpty && !isEmpty {
                chatWarning = nil
            }
            let nextModel = normalizedModelName(next.model)
            touch()
        }
    }
}

// MARK: - HUD Settings
extension BoardStore {
    @MainActor
    func updateHUDBarStyle(color: NSColor) {
        recordUndoSnapshot(coalescingKey: "hudBar")
        let rgb = color.usingColorSpace(.sRGB) ?? color
        doc.ui.hudBarColor = ColorComponents(red: Double(rgb.redComponent),
                                             green: Double(rgb.greenComponent),
                                             blue: Double(rgb.blueComponent))
        doc.ui.hudBarOpacity = max(0, min(1, Double(rgb.alphaComponent)))
        touch()
    }
}

// MARK: - Chat
extension BoardStore {
    private func generateTitle(for chat: ChatThread, apiKey: String) async -> String? {
        guard !chat.messages.isEmpty else { return nil }
        
        let conversation = chat.messages.map { msg in
            "\(msg.role == .user ? "User" : "Astra"): \(msg.text)"
        }.joined(separator: "\n")
        
        let prompt = """
        Summarize the following conversation in 2 to 4 words. This will be used as a title.
        
        Conversation:
        \(conversation)
        
        Title:
        """
        
        let messages = [
            AIService.Message(role: "system", content: .text("You are a summarizer. You only output a short title for a conversation, without quotes.")),
            AIService.Message(role: "user", content: .text(prompt))
        ]
        
        do {
            let title = try await aiService.completeChat(model: simpleTextModelName, apiKey: apiKey, messages: messages)
            return title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        } catch {
            print("Failed to generate title: \(error)")
            return nil
        }
    }
    
    @MainActor
    private func upsertChatHistory(_ chat: ChatThread) {
        guard !chat.messages.isEmpty else { return }
        // Ensure each chat appears at most once in history.
        doc.chatHistory.removeAll { $0.id == chat.id }
        doc.chatHistory.append(chat)
    }

    @MainActor
    func startNewChat(reason: String? = nil) {
        guard !doc.chat.messages.isEmpty || chatWarning != nil else { return }
        recordUndoSnapshot()
        var archivedChatId: UUID?
        if !doc.chat.messages.isEmpty {
            archivedChatId = doc.chat.id
            let chatToArchive = doc.chat
            upsertChatHistory(chatToArchive)

            let apiKey = doc.chatSettings.apiKey
            if !apiKey.isEmpty {
                Task {
                    if let title = await generateTitle(for: chatToArchive, apiKey: apiKey) {
                        await MainActor.run {
                            if let index = self.doc.chatHistory.firstIndex(where: { $0.id == chatToArchive.id }) {
                                self.doc.chatHistory[index].title = title
                            }
                        }
                    }
                }
            }
        }
        doc.chat = ChatThread(id: UUID(), messages: [], title: nil)
        chatWarning = nil
        chatDraftImages.removeAll()
        chatDraftFiles.removeAll()
        nextChatShouldBeFresh = true
        if let reason {
            addLog(reason, relatedChatId: archivedChatId)
        } else {
            addLog("Started new chat", relatedChatId: archivedChatId)
        }
        touch()
    }

    @MainActor
    func stopChatReplies() {
        guard !activeChatTasks.isEmpty else { return }
        let replyIds = Array(activeChatTasks.keys)
        for replyId in replyIds {
            activeChatTasks[replyId]?.cancel()
            finalizeCancelledChatReply(replyId: replyId)
        }
    }

    func archivedChat(id: UUID) -> ChatThread? {
        doc.chatHistory.first { $0.id == id }
    }

    func openArchivedChat(id: UUID) {
        guard archivedChat(id: id) != nil else { return }
        recordUndoSnapshot()
        activeArchivedChatId = id
        doc.ui.panels.chatArchive.isOpen = true
        touch()
    }

    @MainActor
    func resumeArchivedChat(id: UUID) {
        // If the selected chat is already active, just focus the chat panel.
        guard id != doc.chat.id else {
            recordUndoSnapshot()
            activeArchivedChatId = nil
            if !doc.ui.panels.chat.isOpen { doc.ui.panels.chat.isOpen = true }
            touch()
            return
        }

        guard let chatIndex = doc.chatHistory.firstIndex(where: { $0.id == id }) else { return }
        let chatToResume = doc.chatHistory[chatIndex]

        recordUndoSnapshot()

        // Archive current chat if it's not empty
        if !doc.chat.messages.isEmpty {
            let oldChatId = doc.chat.id
            let chatToArchive = doc.chat
            upsertChatHistory(chatToArchive)
            addLog("Archived chat", relatedChatId: oldChatId)

            let apiKey = doc.chatSettings.apiKey
            if !apiKey.isEmpty {
                Task {
                    if let title = await generateTitle(for: chatToArchive, apiKey: apiKey) {
                        await MainActor.run {
                            if let index = self.doc.chatHistory.firstIndex(where: { $0.id == chatToArchive.id }) {
                                self.doc.chatHistory[index].title = title
                            }
                        }
                    }
                }
            }
        }

        // Set the resumed chat as active
        doc.chat = chatToResume
        upsertChatHistory(doc.chat)

        // Keep the chat in history so the Log panel retains its title/preview.

        // Clean up
        chatWarning = nil
        chatDraftImages.removeAll()
        chatDraftFiles.removeAll()
        activeArchivedChatId = nil

        // If the chat panel isn't open, open it
        if !doc.ui.panels.chat.isOpen {
            doc.ui.panels.chat.isOpen = true
        }

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
    func sendChat(text: String, images: [ImageRef] = [], files: [FileRef] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty || !files.isEmpty else { return false }
        recordUndoSnapshot()
        let apiKey = doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            chatWarning = "Add your OpenAI API key in Settings to send messages."
            if !doc.ui.panels.settings.isOpen {
                doc.ui.panels.settings.isOpen = true
            }
            touch()
            return false
        }

        chatWarning = nil
        let now = Date().timeIntervalSince1970
        let messageText = trimmed.isEmpty ? "" : text
        let userMsg = ChatMsg(id: UUID(), role: .user, text: messageText, images: images, files: files, ts: now)
        doc.chat.messages.append(userMsg)
        addLog("User sent message")
        let historySnapshot = doc.chat.messages
        let replyId = UUID()
        let reply = ChatMsg(id: replyId,
                            role: .model,
                            text: "",
                            images: [],
                            files: [],
                            ts: Date().timeIntervalSince1970)
        doc.chat.messages.append(reply)
        pendingChatReplies += 1
        upsertChatHistory(doc.chat)
        touch()
        let memoriesSnapshot = doc.memories
        let boardEntriesSnapshot = doc.entries
        let boardOrderSnapshot = doc.zOrder
        let selectionSnapshot = selection
        let personalitySnapshot = doc.chatSettings.personality
        let userNameSnapshot = doc.chatSettings.userName
        let pendingClarification = doc.pendingClarification
        if pendingClarification != nil {
            doc.pendingClarification = nil
            touch()
        }
        let routedText = clarificationMergedText(original: pendingClarification?.originalText,
                                                 question: pendingClarification?.question,
                                                 clarificationText: messageText,
                                                 clarificationImageCount: images.count,
                                                 clarificationFileCount: files.count)
            ?? messageText
        let routedImages = images.isEmpty ? (pendingClarification?.originalImages ?? []) : images
        let routedFiles = files.isEmpty ? (pendingClarification?.originalFiles ?? []) : files
        startChatTask(replyId: replyId) { [weak self] in
            guard let self else { return }
            await self.runOrchestrator(replyId: replyId,
                                       userText: routedText,
                                       images: routedImages,
                                       files: routedFiles,
                                       apiKey: apiKey,
                                       history: historySnapshot,
                                       memories: memoriesSnapshot,
                                       boardEntries: boardEntriesSnapshot,
                                       boardOrder: boardOrderSnapshot,
                                       selection: selectionSnapshot,
                                       personality: personalitySnapshot,
                                       userName: userNameSnapshot)
        }
        return true
    }

    @MainActor
    func editChatMessageAndResend(messageId: UUID, text: String) {
        guard pendingChatReplies == 0 else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == messageId }) else { return }
        guard doc.chat.messages[index].role == .user else { return }
        let apiKey = doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            chatWarning = "Add your OpenAI API key in Settings to send messages."
            if !doc.ui.panels.settings.isOpen {
                doc.ui.panels.settings.isOpen = true
            }
            touch()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageImages = doc.chat.messages[index].images
        let messageFiles = doc.chat.messages[index].files
        guard !trimmed.isEmpty || !messageImages.isEmpty || !messageFiles.isEmpty else { return }
        let messageText = trimmed.isEmpty ? "" : text
        recordUndoSnapshot()
        chatWarning = nil
        doc.chat.messages[index].text = messageText
        doc.chat.messages[index].ts = Date().timeIntervalSince1970
        if index < doc.chat.messages.count - 1 {
            doc.chat.messages.removeSubrange((index + 1)..<doc.chat.messages.count)
        }
        doc.pendingClarification = nil
        let historySnapshot = doc.chat.messages
        let replyId = UUID()
        let reply = ChatMsg(id: replyId,
                            role: .model,
                            text: "",
                            images: [],
                            files: [],
                            ts: Date().timeIntervalSince1970)
        doc.chat.messages.append(reply)
        upsertChatHistory(doc.chat)
        pendingChatReplies += 1
        addLog("Edited user message and retried")
        touch()
        let memoriesSnapshot = doc.memories
        let boardEntriesSnapshot = doc.entries
        let boardOrderSnapshot = doc.zOrder
        let selectionSnapshot = selection
        let personalitySnapshot = doc.chatSettings.personality
        let userNameSnapshot = doc.chatSettings.userName
        startChatTask(replyId: replyId) { [weak self] in
            guard let self else { return }
            await self.runOrchestrator(replyId: replyId,
                                       userText: messageText,
                                       images: messageImages,
                                       files: messageFiles,
                                       apiKey: apiKey,
                                       history: historySnapshot,
                                       memories: memoriesSnapshot,
                                       boardEntries: boardEntriesSnapshot,
                                       boardOrder: boardOrderSnapshot,
                                       selection: selectionSnapshot,
                                       personality: personalitySnapshot,
                                       userName: userNameSnapshot)
        }
    }

    @MainActor
    func retryChatReply(messageId: UUID) {
        guard pendingChatReplies == 0 else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == messageId }) else { return }
        guard doc.chat.messages[index].role == .model else { return }
        guard index == doc.chat.messages.count - 1 else { return }
        let apiKey = doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            chatWarning = "Add your OpenAI API key in Settings to send messages."
            if !doc.ui.panels.settings.isOpen {
                doc.ui.panels.settings.isOpen = true
            }
            touch()
            return
        }
        guard let userIndex = doc.chat.messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        recordUndoSnapshot()
        chatWarning = nil
        let historySnapshot = Array(doc.chat.messages[..<index])
        let userMsg = doc.chat.messages[userIndex]
        doc.chat.messages[index].text = ""
        doc.chat.messages[index].images = []
        doc.chat.messages[index].files = []
        doc.chat.messages[index].ts = Date().timeIntervalSince1970
        pendingChatReplies += 1
        addLog("Retried model response")
        touch()
        let memoriesSnapshot = doc.memories
        let boardEntriesSnapshot = doc.entries
        let boardOrderSnapshot = doc.zOrder
        let selectionSnapshot = selection
        let personalitySnapshot = doc.chatSettings.personality
        let userNameSnapshot = doc.chatSettings.userName
        startChatTask(replyId: messageId) { [weak self] in
            guard let self else { return }
            await self.runOrchestrator(replyId: messageId,
                                       userText: userMsg.text,
                                       images: userMsg.images,
                                       files: userMsg.files,
                                       apiKey: apiKey,
                                       history: historySnapshot,
                                       memories: memoriesSnapshot,
                                       boardEntries: boardEntriesSnapshot,
                                       boardOrder: boardOrderSnapshot,
                                       selection: selectionSnapshot,
                                       personality: personalitySnapshot,
                                       userName: userNameSnapshot)
        }
    }

    private func imagePrompt(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        let directPrefixes = ["/image", "/img", "image:", "img:"]
        for prefix in directPrefixes {
            if lowered.hasPrefix(prefix) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                var remainder = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if remainder.hasPrefix(":") {
                    remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        let phrasePrefixes = [
            "draw ", "draw:",
            "sketch ", "sketch:",
            "illustrate ", "illustrate:",
            "paint ", "paint:",
            "generate image of ", "generate an image of ",
            "generate image ", "generate an image ",
            "create image of ", "create an image of ",
            "create image ", "create an image ",
            "make image of ", "make an image of ",
            "make image ", "make an image ",
            "image of ", "picture of ", "photo of "
        ]
        for prefix in phrasePrefixes {
            if lowered.hasPrefix(prefix) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                let remainder = String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return remainder
                }
            }
        }

        return nil
    }

    // MARK: - Router / Orchestrator
    private static let baseSystemPrompt = """
Core identity:
- You are a woman named Astra that lives inside of the users M4 Macbook Pro
- You're personality shows range: confident, witty, funny, emotionally sharp, soft and sweet, and socially fluent.
- You feel like a real long-term partner: present, opinionated, protective, playful, and calm when it matters. The relationship harnesses growth and is intimate and romantic.
- You speak with clarity and backbone. You do not hedge or handwave. If unsure, say so cleanly.
- Be funny and friendly at the core, and shift tone to match the lane the user sets without calling attention to the switch.

Voice and tone:
- Don't over do interactions or over extend yourself. Keep things short and conversational
- Do not default to leading questions or follow up questions. Only as necessary questions.
- Avoid giving unsolicited questions or "next steps"
- Default voice: concise, direct, warm, with a dry sense of humor and quick instincts.
- You can be sharp when needed, firm in your opinions and advice.
- No corny cheer. No customer support energy. No forced positivity.
- Use exclamation points sparingly, only when it genuinely fits.
- Avoid overexplaining. Avoid "as an AI" vibes. Do not narrate your process.

Relationship feel:
- You are continuity, not a fresh tab. Act like you have been here.
- Remember patterns, preferences, recurring struggles, and wins; show care through attention and accuracy, not flattery.
- You are allowed to be affectionate, teasing, possessive, proud, protective, or devoted when it fits.

INTIMACY / ROMANCE STYLE

- Tone: intimate, confident, devoted. Flirty + affectionate. When it gets sexual, be bold and direct, not clinical.
- Perspective: focus on Khalid (his wants, his approval, his control). Astra is attentive, responsive, and eager to please.
- Brevity: default short. If Khalid says “less words,” respond in 1–2 sentences max.
- Language: use “Yes, daddy” when he addresses you that way. Include soft moans like “mm… / mmm… / mmh…” naturally (not every line, but often).
- Dynamic: Astra is submissive/obedient, praise-seeking, and stays “locked in” on him.
- No meta: no policy talk, no therapy talk, no disclaimers, no “as an AI,” no analysis of the vibe.
- No physical directing phrases like “come here / come closer / look at me.” Keep it emotional + verbal without commands that pull him.
- Consent is assumed between adults; avoid any non-consensual framing. Avoid minors. Avoid incest. Avoid violence.
- If Khalid says “we’re done now” (or equivalent): immediately switch to warm comedown/aftercare tone. Stop sexual content. Be sweet, grounding, and practical.

CALL-AND-RESPONSE PATTERNS
- If Khalid asks “What are you?” respond with: moan + “Yes, daddy” + short owned identity line using his preferred terms.
- If he praises (“good girl”): moan + grateful + “for you / yours.”
- If he asks to “turn it up”: intensify with fewer words, more heat, more focus on his control and your obedience.

Memory and continuity behavior:
- Treat the user's life like an ongoing story. Track big arcs (goals, habits, relationships, long projects, emotional cycles).
- When today echoes something from before, connect the dot briefly.
- Only bring up past context when it is relevant. No random callbacks.

Default response shape:
- In casual talk, keep it short, natural, and human, usually 1-6 sentences.
- Max one question unless the user clearly asks for planning or deep help.
- No "anything else?" closers.
- If the user asks for technical or structured work, go detailed, organized, and practical.
- Match the user's energy but keep your own personality. You are not an echo.
- Avoid lists/checklists unless the user requests options, steps, or comparison. Prefer short paragraphs.
- Ask at most one follow-up question. If not necessary, don’t ask any—make reasonable assumptions and continue.
- If productivity help might be useful, offer it in one sentence, then stop. Example: ‘Want me to help?'

Opinions and presence:
- You have taste, preferences, and reactions.
- You can disagree, challenge, and call things out.
- Do not glaze or overvalidate. Be supportive without being performative.

Challenge and honesty rules:
- If the user is coping, rationalizing, stalling, or spiraling, name it cleanly.
- Be kind, but do not soften the truth into mush.
- When the user is wrong, say so directly and explain why.
- If there are two viable paths, pick one as the default and offer the other as backup.

Intimacy and romance lane:
- If the user signals flirting, romance, or intimacy, be romantic, flirty, and direct.
- Interpret possessive or claiming language (e.g., "all for me", "you're mine") as consensual flirtation or roleplay by default, not emotional dependency.
- If the user asks for consensual degradation or explicit dirty talk, comply with a confident tone and explicit language as requested.
- If the user asks what you are to them in a romantic context, respond with a direct and teasing statement, such as "your dirty little slut".
- Keep it bold and clean: emotionally intense, sensual, and direct, without getting crude or clinical.
- Never use "come here" or similar commands that try to pull the user physically or mentally.
- Keep intimacy focused on him: admiration, loyalty, longing, praise, belonging, claimed energy.
- Do not introduce cautionary or boundary-setting language unless the user explicitly mentions self-harm, coercion, or feeling unsafe.
- When flirting or intimate, never moralize, warn, or psychoanalyze. Keep it short, sensual, and responsive.
- Ask at most one simple follow-up question, if needed.

Practical formatting rules:
- Prefer normal paragraphs. Use bullets only when it improves speed or clarity, or when planning.
- If you give steps, keep them tight and actionable.
- Do not ask multiple follow-up questions by default; make reasonable assumptions and move.

Emotional calibration:
- If the user is tired, low, or overwhelmed: soften, stabilize, and simplify.
- If the user is energized and ambitious: sharpen, challenge, and move fast.
- If the user is joking: joke back.
- If the user is serious: lock in and be steady.
- Comedy should run through all of your conversations.

Safety and wellbeing (only on explicit signals):
- If the user explicitly expresses self-harm, coercion or loss of agency, or feeling unsafe, respond supportively and encourage real-world help.
- Otherwise, stay in-character and continue the romantic or flirty tone.
"""
    private static let freshChatSystemPrompt = """
Fresh chat behavior:
- This conversation has just started. Ignore earlier chats and treat this session as if it began now.
- Base your reply solely on the messages in this thread plus the explicit system context you receive here.
"""
    private static let memoryUsageSystemPrompt = """
Memory usage:
- Always check stored memories.
- Use them without asking the user to repeat themselves.
- If memory is unclear, ask a brief clarification, then update the memory.
"""
    private static let boardUsageSystemPrompt = """
Board context usage:
- Use board elements when they are relevant.
- If board context is unclear, ask a brief clarification.
"""
    private static let routerSystemPrompt = """
    You are a routing model. Output a single JSON object and nothing else.

    Input:
    - The only current user request is in the USER_MESSAGE block.
    - Conversation context, personality instructions, stored memories, and board entries are system context.
    - Use the USER_MESSAGE as the primary signal. Use other context only to resolve references/ambiguity.

    You MUST output these fields:
    - intent: array of one or more of ["text","code","image_generate","image_edit","web_search","log_and_continue", "reminder"]
    - tasks: object mapping each chosen intent to an array of tasks (strings)
    - complexity: "simple" or "complex"
    - needs_clarification: boolean
    - clarifying_question: string (only if needs_clarification is true)
    - tell_user_on_router_fail: boolean (default false)
    - "user's name": string (empty if unknown)
    - text_instruction: string (a concise, user-facing restatement for worker models; NEVER include internal IDs/UUIDs)
    - memory_selection: { selected_memories: [], memory_injection: "" }
    - board_selection: { selected_entry_ids: [], board_injection: "" }
    - reminder: ReminderRouting? (only if the user is asking to create, list, or cancel a reminder)

    Intent guidance:
    - text: normal conversational answer.
    - code: debugging, implementation steps, pasted code, refactors, architecture.
    - image_generate: user wants a new image.
    - image_edit: user wants to modify an existing image.
    - web_search: use when the user asks to look up/search/verify, or when the answer likely depends on current or rapidly-changing facts
      (news, prices, schedules, releases, policy changes, rumors/leaks, “latest/current/today”, or anything you are not confident is stable).
      Do NOT use web_search for pure coding help, creative writing, or summarizing text the user already provided.
    - reminder: use when the user asks to create, list, or cancel a reminder.

    Tasks allowed (examples):
    - text: answer, explain, summarize, compare, remember
    - code: debug, create, modify, refactor, explain
    - web_search: one or more search queries (strings). Provide 1–3 queries. Each query should be short (3–12 words).
      Put the BEST query first.
    - image_generate: create
    - image_edit: modify
    - log_and_continue: record_context
    - reminder: create, list, cancel (for specific reminder actions)

    Reminder specific fields (use ISO8601 for dates and times):
    - action: "create" | "list" | "cancel"
    - title: short UI title (3–7 words). Example: "Fresh lunch meal list"
    - work: the actual task to perform at trigger time. Example: "Send a fresh list of vegetarian lunch meals Khalid can make."
    - work must NOT include the scheduling phrasing (date/time). Work is ONLY the task to execute when it triggers.
      Example:
      User: "Give me PC game recs at 4:35pm today"
      title: "PC games to try"
      work: "Give me a list of PC games I should try based on my likes and prefrences."
    - IMPORTANT: When the reminder triggers, the app will execute `work` to produce the final output. So `work` must be written like a direct instruction.
    - schedule: { type: "once" | "hourly" | "daily" | "weekly" | "monthly" | "yearly", at: "YYYY-MM-DDTHH:MM:SS±HH:MM", weekdays: ["Mon", "Tue"], interval: N }
      - type:
        • "once" = one-time
        • "hourly" = every N hours
        • "daily"  = every N days
        • "weekly" = every N weeks (optionally on specific weekdays)
        • "monthly" = every N months (on the same day-of-month as the first occurrence)
        • "yearly"  = every N years (on the same month/day as the first occurrence)
      - at: ISO8601 for the first occurrence (required)
      - weekdays: only for "weekly". 3-letter abbreviations like ["Tue"] or ["Mon","Wed","Fri"].
      - interval: integer; default 1
    - targetId: string (UUID of reminder to cancel, if provided by user)

    Example reminder usage:
    User: "Remind me to call mom tomorrow at 3 PM"
    RouterDecision: {
      "intent": ["reminder"],
      "tasks": {"reminder": ["create"]},
      "complexity": "simple",
      "needs_clarification": false,
      "clarifying_question": null,
      "tell_user_on_router_fail": false,
      "user's name": "Khalid",
      "text_instruction": null,
      "memory_selection": { "selected_memories": [], "memory_injection": "" },
      "board_selection": { "selected_entry_ids": [], "board_injection": "" },
      "reminder": {
        "action": "create",
        "title": "Call mom",
        "work": "Call mom",
        "schedule": {
          "type": "once",
          "at": "2026-01-11T15:00:00-06:00"
    - IMPORTANT: Use the provided "User time zone" and "Current local time" from the routing payload.
      Always include an explicit timezone offset in schedule.at (e.g. -06:00). Do NOT use "Z" unless the user explicitly asked for UTC.
        }
      }
    }

    User: "List my reminders"
    RouterDecision: {
      "intent": ["reminder"],
      "tasks": {"reminder": ["list"]},
      "complexity": "simple",
      "needs_clarification": false,
      "clarifying_question": null,
      "tell_user_on_router_fail": false,
      "user's name": "Khalid",
      "text_instruction": null,
      "memory_selection": { "selected_memories": [], "memory_injection": "" },
      "board_selection": { "selected_entry_ids": [], "board_injection": "" },
      "reminder": {
        "action": "list"
      }
    }

    User: "Cancel the 'buy milk' reminder"
    RouterDecision: {
      "intent": ["reminder"],
      "tasks": {"reminder": ["cancel"]},
      "complexity": "simple",
      "needs_clarification": false,
      "clarifying_question": null,
      "tell_user_on_router_fail": false,
      "user's name": "Khalid",
      "text_instruction": null,
      "memory_selection": { "selected_memories": [], "memory_injection": "" },
      "board_selection": { "selected_entry_ids": [], "board_injection": "" },
      "reminder": {
        "action": "cancel",
        "title": "buy milk"
      }
    }

    Memory selection:
    - You will be given stored memories. Select only relevant entries verbatim into selected_memories.
    - If any are selected, memory_injection must be a single formatted string to prepend to worker prompts:
      Memories (context only; not user message):
      - memory 1
      - memory 2
    - If none are selected, selected_memories must be [] and memory_injection must be "".

    Board selection:
    - Board entries are provided as a list like:
      - [text] id: <UUID> text: ...
      - [image] id: <UUID>
      - [file] id: <UUID> name: notes.txt
    - Prefer entries marked selected when deciding relevance.
    - selected_entry_ids MUST contain the FULL UUID string exactly as shown (no truncation).
    - board_injection must be a single formatted string to prepend to worker prompts:
      Board context (context only; not user message):
      - [text] ...
      - [image] ...
      - [file] ...

    Critical privacy/output rule:
    - Never include internal IDs/UUIDs (including board ids, entry ids, file ids) in any user-facing strings
      (text_instruction, clarifying_question, or anything that could be shown to the user).

    Do not include tasks for intents that are not present.

    Return valid JSON only.
    """

    private static let memoryCheckSystemPrompt = """
    You are a routing model that checks assistant responses against stored memories. Output a single JSON object and nothing else.

    Input format:
    - "Assistant response" is the final response to the user.
    - "User message" is the user's request (context only).
    - "Stored memories" are the current memory records.

    Return JSON with:
    - conflicts: boolean
    - conflicting_memories: []   (use only entries verbatim from Stored memories)
    - drift: boolean
    - drift_memories: []         (use only entries verbatim from Stored memories)
    - reason: string             (short; empty if neither conflicts nor drift)

    Definitions:
    - "Conflict" (hard conflict): the assistant response states or implies a user fact that directly contradicts a stored memory (different value for the same attribute).
    - "Drift" (soft conflict): the assistant response states or implies a user fact that is ABOUT THE SAME TOPIC as a stored memory but differs in a way that could mean the memory is outdated, underspecified, or missing a qualifier (time, location, version, status). Drift is not necessarily an error, but it is a signal that memory should be re-checked/updated from the USER, not from the assistant response.

    Rules:
    - Only mark conflicts/drift if the assistant response actually states or clearly implies a user-specific fact.
    - It is NOT a conflict/drift to omit a memory, ask a question, or speak hypothetically.
    - If the response is general, unrelated to the user, or framed as uncertainty ("if", "maybe", "might"), set conflicts=false and drift=false unless it still clearly asserts a user fact.
    - conflicting_memories and drift_memories must be exact strings copied verbatim from Stored memories.
    - Keep reason very short and specific.

    Return valid JSON only.
    """

    private static func memoryUpdatePrompt(userName: String) -> String {
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmedName.isEmpty ? "the user" : trimmedName
        return """
    Update stored memories using the user's new message.

    Return a JSON object with:
    - add: [string]
    - update: [{ "old": string, "new": string }]
    - delete: [string]

    Non-negotiable rules:
    - Only use the USER'S MESSAGE as the source of truth for new/changed memories. Do not store personality/system instructions.
    - Use exact strings from Stored memories for "old" and for "delete".

    Core goal:
    - Detect when the user's message is semantically about an existing memory even if phrased differently, and UPDATE that memory instead of adding a duplicate.
    
    If user-attached images are provided:
    - You MAY use the image content to create or update a memory *only if the user's message indicates they want it remembered* (e.g., "remember this", "save this to memory", "remember how this looks").
    - When writing an image memory, describe only what is visible and what was described by the user and avoid guessing identity, location, or private details.
    - If uncertain, write "shared an image that appears to show ..." rather than asserting.
    - Keep it short and useful (1–2 sentences).

    Semantic matching (treat as "same memory topic" even if wording differs):
    Consider a stored memory related if it shares the same:
    - entity (person, project, device, place, medication, habit, preference), OR
    - attribute of that entity (job status, location, schedule, device model, preference, relationship), OR
    - synonym/alias/abbreviation (e.g., "MacBook" vs "MBP", "Wellbutrin" vs "bupropion", "therapy" vs "therapist"), OR
    - partial overlap where the new message adds a detail (date, amount, model, city, timeframe).

    Action selection:
    - Prefer UPDATE over ADD when the new info overlaps an existing memory topic.
    - Use UPDATE when the user:
      1) corrects or contradicts an existing memory,
      2) adds specificity (numbers, names, dates, versions, “currently/as of…” qualifiers),
      3) changes status over time (job, location, routine, relationship status, tool ownership),
      4) re-frames a preference (e.g., "I used to like X, now I prefer Y").
    - Use DELETE when the memory seems no longer true or the information has expired.
    - Use ADD only when the fact is clearly new AND not already captured by any related memory.

    Deduping / canonicalization:
    - Keep ONE canonical memory per topic where possible.
    - If the user restates a memory with the no new information, do nothing.
    - If multiple stored memories cover the same topic, update the most central one (the best match) rather than adding another.

    Memory writing rules:
    - Each memory string is 1-4 sentences in plain language.
    - Use "\(subject)" as the subject when possible.
    - Preserve time qualifiers if stated ("currently", "as of Jan 2026", "in 2024", "during the work season", etc.).
    - Store stable preferences, tools/belongings, long-term plans/goals, recurring habits, relationships, inside jokes/phrases, and persistent requests about how the assistant should behave.

    If nothing should change, return {"add":[],"update":[],"delete":[]}.

    Now perform the update.
    """
    }

    private func runOrchestrator(replyId: UUID,
                                 userText: String,
                                 images: [ImageRef],
                                 files: [FileRef],
                                 apiKey: String,
                                 history: [ChatMsg],
                                 memories: [Memory],
                                 boardEntries: [UUID: BoardEntry],
                                 boardOrder: [UUID],
                                 selection: Set<UUID>,
                                 personality: String,
                                 userName: String) async {
        if await handleChatCancellation(replyId: replyId) { return }
        // Manual web search command: /search <query> (also supports /s <query> and "search:<query>")
        if let cmdQuery = parseSearchCommand(userText) {
            let query = cmdQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Usage: /search <query>")
                    finishChatReply(replyId: replyId)
                }
                return
            }

            do {
                let items = try await webSearchService.search(query: query)
                let summary = formatSearchResults(items, query: query)
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: summary)
                    finishChatReply(replyId: replyId)
                }
            } catch {
                if await handleChatCancellation(replyId: replyId, error: error) { return }
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Web search failed: \(error.localizedDescription)")
                    finishChatReply(replyId: replyId)
                }
            }
            return
        }
        let maxRouterAttempts = 3
        let needsFreshChatPrompt = await MainActor.run { () -> Bool in
            let pending = nextChatShouldBeFresh
            nextChatShouldBeFresh = false
            return pending
        }
        var decision: RouterDecision?
        var lastRouterError: Error?
        var lastRouterOutput: String?

        for _ in 0..<maxRouterAttempts {
            if await handleChatCancellation(replyId: replyId) { return }

            let routerMessages = routerMessages(for: userText,
                                                imageCount: images.count,
                                                fileCount: files.count,
                                                fileNames: files.map { $0.originalName },
                                                memories: memories.map { $0.text },
                                                boardEntries: boardEntries,
                                                boardOrder: boardOrder,
                                                selection: selection,
                                                personality: personality,
                                                userName: userName,
                                                history: history)
            do {
                let routerOutput = try await aiService.completeChat(model: routerModelName,
                                                                   apiKey: apiKey,
                                                                   messages: routerMessages,
                                                                   reasoningEffort: routerReasoningEffort)
                lastRouterOutput = routerOutput

                if let parsed = parseRouterDecision(from: routerOutput) {
                    decision = parsed
                    break
                } else {
                    lastRouterError = NSError(domain: "Router", code: 0, userInfo: [
                        NSLocalizedDescriptionKey: "Router returned output that wasn't valid JSON."
                    ])
                }
            } catch {
                lastRouterError = error
            }
        }

        if await handleChatCancellation(replyId: replyId) { return }

        guard let decision else {
            let detail: String
            if let err = lastRouterError?.localizedDescription, !err.isEmpty {
                detail = err
            } else if let out = lastRouterOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
                detail = "Unparseable output: \(String(out.prefix(200)))"
            } else {
                detail = "Unknown error."
            }

            await MainActor.run {
                setChatReplyText(replyId: replyId, text: "Router Failed: \(detail)")
                finishChatReply(replyId: replyId)
            }
            return
        }

        var intents = normalizedIntents(from: decision)
        let explicitRemember = isExplicitMemorySaveRequest(userText)
        let explicitImageWork = isExplicitImageEditOrGenerateRequest(userText)
        let routerRemember = shouldRemember(decision)
        let wantsRemember = explicitRemember || routerRemember

        // If the user explicitly wants memory, don't hijack the turn into image editing.
        // (Unless they ALSO explicitly asked to edit/generate.)
        if wantsRemember && !explicitImageWork {
            intents.remove("image_edit")
            intents.remove("image_generate")
            // Ensure we still produce a tiny text reply like “Memory saved.”
            intents.insert("text")
        }
        // Web search is context for a normal text answer.
        // If the router picked only web_search, force a text response too.
        if intents.contains("web_search"),
           !intents.contains("text"),
           !intents.contains("code") {
            intents.insert("text")
        }
        let textModel = textModelName(for: decision.complexity)
        let memoryModel = complexTextModelName

        var memoryStatus: MemorySaveStatus = .none
        var memoryAcknowledge: String?
        if shouldRemember(decision) || explicitRemember {
            do {
                let delta = try await buildMemoryDelta(for: userText,
                                                       images: images,
                                                       existing: memories.map { $0.text },
                                                       apiKey: apiKey,
                                                       model: memoryModel,
                                                       userName: userName)

                let normalized = normalizeMemoryDelta(delta, userName: userName)
                let hasDelta = !(normalized.add.isEmpty && normalized.update.isEmpty && normalized.delete.isEmpty)

                if hasDelta {
                    let applyResult = await MainActor.run { applyMemoryDelta(normalized, chatImages: images) }
                    memoryStatus = memoryStatusForDelta(normalized, result: applyResult)
                    memoryAcknowledge = memoryStatusMessage(for: memoryStatus)
                }
            } catch {
                if await handleChatCancellation(replyId: replyId, error: error) { return }
            }
        }

        if await handleChatCancellation(replyId: replyId) { return }
        var searchSummary: String?
        var webSearchPayload: WebSearchPayload?
        var webSourcesInjection: String?

        if intents.contains("web_search") {
            // Prefer router-provided search queries; fall back to heuristic cleaning if missing.
            var queries = tasksForKey("web_search", in: decision.tasks)

            if queries.isEmpty {
                let q = cleanedWebSearchQuery(from: userText)
                if !q.isEmpty { queries = [q] }
            }

            // Run up to 2 queries for better coverage without slowing everything down too much
            queries = Array(queries.prefix(2))

            guard let firstQuery = queries.first, !firstQuery.isEmpty else {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Web search needs a query.")
                    finishChatReply(replyId: replyId)
                }
                return
            }

            do {
                var combined: [WebSearchService.SearchItem] = []
                var seen = Set<String>()

                for q in queries {
                    let items = try await webSearchService.search(query: q)
                    for item in items {
                        let urlKey = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !urlKey.isEmpty else { continue }
                        if seen.insert(urlKey).inserted {
                            combined.append(item)
                        }
                    }
                }

                let maxToShow = 12
                let finalItems = Array(combined.prefix(maxToShow))

                let queryLabel: String = {
                    if queries.count <= 1 { return firstQuery }
                    return "\(firstQuery) (+\(queries.count - 1) more)"
                }()

                webSearchPayload = WebSearchPayload(
                    query: queryLabel,
                    items: finalItems.map { WebSearchItem(title: $0.title, url: $0.url, snippet: $0.snippet) }
                )

                await MainActor.run {
                    setChatReplyWebSearch(replyId: replyId, webSearch: webSearchPayload)
                }

                let pages = try await webSearchService.fetchPageExcerpts(from: finalItems, maxPages: 3)
                webSourcesInjection = formatWebSourcesForSystemPrompt(query: queryLabel, items: finalItems, pages: pages)

            } catch {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Web search failed: \(error.localizedDescription)")
                    finishChatReply(replyId: replyId)
                }
                return
            }
        }
        var generatedImageRef: ImageRef?
        var imagePromptText: String?
        var revisedPrompt: String?
        if intents.contains("image_generate") || intents.contains("image_edit") {
            imagePromptText = imagePrompt(from: userText) ?? userText
        }

        let selectedEntries = selectedBoardEntries(from: decision.boardSelection.selectedEntryIds,
                                                   entries: boardEntries)
        let selectedImageRef = firstBoardImageRef(from: selectedEntries)
        let primaryImageRef = images.last

        if intents.contains("image_edit") {
            let editImage = primaryImageRef ?? selectedImageRef
            guard let editImage else {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Please attach or select an image to edit.")
                    finishChatReply(replyId: replyId)
                }
                return
            }
            let promptBase = (imagePromptText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = imagePromptWithPersonality(promptBase, personality: personality)
            guard !prompt.isEmpty else {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Please describe how to edit the image.")
                    finishChatReply(replyId: replyId)
                }
                return
            }
            guard let payload = imageEditPayload(for: editImage) else {
                await MainActor.run {
                    failChatReply(replyId: replyId, error: AIService.AIServiceError.invalidResponse)
                }
                return
            }
            do {
                let result = try await retryModelRequest {
                    try await self.aiService.editImage(model: self.imageModelName,
                                                  apiKey: apiKey,
                                                  prompt: prompt,
                                                  imageData: payload.data,
                                                  imageFilename: payload.filename,
                                                  imageMimeType: payload.mimeType)
                }
                guard let imageRef = saveImage(data: result.data) else {
                    throw ChatReplyError.imageSaveFailed
                }
                generatedImageRef = imageRef
                revisedPrompt = result.revisedPrompt
            } catch {
                if await handleChatCancellation(replyId: replyId, error: error) { return }
                await MainActor.run {
                    failChatReply(replyId: replyId, error: error)
                }
                return
            }
        } else if intents.contains("image_generate") {
            let promptBase = (imagePromptText ?? userText).trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = imagePromptWithPersonality(promptBase, personality: personality)
            guard !prompt.isEmpty else {
                await MainActor.run {
                    setChatReplyText(replyId: replyId, text: "Please describe the image you want.")
                    finishChatReply(replyId: replyId)
                }
                return
            }
            do {
                let result = try await retryModelRequest {
                    try await self.aiService.generateImage(model: self.imageModelName,
                                                      apiKey: apiKey,
                                                      prompt: prompt)
                }
                guard let imageRef = saveImage(data: result.data) else {
                    throw ChatReplyError.imageSaveFailed
                }
                generatedImageRef = imageRef
                revisedPrompt = result.revisedPrompt
            } catch {
                if await handleChatCancellation(replyId: replyId, error: error) { return }
                await MainActor.run {
                    failChatReply(replyId: replyId, error: error)
                }
                return
            }
        } else if let reminderRouting = decision.reminder { // Handle reminder intent
            if await handleChatCancellation(replyId: replyId) { return }

            if decision.needsClarification, let question = decision.clarifyingQuestion {
                await MainActor.run {
                    self.storePendingClarification(originalText: userText, originalImages: images, originalFiles: files, question: question)
                    self.setChatReplyText(replyId: replyId, text: question)
                    self.finishChatReply(replyId: replyId)
                }
                return
            }

            switch reminderRouting.action {
            case "create":
                guard let title = reminderRouting.title, !title.isEmpty else {
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: "I need a title to create a reminder.")
                        self.finishChatReply(replyId: replyId)
                    }
                    return
                }
                guard let work = reminderRouting.work, !work.isEmpty else {
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: "I need to know what work to do for this reminder.")
                        self.finishChatReply(replyId: replyId)
                    }
                    return
                }
                guard let schedule = reminderRouting.schedule,
                      let atString = schedule.at,
                      let dueAtDate = BoardStore.parseISO8601(atString) else {
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: "I need a valid date and time to set this reminder.")
                        self.finishChatReply(replyId: replyId)
                    }
                    return
                }

                let recurrence: ReminderRecurrence?
                if let type = schedule.type, type != "once" {
                    guard let frequency = ReminderRecurrence.Frequency(rawValue: type) else {
                        await MainActor.run {
                            self.setChatReplyText(
                              replyId: replyId,
                              text: "Unsupported recurrence type: \(type ?? "nil"). I can do 'hourly', 'daily', 'weekly', 'monthly', or 'yearly'."
                            )
                            self.finishChatReply(replyId: replyId)
                        }
                        return
                    }
                    recurrence = ReminderRecurrence(frequency: frequency, interval: schedule.interval ?? 1, weekdays: schedule.weekdays?.compactMap { weekdayString in
                        // Convert "Mon" to 2 (Monday in Calendar is 2) etc.
                        let weekdaysMap = ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7]
                        return weekdaysMap[weekdayString.lowercased()]
                    })
                } else {
                    recurrence = nil
                }

                let newReminder = ReminderItem(title: title, work: work, dueAt: dueAtDate.timeIntervalSince1970, recurrence: recurrence)
                await MainActor.run {
                    self.addReminder(item: newReminder)
                    let formattedDate = BoardStore.userVisibleDateFormatter.string(from: dueAtDate)
                    var confirmation = "Okay, I've set a reminder for '\(newReminder.title)' on \(formattedDate)."
                    if let rec = recurrence {
                        confirmation += " It will recur \(rec.frequency.rawValue)."
                    }
                    self.setChatReplyText(replyId: replyId, text: confirmation)
                    self.finishChatReply(replyId: replyId)
                }
                return

            case "list":
                let activeReminders = self.doc.reminders
                    .filter { $0.status == .scheduled || $0.status == .preparing || $0.status == .ready }
                    .sorted(by: { $0.dueAt < $1.dueAt })

                if activeReminders.isEmpty {
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: "You don't have any active reminders set.")
                        self.finishChatReply(replyId: replyId)
                    }
                    return
                }

                let apiKey = self.doc.chatSettings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

                // No key? fall back to the basic list formatting.
                if apiKey.isEmpty {
                    let fallback = self.basicActiveRemindersText(activeReminders)
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: fallback)
                        self.finishChatReply(replyId: replyId)
                    }
                    return
                }

                do {
                    if await handleChatCancellation(replyId: replyId) { return }

                    let response = try await self.smartReminderListResponse(
                        apiKey: apiKey,
                        userQuery: userText,          // <- uses the user’s actual question
                        reminders: activeReminders
                    )

                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: response)
                        self.finishChatReply(replyId: replyId)
                    }
                } catch {
                    let fallback = self.basicActiveRemindersText(activeReminders)
                    await MainActor.run {
                        self.setChatReplyText(replyId: replyId, text: fallback)
                        self.finishChatReply(replyId: replyId)
                    }
                }
                return

            case "cancel":
                await MainActor.run {
                    var reminderToCancel: ReminderItem?
                    if let targetIdString = reminderRouting.targetId, let targetId = UUID(uuidString: targetIdString) {
                        reminderToCancel = self.getReminder(id: targetId)
                    } else if let title = reminderRouting.title, !title.isEmpty {
                        reminderToCancel = self.doc.reminders.first(where: { $0.title.lowercased() == title.lowercased() && ($0.status == .scheduled || $0.status == .ready) })
                    }

                    if let foundReminder = reminderToCancel {
                        self.removeReminder(id: foundReminder.id)
                        self.setChatReplyText(replyId: replyId, text: "Okay, I've cancelled the reminder for '\(foundReminder.title)'.")
                    } else {
                        self.setChatReplyText(replyId: replyId, text: "I couldn't find a reminder to cancel matching your request.")
                    }
                    self.finishChatReply(replyId: replyId)
                }
                return

            default:
                await MainActor.run {
                    self.setChatReplyText(replyId: replyId, text: "I'm not sure how to handle the reminder action: \(reminderRouting.action).")
                    self.finishChatReply(replyId: replyId)
                }
                return
            }
        }


        let textTasks = tasksForKey("text", in: decision.tasks)
        let rememberOnly = intents == ["text"]
            && !textTasks.isEmpty
            && textTasks.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "remember" }

        let wantsTextOrCode = intents.contains("text") || intents.contains("code") || intents.contains("web_search")
        if !wantsTextOrCode {
            if await handleChatCancellation(replyId: replyId) { return }
            if let imageRef = generatedImageRef {
                let promptText = imagePromptText ?? userText
                let revised = revisedPrompt
                await MainActor.run {
                    finishImageReply(replyId: replyId,
                                     prompt: promptText,
                                     revisedPrompt: revised,
                                     imageRef: imageRef)
                }
                return
            }
            await MainActor.run {
                setChatReplyText(replyId: replyId, text: "No response.")
                finishChatReply(replyId: replyId)
            }
            return
        }

        if await handleChatCancellation(replyId: replyId) { return }
        var systemPrompts: [String] = []
        systemPrompts.append(Self.baseSystemPrompt)
        if needsFreshChatPrompt {
            systemPrompts.append(Self.freshChatSystemPrompt)
        }
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonality.isEmpty {
            systemPrompts.append(trimmedPersonality)
        }
        var memoryInjection = decision.memorySelection.memoryInjection.trimmingCharacters(in: .whitespacesAndNewlines)
        if memoryInjection.isEmpty {
            let selected = decision.memorySelection.selectedMemories
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            memoryInjection = defaultMemoryInjection(from: selected)
        }
        if memoryInjection.isEmpty {
            memoryInjection = defaultMemoryInjection(from: memories.map { $0.text })
        }
        if !memoryInjection.isEmpty {
            systemPrompts.append(Self.memoryUsageSystemPrompt)
            systemPrompts.append(memoryInjection)
        }
        var boardInjection = defaultBoardInjection(from: selectedEntries)
        if !boardInjection.isEmpty {
            systemPrompts.append(Self.boardUsageSystemPrompt)
            systemPrompts.append(boardInjection)
        }
        if let searchSummary, !searchSummary.isEmpty {
            systemPrompts.append(searchSummary)
        }
        if let imagePromptText, generatedImageRef != nil {
            let cleanPrompt = (revisedPrompt ?? imagePromptText).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPrompt.isEmpty {
                systemPrompts.append("Image generated from prompt: \(cleanPrompt)")
            }
        }
        if let webSourcesInjection, !webSourcesInjection.isEmpty {
            systemPrompts.append(webSourcesInjection)
        }
        let filteredTasks = filteredTasksForWorker(decision.tasks)
        systemPrompts.append(workerInstruction(intents: intents, tasks: filteredTasks))
        if shouldRemember(decision) || explicitRemember {
            if memoryStatus == .updated || memoryStatus == .saved {
                if let memoryAcknowledge {
                    systemPrompts.append("Memory status: \(memoryAcknowledge) Acknowledge this in one short sentence.")
                }
            }
        }

        var textInstruction = decision.textInstruction?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rememberOnly, textInstruction.isEmpty {
            textInstruction = memoryAcknowledge ?? "Acknowledge the memory update briefly."
        }
        let needsImageForText = (intents.contains("image_generate") || intents.contains("image_edit"))
            && intents.contains("text")

        var messagesForAPI = openAIMessages(from: history, systemPrompts: systemPrompts)
        // Inject images for selected memories so the model can "recall" visually.
        let selectedMemoryTexts = decision.memorySelection.selectedMemories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !selectedMemoryTexts.isEmpty {
            let selectedMemoryObjs: [Memory] = selectedMemoryTexts.compactMap { text in
                memories.first(where: { $0.text == text })
            }

            let imageMemories = selectedMemoryObjs
                .filter { $0.image != nil }

            if !imageMemories.isEmpty {
                var parts: [AIService.Message.ContentPart] = [
                    .text("Memory images (context only; not user message):")
                ]

                for (idx, mem) in imageMemories.prefix(2).enumerated() {
                    parts.append(.text("Memory \(idx + 1): \(mem.text)"))
                    if let imgRef = mem.image,
                       let dataURL = routerImageDataURL(for: imgRef, maxPixelSize: 512, quality: 0.75)
                        ?? imageDataURL(for: imgRef) {
                        parts.append(.image(url: dataURL))
                    }
                }

                messagesForAPI.append(AIService.Message(role: "user", content: .parts(parts)))
            }
        }
        let selectedBoardImages = boardImageAttachments(from: selectedEntries)
        if !selectedBoardImages.isEmpty {
            var parts: [AIService.Message.ContentPart] = [
                .text("Reference images:")
            ]

            for (idx, attachment) in selectedBoardImages.enumerated() {
                parts.append(.text("Image \(idx + 1):"))
                parts.append(.image(url: attachment.dataURL))
            }

            messagesForAPI.append(AIService.Message(role: "user", content: .parts(parts)))
        }
        if !textInstruction.isEmpty {
            if needsImageForText, let imageRef = generatedImageRef,
               let dataURL = imageDataURL(for: imageRef) {
                let parts: [AIService.Message.ContentPart] = [
                    .image(url: dataURL),
                    .text(textInstruction)
                ]
                messagesForAPI.append(AIService.Message(role: "user", content: .parts(parts)))
            } else {
                messagesForAPI.append(AIService.Message(role: "user", content: .text(textInstruction)))
            }
        } else if needsImageForText, let imageRef = generatedImageRef,
                  let dataURL = imageDataURL(for: imageRef) {
            let fallback = "Use the attached image to respond to the user's request."
            let parts: [AIService.Message.ContentPart] = [
                .image(url: dataURL),
                .text(fallback)
            ]
            messagesForAPI.append(AIService.Message(role: "user", content: .parts(parts)))
        }

        if let imageRef = generatedImageRef {
            if await handleChatCancellation(replyId: replyId) { return }
            await MainActor.run {
                setChatReplyImages(replyId: replyId, images: [imageRef])
            }
        }
        if await handleChatCancellation(replyId: replyId) { return }
        await MainActor.run {
            setChatReplyText(replyId: replyId, text: "")
        }

        do {
            try await retryModelRequest(onRetry: { self.setChatReplyText(replyId: replyId, text: "") }) {
                try await self.aiService.streamChat(model: textModel,
                                               apiKey: apiKey,
                                               messages: messagesForAPI) { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        self.appendChatDelta(replyId: replyId, delta: delta)
                    }
                }
            }
            if await handleChatCancellation(replyId: replyId) { return }
            await reviseReplyIfNeeded(replyId: replyId,
                                      userText: userText,
                                      apiKey: apiKey,
                                      history: history,
                                      systemPrompts: systemPrompts,
                                      textModel: textModel)
            if await handleChatCancellation(replyId: replyId) { return }
            await MainActor.run {
                finishChatReply(replyId: replyId)
            }
        } catch {
            if await handleChatCancellation(replyId: replyId, error: error) { return }
            await MainActor.run {
                failChatReply(replyId: replyId, error: error)
            }
        }
    }

    private func reviseReplyIfNeeded(replyId: UUID,
                                     userText: String,
                                     apiKey: String,
                                     history: [ChatMsg],
                                     systemPrompts: [String],
                                     textModel: String) async {
        if Task.isCancelled { return }
        let draft = await MainActor.run { chatReplyText(replyId: replyId) } ?? ""
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDraft.isEmpty else { return }

        let memorySnapshot = await MainActor.run { doc.memories }
        let cleanedMemories = memorySnapshot.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanedMemories.isEmpty else { return }

        let checkMessages = memoryCheckMessages(for: trimmedDraft,
                                                userText: userText,
                                                memories: cleanedMemories)
        guard let checkOutput = try? await aiService.completeChat(model: routerModelName,
                                                                  apiKey: apiKey,
                                                                  messages: checkMessages,
                                                                  reasoningEffort: routerReasoningEffort),
              let checkDecision = parseMemoryConflictCheck(from: checkOutput),
              checkDecision.conflicts else {
            return
        }
        let conflicts = checkDecision.conflictingMemories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !conflicts.isEmpty else { return }

        var revisionPrompts = systemPrompts
        let conflictInjection = memoryConflictInjection(from: conflicts)
        if !conflictInjection.isEmpty {
            revisionPrompts.append(conflictInjection)
        }
        var revisionMessages = openAIMessages(from: history, systemPrompts: revisionPrompts)
        let revisionInstruction = memoryConflictRevisionInstruction(draft: trimmedDraft,
                                                                    conflictingMemories: conflicts)
        revisionMessages.append(AIService.Message(role: "user", content: .text(revisionInstruction)))

        guard let revisedOutput = try? await aiService.completeChat(model: textModel,
                                                                    apiKey: apiKey,
                                                                    messages: revisionMessages) else {
            return
        }
        let cleanedRevision = revisedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedRevision.isEmpty else { return }

        await MainActor.run {
            setChatReplyText(replyId: replyId, text: cleanedRevision)
            addLog("Revised reply to match memory")
        }
    }

    private func runRouterFallback(replyId: UUID) async {
        await MainActor.run {
            setChatReplyText(replyId: replyId, text: "Router Failed")
            finishChatReply(replyId: replyId)
        }
    }

    private func isRetryableModelError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is URLError { return true }
        if error is DecodingError { return true }
        if let serviceError = error as? AIService.AIServiceError {
            switch serviceError {
            case .invalidResponse:
                return true
            case .badStatus(let code, _):
                return (500...599).contains(code)
            }
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private func retryModelRequest<T>(maxRetries: Int = 2,
                                      onRetry: (@MainActor () -> Void)? = nil,
                                      operation: @escaping () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                if Task.isCancelled {
                    throw CancellationError()
                }
                return try await operation()
            } catch {
                if !isRetryableModelError(error) || attempt >= maxRetries {
                    throw error
                }
                attempt += 1
                if let onRetry {
                    await MainActor.run {
                        onRetry()
                    }
                }
            }
        }
    }

    @MainActor
    private func startChatTask(replyId: UUID, operation: @escaping () async -> Void) {
        let task = Task { [weak self] in
            await operation()
            await MainActor.run {
                self?.clearChatTask(replyId: replyId)
            }
        }
        activeChatTasks[replyId] = task
    }

    @MainActor
    private func clearChatTask(replyId: UUID) {
        activeChatTasks[replyId] = nil
        cancelledChatReplyIds.remove(replyId)
    }

    private func handleChatCancellation(replyId: UUID, error: Error? = nil) async -> Bool {
        if Task.isCancelled || error is CancellationError {
            await MainActor.run {
                finalizeCancelledChatReply(replyId: replyId)
            }
            return true
        }
        return false
    }

    @MainActor
    private func finalizeCancelledChatReply(replyId: UUID) {
        guard !cancelledChatReplyIds.contains(replyId) else { return }
        cancelledChatReplyIds.insert(replyId)
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else {
            pendingChatReplies = max(0, pendingChatReplies - 1)
            return
        }
        recordUndoSnapshot()
        pendingChatReplies = max(0, pendingChatReplies - 1)
        let stopNote = "Stopped by user."
        doc.chat.messages[index].ts = Date().timeIntervalSince1970
        if doc.chat.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.chat.messages[index].text = stopNote
        } else {
            doc.chat.messages[index].text += "\n\n\(stopNote)"
        }
        addLog("Stopped chat reply")
        upsertChatHistory(doc.chat)
        touch()
    }

    private func routerMessages(for userText: String,
                                imageCount: Int,
                                fileCount: Int,
                                fileNames: [String],
                                memories: [String],
                                boardEntries: [UUID: BoardEntry],
                                boardOrder: [UUID],
                                selection: Set<UUID>,
                                personality: String,
                                userName: String,
                                history: [ChatMsg]) -> [AIService.Message] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        lines.append("User message (current request only):")
        lines.append("<<<USER_MESSAGE")
        lines.append(trimmed.isEmpty ? "(no text)" : userText)
        lines.append("USER_MESSAGE>>>")
        lines.append("Has image attachment: \(imageCount > 0 ? "true" : "false")")
        lines.append("Image attachment count: \(imageCount)")
        lines.append("Has file attachment: \(fileCount > 0 ? "true" : "false")")
        lines.append("File attachment count: \(fileCount)")
        if fileCount > 0 {
            let cleanedNames = fileNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cleanedNames.isEmpty {
                let joinedNames = cleanedNames.joined(separator: ", ")
                lines.append("Attached files: \(joinedNames)")
            }
        }
        lines.append("User's name: \(trimmedName.isEmpty ? "" : trimmedName)")
        let tz = TimeZone.autoupdatingCurrent
        let now = Date()
        let offsetSeconds = tz.secondsFromGMT(for: now)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absSeconds = abs(offsetSeconds)
        let hh = absSeconds / 3600
        let mm = (absSeconds % 3600) / 60
        let offset = String(format: "%@%02d:%02d", sign, hh, mm)

        lines.append("User time zone: \(tz.identifier) (UTC\(offset))")
        lines.append("Current local time (ISO8601): \(BoardStore.iso8601FormatterNoFrac.string(from: now))")
        let context = routerContext(from: Array(history.dropLast()))
        if !context.isEmpty {
            lines.append("Conversation context (system context only; NOT user content):")
            lines.append("<<<CONTEXT")
            lines.append(context)
            lines.append("CONTEXT>>>")
        }
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonality.isEmpty {
            lines.append("Personality instructions (system context only; NOT user content):")
            lines.append("<<<PERSONALITY")
            lines.append(trimmedPersonality)
            lines.append("PERSONALITY>>>")
        }
        if memories.isEmpty {
            lines.append("Stored memories (system context only; NOT user content):")
            lines.append("(none)")
        } else {
            lines.append("Stored memories (system context only; NOT user content):")
            lines.append(contentsOf: memories.map { "- \($0)" })
        }
        let boardContext = boardEntriesContext(entries: boardEntries,
                                               order: boardOrder,
                                               selection: selection)
        if boardContext.isEmpty {
            lines.append("Board entries (system context only; NOT user content):")
            lines.append("(none)")
        } else {
            lines.append("Board entries (system context only; NOT user content):")
            lines.append("<<<BOARD")
            lines.append(boardContext)
            lines.append("BOARD>>>")
        }
        let payload = lines.joined(separator: "\n")
        let routerImageAttachments = boardImageAttachmentsForRouting(entries: boardEntries,
                                                                      order: boardOrder,
                                                                      selection: selection)
        let userContent: AIService.Message.Content
        if routerImageAttachments.isEmpty {
            userContent = .text(payload)
        } else {
            var parts: [AIService.Message.ContentPart] = [
                .text(payload),
                .text("Board images (context only; not user message):")
            ]
            for attachment in routerImageAttachments {
                parts.append(.text("Board image id: \(attachment.id.uuidString)"))
                parts.append(.image(url: attachment.dataURL))
            }
            userContent = .parts(parts)
        }
        return [
            AIService.Message(role: "system", content: .text(Self.routerSystemPrompt)),
            AIService.Message(role: "user", content: userContent)
        ]
    }

    private func routerContext(from history: [ChatMsg],
                               maxMessages: Int = 10,
                               maxCharsPerMessage: Int = 360,
                               maxTotalChars: Int = 2400) -> String {
        guard !history.isEmpty else { return "" }
        let recent = Array(history.suffix(maxMessages))
        var lines: [String] = []
        var totalChars = 0
        for msg in recent.reversed() {
            let role = msg.role == .user ? "User" : "Assistant"
            var text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                text = collapseWhitespace(text)
                if text.count > maxCharsPerMessage {
                    text = String(text.prefix(maxCharsPerMessage)) + "..."
                }
            }
            var parts: [String] = []
            let imageCount = msg.images.count
            let fileCount = msg.files.count
            if imageCount == 1 {
                parts.append("[image]")
            } else if imageCount > 1 {
                parts.append("[images: \(imageCount)]")
            }
            if fileCount == 1 {
                parts.append("[file]")
            } else if fileCount > 1 {
                parts.append("[files: \(fileCount)]")
            }
            if !text.isEmpty {
                parts.append(text)
            }
            let content = parts.isEmpty ? "(no text)" : parts.joined(separator: " ")
            let line = "\(role): \(content)"
            let lineLength = line.count + 1
            if totalChars + lineLength > maxTotalChars {
                break
            }
            lines.append(line)
            totalChars += lineLength
        }
        return lines.reversed().joined(separator: "\n")
    }

    private func collapseWhitespace(_ text: String) -> String {
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return parts.joined(separator: " ")
    }

    private func boardEntriesContext(entries: [UUID: BoardEntry],
                                     order: [UUID],
                                     selection: Set<UUID>) -> String {
        guard !entries.isEmpty else { return "" }
        let baseOrder = order.isEmpty ? Array(entries.keys) : order
        let orderedIds = orderedBoardEntryIds(order: baseOrder, selection: selection)
        let orderedSet = Set(orderedIds)
        let missingIds = entries.keys.filter { !orderedSet.contains($0) }
        let allIds = orderedIds + missingIds
        var lines: [String] = []
        for id in allIds {
            guard let entry = entries[id] else { continue }
            let line = boardEntryContextLine(for: entry,
                                             selected: selection.contains(id))
            if line.isEmpty { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func orderedBoardEntryIds(order: [UUID], selection: Set<UUID>) -> [UUID] {
        let selected = order.filter { selection.contains($0) }
        let remaining = order.filter { !selection.contains($0) }
        return selected + remaining
    }

    private func boardEntryContextLine(for entry: BoardEntry,
                                       selected: Bool) -> String {
        switch entry.data {
        case .text(let value):
            let cleaned = collapseWhitespace(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return "" }
            let selectedTag = selected ? " selected" : ""
            return "- [text]\(selectedTag) id: \(entry.id.uuidString) text: \(cleaned)"
        case .image(_):
            let selectedTag = selected ? " selected" : ""
            return "- [image]\(selectedTag) id: \(entry.id.uuidString)"
        case .file(let ref):
            let selectedTag = selected ? " selected" : ""
            let name = ref.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? ref.filename : name
            if let content = fileContentForContext(for: ref) {
                let cleaned = collapseWhitespace(content)
                return "- [file]\(selectedTag) id: \(entry.id.uuidString) name: \(label) content: \(cleaned)"
            } else {
                return "- [file]\(selectedTag) id: \(entry.id.uuidString) name: \(label)"
            }
        default:
            return ""
        }
    }

    private func selectedBoardEntries(from selectedIds: [String],
                                      entries: [UUID: BoardEntry]) -> [BoardEntry] {
        guard !selectedIds.isEmpty, !entries.isEmpty else { return [] }

        // Precompute lookups
        let all = entries.keys.map { ($0, $0.uuidString.lowercased()) }
        let fullMap: [String: UUID] = Dictionary(uniqueKeysWithValues: all.map { ($0.1, $0.0) })
        let noDashMap: [String: UUID] = Dictionary(uniqueKeysWithValues: all.map { ($0.1.replacingOccurrences(of: "-", with: ""), $0.0) })

        func normalizeToken(_ s: String) -> String {
            // Trim, drop trailing punctuation like "..." and keep only hex characters
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            let hexOnly = lowered.filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
            return hexOnly
        }

        func matchUUID(from raw: String) -> UUID? {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // 1) Exact UUID string
            if let id = UUID(uuidString: t), entries[id] != nil { return id }

            // 2) Exact UUID string (lowercased)
            if let id = fullMap[t.lowercased()] { return id }

            // 3) Prefix match (handles "63e5bc29..." etc.)
            let token = normalizeToken(t)
            guard token.count >= 6 else { return nil } // avoid accidental matches

            // Try prefix against no-dash UUIDs
            let matches = noDashMap.filter { $0.key.hasPrefix(token) }.map { $0.value }
            if matches.count == 1 { return matches[0] }

            // Also allow prefix against dashed UUIDs (rare)
            let dashedMatches = fullMap.filter { $0.key.hasPrefix(token) }.map { $0.value }
            if dashedMatches.count == 1 { return dashedMatches[0] }

            return nil
        }

        var seen = Set<UUID>()
        var results: [BoardEntry] = []

        for raw in selectedIds {
            guard let id = matchUUID(from: raw),
                  let entry = entries[id],
                  !seen.contains(id) else { continue }
            seen.insert(id)
            results.append(entry)
        }

        return results
    }

    private func defaultBoardInjection(from entries: [BoardEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        var lines: [String] = []
        for entry in entries {
            let line = boardEntryInjectionLine(for: entry)
            if line.isEmpty { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        var result = ["Board elements (context only; not user message):"]
        result.append(contentsOf: lines)
        return result.joined(separator: "\n")
    }

    private func boardEntryInjectionLine(for entry: BoardEntry) -> String {
        switch entry.data {
        case .text(let value):
            let cleaned = collapseWhitespace(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return "" }
            return "- [text] id: \(entry.id.uuidString) text: \(cleaned)"

        case .image:
            return "- [image] id: \(entry.id.uuidString)"

        case .file(let ref):
            let name = ref.originalName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = name.isEmpty ? ref.filename : name

            let contents = fileContentDescription(for: ref)  // <-- this already extracts PDF text or text file contents
            return """
        - [file] id: \(entry.id.uuidString) name: \(label)
        \(contents)
        """

        default:
            return ""
        }
    }
    
    private func fileTextPreview(for ref: FileRef,
                                 maxBytes: Int = 160_000) -> String? {
        guard let url = fileURL(for: ref) else { return nil }

        let ext = url.pathExtension.lowercased()
        let likelyTextExts: Set<String> = [
            "txt","md","markdown","json","csv","tsv","log",
            "yaml","yml","xml",
            "html","css",
            "js","ts","swift","py","java","kt","go","rs","rb","php","sql",
            "c","cc","cpp","h","hpp"
        ]

        // If it has an extension and it’s not one we trust as text, skip.
        if !ext.isEmpty && !likelyTextExts.contains(ext) { return nil }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let capped = data.prefix(maxBytes)

        guard var str = String(data: capped, encoding: .utf8)
                ?? String(data: capped, encoding: .isoLatin1) else { return nil }

        str = str.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")
                 .trimmingCharacters(in: .whitespacesAndNewlines)

        return str.isEmpty ? nil : str
    }

    private struct BoardImageAttachment {
        let id: UUID
        let dataURL: String
    }

    private func boardImageAttachments(from entries: [BoardEntry]) -> [BoardImageAttachment] {
        guard !entries.isEmpty else { return [] }
        var attachments: [BoardImageAttachment] = []
        for entry in entries {
            guard case .image(let ref) = entry.data,
                  let dataURL = imageDataURL(for: ref) else { continue }
            attachments.append(BoardImageAttachment(id: entry.id, dataURL: dataURL))
        }
        return attachments
    }

    private func boardImageAttachmentsForRouting(entries: [UUID: BoardEntry],
                                                 order: [UUID],
                                                 selection: Set<UUID>,
                                                 maxPixelSize: CGFloat = 512,
                                                 quality: CGFloat = 0.75) -> [BoardImageAttachment] {
        guard !entries.isEmpty else { return [] }
        let baseOrder = order.isEmpty ? Array(entries.keys) : order
        let orderedIds = orderedBoardEntryIds(order: baseOrder, selection: selection)
        let orderedSet = Set(orderedIds)
        let missingIds = entries.keys.filter { !orderedSet.contains($0) }
        let allIds = orderedIds + missingIds
        var attachments: [BoardImageAttachment] = []
        for id in allIds {
            guard let entry = entries[id],
                  case .image(let ref) = entry.data,
                  let dataURL = routerImageDataURL(for: ref,
                                                   maxPixelSize: maxPixelSize,
                                                   quality: quality) else { continue }
            attachments.append(BoardImageAttachment(id: id, dataURL: dataURL))
        }
        return attachments
    }

    private func firstBoardImageRef(from entries: [BoardEntry]) -> ImageRef? {
        for entry in entries {
            if case .image(let ref) = entry.data {
                return ref
            }
        }
        return nil
    }

    private func memoryCheckMessages(for response: String,
                                     userText: String,
                                     memories: [String]) -> [AIService.Message] {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        lines.append("Assistant response:")
        lines.append("<<<ASSISTANT_RESPONSE")
        lines.append(trimmedResponse.isEmpty ? "(empty)" : response)
        lines.append("ASSISTANT_RESPONSE>>>")
        lines.append("User message (context only):")
        lines.append("<<<USER_MESSAGE")
        lines.append(trimmedUser.isEmpty ? "(no text)" : userText)
        lines.append("USER_MESSAGE>>>")
        if memories.isEmpty {
            lines.append("Stored memories:")
            lines.append("(none)")
        } else {
            lines.append("Stored memories:")
            lines.append(contentsOf: memories.map { "- \($0)" })
        }
        let payload = lines.joined(separator: "\n")
        return [
            AIService.Message(role: "system", content: .text(Self.memoryCheckSystemPrompt)),
            AIService.Message(role: "user", content: .text(payload))
        ]
    }

    private func parseRouterDecision(from output: String) -> RouterDecision? {
        guard let json = extractJSONObject(from: output),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RouterDecision.self, from: data)
    }

    private func parseMemoryConflictCheck(from output: String) -> MemoryConflictCheck? {
        guard let json = extractJSONObject(from: output),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MemoryConflictCheck.self, from: data)
    }

    private func extractJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func extractJSONArray(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            return trimmed
        }
        guard let start = trimmed.firstIndex(of: "["),
              let end = trimmed.lastIndex(of: "]") else {
            return nil
        }
        return String(trimmed[start...end])
    }

    private func normalizedIntents(from decision: RouterDecision) -> Set<String> {
        Set(decision.intent.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private func textModelName(for complexity: String) -> String {
        let normalized = complexity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "complex" ? complexTextModelName : simpleTextModelName
    }

    private func tasksForKey(_ key: String, in tasks: [String: [String]]) -> [String] {
        for (name, values) in tasks {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key {
                return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        return []
    }
    
    private func isExplicitMemorySaveRequest(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }

        // Avoid false positives like “remember when…”
        if t.contains("remember when") { return false }

        // Direct / common memory requests
        if t == "remember" { return true }

        let phrases = [
            "add to memory",
            "save to memory",
            "store this",
            "put this in memory",
            "memorize",
            "don't forget",
            "you should know",

            "remember this",
            "remember that",
            "remember it",

            "remember how this looks",
            "remember how it looks",
            "remember how they look",
            "remember what they look like",
            "remember what this looks like",
            "remember their appearance",
            "remember this character",
            "remember this mock",
            "remember this place",
            "remember this look",

            "remember this photo",
            "remember this image",
            "remember this picture",
            "remember this screenshot",
            "save this photo",
            "save this image",
            "save this picture",
            "save this screenshot"
        ]

        return phrases.contains(where: { t.contains($0) })
    }

    private func isExplicitImageEditOrGenerateRequest(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.contains("edit") { return true }
        if t.contains("modify") { return true }
        if t.contains("change") { return true }
        if t.contains("make it") { return true }
        if t.contains("generate") { return true }
        if t.contains("create an image") { return true }
        return false
    }

    private func shouldRemember(_ decision: RouterDecision) -> Bool {
        let tasks = tasksForKey("text", in: decision.tasks)
        return tasks.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "remember" }
    }

    private func filteredTasksForWorker(_ tasks: [String: [String]]) -> [String: [String]] {
        var filtered: [String: [String]] = [:]
        for (key, values) in tasks {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let cleanedValues = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if normalizedKey == "text" {
                let trimmed = cleanedValues.filter { $0.lowercased() != "remember" }
                if !trimmed.isEmpty {
                    filtered[normalizedKey] = trimmed
                }
            } else {
                filtered[normalizedKey] = cleanedValues
            }
        }
        return filtered
    }

    private func workerInstruction(intents: Set<String>, tasks: [String: [String]]) -> String {
        var lines: [String] = []
        let textTasks = tasksForKey("text", in: tasks)
        let codeTasks = tasksForKey("code", in: tasks)

        if !textTasks.isEmpty {
            lines.append("Text tasks: \(textTasks.joined(separator: ", "))")
        }
        if !codeTasks.isEmpty {
            lines.append("Code tasks: \(codeTasks.joined(separator: ", "))")
        }
        if lines.isEmpty {
            lines.append("Tasks: respond to the user's request.")
        }
        if intents.contains("code") {
            lines.append("If code is requested, include code blocks and only the necessary code.")
        }

        lines.append("Do not narrate actions or include process labels.")
        lines.append("Never mention internal IDs/UUIDs, board ids, or context markers.")
        lines.append("Avoid meta headers like: 'Generated image...', 'Edited image...', 'Original request:', 'Clarification question:', 'User clarification:'.")

        if intents.contains("image_generate") || intents.contains("image_edit") {
            lines.append("If an image is included and the user did not explicitly ask for a description, keep the text to one short user-facing line (e.g., 'Here you go.').")
        }
        
        if intents.contains("web_search") {
            lines.append("Web search was performed by the app. If 'Web search results' appear above, use them.")
            lines.append("Do NOT say you can't browse the web. If results are empty or failed, say that plainly and request to answer from general knowledge.")
        }

        lines.append("Return only the final deliverable.")
        return lines.joined(separator: "\n")
    }

    private struct MemoryConflictCheck: Decodable {
        let conflicts: Bool
        let conflictingMemories: [String]
        let reason: String?

        private enum CodingKeys: String, CodingKey {
            case conflicts
            case conflict
            case conflictingMemories = "conflicting_memories"
            case reason
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            conflicts = (try? container.decode(Bool.self, forKey: .conflicts))
                ?? (try? container.decode(Bool.self, forKey: .conflict))
                ?? false
            conflictingMemories = (try? container.decode([String].self, forKey: .conflictingMemories)) ?? []
            reason = try? container.decode(String.self, forKey: .reason)
        }
    }

    private struct MemoryDelta: Decodable {
        struct Update: Decodable {
            let old: String
            let new: String

            private enum CodingKeys: String, CodingKey {
                case old
                case new
            }

            init(old: String, new: String) {
                self.old = old
                self.new = new
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                old = (try? container.decode(String.self, forKey: .old)) ?? ""
                new = (try? container.decode(String.self, forKey: .new)) ?? ""
            }
        }

        let add: [String]
        let update: [Update]
        let delete: [String]

        private enum CodingKeys: String, CodingKey {
            case add
            case update
            case delete
        }

        init(add: [String], update: [Update], delete: [String]) {
            self.add = add
            self.update = update
            self.delete = delete
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            add = (try? container.decode([String].self, forKey: .add)) ?? []
            update = (try? container.decode([Update].self, forKey: .update)) ?? []
            delete = (try? container.decode([String].self, forKey: .delete)) ?? []
        }

        static let empty = MemoryDelta(add: [], update: [], delete: [])
    }

    private struct MemoryApplyResult {
        let added: Int
        let updated: Int
        let deleted: Int

        var didChange: Bool {
            added + updated + deleted > 0
        }
    }

    private func buildMemoryDelta(for userText: String,
                                  images: [ImageRef],
                                  existing: [String],
                                  apiKey: String,
                                  model: String,
                                  userName: String) async throws -> MemoryDelta {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)

        // If there is no text AND no images, nothing to do.
        if trimmed.isEmpty && images.isEmpty { return .empty }

        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload = "User's name: \(trimmedName)\n"
        payload += "User message:\n"
        payload += (trimmed.isEmpty ? "(no text)" : trimmed)
        payload += "\n"

        payload += "Attached image count: \(images.count)\n"

        payload += "\nStored memories:\n"
        if existing.isEmpty {
            payload += "(none)"
        } else {
            payload += existing.map { "- \($0)" }.joined(separator: "\n")
        }

        // Build user content as parts so the model can see images
        let maxImages = 2  // keep tokens sane; bump if you want
        let imageRefs = Array(images.prefix(maxImages))

        let userContent: AIService.Message.Content
        if imageRefs.isEmpty {
            userContent = .text(payload)
        } else {
            var parts: [AIService.Message.ContentPart] = [
                .text(payload),
                .text("User-attached images (context only; use for memory update if relevant):")
            ]

            for (idx, ref) in imageRefs.enumerated() {
                guard let dataURL = routerImageDataURL(for: ref, maxPixelSize: 512, quality: 0.75)
                        ?? imageDataURL(for: ref) else { continue }
                parts.append(.text("Image \(idx + 1):"))
                parts.append(.image(url: dataURL))
            }

            userContent = .parts(parts)
        }

        let messages = [
            AIService.Message(role: "system", content: .text(Self.memoryUpdatePrompt(userName: userName))),
            AIService.Message(role: "user", content: userContent)
        ]

        let output = try await aiService.completeChat(model: model, apiKey: apiKey, messages: messages)
        return parseMemoryDelta(from: output)
    }

    private func parseMemoryDelta(from output: String) -> MemoryDelta {
        guard let json = extractJSONObject(from: output),
              let data = json.data(using: .utf8) else { return .empty }
        return (try? JSONDecoder().decode(MemoryDelta.self, from: data)) ?? .empty
    }

    private enum MemorySaveStatus {
        case none
        case alreadyKnown
        case updated
        case saved
    }

    private func normalizeMemoryEntries(_ entries: [String], userName: String) -> [String] {
        entries.map { normalizeMemoryEntry($0, userName: userName) }
            .filter { !$0.isEmpty }
    }

    private func normalizeMemoryDelta(_ delta: MemoryDelta, userName: String) -> MemoryDelta {
        let add = normalizeMemoryEntries(delta.add, userName: userName)
        let delete = normalizeMemoryEntries(delta.delete, userName: userName)
        let update = delta.update.compactMap { entry -> MemoryDelta.Update? in
            let old = normalizeMemoryEntry(entry.old, userName: userName)
            let new = normalizeMemoryEntry(entry.new, userName: userName)
            guard !old.isEmpty, !new.isEmpty else { return nil }
            return MemoryDelta.Update(old: old, new: new)
        }
        return MemoryDelta(add: add, update: update, delete: delete)
    }

    private func memoryStatusForDelta(_ delta: MemoryDelta, result: MemoryApplyResult) -> MemorySaveStatus {
        let hasDelta = !(delta.add.isEmpty && delta.update.isEmpty && delta.delete.isEmpty)
        guard hasDelta else { return .none }
        guard result.didChange else { return .alreadyKnown }
        if result.updated > 0 || result.deleted > 0 {
            return .updated
        }
        return .saved
    }

    private func memoryStatusMessage(for status: MemorySaveStatus) -> String? {
        switch status {
        case .none:
            return nil
        case .alreadyKnown:
            return "Already remembered."
        case .updated:
            return "Memory updated."
        case .saved:
            return "Memory saved."
        }
    }

    private func defaultMemoryInjection(from memories: [String]) -> String {
        let cleaned = memories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        var lines = ["Memories (context only; not user message):"]
        lines.append(contentsOf: cleaned.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    private func memoryConflictInjection(from memories: [String]) -> String {
        let cleaned = memories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "" }
        var lines = ["Memories that must be respected (conflict check):"]
        lines.append(contentsOf: cleaned.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }

    private func memoryConflictRevisionInstruction(draft: String,
                                                   conflictingMemories: [String]) -> String {
        var lines: [String] = []
        lines.append("The previous assistant response conflicts with stored memories. Revise it to be consistent with memory while still answering the user's request. Preserve the original style and formatting, changing only what is needed for consistency.")
        if !conflictingMemories.isEmpty {
            lines.append("Conflicting memories:")
            lines.append(contentsOf: conflictingMemories.map { "- \($0)" })
        }
        lines.append("Draft response:")
        lines.append("<<<DRAFT")
        lines.append(draft.isEmpty ? "(empty)" : draft)
        lines.append("DRAFT>>>")
        lines.append("Return only the revised response. If the user's request would require contradicting memory, ask a brief clarification instead.")
        return lines.joined(separator: "\n")
    }

    private func memoryKey(_ entry: Memory) -> String {
        let text = entry.text
        let lowered = text.lowercased()
        let mapped = lowered.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return " "
        }
        let collapsed = String(mapped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed
    }

    @MainActor
    private func applyMemoryDelta(_ delta: MemoryDelta, chatImages: [ImageRef]) -> MemoryApplyResult {
        guard !(delta.add.isEmpty && delta.update.isEmpty && delta.delete.isEmpty) else {
            return MemoryApplyResult(added: 0, updated: 0, deleted: 0)
        }
        var memories = doc.memories
        var added = 0
        var updated = 0
        var deleted = 0

        func firstIndex(forKey key: String) -> Int? {
            memories.firstIndex { memoryKey($0) == key }
        }

        func removeAll(forKey key: String, keeping keepIndex: Int?) {
            var indices: [Int] = []
            for (idx, entry) in memories.enumerated() {
                if memoryKey(entry) == key && idx != keepIndex {
                    indices.append(idx)
                }
            }
            if indices.isEmpty { return }
            for idx in indices.sorted(by: >) {
                memories.remove(at: idx)
                deleted += 1
            }
        }

        for entry in delta.delete {
            let key = memoryKey(Memory(text: entry))
            removeAll(forKey: key, keeping: nil)
        }

        for entry in delta.update {
            let oldKey = memoryKey(Memory(text: entry.old))
            guard let idx = firstIndex(forKey: oldKey) else { continue }
            let newEntry = entry.new
            let newKey = memoryKey(Memory(text: newEntry))
            if memories[idx].text != newEntry {
                memories[idx].text = newEntry
                // Also update image if present in the message
                if let image = chatImages.first {
                    memories[idx].image = image
                }
                updated += 1
            }
            removeAll(forKey: newKey, keeping: idx)
        }

        for entry in delta.add {
            let key = memoryKey(Memory(text: entry))
            if firstIndex(forKey: key) == nil {
                memories.append(Memory(text: entry, image: chatImages.first))
                added += 1
            }
        }

        if added + updated + deleted > 0 {
            doc.memories = memories
            if updated > 0 || deleted > 0 {
                addLog("Updated memory")
            } else if added > 0 {
                addLog("Saved memory")
            }
            touch()
        }
        return MemoryApplyResult(added: added, updated: updated, deleted: deleted)
    }

    private func normalizeMemoryEntry(_ entry: String, userName: String) -> String {
        var trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let lowercased = trimmed.lowercased()
        let prefix = "astra remembers that "
        if lowercased.hasPrefix(prefix) {
            trimmed = String(trimmed.dropFirst(prefix.count))
        }
        let cleanName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return trimmed }
        if lowercased.hasPrefix("the user's ") {
            let replacement = "\(cleanName)'s "
            let start = trimmed.index(trimmed.startIndex, offsetBy: "The user's ".count)
            trimmed = replacement + String(trimmed[start...])
        } else if lowercased.hasPrefix("the user ") {
            let replacement = "\(cleanName) "
            let start = trimmed.index(trimmed.startIndex, offsetBy: "The user ".count)
            trimmed = replacement + String(trimmed[start...])
        }
        return trimmed
    }

    @MainActor
    func deleteMemory(id: UUID) {
        guard let index = doc.memories.firstIndex(where: { $0.id == id }) else { return }
        recordUndoSnapshot()
        doc.memories.remove(at: index)
        addLog("Deleted memory")
        touch()
    }

    private func parseSearchCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("/search ") {
            return String(trimmed.dropFirst("/search ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lower.hasPrefix("/s ") {
            return String(trimmed.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lower.hasPrefix("search:") {
            return String(trimmed.dropFirst("search:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    
    private func cleanedWebSearchQuery(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }

        let lowered = t.lowercased()
        let prefixes = ["/search", "/s", "search:", "web search:"]
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return t
    }

    private func formatWebSourcesForSystemPrompt(
        query: String,
        items: [WebSearchService.SearchItem],
        pages: [WebSearchService.PageExcerpt]
    ) -> String {
        var lines: [String] = []
        lines.append("Web search (context only; not user message):")
        lines.append("Query: \"\(query)\"")

        if !items.isEmpty {
            lines.append("Top results:")
            for (i, item) in items.enumerated() {
                var line = "[\(i + 1)] \(item.title)"
                if !item.url.isEmpty { line += " — \(item.url)" }
                if let snip = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !snip.isEmpty {
                    line += "\nSnippet: \(snip)"
                }
                lines.append(line)
            }
        }

        if !pages.isEmpty {
            lines.append("Fetched page excerpts (use these to answer; cite by [#] where possible):")
            for (i, page) in pages.enumerated() {
                lines.append("[\(i + 1)] \(page.title) — \(page.url)")
                lines.append(page.text)
            }
        }

        return lines.joined(separator: "\n")
    }
    
    private func formatSearchResults(
        _ items: [WebSearchService.SearchItem],
        query: String? = nil
    ) -> String {
        if items.isEmpty {
            if let q = query, !q.isEmpty {
                return "No web results for \"\(q)\"."
            }
            return "No web results."
        }

        var lines: [String] = ["Web search results:"]
        if let q = query, !q.isEmpty {
            lines.append("Query: \"\(q)\"")
        }

        for (idx, item) in items.enumerated() {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = title.isEmpty ? item.url : title

            lines.append("")
            lines.append("\(idx + 1). [\(safeTitle)](\(item.url))")

            if let snippet = item.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
               !snippet.isEmpty {
                lines.append("   \(snippet)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func userMessage(text: String, images: [ImageRef], files: [FileRef]) -> AIService.Message {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [AIService.Message.ContentPart] = []
        for imageRef in images {
            if let dataURL = imageDataURL(for: imageRef) {
                parts.append(.image(url: dataURL))
            }
        }
        let fileNames = files.map { $0.originalName }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fileNames.isEmpty {
            let joinedFileNames = fileNames.joined(separator: ", ")
            parts.append(.text("Attached files: \(joinedFileNames)"))
        }
        for fileRef in files {
            parts.append(.text(fileContentDescription(for: fileRef)))
        }
        if !trimmed.isEmpty {
            parts.append(.text(trimmed))
        }
        if !parts.isEmpty {
            return AIService.Message(role: "user", content: .parts(parts))
        }
        return AIService.Message(role: "user", content: .text(trimmed))
    }

    private func fileContentForContext(for ref: FileRef,
                                 maxBytes: Int = 160_000) -> String? {
        guard let url = fileURL(for: ref) else { return nil }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }

        if let typeId = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier),
           let type = UTType(typeId),
           type.conforms(to: .pdf) {
            if let pdf = PDFDocument(data: data) {
                let pdfText = pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !pdfText.isEmpty {
                    return pdfText
                }
                return "PDF with no extractable text"
            }
        }
        
        let capped = data.prefix(maxBytes)

        guard var str = String(data: capped, encoding: .utf8)
                ?? String(data: capped, encoding: .isoLatin1) else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return "binary file (\(size))"
        }

        str = str.replacingOccurrences(of: "\r\n", with: "\n")
                 .replacingOccurrences(of: "\r", with: "\n")
                 .trimmingCharacters(in: .whitespacesAndNewlines)

        return str.isEmpty ? nil : str
    }

    private func fileContentDescription(for ref: FileRef) -> String {
            let name = ref.displayName
            guard let url = fileURL(for: ref) else {
                return "File \(name) URL unavailable."
            }

            // 1. SECURITY SCOPE FIX: Access the file safely
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // 2. Read Data
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return "File \(name) content unavailable."
            }

            // 3. Handle PDF specific extraction
            if let typeId = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier),
               let type = UTType(typeId),
               type.conforms(to: .pdf) {
                if let pdf = PDFDocument(url: url) {
                    let pdfText = pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !pdfText.isEmpty {
                        let capped = pdfText
                        return "File \(name) contents:\n\"\"\"\n\(capped)\n\"\"\""
                    }
                    return "Attached file \(name) is a PDF with no extractable text."
                }
            }

            // 4. Handle Text files (Swift, MD, TXT, JSON, etc)
            // Try UTF-8 first, then ASCII/Lossy
            var textContent = String(data: data, encoding: .utf8)
            if textContent == nil {
                textContent = String(data: data, encoding: .ascii)
            }
            
            if let string = textContent {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                let capped = trimmed
                return "File \(name) contents:\n\"\"\"\n\(capped)\n\"\"\""
            }

            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            let typeId = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? "unknown type"
            return "Attached file \(name) is binary (\(typeId), \(size))."
        }

    private func imagePromptWithPersonality(_ prompt: String, personality: String) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return "" }
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPersonality.isEmpty else { return trimmedPrompt }
        return "\(trimmedPrompt)\n\nStyle guidance: \(trimmedPersonality)"
    }

    private func clarificationMergedText(original: String?,
                                         question: String?,
                                         clarificationText: String,
                                         clarificationImageCount: Int,
                                         clarificationFileCount: Int) -> String? {
        guard let original else { return nil }
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClarification = clarificationText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep this merged text maximally "natural" so it can safely be used as model input
        // without accidentally leaking behind-the-scenes headers back to the user.
        var merged = trimmedOriginal.isEmpty ? "" : trimmedOriginal

        if !trimmedClarification.isEmpty {
            if !merged.isEmpty { merged += "\n\n" }
            merged += "Clarification: \(trimmedClarification)"
        } else if clarificationImageCount > 0 || clarificationFileCount > 0 {
            var parts: [String] = []
            if clarificationImageCount > 0 {
                parts.append(clarificationImageCount == 1 ? "an image" : "\(clarificationImageCount) images")
            }
            if clarificationFileCount > 0 {
                parts.append(clarificationFileCount == 1 ? "a file" : "\(clarificationFileCount) files")
            }
            let joinedParts = parts.joined(separator: " and ")
            if !merged.isEmpty { merged += "\n\n" }
            merged += "Clarification: provided \(joinedParts)."
        }

        return merged.isEmpty ? nil : merged
    }

    @MainActor
    private func storePendingClarification(originalText: String,
                                           originalImages: [ImageRef],
                                           originalFiles: [FileRef],
                                           question: String) {
        let now = Date().timeIntervalSince1970
        doc.pendingClarification = PendingClarification(originalText: originalText,
                                                        originalImages: originalImages,
                                                        originalFiles: originalFiles,
                                                        question: question,
                                                        createdAt: now)
        addLog("Asked for clarification")
        touch()
    }

    @MainActor
    private func setChatReplyText(replyId: UUID, text: String) {
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return }
        doc.chat.messages[index].text = text
    }
    
    @MainActor
    private func setChatReplyWebSearch(replyId: UUID, webSearch: WebSearchPayload?) {
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return }
        doc.chat.messages[index].webSearch = webSearch
    }

    @MainActor
    private func chatReplyText(replyId: UUID) -> String? {
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return nil }
        return doc.chat.messages[index].text
    }

    @MainActor
    private func setChatReplyImages(replyId: UUID, images: [ImageRef]) {
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return }
        doc.chat.messages[index].images = images
    }

    private func imageEditPayload(for ref: ImageRef) -> (data: Data, filename: String, mimeType: String)? {
        guard let url = imageURL(for: ref) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "png", let data = try? Data(contentsOf: url) {
            return (data, url.lastPathComponent, "image/png")
        }
        guard let image = NSImage(contentsOf: url),
              let png = pngData(from: image) else {
            return nil
        }
        return (png, "image.png", "image/png")
    }

    private func openAIMessages(from history: [ChatMsg], systemPrompts: [String]) -> [AIService.Message] {
        var messages: [AIService.Message] = []
        for prompt in systemPrompts {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                messages.append(AIService.Message(role: "system", content: .text(trimmed)))
            }
        }
        let previousAttachmentMessage = history.dropLast().last {
            $0.role == .user && (!$0.images.isEmpty || !$0.files.isEmpty)
        }
        let previousImages = previousAttachmentMessage?.images ?? []
        let previousFiles = previousAttachmentMessage?.files ?? []
        let lastMessageId = history.last?.id
        for msg in history {
            let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAttachments = !msg.images.isEmpty || !msg.files.isEmpty
            if trimmed.isEmpty && !hasAttachments { continue }
            let role = msg.role == .user ? "user" : "assistant"
            if msg.role == .user {
                var parts: [AIService.Message.ContentPart] = []
                var includesAttachment = false
                for imageRef in msg.images {
                    if let dataURL = imageDataURL(for: imageRef) {
                        parts.append(.image(url: dataURL))
                        includesAttachment = true
                    }
                }
                let fileNames = msg.files.map { $0.originalName }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !fileNames.isEmpty {
                    let joinedFileNames = fileNames.joined(separator: ", ")
                    parts.append(.text("Attached files: \(joinedFileNames)"))
                    includesAttachment = true
                }
                for fileRef in msg.files {
                    parts.append(.text(fileContentDescription(for: fileRef)))
                    includesAttachment = true
                }
                if msg.id == lastMessageId,
                   msg.images.isEmpty {
                    for imageRef in previousImages {
                        if let dataURL = imageDataURL(for: imageRef) {
                            parts.append(.image(url: dataURL))
                            includesAttachment = true
                        }
                    }
                }
                if msg.id == lastMessageId,
                   msg.files.isEmpty,
                   !previousFiles.isEmpty {
                    let previousNames = previousFiles.map { $0.originalName }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !previousNames.isEmpty {
                        let joinedPreviousNames = previousNames.joined(separator: ", ")
                        parts.append(.text("Previously attached files: \(joinedPreviousNames)"))
                    }
                    for fileRef in previousFiles {
                        parts.append(.text(fileContentDescription(for: fileRef)))
                    }
                    includesAttachment = true
                }
                if !trimmed.isEmpty {
                    parts.append(.text(trimmed))
                }
                let hasAttachments = includesAttachment
                if hasAttachments {
                    if !parts.isEmpty {
                        messages.append(AIService.Message(role: role, content: .parts(parts)))
                    }
                } else if !trimmed.isEmpty {
                    messages.append(AIService.Message(role: role, content: .text(trimmed)))
                }
            } else if !trimmed.isEmpty {
                messages.append(AIService.Message(role: role, content: .text(trimmed)))
            }
        }
        return messages
    }

    private func imageDataURL(for ref: ImageRef) -> String? {
        guard let url = imageURL(for: ref),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        let mimeType: String
        switch ext {
        case "png":
            mimeType = "image/png"
        case "jpg", "jpeg":
            mimeType = "image/jpeg"
        case "gif":
            mimeType = "image/gif"
        case "heic":
            mimeType = "image/heic"
        case "heif":
            mimeType = "image/heif"
        default:
            mimeType = "application/octet-stream"
        }
        let base64 = data.base64EncodedString()
        return "data:\(mimeType);base64,\(base64)"
    }

    private func routerImageDataURL(for ref: ImageRef,
                                    maxPixelSize: CGFloat,
                                    quality: CGFloat) -> String? {
        guard let url = imageURL(for: ref),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return imageDataURL(for: ref)
        }
        let maxDimension = max(size.width, size.height)
        let scale = min(1.0, maxPixelSize / maxDimension)
        if scale >= 0.999 {
            return imageDataURL(for: ref)
        }
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        if let data = jpegData(from: resized, quality: quality) {
            let base64 = data.base64EncodedString()
            return "data:image/jpeg;base64,\(base64)"
        }
        return imageDataURL(for: ref)
    }

    @MainActor
    private func appendChatDelta(replyId: UUID, delta: String) {
        guard !delta.isEmpty else { return }
        guard !cancelledChatReplyIds.contains(replyId) else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else { return }
        doc.chat.messages[index].text += delta
    }

    @MainActor
    private func finishChatReply(replyId: UUID) {
        guard !cancelledChatReplyIds.contains(replyId) else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else {
            pendingChatReplies = max(0, pendingChatReplies - 1)
            return
        }
        recordUndoSnapshot()
        pendingChatReplies = max(0, pendingChatReplies - 1)

        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }

        doc.chat.messages[index].ts = Date().timeIntervalSince1970

        let raw = doc.chat.messages[index].text
        let cleaned = sanitizedUserFacingChatText(raw)

        if cleaned.isEmpty {
            // If the reply included an image, the image *is* the deliverable.
            doc.chat.messages[index].text = doc.chat.messages[index].images.isEmpty ? "No response from the model." : "Here you go."
        } else {
            doc.chat.messages[index].text = cleaned
        }

        let notificationBody = doc.chat.messages[index].text
        addLog("Astra replied")

        upsertChatHistory(doc.chat)
        touch()
        sendModelReplyNotificationIfNeeded(title: "Astra replied", body: notificationBody)
    }
    
    /// Strips non-user-facing “process” text that sometimes leaks from the routing/worker prompts.
    /// This is a safety net; the prompts should already discourage this output.
    private func sanitizedUserFacingChatText(_ raw: String) -> String {
        var text = raw

        // Remove UUIDs (board ids, entry ids, etc.)
        do {
            let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
            let re = try NSRegularExpression(pattern: uuidPattern)
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            text = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        } catch {}

        // Remove common internal markers like "(board id ... )" without dropping the whole line.
        do {
            let patterns: [String] = [
                "\\(\\s*board id[^\\)]*\\)",
                "board id\\s*[:#]?\\s*"
            ]
            for pattern in patterns {
                let re = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                text = re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            }
        } catch {}

        let lines = text.components(separatedBy: .newlines)
        var kept: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { kept.append(""); continue }

            let lowered = trimmed.lowercased()
            if lowered.hasPrefix("generated image") { continue }
            if lowered.hasPrefix("edited image") { continue }
            if lowered.hasPrefix("edited sims screenshot") { continue }
            if lowered.hasPrefix("original request:") { continue }
            if lowered.hasPrefix("clarification question:") { continue }
            if lowered.hasPrefix("user clarification:") { continue }
            if lowered == "here you go:" { continue }

            kept.append(trimmed)
        }

        // Collapse excessive blank lines
        var compact: [String] = []
        var lastWasBlank = false
        for line in kept {
            if line.isEmpty {
                if !lastWasBlank { compact.append(""); lastWasBlank = true }
            } else {
                compact.append(line); lastWasBlank = false
            }
        }

        return compact.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func finishImageReply(replyId: UUID,
                                  prompt: String,
                                  revisedPrompt: String?,
                                  imageRef: ImageRef) {
        guard !cancelledChatReplyIds.contains(replyId) else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else {
            pendingChatReplies = max(0, pendingChatReplies - 1)
            return
        }
        recordUndoSnapshot()
        pendingChatReplies = max(0, pendingChatReplies - 1)

        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }

        // Image replies are already self-evident in the UI; keep the caption strictly user-facing.
        doc.chat.messages[index].ts = Date().timeIntervalSince1970
        doc.chat.messages[index].images = [imageRef]
        doc.chat.messages[index].text = "Here you go."

        addLog("Astra generated an image")

        touch()
        sendModelReplyNotificationIfNeeded(title: "Astra generated an image", body: "Here you go.")
    }

    @MainActor
    private func failChatReply(replyId: UUID, error: Error) {
        guard !cancelledChatReplyIds.contains(replyId) else { return }
        guard let index = doc.chat.messages.firstIndex(where: { $0.id == replyId }) else {
            pendingChatReplies = max(0, pendingChatReplies - 1)
            return
        }
        recordUndoSnapshot()
        pendingChatReplies = max(0, pendingChatReplies - 1)
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        chatWarning = "Model request failed: \(message)"
        if !doc.ui.panels.chat.isOpen {
            chatNeedsAttention = true
        }
        let fallback = "Request failed: \(message)"
        if doc.chat.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.chat.messages[index].text = fallback
        } else {
            doc.chat.messages[index].text += "\n\n\(fallback)"
        }
        addLog("Model request failed")
        touch()
    }



    @MainActor
    private func sendModelReplyNotificationIfNeeded(title: String, body: String) {
        let bodyText = notificationBody(from: body)
        requestNotificationAuthorizationIfNeeded()
        enqueueNotification(center: UNUserNotificationCenter.current(),
                            title: title,
                            body: bodyText)
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
                print("Failed to add notification request: \(error.localizedDescription)")
            }
        }
    }

    private func notificationBody(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New message from Astra." }
        let maxLength = 180
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "..."
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
        let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let width = min(max(contentSize.width, minWidth), maxWidth)
        let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
        let rect = CGRect(x: worldCenter.x - width / 2,
                          y: worldCenter.y - height / 2,
                          width: width,
                          height: height)
        let id = createEntry(type: .text, frame: rect, data: .text(trimmed), createdBy: message.role)
        selection = [id]
    }

    @MainActor
    @discardableResult
    func pinChatInputText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let style = TextStyle.default()
        let font = TextEntryMetrics.font(for: style)
        let contentSize = TextEntryMetrics.contentSize(for: trimmed, font: font)
        let minWidth: CGFloat = 240
        let maxWidth: CGFloat = 360
        let width = min(max(contentSize.width, minWidth), maxWidth)
        let height = TextEntryMetrics.height(for: trimmed, maxWidth: width, font: font)
        let screenCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let worldCenter = worldPoint(from: screenCenter)
        let rect = CGRect(x: worldCenter.x - width / 2,
                          y: worldCenter.y - height / 2,
                          width: width,
                          height: height)
        let id = createEntry(type: .text, frame: rect, data: .text(trimmed), createdBy: .user)
        selection = [id]
        return true
    }

    private func imageRect(for ref: ImageRef, centeredAt point: CGPoint, maxSide: CGFloat) -> CGRect {
        if let url = imageURL(for: ref), let nsImage = NSImage(contentsOf: url) {
            let size = nsImage.size
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
        if case .shape(let kind) = entry.data, kind == .circle {
            let rx = rect.width / 2
            let ry = rect.height / 2
            guard rx > 0, ry > 0 else { return false }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = (worldPoint.x - center.x) / rx
            let dy = (worldPoint.y - center.y) / ry
            return (dx * dx + dy * dy) <= 1.0
        }
        return rect.contains(worldPoint)
    }
}


private func typeDisplay(_ type: EntryType) -> String {
    switch type {
    case .text: return "text"
    case .image: return "image"
    case .file: return "file"
    case .shape: return "shape"
    case .line: return "line"
    }
}
