import SwiftUI

/// Tethering mode view - shows camera connection status, live capture info,
/// and a preview of the latest captured photo.
struct TetherView: View {
    @EnvironmentObject var store: PhotoStore
    @StateObject private var tether = TetherService()
    @State private var previewImage: NSImage? = nil
    @State private var pulseScale: CGFloat = 0.8

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
            // 진입 즉시 카메라 검색 시작 — 연결되면 자동 촬영 준비
            if !tether.isActive {
                tether.startBrowsing()
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

                        // PC Remote 모드 아니면 안내 표시
                        if !tether.canTriggerShutter {
                            tetheringModeHelpBanner
                            Divider().padding(.horizontal, AppTheme.space4)
                        }
                    }

                    // Output Folder
                    outputFolderSection

                    Divider().padding(.horizontal, AppTheme.space4)

                    // Filename Template (prefix + sequence)
                    filenameTemplateSection

                    Divider().padding(.horizontal, AppTheme.space4)

                    // Remote Shutter (if camera supports)
                    if tether.isConnected && tether.canTriggerShutter {
                        remoteShutterSection
                        Divider().padding(.horizontal, AppTheme.space4)
                    }

                    // Capture Stats
                    captureStatsSection

                    Spacer()
                }
                .padding(AppTheme.space16)
            }

            // Start/Stop 버튼 제거 — 진입 시 자동 브라우징
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
                // 연결 상태 시각화 — 초록=연결됨, 펄스 주황=검색중, 회색=연결안됨
                ZStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    if tether.isActive && !tether.isConnected {
                        // 검색 중 펄스 애니메이션
                        Circle()
                            .stroke(statusColor, lineWidth: 2)
                            .frame(width: 18, height: 18)
                            .opacity(0.5)
                            .scaleEffect(pulseScale)
                            .onAppear { pulseScale = 1.0 }
                            .animation(
                                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                value: pulseScale
                            )
                    }
                }
                .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.system(size: AppTheme.fontBody, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(tether.statusMessage)
                        .font(.system(size: AppTheme.fontCaption))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var statusTitle: String {
        if tether.isConnected { return "연결됨" }
        if tether.isActive { return "카메라 검색 중" }
        return "연결 끊김"
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

    // MARK: - PC Remote 모드 안내 배너

    private var tetheringModeHelpBanner: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                Text("USB 모드 변경 필요")
                    .font(.system(size: AppTheme.fontBody, weight: .semibold))
                    .foregroundColor(.orange)
            }

            Text("카메라가 현재 파일 전송 모드(MTP/Mass Storage)로 연결되어 있어서 촬영 이벤트를 받을 수 없습니다.")
                .font(.system(size: AppTheme.fontCaption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("카메라 메뉴에서 USB 연결 모드 변경:")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.top, 4)

                helpLine(brand: "Sony", steps: "메뉴 → 네트워크 → USB 연결 → PC Remote")
                helpLine(brand: "Canon", steps: "MENU → Communication → 통신 방식 → EOS Utility")
                helpLine(brand: "Nikon", steps: "SETUP → USB → MTP/PTP → Camera Control")
                helpLine(brand: "Fujifilm", steps: "MENU → CONNECT → USB → PC Shoot")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func helpLine(brand: String, steps: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(brand)
                .font(.system(size: AppTheme.fontCaption, weight: .semibold, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 58, alignment: .leading)
            Text(steps)
                .font(.system(size: AppTheme.fontCaption, design: .monospaced))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Filename Template

    private var filenameTemplateSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            HStack {
                Text("파일명 템플릿")
                    .font(.system(size: AppTheme.fontCaption, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if !tether.filenamePrefix.isEmpty {
                    Text("\(tether.filenamePrefix)\(String(format: "%04d", tether.sequenceNumber))")
                        .font(.system(size: AppTheme.fontMicro, design: .monospaced))
                        .foregroundColor(.orange)
                }
            }

            HStack(spacing: AppTheme.space8) {
                Text("접두어")
                    .font(.system(size: AppTheme.fontCaption))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)

                TextField("비워두면 원본 이름 유지", text: $tether.filenamePrefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.fontBody, design: .monospaced))
            }

            HStack(spacing: AppTheme.space8) {
                Text("시작 #")
                    .font(.system(size: AppTheme.fontCaption))
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)

                Stepper(value: $tether.sequenceNumber, in: 1...99999) {
                    Text("\(tether.sequenceNumber)")
                        .font(.system(size: AppTheme.fontBody, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)

                Button(action: { tether.sequenceNumber = 1 }) {
                    Text("리셋")
                        .font(.system(size: AppTheme.fontCaption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !tether.filenamePrefix.isEmpty {
                Text("예: IMG_1234.CR3 → \(tether.filenamePrefix)\(String(format: "%04d", tether.sequenceNumber)).CR3")
                    .font(.system(size: AppTheme.fontMicro, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    // MARK: - Remote Shutter

    private var remoteShutterSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.space8) {
            Text("원격 촬영")
                .font(.system(size: AppTheme.fontCaption, weight: .medium))
                .foregroundColor(.secondary)

            Button(action: { tether.triggerShutter() }) {
                HStack(spacing: AppTheme.space8) {
                    Image(systemName: "camera.shutter.button")
                        .font(.system(size: 16))
                    Text("촬영 (Enter)")
                        .font(.system(size: AppTheme.fontBody, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
                )
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
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
