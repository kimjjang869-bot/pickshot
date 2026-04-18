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

/// Pickshot 전용 pasteboard type — cut/paste 구분용
private let pickshotCutPasteboardType = NSPasteboard.PasteboardType("app.pickshot.cut")

/// 선택된 사진/폴더의 실제 파일 URL 목록을 수집.
/// RAW + JPG 쌍은 둘 다, 폴더는 폴더 자체. parentFolder 는 제외.
private func collectURLsForSelection(store: PhotoStore) -> (urls: [URL], selectedIDs: Set<UUID>) {
    let selected = store.photos.filter { store.selectedPhotoIDs.contains($0.id) && !$0.isParentFolder }
    guard !selected.isEmpty else { return ([], []) }
    var urls: [URL] = []
    for item in selected {
        if item.isFolder {
            urls.append(item.jpgURL)  // 폴더 URL
        } else {
            urls.append(item.jpgURL)
            if let raw = item.rawURL, raw != item.jpgURL {
                urls.append(raw)
            }
        }
    }
    return (urls, Set(selected.map { $0.id }))
}

/// Copy selected photos/folders to macOS pasteboard (Cmd+C, Finder 호환).
/// `public` 으로 열어서 context menu 에서도 호출 가능.
func copySelectionToPasteboard(store: PhotoStore) {
    let (urls, selectedIDs) = collectURLsForSelection(store: store)
    guard !urls.isEmpty else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])

    // cut 마커 있던 것 clear (copy 후엔 이전 cut 무효화)
    store.pendingCutPhotoIDs = []

    fputs("📋 [COPY] \(selectedIDs.count)개 아이템 (\(urls.count)파일) 클립보드에 복사됨\n", stderr)
}

/// Cut selected photos/folders (Cmd+X). Paste 시 move 동작.
func cutSelectionToPasteboard(store: PhotoStore) {
    let (urls, selectedIDs) = collectURLsForSelection(store: store)
    guard !urls.isEmpty else { return }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects(urls as [NSURL])
    pasteboard.setData(Data([1]), forType: pickshotCutPasteboardType)

    store.pendingCutPhotoIDs = selectedIDs

    fputs("✂️ [CUT] \(selectedIDs.count)개 아이템 (\(urls.count)파일) 잘라내기 대기\n", stderr)
}

// 기존 이름 호환 (내부 호출 유지)
private func copySelectedFilesToPasteboard(store: PhotoStore) { copySelectionToPasteboard(store: store) }
private func cutSelectedFilesToPasteboard(store: PhotoStore) { cutSelectionToPasteboard(store: store) }

/// 단일 URL (폴더 트리 등 컨텍스트에서) 복사.
func copyURLToPasteboard(_ url: URL) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects([url as NSURL])
    fputs("📋 [COPY] \(url.lastPathComponent) 클립보드에 복사됨\n", stderr)
}

/// 단일 URL 잘라내기.
func cutURLToPasteboard(_ url: URL) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.writeObjects([url as NSURL])
    pb.setData(Data([1]), forType: pickshotCutPasteboardType)
    fputs("✂️ [CUT] \(url.lastPathComponent) 잘라내기 대기\n", stderr)
}

/// 클립보드 파일을 지정 폴더에 붙여넣기 (폴더 트리에서 사용).
func pasteFilesToFolder(_ destFolder: URL, store: PhotoStore) {
    let pasteboard = NSPasteboard.general
    guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
          !urls.isEmpty else {
        fputs("📋 [PASTE] 클립보드에 파일 없음\n", stderr)
        return
    }
    let isCut = pasteboard.data(forType: pickshotCutPasteboardType) != nil
    // 완료 후 클립보드 정리는 performFileTransferToFolder 내부에서 처리
    performFileTransferToFolder(urls: urls, destFolder: destFolder, isCut: isCut, store: store,
                                clearClipboardOnSuccess: true)
}

