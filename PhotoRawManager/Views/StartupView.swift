//
//  StartupView.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - Startup View

struct StartupView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var hoveredCard: String?
    @State private var showRawMatchResult: Bool = false
    @State private var rawMatchResult: RawMatchResult = RawMatchResult()
    @State private var showFileSyncPopup: Bool = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.linearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text("PickShot")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                    }
                    Text("초고속 사진 선별 도구")
                        .font(.system(size: AppTheme.fontSubhead))
                        .foregroundColor(.secondary)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.2")")
                        .font(.system(size: AppTheme.fontCaption, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                Spacer().frame(height: 40)

                // === TOP: File Sync Button ===
                Button(action: { showFileSyncPopup = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("JPG · RAW 파일 연동하기")
                                .font(.system(size: 15, weight: .bold))
                            Text("픽샷 셀렉 가져오기 · JPG,RAW 매칭 복사")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(width: 380, height: 60)
                    .background(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 28)

                // === Mode buttons ===
                HStack(spacing: 16) {
                    // Viewer
                    Button(action: {
                        store.startupMode = .viewer
                        store.shouldOpenFolderBrowser = true
                        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                        // Try security-scoped bookmark first (App Sandbox)
                        if let bookmarkedURL = SandboxBookmarkService.resolveBookmark(key: "lastFolder") {
                            store.loadFolder(bookmarkedURL, restoreRatings: true)
                        } else {
                            let lastPath = UserDefaults.standard.string(forKey: "lastFolderPath") ?? ""
                            if !lastPath.isEmpty && FileManager.default.fileExists(atPath: lastPath) {
                                store.loadFolder(URL(fileURLWithPath: lastPath), restoreRatings: true)
                            } else {
                                store.loadFolder(desktop, restoreRatings: true)
                            }
                        }
                    }) {
                        HStack(spacing: 10) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("뷰어")
                                    .font(.system(size: 14, weight: .bold))
                                Text("사진 선별 · 분류 · 내보내기")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        .foregroundColor(.white)
                        .frame(width: 182, height: 56)
                        .background(
                            LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .blue.opacity(0.25), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)

                    // Tethering
                    Button(action: { store.startupMode = .tethering }) {
                        HStack(spacing: 10) {
                            Image(systemName: "cable.connector")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("테더링")
                                    .font(.system(size: 14, weight: .bold))
                                HStack(spacing: 4) {
                                    Text("카메라 연결 · 실시간 촬영")
                                        .font(.system(size: 10))
                                    Text("Soon")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.2))
                                        .cornerRadius(3)
                                }
                                .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 182, height: 56)
                        .background(
                            LinearGradient(colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Text("\u{00A9} 2026 PickShot")
                    .font(.system(size: AppTheme.fontMicro))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.bottom, AppTheme.space20)
            }
        }
        .sheet(isPresented: $showRawMatchResult) {
            RawMatchResultView(result: rawMatchResult, isPresented: $showRawMatchResult)
        }
        .sheet(isPresented: $showFileSyncPopup) {
            FileSyncPopupView(store: store, isPresented: $showFileSyncPopup, showRawMatchResult: $showRawMatchResult, rawMatchResult: $rawMatchResult)
        }
    }

    private func performRawMatching() {
        // Step 1: Select JPG folder
        let jpgPanel = NSOpenPanel()
        jpgPanel.title = "JPG 폴더 선택"
        jpgPanel.message = "JPG 파일이 있는 폴더를 선택하세요"
        jpgPanel.canChooseDirectories = true
        jpgPanel.canChooseFiles = false
        guard jpgPanel.runModal() == .OK, let jpgFolder = jpgPanel.url else { return }

        // Step 2: Select RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "매칭할 RAW 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Step 3: Select destination
        let destPanel = NSOpenPanel()
        destPanel.title = "저장할 폴더 선택"
        destPanel.message = "매칭된 파일을 복사할 폴더를 선택하세요"
        destPanel.canChooseDirectories = true
        destPanel.canChooseFiles = false
        destPanel.canCreateDirectories = true
        guard destPanel.runModal() == .OK, let destFolder = destPanel.url else { return }

        // Step 4: Match and copy
        let fm = FileManager.default
        let rawExts = FileMatchingService.rawExtensions

        // Get JPG file names
        let jpgFiles = (try? fm.contentsOfDirectory(at: jpgFolder, includingPropertiesForKeys: nil)) ?? []
        let jpgItems = jpgFiles.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let jpgNames = Set(jpgItems.map { $0.deletingPathExtension().lastPathComponent })

        // Get RAW file names
        let rawFiles = (try? fm.contentsOfDirectory(at: rawFolder, includingPropertiesForKeys: nil)) ?? []
        let rawItems = rawFiles.filter { rawExts.contains($0.pathExtension.lowercased()) }
        let rawNames = Set(rawItems.map { $0.deletingPathExtension().lastPathComponent })

        // Find matches and mismatches
        var matchedNames: [String] = []
        var jpgOnly: [String] = []
        var rawOnly: [String] = []
        var copyFailed: [(name: String, reason: String)] = []

        // Create JPG + RAW subdirectories
        let jpgDest = destFolder.appendingPathComponent("JPG")
        let rawDest = destFolder.appendingPathComponent("RAW")
        try? fm.createDirectory(at: jpgDest, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rawDest, withIntermediateDirectories: true)

        // Process matches
        for jpgFile in jpgItems {
            let name = jpgFile.deletingPathExtension().lastPathComponent
            if rawNames.contains(name) {
                matchedNames.append(name)
                // Copy JPG
                let dest = jpgDest.appendingPathComponent(jpgFile.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: jpgFile, to: dest)
                } catch {
                    copyFailed.append((name: jpgFile.lastPathComponent, reason: error.localizedDescription))
                }
                // Copy RAW
                if let rawFile = rawItems.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                    let rdest = rawDest.appendingPathComponent(rawFile.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: rdest.path) { try fm.removeItem(at: rdest) }
                        try fm.copyItem(at: rawFile, to: rdest)
                    } catch {
                        copyFailed.append((name: rawFile.lastPathComponent, reason: error.localizedDescription))
                    }
                }
            } else {
                jpgOnly.append(name)
            }
        }

        // RAW only (no matching JPG)
        for rawFile in rawItems {
            let name = rawFile.deletingPathExtension().lastPathComponent
            if !jpgNames.contains(name) {
                rawOnly.append(name)
            }
        }

        rawMatchResult = RawMatchResult(
            jpgCount: jpgItems.count,
            rawCount: rawItems.count,
            matchedCount: matchedNames.count,
            jpgOnlyNames: jpgOnly,
            rawOnlyNames: rawOnly,
            failedNames: copyFailed,
            destFolder: destFolder
        )
        showRawMatchResult = true
    }
}

