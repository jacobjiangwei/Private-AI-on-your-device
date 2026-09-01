import SwiftUI

struct ConversationSidebar: View {
    @Bindable var coordinator: ChatCoordinator

    var body: some View {
        VStack(spacing: 0) {
            brandHeader
            List(selection: selection) {
                ForEach(coordinator.conversations) { conversation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .lineLimit(2)
                        Text(conversation.updatedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(conversation.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            coordinator.deleteConversation(conversation)
                        }
                    }
                }
            }
        }
        .navigationTitle("PrivateAI")
        .toolbar {
            ToolbarItem {
                Button(action: coordinator.newConversation) {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("conversation.new.button")
                .help("New conversation")
            }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: InterfaceMetrics.spacingS) {
            BrandMascotView(size: 30)
            Text("PrivateAI")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterfaceMetrics.spacingM)
        .padding(.top, InterfaceMetrics.spacingS)
        .padding(.bottom, InterfaceMetrics.spacingM)
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { coordinator.selectedConversation?.id },
            set: { id in
                if let id { coordinator.selectConversation(id: id) }
            }
        )
    }
}