import SwiftUI

struct ComposerView: View {
    @Bindable var coordinator: ChatCoordinator
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: InterfaceMetrics.spacingXS) {
            inputContainer
            hint
        }
        .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
        .padding(.vertical, InterfaceMetrics.spacingM)
        .onAppear {
            isComposerFocused = true
        }
        .onChange(of: coordinator.composerFocusRequest) {
            isComposerFocused = true
        }
    }

    private var inputContainer: some View {
        HStack(alignment: .bottom, spacing: InterfaceMetrics.spacingS) {
            TextField("Message PrivateAI", text: $coordinator.draft, axis: .vertical)
                .focused($isComposerFocused)
                .accessibilityIdentifier("chat.composer")
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...12)
                .padding(.leading, InterfaceMetrics.spacingXS)
                .padding(.vertical, InterfaceMetrics.spacingXS)
                .onSubmit {
                    if coordinator.canSend { coordinator.send() }
                }

            actionButton
        }
        .padding(.horizontal, InterfaceMetrics.spacingM)
        .padding(.vertical, InterfaceMetrics.spacingS)
        .background(
            RoundedRectangle(cornerRadius: InterfaceMetrics.composerCornerRadius, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InterfaceMetrics.composerCornerRadius, style: .continuous)
                .stroke(
                    isComposerFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: isComposerFocused ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isComposerFocused)
    }

    @ViewBuilder
    private var actionButton: some View {
        if coordinator.isGenerating {
            Button(action: coordinator.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("chat.stop.button")
            .help("Stop generation")
        } else {
            Button(action: coordinator.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityIdentifier("chat.send.button")
            .disabled(!coordinator.canSend)
            .help("Send message")
        }
    }

    private var hint: some View {
        Text("Press Return to send · Shift-Return for a new line")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}