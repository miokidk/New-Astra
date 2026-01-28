#if os(macOS)
import Foundation
import AppKit

extension PersistenceService {
    func export(doc: BoardDoc) {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "AstraBoard.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(doc)
                try data.write(to: url)
            } catch {
                NSLog("Export failed: \(error)")
            }
        }
    }

    func importDoc() -> BoardDoc? {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            var doc = try decoder.decode(BoardDoc.self, from: data)
            doc.updatedAt = Date().timeIntervalSince1970
            return doc
        } catch {
            NSLog("Import failed: \(error)")
            return nil
        }
    }
}
#endif