struct StartupCard: View {
    let icon: String; let title: String; let subtitle: String; let color: Color; let isHovered: Bool; var comingSoon: Bool = false
    var body: some View {
        VStack(spacing: AppTheme.space12) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundColor(comingSoon ? .secondary : color)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(comingSoon ? .secondary : .primary)
            Text(subtitle)
                .font(.system(size: AppTheme.fontBody))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if comingSoon {
                Text("Coming Soon")
                    .font(.system(size: AppTheme.fontMicro, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .frame(width: 120, height: 120)
        .padding(AppTheme.space16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered && !comingSoon ? color.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered && !comingSoon ? color.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .scaleEffect(isHovered && !comingSoon ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Breadcrumb Path View

struct BreadcrumbPathView: View {
    let url: URL
    let store: PhotoStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pathComponents.indices, id: \.self) { i in
                if i > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Button(action: {
                    let targetURL = buildURL(upTo: i)
                    let systemPaths = ["/Volumes", "/System", "/Library", "/usr", "/private"]
                    let isSystem = systemPaths.contains(targetURL.path) || targetURL.path == "/"
                    if !isSystem && FileManager.default.fileExists(atPath: targetURL.path) {
                        store.startupMode = .viewer
                        store.loadFolder(targetURL, restoreRatings: true)
                    }
                }) {
                    Text(pathComponents[i])
                        .font(.system(size: AppTheme.fontSubhead, weight: i == pathComponents.count - 1 ? .bold : .medium))
                        .foregroundColor(i == pathComponents.count - 1 ? Color(red: 0.4, green: 0.85, blue: 1.0) : .secondary.opacity(0.7))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .help(url.path)
    }

    private var pathComponents: [String] {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            let relative = String(path.dropFirst(home.count))
            let parts = relative.split(separator: "/").map(String.init)
            return ["~"] + parts
        }
        return url.pathComponents.filter { $0 != "/" }
    }

    private func buildURL(upTo index: Int) -> URL {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) {
            if index == 0 { return URL(fileURLWithPath: home) }
            let relative = String(path.dropFirst(home.count))
            let parts = relative.split(separator: "/").map(String.init)
            let subParts = Array(parts.prefix(index))
            return URL(fileURLWithPath: home + "/" + subParts.joined(separator: "/"))
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let subParts = Array(parts.prefix(index + 1))
        return URL(fileURLWithPath: "/" + subParts.joined(separator: "/"))
    }
}