/// 파일/폴더를 지정된 폴더로 전송하는 **공용 엔트리포인트**.
/// 충돌 감지 + 사용자 다이얼로그 + 백그라운드 진행률 + 병합/건너뛰기/이름변경/취소 + 언두 스택 전부 포함.
/// `pasteFilesToFolder`, `FolderDropDelegate` 등이 공유.
func performFileTransferToFolder(
    urls: [URL],
    destFolder: URL,
    isCut: Bool,
    store: PhotoStore,
    clearClipboardOnSuccess: Bool = false
) {
    let fm = FileManager.default

    // 충돌 검사 + 사용자에게 전략 묻기 (메인 스레드)
    let conflicts = FileConflictResolver.detectConflicts(sources: urls, destFolder: destFolder)
    var strategy: FileConflictStrategy = .mergeOrOverwrite
    if !conflicts.isEmpty {
        strategy = FileConflictResolver.promptUser(conflicts: conflicts)
        if strategy == .cancel {
            fputs("📋 [TRANSFER] 사용자 취소 (충돌 다이얼로그)\n", stderr)
            return
        }
    }
    // 총 바이트 계산
    var totalBytes: Int64 = 0
    var fileSizes: [Int64] = []
    for u in urls {
        var sz: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: u.path) {
            if let s = attrs[.size] as? Int64 { sz = s }
            else if let s = attrs[.size] as? Int { sz = Int64(s) }
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                // 재귀 사이즈
                if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let f as URL in e {
                        if let v = try? f.resourceValues(forKeys: [.fileSizeKey]),
                           let s = v.fileSize { sz += Int64(s) }
                    }
                }
            }
        }
        fileSizes.append(sz)
        totalBytes += sz
    }

    store.bgExportActive = true
    store.bgExportLabel = isCut ? "잘라내기" : "붙여넣기"
    store.bgExportTotal = urls.count
    store.bgExportDone = 0
    store.bgExportProgress = 0
    store.bgExportCancelled = false
    store.bgExportDestination = destFolder
    store.bgTransferSourcePath = urls.first?.deletingLastPathComponent().path ?? ""
    store.bgTransferDestPath = destFolder.path
    store.bgTransferBytesDone = 0
    store.bgTransferBytesTotal = totalBytes
    store.bgTransferSpeed = 0
    store.bgTransferETA = 0
    store.bgTransferSpeedHistory = []
    store.bgTransferStartedAt = Date()

    var completed: [(source: URL, dest: URL)] = []

    // 500ms 타이머로 그래프/속도 샘플 보장 (큰 파일 1개라도 그래프 갱신)
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    var tickLastBytes: Int64 = 0
    var tickLastTime = CFAbsoluteTimeGetCurrent()
    timer.setEventHandler {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - tickLastTime
        let currentBytes = store.bgTransferBytesDone
        let delta = currentBytes - tickLastBytes
        let speed = elapsed > 0 ? Double(delta) / elapsed : 0
        tickLastBytes = currentBytes
        tickLastTime = now
        let eta = speed > 0 ? Double(max(0, store.bgTransferBytesTotal - currentBytes)) / speed : 0
        DispatchQueue.main.async {
            store.bgTransferSpeed = speed
            store.bgTransferETA = eta
            var hist = store.bgTransferSpeedHistory
            hist.append(speed)
            if hist.count > 40 { hist.removeFirst(hist.count - 40) }
            store.bgTransferSpeedHistory = hist
        }
    }
    timer.resume()

    DispatchQueue.global(qos: .userInitiated).async {
        defer { timer.cancel() }
        var successCount = 0
        var accumulatedBytes: Int64 = 0
        var lastSampleTime = CFAbsoluteTimeGetCurrent()
        var lastSampleBytes: Int64 = 0

        for (idx, srcURL) in urls.enumerated() {
            if store.bgExportCancelled { break }
            let fileSize = fileSizes[idx]
            let fname = srcURL.lastPathComponent
            DispatchQueue.main.async { store.bgTransferCurrentFile = fname }

            let destURL = destFolder.appendingPathComponent(fname)
            if srcURL.standardizedFileURL == destURL.standardizedFileURL {
                accumulatedBytes += fileSize
                continue
            }

            // 충돌 시 전략 적용
            var isDirExisting: ObjCBool = false
            let destExists = fm.fileExists(atPath: destURL.path, isDirectory: &isDirExisting)
            var srcIsDir: ObjCBool = false
            fm.fileExists(atPath: srcURL.path, isDirectory: &srcIsDir)

            if destExists {
                // 폴더 → 폴더 충돌이면 skip/mergeOrOverwrite 둘 다 병합 (subMode만 다름)
                if isDirExisting.boolValue && srcIsDir.boolValue && (strategy == .skip || strategy == .mergeOrOverwrite) {
                    let subMode: SubFileConflictMode = strategy == .skip ? .skip : .overwrite
                    let baseBytes = accumulatedBytes
                    var subBytes: Int64 = 0
                    var lastUIUpdate = CFAbsoluteTimeGetCurrent()
                    let srcRoot = srcURL
                    let merged = FileConflictResolver.mergeFolders(
                        source: srcURL, destination: destURL, isCut: isCut,
                        subFileMode: subMode,
                        onProgress: { subFile, sz in
                            subBytes += sz
                            // UI 업데이트는 100ms 에 한 번만 (플러딩 방지)
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - lastUIUpdate < 0.1 { return }
                            lastUIUpdate = now
                            let current = baseBytes + subBytes
                            // 최상위 폴더 기준 상대 경로 표시 (중첩 폴더 전체 반영)
                            let rel = subFile.path.replacingOccurrences(of: srcRoot.path + "/", with: "")
                            let subName = "🔀 \(fname)/\(rel)"
                            DispatchQueue.main.async {
                                store.bgTransferCurrentFile = subName
                                store.bgTransferBytesDone = current
                                store.bgExportProgress = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                            }
                        },
                        shouldCancel: { store.bgExportCancelled }
                    )
                    successCount += merged.success > 0 ? 1 : 0
                    completed.append(contentsOf: merged.transferred)
                    accumulatedBytes += fileSize
                    continue
                }

                switch strategy {
                case .skip:
                    // 파일 skip (파일 충돌)
                    accumulatedBytes += fileSize
                    DispatchQueue.main.async {
                        store.bgTransferCurrentFile = "⏭️ 건너뜀: \(fname)"
                        store.bgTransferBytesDone = accumulatedBytes
                        store.bgExportProgress = totalBytes > 0 ? Double(accumulatedBytes) / Double(totalBytes) : 0
                        store.bgExportDone = idx + 1
                    }
                    continue
                case .mergeOrOverwrite:
                    // 파일 덮어쓰기 (비폴더 충돌)
                    try? fm.removeItem(at: destURL)
                case .rename:
                    break  // 아래 uniqueDestination 처리
                case .cancel:
                    break  // 이미 return 됐음
                }
            }

            var finalDest = destURL
            if fm.fileExists(atPath: finalDest.path) {
                // strategy == .rename 이거나, .mergeOrOverwrite 이지만 삭제 실패한 경우
                finalDest = FileConflictResolver.uniqueDestination(for: srcURL, in: destFolder)
            }

            // 폴더는 재귀 merge 로 per-file 진행률 확보 (단일 moveItem은 콜백 없음)
            if srcIsDir.boolValue {
                let baseBytes = accumulatedBytes
                var subBytes: Int64 = 0
                var lastUIUpdate = CFAbsoluteTimeGetCurrent()
                let srcRoot = srcURL
                let displayName = finalDest.lastPathComponent
                let merged = FileConflictResolver.mergeFolders(
                    source: srcURL, destination: finalDest, isCut: isCut,
                    subFileMode: .overwrite,
                    onProgress: { subFile, sz in
                        subBytes += sz
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastUIUpdate < 0.1 { return }
                        lastUIUpdate = now
                        let current = baseBytes + subBytes
                        let rel = subFile.path.replacingOccurrences(of: srcRoot.path + "/", with: "")
                        let subName = "🔀 \(displayName)/\(rel)"
                        DispatchQueue.main.async {
                            store.bgTransferCurrentFile = subName
                            store.bgTransferBytesDone = current
                            store.bgExportProgress = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                        }
                    },
                    shouldCancel: { store.bgExportCancelled }
                )
                successCount += merged.success > 0 ? 1 : 0
                completed.append(contentsOf: merged.transferred)
                accumulatedBytes += fileSize
            } else {
                do {
                    if isCut { try fm.moveItem(at: srcURL, to: finalDest) }
                    else { try fm.copyItem(at: srcURL, to: finalDest) }
                    successCount += 1
                    completed.append((srcURL, finalDest))
                } catch {
                    fputs("📋 [PASTE] 실패: \(fname) — \(error.localizedDescription)\n", stderr)
                }
                accumulatedBytes += fileSize
            }

            let now = CFAbsoluteTimeGetCurrent()
            let sampleElapsed = now - lastSampleTime
            if sampleElapsed >= 0.3 || idx == urls.count - 1 {
                let bytesInSample = accumulatedBytes - lastSampleBytes
                let speed = sampleElapsed > 0 ? Double(bytesInSample) / sampleElapsed : 0
                lastSampleTime = now
                lastSampleBytes = accumulatedBytes
                let remaining = totalBytes - accumulatedBytes
                let eta = speed > 0 ? Double(remaining) / speed : 0
                let done = idx + 1
                let bytesDone = accumulatedBytes
                DispatchQueue.main.async {
                    store.bgExportDone = done
                    store.bgTransferBytesDone = bytesDone
                    store.bgExportProgress = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0
                    store.bgTransferSpeed = speed
                    store.bgTransferETA = eta
                    var hist = store.bgTransferSpeedHistory
                    hist.append(speed)
                    if hist.count > 40 { hist.removeFirst(hist.count - 40) }
                    store.bgTransferSpeedHistory = hist
                }
            }
        }

        let wasCancelled = store.bgExportCancelled
        let completedSnapshot = completed

        if wasCancelled {
            for (origSrc, destURL) in completed.reversed() {
                if isCut {
                    try? fm.moveItem(at: destURL, to: origSrc)
                } else {
                    try? fm.removeItem(at: destURL)
                }
            }
        }

        DispatchQueue.main.async {
            if isCut && !wasCancelled && clearClipboardOnSuccess {
                NSPasteboard.general.clearContents()
                store.pendingCutPhotoIDs = []
            }
            if !wasCancelled && !completedSnapshot.isEmpty {
                let record = PhotoStore.PasteUndoRecord(
                    kind: isCut ? "cut" : "copy",
                    items: completedSnapshot,
                    destFolder: destFolder
                )
                store.pasteUndoStack.append(record)
                if store.pasteUndoStack.count > 20 {
                    store.pasteUndoStack.removeFirst(store.pasteUndoStack.count - 20)
                }
            }
            store.bgExportActive = false
            store.bgExportProgress = 0
            store.bgExportDone = 0
            store.bgExportTotal = 0
            store.bgExportLabel = ""
            store.bgExportDestination = nil
            store.bgExportCancelled = false
            store.bgTransferCurrentFile = ""
            store.bgTransferSourcePath = ""
            store.bgTransferDestPath = ""
            store.bgTransferBytesDone = 0
            store.bgTransferBytesTotal = 0
            store.bgTransferSpeed = 0
            store.bgTransferETA = 0
            store.bgTransferSpeedHistory = []
            store.bgTransferStartedAt = nil

            let icon = isCut ? "✂️" : "📋"
            let verb = isCut ? "이동" : "복사"
            if wasCancelled {
                store.showToastMessage("❌ \(verb) 취소됨")
            } else {
                store.showToastMessage("\(icon) \(verb) 완료 — \(successCount)개 → \(destFolder.lastPathComponent)")
            }
            // 현재 폴더가 대상 폴더와 일치하면 리로드
            if store.folderURL == destFolder {
                store.loadFolder(destFolder, restoreRatings: true)
            }
            NotificationCenter.default.post(name: .init("FolderTreeNeedsRefresh"), object: nil)
        }
    }
}

