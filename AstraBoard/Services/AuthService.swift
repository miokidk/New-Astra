import Foundation
import Combine
import Supabase

@MainActor
final class AuthService: ObservableObject {
    enum AuthServiceError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Supabase is not configured."
            }
        }
    }

    @Published private(set) var user: User?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSendingLink: Bool = false

    private let supabase: SupabaseClient?
    private var authStateTask: Task<Void, Never>?

    init(supabaseService: SupabaseService? = nil) {
        let resolvedService = supabaseService ?? (try? SupabaseService())
        if let resolvedService {
            self.supabase = resolvedService.client
            self.user = resolvedService.client.auth.currentUser
        } else {
            self.supabase = nil
            self.user = nil
            self.statusMessage = "Supabase not configured."
            NSLog("Supabase auth: missing config; sign-in disabled.")
        }

        observeAuthChanges()
    }

    deinit {
        authStateTask?.cancel()
    }

    var client: SupabaseClient? {
        supabase
    }

    func sendMagicLink(email: String) async throws {
        guard let supabase else {
            statusMessage = "Supabase not configured."
            NSLog("Supabase auth: missing config when sending link.")
            throw AuthServiceError.notConfigured
        }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSendingLink = true
        defer { isSendingLink = false }

        do {
            try await supabase.auth.signInWithOTP(
                email: trimmed,
                redirectTo: URL(string: "astraboard://auth-callback")
            )
            statusMessage = "Sign-in link sent to \(trimmed)."
            NSLog("Supabase auth: magic link sent to \(trimmed)")
        } catch {
            statusMessage = "Failed to send link: \(error.localizedDescription)"
            NSLog("Supabase auth: failed to send magic link: \(error)")
            throw error
        }
    }

    func handleOpenURL(_ url: URL) async throws {
        guard let supabase else { throw AuthServiceError.notConfigured }
        do {
            let session = try await supabase.auth.session(from: url)
            user = session.user
            statusMessage = "Signed in as \(session.user.email ?? "Unknown email")."
            NSLog("Supabase auth: session established")
        } catch {
            statusMessage = "Sign-in failed: \(error.localizedDescription)"
            NSLog("Supabase auth: failed to establish session: \(error)")
            throw error
        }
    }

    func currentUser() -> User? {
        user
    }

    static func isAuthCallbackURL(_ url: URL) -> Bool {
        guard url.scheme == "astraboard" else { return false }
        if url.host == "auth-callback" { return true }
        return url.path.contains("auth-callback")
    }

    private func observeAuthChanges() {
        guard let supabase else { return }
        authStateTask = Task { [weak self] in
            for await change in supabase.auth.authStateChanges {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.user = change.session?.user
                }
            }
        }
    }
}
