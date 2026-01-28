import Foundation
import Combine

@MainActor
final class AstraIOSAppModel: ObservableObject {
    let persistence = PersistenceService()
    let aiService = AIService()
    let webSearchService = WebSearchService()
    let authService = AuthService()

    var defaultBoardId: UUID { persistence.defaultBoardId() }
    func createBoard() -> UUID { persistence.createBoard().id }
}
