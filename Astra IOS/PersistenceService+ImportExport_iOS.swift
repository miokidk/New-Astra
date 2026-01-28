#if os(iOS)
import Foundation

extension PersistenceService {
    func export(doc: BoardDoc) {
        // iOS export will be done via share sheet / SwiftUI fileExporter later.
        // For now, we write a temp file so you have *something* to share when you wire UI.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("AstraBoard.json")
            try data.write(to: url, options: [.atomic])
            NSLog("iOS export wrote temp file: \(url)")
        } catch {
            NSLog("iOS export failed: \(error)")
        }
    }

    func importDoc() -> BoardDoc? {
        // iOS import will be done via UIDocumentPicker / SwiftUI fileImporter later.
        return nil
    }
}
#endif
