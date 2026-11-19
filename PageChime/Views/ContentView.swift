import PhotosUI
import SwiftUI

/// The reading flow: home → page scanned → reading → the end.
struct ContentView: View {
    @StateObject private var viewModel = ReadingSessionViewModel()
    @State private var screen: Screen = .home
    @State private var showSettings = false
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var photo: PhotosPickerItem?
    /// The scan in progress redoes the current page instead of adding one.
    @State private var rescanning = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Onboarding opened again from Settings.
    @State private var replayingOnboarding = false

    enum Screen { case home, page, reading, recap }

    private var copy: Copy { Copy(chinese: viewModel.language == .chinese) }

    var body: some View {
        ZStack {
            Theme.night.ignoresSafeArea()

            if !hasCompletedOnboarding || replayingOnboarding {
                OnboardingView(viewModel: viewModel, isReplay: replayingOnboarding) {
                    hasCompletedOnboarding = true
                    replayingOnboarding = false
                    screen = .home
                }
                .transition(.opacity)
            } else {
                flow
            }
        }
        .animation(.easeInOut(duration: 0.35), value: screen)
        .animation(.easeInOut(duration: 0.35), value: hasCompletedOnboarding)
        .animation(.easeInOut(duration: 0.35), value: replayingOnboarding)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel) {
                showSettings = false
                replayingOnboarding = true
            }
        }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { pages in handleScan(pages) }
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    handleScan([image])
                }
                photo = nil
            }
        }
    }

    @ViewBuilder
    private var flow: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(
                    copy: copy,
                    language: viewModel.language,
                    canScan: viewModel.canScanPages,
                    onScan: { scan(replacing: false) },
                    onReadWithoutScanning: readWithoutScanning,
                    onLanguage: { viewModel.changeLanguage($0) },
                    onSettings: { showSettings = true }
                )
                .transition(.opacity)
            case .page:
                PageReadyView(
                    copy: copy,
                    chinese: viewModel.language == .chinese,
                    status: viewModel.pageStatus,
                    page: viewModel.page,
                    pageNumberHint: rescanning ? (viewModel.page?.number ?? 1) : (viewModel.story?.pages ?? 0) + 1,
                    onBack: backFromPage,
                    onRescan: { scan(replacing: isCurrentPageScan || rescanning) },
                    onStart: startFromPage
                )
                .transition(.opacity)
            case .reading:
                ReadingView(
                    copy: copy,
                    state: viewModel.state,
                    isPaused: viewModel.isPaused,
                    page: viewModel.page,
                    firedCueCount: viewModel.firedCueCount,
                    sceneIDs: viewModel.sceneIDs,
                    lastSound: viewModel.lastOneShot,
                    canScan: viewModel.canScanPages,
                    onStop: {
                        viewModel.endStory()
                        screen = .recap
                    },
                    onPauseToggle: {
                        if viewModel.isPaused { viewModel.resumeReading() } else { viewModel.pauseReading() }
                    },
                    onNextPage: {
                        viewModel.pauseReading()
                        scan(replacing: false)
                    }
                )
                .transition(.opacity)
            case .recap:
                RecapView(
                    copy: copy,
                    story: viewModel.story,
                    onAnotherStory: finishStory,
                    onDone: finishStory
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: - Flow

    /// Whether the page screen shows a page that scanned successfully.
    private var isCurrentPageScan: Bool {
        if case .ready = viewModel.pageStatus { return true }
        return false
    }

    /// The document camera on a device, a photo picker in the simulator.
    private func scan(replacing: Bool) {
        rescanning = replacing
        if DocumentScannerView.isAvailable {
            showScanner = true
        } else {
            showPhotoPicker = true
        }
    }

    private func handleScan(_ images: [UIImage]) {
        viewModel.beginStory()
        screen = .page
        let replacing = rescanning
        Task { await viewModel.scanPage(images, replacing: replacing) }
    }

    private func startFromPage() {
        if viewModel.isPaused {
            viewModel.resumeReading()
        } else {
            viewModel.startReading()
        }
        rescanning = false
        screen = .reading
    }

    private func readWithoutScanning() {
        viewModel.clearPage()
        viewModel.startReading()
        screen = .reading
    }

    private func backFromPage() {
        if viewModel.isPaused {
            // Mid-story: back to the paused reading screen.
            screen = .reading
        } else {
            viewModel.resetStory()
            screen = .home
        }
        rescanning = false
    }

    private func finishStory() {
        viewModel.resetStory()
        screen = .home
    }
}

#Preview {
    ContentView()
}
