import SwiftUI
import LLMCore

struct ChatDetailView: View {
    @Bindable var coordinator: ChatCoordinator
    @State private var showsLocationDemo = false
    @State private var showsModelDetails = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if coordinator.selectedConversation == nil {
                ContentUnavailableView(
                    "Start a conversation",
                    systemImage: "bubble.left.and.bubble.right"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptWebView(
                    messages: coordinator.messages,
                    revision: coordinator.transcriptRevision,
                    onCopy: coordinator.copyMessage
                )
            }
            Divider()
            ComposerView(coordinator: coordinator)
        }
        .navigationTitle(coordinator.selectedConversation?.title ?? "PrivateAI")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: InterfaceMetrics.spacingM) {
            Circle()
                .fill(coordinator.ollama.state.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(coordinator.ollama.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if coordinator.ollama.state.isReady {
                Picker("Model", selection: modelSelection) {
                    ForEach(coordinator.ollama.models, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240, minHeight: InterfaceMetrics.controlHeight)
                ModelPerformanceLabel(metrics: coordinator.generationMetrics)
                Button {
                    showsModelDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .frame(width: InterfaceMetrics.controlHeight, height: InterfaceMetrics.controlHeight)
                .contentShape(Rectangle())
                .accessibilityIdentifier("model.transparency.button")
                .help("Model details and system prompt")
                .popover(isPresented: $showsModelDetails, arrowEdge: .bottom) {
                    ModelTransparencyView(coordinator: coordinator)
                }
            } else {
                Button("Open Ollama") {
                    Task { await coordinator.ollama.openOllama() }
                }
                Button("Retry") {
                    Task { await coordinator.ollama.refresh() }
                }
            }
            Spacer()
            Button {
                showsLocationDemo.toggle()
            } label: {
                Image(systemName: "location.circle")
            }
            .buttonStyle(.plain)
            .frame(width: InterfaceMetrics.controlHeight, height: InterfaceMetrics.controlHeight)
            .contentShape(Rectangle())
            .accessibilityIdentifier("location.demo.button")
            .help("Core Location demo")
            .popover(isPresented: $showsLocationDemo, arrowEdge: .bottom) {
                LocationDemoView()
            }
            if !coordinator.activity.isEmpty {
                Text(coordinator.activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, InterfaceMetrics.pageHorizontalPadding)
        .frame(height: InterfaceMetrics.headerHeight)
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { coordinator.ollama.selectedModel },
            set: { coordinator.selectModel($0) }
        )
    }
}

private struct ModelTransparencyView: View {
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceMetrics.spacingM) {
            Text("Model transparency")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: InterfaceMetrics.spacingL) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(coordinator.ollama.selectedModel).textSelection(.enabled)
                }
                GridRow {
                    Text("Keep alive").foregroundStyle(.secondary)
                    Text("Until App exit (`-1`)")
                }
                GridRow {
                    Text("Warmup").foregroundStyle(.secondary)
                    Text(coordinator.warmupState).textSelection(.enabled)
                }
                GridRow {
                    Text("Warmup work").foregroundStyle(.secondary)
                    Text("Load model, evaluate system prompt, cache Tool schemas")
                }
                if let elapsed = coordinator.warmupElapsedSeconds {
                    GridRow {
                        Text("Warmup time").foregroundStyle(.secondary)
                        Text("\(elapsed, format: .number.precision(.fractionLength(2))) s")
                    }
                }
                if let tokens = coordinator.warmupPrefixTokens {
                    GridRow {
                        Text("Prefix tokens").foregroundStyle(.secondary)
                        Text(tokens, format: .number)
                    }
                }
                GridRow {
                    Text("System prompt").foregroundStyle(.secondary)
                    Text("Version \(LLMCoreSystemPrompt.version)")
                }
            }
            .font(.caption)

            Divider()

            ScrollView {
                Text(LLMCoreSystemPrompt.current)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(InterfaceMetrics.spacingM)
            }
            .frame(width: 560, height: 320)
            .background(.background.secondary, in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.fieldCornerRadius
            ))
        }
        .padding(InterfaceMetrics.spacingL)
        .frame(width: 600)
        .accessibilityIdentifier("model.transparency.panel")
    }
}

private struct ModelPerformanceLabel: View {
    let metrics: GenerationMetrics

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            Label {
                Text(metrics.statusText(at: context.date))
                    .monospacedDigit()
            } icon: {
                Image(systemName: "gauge.with.dots.needle.33percent")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 190, height: InterfaceMetrics.controlHeight, alignment: .center)
            .padding(.horizontal, InterfaceMetrics.controlHorizontalPadding)
            .background(.quaternary, in: RoundedRectangle(
                cornerRadius: InterfaceMetrics.compactCornerRadius
            ))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("model.performance.label")
            .accessibilityLabel(
                "Model performance, \(metrics.statusText(at: context.date))"
            )
        }
    }
}