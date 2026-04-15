//
//  KeyEventHandling.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI
import AppKit
import Quartz

// MARK: - NSView-based keyboard event handler

struct KeyEventHandlingView: NSViewRepresentable {
    let store: PhotoStore
    var onFullscreen: (() -> Void)?
    var onHideFullscreen: (() -> Void)?

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.store = store
        view.showFullscreen = onFullscreen
        view.hideFullscreen = onHideFullscreen
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.store = store
        nsView.refreshTouchBar()
    }
}

/// Copy selected photo files to macOS pasteboard (Finder-compatible Cmd+C)
private func copySelectedFilesToPasteboard(store: PhotoStore) {
    let selectedPhotos = store.photos.filter { store.selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
    guard !selectedPhotos.isEmpty else { return }

    var urls: [URL] = []
    for photo in selectedPhotos {
        urls.append(photo.jpgURL)
        if let rawURL = photo.rawURL {
            urls.append(rawURL)
        }
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])

    // Visual feedback
    let count = selectedPhotos.count
    let fileCount = urls.count
    print("📋 [COPY] \(count)장 (\(fileCount)파일) 클립보드에 복사됨")
}

class KeyCaptureView: NSView {
    var showFullscreen: (() -> Void)?
    var hideFullscreen: (() -> Void)?
    var store: PhotoStore? {
        didSet { touchBarProvider.store = store }
    }
    private var quickLookDataSource: QuickLookDataSource?
    private let touchBarProvider = TouchBarProvider()

    override var acceptsFirstResponder: Bool { true }

    // MARK: - NSTouchBar

    override func makeTouchBar() -> NSTouchBar? {
        touchBarProvider.store = store
        return touchBarProvider.makeTouchBar()
    }

    /// Call to refresh TouchBar when selection changes
    func refreshTouchBar() {
        self.touchBar = nil  // forces re-creation
    }

