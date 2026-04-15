//
//  FileSyncPopupView.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit

// MARK: - File Sync Popup

struct FileSyncPopupView: View {
    let store: PhotoStore
    @Binding var isPresented: Bool
    @Binding var showRawMatchResult: Bool
    @Binding var rawMatchResult: RawMatchResult

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("파일 연동하기")
                    .font(.system(size: 18, weight: .bold))
                Text("셀렉 파일을 가져오거나 JPG와 RAW를 매칭합니다")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Divider()

            // Two buttons
            HStack(spacing: 16) {
                // PickShot file import
                Button(action: { importPickshotFile() }) {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.badge.arrow.up")
                            .font(.system(size: 28))
                        Text(".pickshot 파일\n가져오기")
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("셀렉 파일을\nRAW 폴더에 적용합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .frame(width: 180, height: 160)
                    .background(
                        LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                // JPG + RAW matching
                Button(action: { performRawMatch() }) {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 28))
                        Text("JPG, RAW\n매칭 복사")
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                        Text("JPG와 같은 이름의 RAW를\n찾아서 함께 복사합니다")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white)
                    .frame(width: 180, height: 160)
                    .background(
                        LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button("닫기") { isPresented = false }
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func importPickshotFile() {
        isPresented = false

        // Step 1: Select .pickshot file
        let panel = NSOpenPanel()
        panel.title = ".pickshot 파일 선택"
        panel.message = ".pickshot 파일을 선택하세요"
        panel.allowedContentTypes = [.init(filenameExtension: "pickshot")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let pickshotURL = panel.url else { return }

        // Step 2: Select RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "셀렉을 적용할 RAW/JPG 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Load folder and apply pickshot
        store.startupMode = .viewer
        store.shouldOpenFolderBrowser = true
        store.loadFolder(rawFolder, restoreRatings: true)

        // Wait for folder to load, then apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let result = PickshotFileService.applyPickshotFile(url: pickshotURL, to: &store.photos, photoIndex: store._photoIndex)
            if let result = result {
                store.photosVersion += 1
                store.lastImportResult = result
                store.showImportResult = true
            }
        }
    }

    private func performRawMatch() {
        isPresented = false

        // Step 1: JPG folder
        let jpgPanel = NSOpenPanel()
        jpgPanel.title = "JPG 폴더 선택"
        jpgPanel.message = "JPG 파일이 있는 폴더를 선택하세요"
        jpgPanel.canChooseDirectories = true
        jpgPanel.canChooseFiles = false
        guard jpgPanel.runModal() == .OK, let jpgFolder = jpgPanel.url else { return }

        // Step 2: RAW folder
        let rawPanel = NSOpenPanel()
        rawPanel.title = "RAW 폴더 선택"
        rawPanel.message = "매칭할 RAW 파일이 있는 폴더를 선택하세요"
        rawPanel.canChooseDirectories = true
        rawPanel.canChooseFiles = false
        guard rawPanel.runModal() == .OK, let rawFolder = rawPanel.url else { return }

        // Step 3: Destination
        let destPanel = NSOpenPanel()
        destPanel.title = "저장할 폴더 선택"
        destPanel.message = "매칭된 파일을 복사할 폴더를 선택하세요"
        destPanel.canChooseDirectories = true
        destPanel.canChooseFiles = false
        destPanel.canCreateDirectories = true
        guard destPanel.runModal() == .OK, let destFolder = destPanel.url else { return }

        // Match and copy (reuse StartupView logic)
        let fm = FileManager.default
        let rawExts = FileMatchingService.rawExtensions

        let jpgFiles = (try? fm.contentsOfDirectory(at: jpgFolder, includingPropertiesForKeys: nil)) ?? []
        let jpgItems = jpgFiles.filter { ["jpg","jpeg"].contains($0.pathExtension.lowercased()) }
        let jpgNames = Set(jpgItems.map { $0.deletingPathExtension().lastPathComponent })

        let rawFiles = (try? fm.contentsOfDirectory(at: rawFolder, includingPropertiesForKeys: nil)) ?? []
        let rawItems = rawFiles.filter { rawExts.contains($0.pathExtension.lowercased()) }
        let rawNames = Set(rawItems.map { $0.deletingPathExtension().lastPathComponent })

        var matchedNames: [String] = []
        var jpgOnly: [String] = []
        var rawOnly: [String] = []
        var copyFailed: [(name: String, reason: String)] = []

        let jpgDest = destFolder.appendingPathComponent("JPG")
        let rawDest = destFolder.appendingPathComponent("RAW")
        try? fm.createDirectory(at: jpgDest, withIntermediateDirectories: true)
        try? fm.createDirectory(at: rawDest, withIntermediateDirectories: true)

        for jpgFile in jpgItems {
            let name = jpgFile.deletingPathExtension().lastPathComponent
            if rawNames.contains(name) {
                matchedNames.append(name)
                let dest = jpgDest.appendingPathComponent(jpgFile.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: jpgFile, to: dest)
                } catch { copyFailed.append((name: jpgFile.lastPathComponent, reason: error.localizedDescription)) }

                if let rawFile = rawItems.first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                    let rdest = rawDest.appendingPathComponent(rawFile.lastPathComponent)
                    do {
                        if fm.fileExists(atPath: rdest.path) { try fm.removeItem(at: rdest) }
                        try fm.copyItem(at: rawFile, to: rdest)
                    } catch { copyFailed.append((name: rawFile.lastPathComponent, reason: error.localizedDescription)) }
                }
            } else { jpgOnly.append(name) }
        }

        for rawFile in rawItems {
            let name = rawFile.deletingPathExtension().lastPathComponent
            if !jpgNames.contains(name) { rawOnly.append(name) }
        }

        rawMatchResult = RawMatchResult(
            jpgCount: jpgItems.count, rawCount: rawItems.count, matchedCount: matchedNames.count,
            jpgOnlyNames: jpgOnly, rawOnlyNames: rawOnly, failedNames: copyFailed, destFolder: destFolder
        )
        showRawMatchResult = true
    }
}
