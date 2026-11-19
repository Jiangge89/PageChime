import PhotosUI
import SwiftUI
import VisionKit

/// The document camera: finds the page edges, flattens the page and fixes
/// its perspective, which makes text recognition much more reliable than a
/// plain photo. Unavailable in the simulator (see `PageScanSection`).
struct DocumentScannerView: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: VNDocumentCameraViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScannerView

        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.dismiss()
            if !pages.isEmpty { parent.onScan(pages) }
        }

        func documentCameraViewControllerDidCancel(_: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_: VNDocumentCameraViewController, didFailWithError _: Error) {
            parent.dismiss()
        }
    }
}

/// "Scan Page" button with the page's status. Uses the document camera on a
/// device and a photo picker where there is no camera (the simulator).
struct PageScanSection: View {
    @ObservedObject var viewModel: ReadingSessionViewModel
    @State private var showScanner = false
    @State private var photo: PhotosPickerItem?

    private var chinese: Bool { viewModel.language == .chinese }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                scanButton
                if viewModel.pageStatus != .none {
                    Button {
                        viewModel.clearPage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(chinese ? "清除这一页" : "Clear page")
                }
            }
            statusLine
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { pages in
                Task { await viewModel.scanPage(pages) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await viewModel.scanPage([image])
                }
                photo = nil
            }
        }
    }

    @ViewBuilder
    private var scanButton: some View {
        let label = Label(
            chinese ? "扫描这一页" : "Scan Page",
            systemImage: "doc.viewfinder"
        )
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Theme.card)
        .foregroundStyle(Theme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 12))

        if DocumentScannerView.isAvailable {
            Button { showScanner = true } label: { label }
                .disabled(isBusy)
        } else {
            PhotosPicker(selection: $photo, matching: .images) { label }
                .disabled(isBusy)
        }
    }

    private var isBusy: Bool {
        viewModel.pageStatus == .reading || viewModel.pageStatus == .analyzing
    }

    @ViewBuilder
    private var statusLine: some View {
        switch viewModel.pageStatus {
        case .none:
            Text(chinese
                ? "先扫描书页，音效会在读到时立刻响起"
                : "Scan the page first and its sounds play the moment you read them")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .reading, .analyzing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(viewModel.pageStatus == .reading
                    ? (chinese ? "正在识别文字…" : "Reading the page…")
                    : (chinese ? "正在准备音效…" : "Finding the sounds…"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .ready(let cues):
            Label(
                chinese ? "这一页准备好了：\(cues) 个音效" : "Page ready: \(cues) \(cues == 1 ? "sound" : "sounds")",
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.accent)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
