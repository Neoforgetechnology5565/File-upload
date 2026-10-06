import Observation
import ScanCore
import SwiftUI

@Observable
@MainActor
final class ProcessingViewModel {
    enum State: Equatable {
        case idle
        case running
        case completed
        case failed(AppError)
    }

    private(set) var state: State = .idle
    private(set) var steps: [ProcessingStep] = []

    @ObservationIgnored private let service: ScanProcessingService
    @ObservationIgnored private var task: Task<Void, Never>?

    init(service: ScanProcessingService) {
        self.service = service
    }

    var currentStep: ProcessingStep? { state == .running ? steps.last : nil }

    func start(capture: CaptureOutput, draft: ScanDraft, onSuccess: @escaping (ProcessedScan) -> Void) {
        switch state {
        case .idle, .failed: break
        case .running, .completed: return
        }
        state = .running
        steps = []
        let service = self.service
        task = Task { [weak self] in
            do {
                let result = try await service.process(capture, draft: draft) { step in
                    Task { @MainActor in self?.record(step) }
                }
                try Task.checkCancellation()
                self?.state = .completed
                onSuccess(result)
            } catch {
                self?.state = .failed(AppError.from(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func record(_ step: ProcessingStep) {
        guard steps.last != step else { return }
        steps.append(step)
    }
}

struct ProcessingView: View {
    @Environment(AppModel.self) private var model
    @State private var viewModel: ProcessingViewModel

    init(viewModel: ProcessingViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            switch viewModel.state {
            case .failed(let error):
                ContentUnavailableView {
                    Label(error.title, systemImage: "exclamationmark.triangle")
                } description: {
                    Text([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
                } actions: {
                    if model.scanFlow.captureOutput != nil && error != .noGeometryCaptured {
                        Button("Try Again") { start() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Discard Scan", role: .destructive) { model.discardCurrentScan() }
                }
            default:
                ProgressView()
                    .controlSize(.large)
                Text(ScanFeedback.processing.message)
                    .font(.title2.bold())
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.steps, id: \.self) { step in
                        HStack(spacing: 10) {
                            if step == viewModel.currentStep {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                            Text(step.displayName)
                                .foregroundStyle(step == viewModel.currentStep ? .primary : .secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)
                .animation(.default, value: viewModel.steps)
                Text("Processing runs on-device. Large scans can take up to a minute.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if viewModel.state == .running {
                Button("Cancel", role: .cancel) {
                    viewModel.cancel()
                }
            }
        }
        .padding()
        .readableWidth()
        .navigationTitle("Processing")
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled()
        .onAppear(perform: start)
        .onChange(of: viewModel.state) { _, newValue in
            if newValue == .failed(.cancelled) {
                model.discardCurrentScan()
            }
        }
    }

    private func start() {
        guard let capture = model.scanFlow.captureOutput else {
            if model.scanFlow.processed != nil { model.replaceTop(with: .result) }
            return
        }
        let flow = model.scanFlow
        let appModel = model
        viewModel.start(capture: capture, draft: flow.draft) { processed in
            flow.processed = processed
            flow.captureOutput = nil // release raw capture memory
            appModel.replaceTop(with: .result)
        }
    }
}
