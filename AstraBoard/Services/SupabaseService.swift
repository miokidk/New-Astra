import Foundation
import Supabase

enum SupabaseConfigError: LocalizedError {
    case missingURL
    case invalidURL(String)
    case missingPublishableKey

    var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Missing SUPABASE_URL in Info.plist."
        case .invalidURL(let value):
            return "Invalid SUPABASE_URL value: \(value)"
        case .missingPublishableKey:
            return "Missing SUPABASE_PUBLISHABLE_KEY in Info.plist."
        }
    }
}

@MainActor
final class SupabaseService {
    let client: SupabaseClient
    let url: URL
    let publishableKey: String

    init(bundle: Bundle = .main) throws {
        guard let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseConfigError.missingURL
        }
        guard let url = URL(string: urlString) else {
            throw SupabaseConfigError.invalidURL(urlString)
        }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseConfigError.missingPublishableKey
        }

        self.url = url
        self.publishableKey = key
        let options = SupabaseClientOptions(
            auth: .init(emitLocalSessionAsInitialSession: true)
        )
        self.client = SupabaseClient(supabaseURL: url, supabaseKey: key, options: options)
    }
}
