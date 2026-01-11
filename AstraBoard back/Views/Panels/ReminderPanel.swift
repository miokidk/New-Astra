import SwiftUI

struct ReminderPanel: View {
    @EnvironmentObject var store: BoardStore

    var body: some View {
        // Only show the panel if there's an active reminder to display
        if let reminderId = store.activeReminderPanelId,
           let reminder = store.getReminder(id: reminderId) {
            
            VStack(alignment: .leading, spacing: 10) {
                Text(reminder.title)
                    .font(.headline)
                
                Text(reminder.preparedMessage ?? reminder.work)
                    .font(.body)
                
                HStack {
                    Spacer()
                    Button("Dismiss") {
                        store.clearActiveReminderPanel()
                    }
                }
            }
            .padding()
            .frame(width: 320, height: 200) // Match default size in PanelsState
            .background(Color.secondarySystemBackground)
            .cornerRadius(10)
            .shadow(radius: 5)
            .position(x: 400, y: 100) // Match default position in PanelsState
            // TODO: Make position draggable and savable
        }
    }
}