    // MARK: - Quick Look via QLPreviewPanel

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookDataSource
        panel.delegate = quickLookDataSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Panel control ended
    }

    private func toggleQuickLook() {
        guard let store = store, let photo = store.selectedPhoto else { return }

        if quickLookDataSource == nil {
            quickLookDataSource = QuickLookDataSource()
        }
        quickLookDataSource?.currentURL = photo.jpgURL

        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.makeKeyAndOrderFront(nil)
                panel.reloadData()
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        // 방향키/SP/Enter 등 release 시 isKeyRepeat 해제 — 미해제 시 단일 이동도 50ms 디바운스 타게 됨
        store?.isKeyRepeat = false
        super.keyUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let store = store else {
            super.keyDown(with: event)
            return
        }

        let chars = event.charactersIgnoringModifiers ?? ""
        let keyCode = event.keyCode
        let hasCmd = event.modifierFlags.contains(.command)
        let hasShift = event.modifierFlags.contains(.shift)

        // Helper: match by chars OR keyCode for Korean IME compatibility
        func charOrCode(_ c: String, _ code: UInt16) -> Bool {
            return chars == c || keyCode == code
        }

        // Esc → 전체화면 닫기
        if keyCode == 53 {
            hideFullscreen?()
            return
        }

        // Cmd shortcuts
        if hasCmd {
            if chars == "=" || chars == "+" || keyCode == 24 {
                NotificationCenter.default.post(name: .zoomIn, object: nil)
                return
            } else if chars == "-" || keyCode == 27 {
                NotificationCenter.default.post(name: .zoomOut, object: nil)
                return
            } else if charOrCode("a", 0) {
                store.selectAll()
                return
            } else if charOrCode("d", 2) {
                store.deselectAll()
                return
            } else if chars == "/" || chars == "?" || keyCode == 44 {
                store.showShortcutHelp = true
                return
            } else if charOrCode("z", 6) {
                store.undo()
                return
            } else if charOrCode("f", 3) {
                // Cmd+F: 전체화면 토글 (진입/복귀)
                showFullscreen?()
                return
            } else if keyCode == 36 { // Cmd+Enter → 전체화면 닫기
                hideFullscreen?()
                return
            } else if charOrCode("c", 8) {
                // Cmd+C: Copy selected files to clipboard (Finder-compatible)
                copySelectedFilesToPasteboard(store: store)
                return
            }
        }

        // Color labels: 6=빨강, 7=노랑, 8=초록, 9=파랑
        if charOrCode("6", 22) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.red) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.red, for: id) }
            return
        } else if charOrCode("7", 26) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.yellow) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.yellow, for: id) }
            return
        } else if charOrCode("8", 28) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.green) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.green, for: id) }
            return
        } else if charOrCode("9", 25) {
            if store.selectionCount > 1 { store.setColorLabelForSelected(.blue) }
            else if let id = store.selectedPhotoID { store.setColorLabel(.blue, for: id) }
            return
        }

        // Rating - skip if folder/parent selected
        let selectedIsFolder = store.selectedPhoto?.isFolder == true || store.selectedPhoto?.isParentFolder == true

        if charOrCode("1", 18) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(1) }
            else if let id = store.selectedPhotoID { store.setRating(1, for: id) }
            return
        } else if charOrCode("2", 19) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(2) }
            else if let id = store.selectedPhotoID { store.setRating(2, for: id) }
            return
        } else if charOrCode("3", 20) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(3) }
            else if let id = store.selectedPhotoID { store.setRating(3, for: id) }
            return
        } else if charOrCode("4", 21) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(4) }
            else if let id = store.selectedPhotoID { store.setRating(4, for: id) }
            return
        } else if charOrCode("5", 23) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(5) }
            else if let id = store.selectedPhotoID { store.setRating(5, for: id) }
            return
        } else if charOrCode("0", 29) {
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 { store.setRatingForSelected(0) }
            else if let id = store.selectedPhotoID { store.setRating(0, for: id) }
            return
        }

        // === 비디오 재생 단축키 ===
        // 프리뷰가 보이는 레이아웃(gridPreview, filmstrip)에서만 비디오 단축키 활성화
        let videoPreviewVisible = store.layoutMode == .gridPreview || store.layoutMode == .filmstrip
        let isVideo = videoPreviewVisible && store.selectedPhoto?.isVideoFile == true
        let videoMgr = VideoPlayerManager.shared

        // Spacebar: 비디오면 재생/일시정지, 아니면 별 5개 토글 (이미 5점이면 0점)
        if chars == " " || keyCode == 49 {
            if isVideo && videoMgr.isReady {
                videoMgr.togglePlayPause()
                return
            }
            guard !selectedIsFolder else { return }
            if store.selectionCount > 1 {
                let focusRating = store.selectedPhotoID.flatMap { store.idx($0) }.map { store.photos[$0].rating } ?? 0
                store.setRatingForSelected(focusRating == 5 ? 0 : 5)
            } else if let id = store.selectedPhotoID, let i = store.idx(id) {
                store.setRating(store.photos[i].rating == 5 ? 0 : 5, for: id)
            }
            return
        }

        // J/K/L: 비디오 스크러빙 (NLE 편집기 표준)
        if isVideo && videoMgr.isReady {
            if charOrCode("j", 38) && !hasCmd { videoMgr.jklScrub(key: "j"); return }
            if charOrCode("k", 40) && !hasCmd { videoMgr.jklScrub(key: "k"); return }
            if charOrCode("l", 37) && !hasCmd { videoMgr.jklScrub(key: "l"); return }
            // S: 현재 프레임 스냅샷 저장
            if charOrCode("s", 1) && !hasCmd { videoMgr.exportCurrentFrame(); return }
        }

        // G Select: instantly copy to Google Drive
        if charOrCode("g", 5) && !hasCmd {
            let gService = GSelectService.shared
            if gService.isActive {
                if store.selectionCount > 1 {
                    let selected = store.multiSelectedPhotos
                    gService.gSelectMultiple(photos: selected)
                    let indices = selected.compactMap { store.idx($0.id) }
                    store._suppressDidSet = true
                    for i in indices { store.photos[i].isGSelected = true }
                    store._suppressDidSet = false
                } else if let id = store.selectedPhotoID, let photo = store.selectedPhoto {
                    let wasGSelected = photo.isGSelected
                    gService.toggleGSelect(photo: photo)
                    if let i = store.idx(id) { store.photos[i].isGSelected = !wasGSelected }
                }
                store.invalidateCache()
            } else {
                // Not active - show setup
                gService.requestStartSession()
            }
            return
        }

        // H: Toggle histogram overlay
        if charOrCode("h", 4) && !hasCmd {
            NotificationCenter.default.post(name: .toggleHistogram, object: nil)
            return
        }

        // I: Toggle metadata overlay (nomacs-style)
        if charOrCode("i", 34) && !hasCmd {
            store.toggleMetadataOverlay()
            return
        }

        // D: Dual viewer toggle
        if charOrCode("d", 2) && !hasCmd {
            store.showDualViewer.toggle()
            return
        }

        // C: Compare mode (2~4 photos selected)
        if charOrCode("c", 8) && !hasCmd {
            if store.selectionCount >= 2 && store.selectionCount <= 4 {
                store.showCompare = true
            }
            return
        }

        // P: Quick Look preview
        if charOrCode("p", 35) && !hasCmd {
            toggleQuickLook()
            return
        }

        // ?, /: Shortcut help (non-Cmd)
        if (chars == "?" || chars == "/" || keyCode == 44) && !hasCmd {
            store.showShortcutHelp = true
            return
        }

        // Arrow keys, Enter, Delete (keyCode-only)
        store.isKeyRepeat = event.isARepeat

        // 비디오 재생 중: ←/→ = 프레임 스텝 또는 5초 이동
        if isVideo && videoMgr.isReady && (keyCode == 123 || keyCode == 124) {
            if videoMgr.isPlaying {
                // 재생 중이면 5초 점프
                if keyCode == 123 { videoMgr.seekRelative(seconds: -5) }
                else { videoMgr.seekRelative(seconds: 5) }
            } else {
                // 일시정지 중이면 프레임 스텝
                if keyCode == 123 { videoMgr.stepBackward() }
                else { videoMgr.stepForward() }
            }
            return
        }

        switch keyCode {
        case 123: store.selectLeft(shift: hasShift, cmd: hasCmd)    // <-
        case 124: store.selectRight(shift: hasShift, cmd: hasCmd)   // ->
        case 125: store.selectDown(shift: hasShift, cmd: hasCmd)    // down
        case 126: store.selectUp(shift: hasShift, cmd: hasCmd)      // up
        case 36:  // Enter
            if hasCmd {
                // Cmd+Enter: toggle fullscreen filmstrip
                let newMode: LayoutMode = store.layoutMode == .gridPreview ? .filmstrip : .gridPreview
                store.setLayoutMode(newMode)
                if newMode == .filmstrip {
                    // Hide folder tree in filmstrip fullscreen
                    store.showFolderBrowser = false
                } else {
                    store.showFolderBrowser = true
                }
                NSApp.keyWindow?.toggleFullScreen(nil)
            } else {
                // Enter: open folder/parent folder
                if let photo = store.selectedPhoto {
                    if photo.isParentFolder, let parent = store.folderURL?.deletingLastPathComponent() {
                        store.loadFolder(parent, restoreRatings: true)
                    } else if photo.isFolder {
                        store.loadFolder(photo.jpgURL, restoreRatings: true)
                    }
                }
            }
        case 51, 117:  // Backspace / Delete
            guard !store.selectedPhotoIDs.isEmpty else { break }
            let selectedPhotos = store.photos.filter { store.selectedPhotoIDs.contains($0.id) && !$0.isFolder && !$0.isParentFolder }
            guard !selectedPhotos.isEmpty else { break }

            let deleteOriginal = UserDefaults.standard.bool(forKey: "deleteOriginalFile")
            if deleteOriginal {
                // 휴지통으로 이동 (설정에 따라 확인 대화상자 skip 가능)
                store.requestDeleteOriginal(ids: store.selectedPhotoIDs)
            } else {
                // Just remove from thumbnail list (no file deletion)
                store.removePhotosFromList(ids: store.selectedPhotoIDs)
            }
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Quick Look Data Source

class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var currentURL: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        return currentURL.map { $0 as NSURL }
    }
}