/// 폴더 트리용 공통 컨텍스트 메뉴 — 복사/잘라내기/붙여넣기 3줄.
@ViewBuilder
func folderTreeCopyCutPasteMenu(_ url: URL, store: PhotoStore) -> some View {
    Button(action: { copyURLToPasteboard(url) }) {
        Label("복사  ⌘C", systemImage: "doc.on.doc")
    }
    Button(action: { cutURLToPasteboard(url) }) {
        Label("잘라내기  ⌘X", systemImage: "scissors")
    }
    Button(action: { pasteFilesToFolder(url, store: store) }) {
        Label("여기에 붙여넣기  ⌘V", systemImage: "doc.on.clipboard")
    }
    .disabled(NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil)?.isEmpty ?? true)
}

/// Paste files from pasteboard to current folder (Cmd+V).
/// Cut 마커가 있으면 move (원본 삭제), 없으면 copy. 파일/폴더 둘 다 지원.
func pasteFilesFromPasteboard(store: PhotoStore) {
    guard let destFolder = store.folderURL else {
        fputs("📋 [PASTE] 대상 폴더 없음\n", stderr)
        return
    }
    let pasteboard = NSPasteboard.general
    guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
          !urls.isEmpty else {
        fputs("📋 [PASTE] 클립보드에 파일 없음\n", stderr)
        return
    }

    let isCut = pasteboard.data(forType: pickshotCutPasteboardType) != nil
    let op = isCut ? "MOVE" : "COPY"
    fputs("📋 [PASTE] \(op) \(urls.count)개 파일 → \(destFolder.lastPathComponent)\n", stderr)

    // 충돌 검사 + 전략 선택 (메인 스레드)
    let conflicts = FileConflictResolver.detectConflicts(sources: urls, destFolder: destFolder)
    var strategy: FileConflictStrategy = .mergeOrOverwrite
    if !conflicts.isEmpty {
        strategy = FileConflictResolver.promptUser(conflicts: conflicts)
        if strategy == .cancel {
            fputs("📋 [PASTE] 사용자 취소\n", stderr)
            return
        }
    }

    // 총 바이트 수 미리 계산 (진행률 % 정확도 + ETA 계산용)
    let fm = FileManager.default
    var totalBytes: Int64 = 0
    var fileSizes: [Int64] = []
    for u in urls {
        var sz: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: u.path) {
            if let s = attrs[.size] as? Int64 {
                sz = s
            } else if let s = attrs[.size] as? Int {
                sz = Int64(s)
            }
            // 폴더는 하위 전체 크기
            if (attrs[.type] as? FileAttributeType) == .typeDirectory {
                sz = folderSizeRecursive(url: u)
            }
        }
        fileSizes.append(sz)
        totalBytes += sz
    }

    // 진행 상태 시작
    store.bgExportActive = true
    store.bgExportLabel = isCut ? "잘라내기" : "붙여넣기"
    store.bgExportTotal = urls.count
    store.bgExportDone = 0
    store.bgExportProgress = 0
    store.bgExportCancelled = false
    store.bgExportDestination = destFolder
    let firstSource = urls.first?.deletingLastPathComponent().path ?? ""
    store.bgTransferSourcePath = firstSource
    store.bgTransferDestPath = destFolder.path
    store.bgTransferBytesDone = 0
    store.bgTransferBytesTotal = totalBytes
    store.bgTransferSpeed = 0
    store.bgTransferETA = 0
    store.bgTransferSpeedHistory = []
    store.bgTransferStartedAt = Date()

    // 완료된 전송 기록 (취소 시 롤백용)
    // isCut 이면 (원본 → 대상) — 취소 시 대상에서 원본으로 move 해 원복
    // !isCut 이면 대상 경로만 기록 — 취소 시 대상 파일 삭제
    var completedTransfers: [(source: URL, dest: URL)] = []
    let completedLock = NSLock()

    // 500ms 타이머로 그래프/속도 샘플 보장
    let graphTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    graphTimer.schedule(deadline: .now() + 0.5, repeating: 0.5)
    var tickLastBytes: Int64 = 0
    var tickLastTime = CFAbsoluteTimeGetCurrent()
    graphTimer.setEventHandler {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - tickLastTime
        let currentBytes = store.bgTransferBytesDone
        let delta = currentBytes - tickLastBytes
        let speed = elapsed > 0 ? Double(delta) / elapsed : 0
        tickLastBytes = currentBytes
        tickLastTime = now
        let eta = speed > 0 ? Double(max(0, store.bgTransferBytesTotal - currentBytes)) / speed : 0
        DispatchQueue.main.async {
            store.bgTransferSpeed = speed
            store.bgTransferETA = eta
            var hist = store.bgTransferSpeedHistory
            hist.append(speed)
            if hist.count > 40 { hist.removeFirst(hist.count - 40) }
            store.bgTransferSpeedHistory = hist
        }
    }
    graphTimer.resume()

    // 붙여넣기 실행 (background 스레드)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { graphTimer.cancel() }
        var successCount = 0
        var failedFiles: [String] = []
        var accumulatedBytes: Int64 = 0
        var lastSampleTime = CFAbsoluteTimeGetCurrent()
        var lastSampleBytes: Int64 = 0

        for (idx, sourceURL) in urls.enumerated() {
            if store.bgExportCancelled { break }

            let fileSize = fileSizes[idx]
            let fname = sourceURL.lastPathComponent

            DispatchQueue.main.async {
                store.bgTransferCurrentFile = fname
            }

            let destURL = destFolder.appendingPathComponent(fname)
            if sourceURL.standardizedFileURL == destURL.standardizedFileURL {
                accumulatedBytes += fileSize
                let done = idx + 1
                DispatchQueue.main.async {
                    store.bgExportDone = done
                    store.bgTransferBytesDone = accumulatedBytes
                    store.bgExportProgress = totalBytes > 0 ? Double(accumulatedBytes) / Double(totalBytes) : 0
                }
                continue
            }

            // 충돌 전략 적용
            var isDirExisting: ObjCBool = false
            let destExists = fm.fileExists(atPath: destURL.path, isDirectory: &isDirExisting)
            var srcIsDir: ObjCBool = false
            fm.fileExists(atPath: sourceURL.path, isDirectory: &srcIsDir)

            if destExists {
                // 폴더 → 폴더: skip/mergeOrOverwrite 둘 다 병합 (subMode만 차이)
                if isDirExisting.boolValue && srcIsDir.boolValue && (strategy == .skip || strategy == .mergeOrOverwrite) {
                    let subMode: SubFileConflictMode = strategy == .skip ? .skip : .overwrite
                    let baseBytes = accumulatedBytes
                    var subBytes: Int64 = 0
                    var lastUIUpdate = CFAbsoluteTimeGetCurrent()
                    var lastSpeedSample = CFAbsoluteTimeGetCurrent()
                    var lastSpeedBytes: Int64 = 0
                    let srcRoot = sourceURL
                    let merged = FileConflictResolver.mergeFolders(
                        source: sourceURL, destination: destURL, isCut: isCut,
                        subFileMode: subMode,
                        onProgress: { subFile, sz in
                            subBytes += sz
                            let now = CFAbsoluteTimeGetCurrent()
                            // UI 업데이트 100ms 스로틀 (main 큐 플러딩 방지)
                            if now - lastUIUpdate < 0.1 { return }
                            lastUIUpdate = now
                            let current = baseBytes + subBytes
                            let rel = subFile.path.replacingOccurrences(of: srcRoot.path + "/", with: "")
                            let subName = "🔀 \(fname)/\(rel)"
                            // 속도 샘플링
                            let speedElapsed = now - lastSpeedSample
                            var speedSnapshot: Double = 0
                            var sampleSpeed = false
                            if speedElapsed >= 0.3 {
                                speedSnapshot = Double(subBytes - lastSpeedBytes) / speedElapsed
                                lastSpeedSample = now
                                lastSpeedBytes = subBytes
                                sampleSpeed = true
                            }
                            let eta = speedSnapshot > 0 ? Double(totalBytes - current) / speedSnapshot : 0
                            DispatchQueue.main.async {
                                store.bgTransferCurrentFile = subName
                                store.bgTransferBytesDone = current
                                store.bgExportProgress = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                                if sampleSpeed {
                                    store.bgTransferSpeed = speedSnapshot
                                    store.bgTransferETA = eta
                                    var hist = store.bgTransferSpeedHistory
                                    hist.append(speedSnapshot)
                                    if hist.count > 40 { hist.removeFirst(hist.count - 40) }
                                    store.bgTransferSpeedHistory = hist
                                }
                            }
                        },
                        shouldCancel: { store.bgExportCancelled }
                    )
                    successCount += merged.success > 0 ? 1 : 0
                    completedLock.lock()
                    completedTransfers.append(contentsOf: merged.transferred)
                    completedLock.unlock()
                    accumulatedBytes += fileSize
                    let done = idx + 1
                    let bytesDone = accumulatedBytes
                    DispatchQueue.main.async {
                        store.bgExportDone = done
                        store.bgTransferBytesDone = bytesDone
                        store.bgExportProgress = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0
                    }
                    continue
                }

                switch strategy {
                case .skip:
                    // 파일 skip (비폴더 충돌)
                    accumulatedBytes += fileSize
                    let done = idx + 1
                    let bytesDone = accumulatedBytes
                    DispatchQueue.main.async {
                        store.bgTransferCurrentFile = "⏭️ 건너뜀: \(fname)"
                        store.bgExportDone = done
                        store.bgTransferBytesDone = bytesDone
                        store.bgExportProgress = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0
                    }
                    continue
                case .mergeOrOverwrite:
                    // 파일 덮어쓰기
                    try? fm.removeItem(at: destURL)
                case .rename:
                    break  // 아래에서 uniqueDestination 처리
                case .cancel:
                    break
                }
            }

            // 최종 대상 결정: 여전히 충돌이면 _1 suffix
            var finalDest = destURL
            if fm.fileExists(atPath: finalDest.path) {
                finalDest = FileConflictResolver.uniqueDestination(for: sourceURL, in: destFolder)
            }

            // 폴더는 재귀 merge 로 per-file 진행률 확보
            var transferOK = false
            if srcIsDir.boolValue {
                let baseBytes = accumulatedBytes
                var subBytes: Int64 = 0
                var lastUIUpdate = CFAbsoluteTimeGetCurrent()
                let srcRoot = sourceURL
                let displayName = finalDest.lastPathComponent
                let merged = FileConflictResolver.mergeFolders(
                    source: sourceURL, destination: finalDest, isCut: isCut,
                    subFileMode: .overwrite,
                    onProgress: { subFile, sz in
                        subBytes += sz
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastUIUpdate < 0.1 { return }
                        lastUIUpdate = now
                        let current = baseBytes + subBytes
                        let rel = subFile.path.replacingOccurrences(of: srcRoot.path + "/", with: "")
                        let subName = "🔀 \(displayName)/\(rel)"
                        DispatchQueue.main.async {
                            store.bgTransferCurrentFile = subName
                            store.bgTransferBytesDone = current
                            store.bgExportProgress = totalBytes > 0 ? Double(current) / Double(totalBytes) : 0
                        }
                    },
                    shouldCancel: { store.bgExportCancelled }
                )
                if merged.success > 0 {
                    successCount += 1
                    transferOK = true
                    completedLock.lock()
                    completedTransfers.append(contentsOf: merged.transferred)
                    completedLock.unlock()
                }
            } else {
                do {
                    if isCut {
                        try fm.moveItem(at: sourceURL, to: finalDest)
                    } else {
                        try fm.copyItem(at: sourceURL, to: finalDest)
                    }
                    successCount += 1
                    transferOK = true
                } catch {
                    failedFiles.append(fname)
                    fputs("📋 [PASTE] 실패: \(fname) — \(error.localizedDescription)\n", stderr)
                }
                if transferOK {
                    completedLock.lock()
                    completedTransfers.append((source: sourceURL, dest: finalDest))
                    completedLock.unlock()
                }
            }

            accumulatedBytes += fileSize

            // 속도 샘플링 (0.3초마다 + 파일 당 1회)
            let now = CFAbsoluteTimeGetCurrent()
            let sampleElapsed = now - lastSampleTime
            if sampleElapsed >= 0.3 || idx == urls.count - 1 {
                let bytesInSample = accumulatedBytes - lastSampleBytes
                let speed = sampleElapsed > 0 ? Double(bytesInSample) / sampleElapsed : 0
                lastSampleTime = now
                lastSampleBytes = accumulatedBytes

                let remainingBytes = totalBytes - accumulatedBytes
                let eta = speed > 0 ? Double(remainingBytes) / speed : 0

                let done = idx + 1
                let bytesDone = accumulatedBytes
                let currentSpeed = speed

                DispatchQueue.main.async {
                    store.bgExportDone = done
                    store.bgTransferBytesDone = bytesDone
                    store.bgExportProgress = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0
                    store.bgTransferSpeed = currentSpeed
                    store.bgTransferETA = eta
                    // 그래프 히스토리 — 최대 40개 유지
                    var hist = store.bgTransferSpeedHistory
                    hist.append(currentSpeed)
                    if hist.count > 40 { hist.removeFirst(hist.count - 40) }
                    store.bgTransferSpeedHistory = hist
                }
            } else {
                // 샘플링 안 해도 바이트/파일 카운트는 업데이트
                let done = idx + 1
                let bytesDone = accumulatedBytes
                DispatchQueue.main.async {
                    store.bgExportDone = done
                    store.bgTransferBytesDone = bytesDone
                    store.bgExportProgress = totalBytes > 0 ? Double(bytesDone) / Double(totalBytes) : 0
                }
            }

        }

        let finalSuccess = successCount
        let finalFailedCount = failedFiles.count
        let finalTotal = urls.count
        let wasCancelled = store.bgExportCancelled

        // 취소된 경우 이미 전송된 파일들 롤백
        if wasCancelled {
            DispatchQueue.main.async {
                store.bgTransferCurrentFile = "취소 중 — 파일 복원 중..."
            }
            completedLock.lock()
            let toRollback = completedTransfers
            completedLock.unlock()

            for (origSrc, destURL) in toRollback.reversed() {
                if isCut {
                    // 원복: dest → origSrc 로 되돌리기
                    if !fm.fileExists(atPath: origSrc.path) {
                        try? fm.moveItem(at: destURL, to: origSrc)
                    } else {
                        try? fm.removeItem(at: destURL)
                    }
                } else {
                    // 복사본 삭제
                    try? fm.removeItem(at: destURL)
                }
            }
            fputs("📋 [PASTE CANCELLED] 복구: \(toRollback.count)개 파일 원위치\n", stderr)
        }

        let completedSnapshot = completedTransfers
        DispatchQueue.main.async {
            // cut 완료/취소 이후 pasteboard + pending 정리
            if isCut && !wasCancelled {
                pasteboard.clearContents()
                store.pendingCutPhotoIDs = []
            }
            // 취소 시엔 pendingCutPhotoIDs 유지

            // 성공적으로 완료되었으면 undo stack 에 기록 (Cmd+Z 로 원위치 가능)
            if !wasCancelled && !completedSnapshot.isEmpty {
                let record = PhotoStore.PasteUndoRecord(
                    kind: isCut ? "cut" : "copy",
                    items: completedSnapshot,
                    destFolder: destFolder
                )
                store.pasteUndoStack.append(record)
                if store.pasteUndoStack.count > 20 {
                    store.pasteUndoStack.removeFirst(store.pasteUndoStack.count - 20)
                }
            }

            store.bgExportActive = false
            store.bgExportProgress = 0
            store.bgExportDone = 0
            store.bgExportTotal = 0
            store.bgExportLabel = ""
            store.bgExportDestination = nil
            store.bgExportCancelled = false
            store.bgTransferCurrentFile = ""
            store.bgTransferSourcePath = ""
            store.bgTransferDestPath = ""
            store.bgTransferBytesDone = 0
            store.bgTransferBytesTotal = 0
            store.bgTransferSpeed = 0
            store.bgTransferETA = 0
            store.bgTransferSpeedHistory = []
            store.bgTransferStartedAt = nil

            let icon = isCut ? "✂️" : "📋"
            let verb = isCut ? "이동" : "복사"
            if wasCancelled {
                store.showToastMessage("❌ \(verb) 취소됨 — 원래 상태로 복원")
            } else if finalFailedCount == 0 {
                store.showToastMessage("\(icon) \(verb) 완료 — \(finalSuccess)개 파일")
            } else {
                store.showToastMessage("\(icon) \(verb) 완료 — 성공 \(finalSuccess), 실패 \(finalFailedCount)")
            }

            store.loadFolder(destFolder, restoreRatings: true)
            fputs("📋 [PASTE] \(wasCancelled ? "취소" : "완료") — \(finalSuccess)/\(finalTotal) 성공, \(finalFailedCount) 실패\n", stderr)
        }
    }
}

