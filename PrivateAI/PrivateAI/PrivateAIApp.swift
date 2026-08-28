import SwiftUI

@main
struct PrivateAIApp: App {
    var body: some Scene {
        Window("PrivateAI", id: "main") {
            PrivateAIApplicationRootView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(
                        name: LocalChatNotifications.newSession,
                        object: nil
                    )
                }
                .keyboardShortcut("n")
            }
        }
    }
}
