import SwiftUI

/// Tethering mode view - shows camera connection status, live capture info,
/// and a preview of the latest captured photo.
struct TetherView: View {
    @EnvironmentObject var store: PhotoStore
    @StateObject private var tether = TetherService()
    @State private var previewImage: NSImage? = nil

    var body: some View {
        HSplitView {
            // Left panel - Camera info & controls
            controlPanel
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)

            // Right panel - Latest photo preview
            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            tether.onNewPhoto = { [weak store] url in
                handleNewPhoto(url, store: store)
            }
        }
        .onDisappear {
            if tether.isActive {
                tether.stopBrowsing()
            }
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cable.connector")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.orange)
                Text("테더링")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(AppTheme.space16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.space20) {
                    // Connection Status
                    connectionStatusSection

                    Divider().padding(.horizontal, AppTheme.space4)

                    // Camera Info
                    if tether.isConnected {
                        cameraInfoSection
                        Divider().padding(.horizontal, AppTheme.space4)
                    }

                    // Output Folder
                    outputFolderSection

                    Divider().padding(.horizontal, AppTheme.space4)

                    // Capture Stats
                    captureStatsSection

                    Spacer()
                }
                .padding(AppTheme.space16)
            }

            Divider()

            // Start/Stop Button
            startStopButton
                .padding(AppTheme.space16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            Text("연결 상태")
                .font(.system(size: AppTheme.fontCaption, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: AppTheme.space8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text(tether.statusMessage)
                    .font(.system(size: AppTheme.fontBody))
                    .foregroundColor(.primary)
                    .lineLimit(2)
            }
        }
    }

    private var statusColor: Color {
        if tether.isConnected {
            return AppTheme.success
        } else if tether.isActive {
            return AppTheme.warning
        } else {
            return Color.gray
        }
    }

    // MARK: - Camera Info

    private var cameraInfoSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            Text("카메라 정보")
                .font(.system(size: AppTheme.fontCaption, weight: .medium))
                .foregroundColor(.secondary)

            infoRow(icon: "camera", label: "모델", value: tether.cameraName)

            if let battery = tether.batteryLevel {
                infoRow(
                    icon: batteryIcon(level: battery),
                    label: "배터리",
                    value: "\(battery)%"
                )
            }
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppTheme.space8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(.system(size: AppTheme.fontBody))
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: AppTheme.fontBody, weight: .medium))
                .foregroundColor(.primary)
        }
    }

    private func batteryIcon(level: Int) -> String {
        switch level {
        case 76...100: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 1...25: return "battery.25"
        default: return "battery.0"
        }
    }

    // MARK: - Output Folder

    private var outputFolderSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            Text("저장 폴더")
                .font(.system(size: AppTheme.fontCaption, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: AppTheme.space8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)

                Text(tether.outputFolder.lastPathComponent)
                    .font(.system(size: AppTheme.fontBody))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button(action: selectOutputFolder) {
                    Text("변경")
                        .font(.system(size: AppTheme.fontCaption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(tether.outputFolder.path)
                .font(.system(size: AppTheme.fontMicro, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    // MARK: - Capture Stats

    private var captureStatsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            Text("촬영 현황")
                .font(.system(size: AppTheme.fontCaption, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: AppTheme.space24) {
                VStack(spacing: 4) {
                    Text("\(tether.captureCount)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                    Text("촬영 수")
                        .font(.system(size: AppTheme.fontMicro))
                        .foregroundColor(.secondary)
                }

                if let url = tether.latestPhotoURL {
                    VStack(spacing: 4) {
                        Text(url.lastPathComponent)
                            .font(.system(size: AppTheme.fontBody, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("최근 파일")
                            .font(.system(size: AppTheme.fontMicro))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Start/Stop Button

    private var startStopButton: some View {
        Button(action: toggleTethering) {
            HStack(spacing: AppTheme.space8) {
                Image(systemName: tether.isActive ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 16))
                Text(tether.isActive ? "테더링 중지" : "테더링 시작")
                    .font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AppTheme.space8)
        }
        .buttonStyle(.borderedProminent)
        .tint(tether.isActive ? .red : .orange)
        .controlSize(.large)
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(AppTheme.space16)

                // File name overlay
                if let url = tether.latestPhotoURL {
                    VStack {
                        Spacer()
                        HStack {
                            Text(url.lastPathComponent)
                                .font(.system(size: AppTheme.fontBody, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, AppTheme.space12)
                                .padding(.vertical, AppTheme.space4)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.6))
                                )
                        }
                        .padding(.bottom, AppTheme.space16)
                    }
                }
            } else {
                // Empty state
                VStack(spacing: AppTheme.space16) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundColor(.secondary.opacity(0.4))

                    if tether.isActive {
                        if tether.isConnected {
                            Text("촬영을 시작하면 여기에 사진이 표시됩니다")
                                .font(.system(size: AppTheme.fontBody))
                                .foregroundColor(.secondary)
                        } else {
                            Text("카메라를 USB로 연결하세요")
                                .font(.system(size: AppTheme.fontBody))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("테더링을 시작하면 촬영된 사진을 미리볼 수 있습니다")
                            .font(.system(size: AppTheme.fontBody))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func toggleTethering() {
        if tether.isActive {
            tether.stopBrowsing()
            previewImage = nil
        } else {
            tether.startBrowsing()
        }
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "선택"
        panel.message = "테더링 사진을 저장할 폴더를 선택하세요"

        if panel.runModal() == .OK, let url = panel.url {
            tether.outputFolder = url
        }
    }

    private func handleNewPhoto(_ url: URL, store: PhotoStore?) {
        // Load preview image
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async {
                previewImage = image

                // Also add to the photo store if in tethering mode
                guard let store = store else { return }
                let ext = url.pathExtension.lowercased()
                let isSupported = FileMatchingService.jpgExtensions.contains(ext)
                    || FileMatchingService.rawExtensions.contains(ext)
                    || FileMatchingService.imageExtensions.contains(ext)

                if isSupported {
                    var newItem = PhotoItem(jpgURL: url)
                    newItem.exifData = ExifService.extractExif(from: url)
                    newItem.jpgFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

                    // Add to beginning of photos array and select it
                    store.photos.insert(newItem, at: 0)
                    store.selectedPhotoID = newItem.id

                    // If folder URL not set, set it to the output folder
                    if store.folderURL == nil {
                        store.folderURL = url.deletingLastPathComponent()
                    }
                }
            }
        }
    }
}