/// 폴더 내부 모든 파일 사이즈 합 (재귀)
private func folderSizeRecursive(url: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url,
          includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var total: Int64 = 0
    for case let u as URL in enumerator {
        if let values = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
           values.isRegularFile == true,
           let sz = values.fileSize {
            total += Int64(sz)
        }
    }
    return total
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
        let wasRepeat = store?.isKeyRepeat ?? false
        store?.isKeyRepeat = false
        // 키 놓은 순간에 prefetch 한번만 수행 (꾹 누르기 중엔 스킵했음)
        // wasRepeat == true 면 꾹 누르기 끝 → 이제 prefetch
        if wasRepeat { store?.prefetchNearbyThumbnails() }
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
                if hasShift {
                    // Cmd+Shift+C: v8.5 보정값 복사
                    if let sel = store.selectedPhoto, !sel.isFolder, !sel.isParentFolder, !sel.isVideoFile {
                        let s = DevelopStore.shared.get(for: sel.jpgURL)
                        if !s.isDefault {
                            DevelopStore.shared.copyToClipboard(s)
                            NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "보정값 복사됨")
                        }
                    }
                    return
                }
                // Cmd+C: Copy selected files to clipboard (Finder-compatible)
                copySelectedFilesToPasteboard(store: store)
                return
            } else if charOrCode("x", 7) {
                // Cmd+X: Cut (move on paste)
                cutSelectedFilesToPasteboard(store: store)
                return
            } else if charOrCode("v", 9) {
                if hasShift {
                    // Cmd+Shift+V: v8.5 보정값 선택된 사진들에 일괄 적용
                    guard DevelopStore.shared.clipboard != nil else { return }
                    let targets: [URL]
                    if store.selectionCount > 1 {
                        targets = store.multiSelectedPhotos.filter { !$0.isFolder && !$0.isParentFolder && !$0.isVideoFile }.map { $0.jpgURL }
                    } else if let sel = store.selectedPhoto, !sel.isFolder, !sel.isParentFolder, !sel.isVideoFile {
                        targets = [sel.jpgURL]
                    } else {
                        targets = []
                    }
                    let applied = DevelopStore.shared.pasteFromClipboard(to: targets)
                    NotificationCenter.default.post(name: .pickShotAdjustmentToast, object: "\(applied)장에 보정값 적용됨")
                    return
                }
                // Cmd+V: Paste (copy or move based on cut marker)
                pasteFilesFromPasteboard(store: store)
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

        // === v8.5 비파괴 보정 단축키 ===
        // 현재 선택된 사진 URL 조회 (없으면 스킵)
        if let selPhoto = store.selectedPhoto,
           !selPhoto.isFolder, !selPhoto.isParentFolder, !selPhoto.isVideoFile {
            let url = selPhoto.jpgURL
            let hasOption = event.modifierFlags.contains(.option)

            // [ / ] — 노출 ±0.1 EV, Shift+[/] → ±0.5 EV
            if chars == "[" || chars == "{" || keyCode == 33 {
                var s = DevelopStore.shared.get(for: url)
                let delta = hasShift ? -0.5 : -0.1
                s.exposure = max(-2.0, min(2.0, (s.exposure + delta * 10).rounded() / 10))
                DevelopStore.shared.set(s, for: url)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                return
            }
            if chars == "]" || chars == "}" || keyCode == 30 {
                var s = DevelopStore.shared.get(for: url)
                let delta = hasShift ? 0.5 : 0.1
                s.exposure = max(-2.0, min(2.0, (s.exposure + delta * 10).rounded() / 10))
                DevelopStore.shared.set(s, for: url)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                return
            }
            // ; / ' — 색온도 ±1, Shift+; / ' → 틴트 ±1
            if chars == ";" || chars == ":" || keyCode == 41 {
                var s = DevelopStore.shared.get(for: url)
                if hasShift {
                    s.tint = max(-100, min(100, s.tint - 5))
                } else {
                    s.temperature = max(-100, min(100, s.temperature - 5))
                }
                DevelopStore.shared.set(s, for: url)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                return
            }
            if chars == "'" || chars == "\"" || keyCode == 39 {
                var s = DevelopStore.shared.get(for: url)
                if hasShift {
                    s.tint = max(-100, min(100, s.tint + 5))
                } else {
                    s.temperature = max(-100, min(100, s.temperature + 5))
                }
                DevelopStore.shared.set(s, for: url)
                NotificationCenter.default.post(name: .pickShotAdjustmentActivity, object: nil)
                return
            }
            // Option+E → 자동 노출 토글
            if hasOption && (charOrCode("e", 14)) {
                var s = DevelopStore.shared.get(for: url)
                s.exposureAuto.toggle()
                DevelopStore.shared.set(s, for: url)
                return
            }
            // Option+W → 자동 WB 토글
            if hasOption && charOrCode("w", 13) {
                var s = DevelopStore.shared.get(for: url)
                s.wbAuto.toggle()
                DevelopStore.shared.set(s, for: url)
                return
            }
            // R — 현재 사진 보정 전체 리셋
            if charOrCode("r", 15) && !hasCmd && !hasShift && !hasOption {
                var s = DevelopStore.shared.get(for: url)
                guard !s.isDefault else { return }
                s.reset()
                DevelopStore.shared.set(s, for: url)
                return
            }
            // Option+K — 자동 커브 토글 (K 키는 비디오 스크러빙 전용이라 Option 필수)
            if hasOption && charOrCode("k", 40) {
                var s = DevelopStore.shared.get(for: url)
                s.curveAuto.toggle()
                DevelopStore.shared.set(s, for: url)
                return
            }
            // C — 인라인 크롭 모드 토글 (단일 선택일 때만 — 2~4장이면 Compare 모드로 양보)
            if charOrCode("c", 8) && !hasCmd && !hasShift && !hasOption && store.selectionCount <= 1 {
                NotificationCenter.default.post(name: .toggleCropMode, object: nil)
                return
            }
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

            // I/O: IN/OUT 마커 (NLE 표준 단축키)
            //  - Shift+I/O → 해당 포인트로 점프
            //  - Alt+I/O → 해당 포인트만 클리어
            //  - X → 모든 마커 클리어
            if charOrCode("i", 34) && !hasCmd {
                if hasShift { videoMgr.jumpToIn() }
                else if event.modifierFlags.contains(.option) { videoMgr.clearInMarker() }
                else { videoMgr.markInAtCurrent() }
                return
            }
            if charOrCode("o", 31) && !hasCmd {
                if hasShift { videoMgr.jumpToOut() }
                else if event.modifierFlags.contains(.option) { videoMgr.clearOutMarker() }
                else { videoMgr.markOutAtCurrent() }
                return
            }
            if charOrCode("x", 7) && !hasCmd && !hasShift {
                videoMgr.clearMarkers()
                return
            }
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

        // F: 고객 펜 오버레이 토글 (클라이언트가 그린 펜 그림 표시/숨김)
        if charOrCode("f", 3) && !hasCmd {
            store.showClientPenOverlay.toggle()
            store.showToastMessage(store.showClientPenOverlay ? "✏️ 고객 펜 표시" : "✏️ 고객 펜 숨김")
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

        // 영상 파일이어도 방향키는 썸네일 이동 전용 — 영상 제어는 JKL / Space 사용
        // (영상 프레임 스텝/점프는 JKL 로 충분, 방향키는 일관된 파일 탐색)

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
