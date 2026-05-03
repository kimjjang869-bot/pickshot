//
//  FileConflictResolver.swift
//  PhotoRawManager
//
//  파일/폴더 전송 시 동일 이름 충돌 감지 + 사용자 선택 다이얼로그.
//  붙여넣기, 드래그 이동, 내보내기 등 모든 전송 시스템에서 공용.
//

import Foundation
import AppKit
import SwiftUI

// MARK: - 충돌 해결 전략

enum FileConflictStrategy {
    /// 폴더: 재귀 병합 + 하위 파일 충돌은 덮어쓰기.
    /// 파일: 덮어쓰기 (기존 파일 교체)
    case mergeOrOverwrite
    /// 폴더: 재귀 병합 + 하위 파일 충돌은 건너뛰기 (기존 보존, 없는 것만 채우기).
    /// 파일: 건너뛰기 (기존 보존)
    case skip
    /// 이름 변경 (_1, _2 suffix 자동 부여)
    case rename
    /// 전체 작업 취소
    case cancel
}

/// 폴더 병합 중 하위 파일 충돌 처리 방법
enum SubFileConflictMode {
    case overwrite  // 기존 파일 덮어쓰기
    case skip       // 기존 파일 보존
}

// MARK: - 충돌 정보

struct FileConflict {
    let source: URL
    let dest: URL
    let isFolder: Bool
}

// MARK: - Dialog View

private struct FileConflictDialogView: View {
    let conflicts: [FileConflict]
    let onChoice: (FileConflictStrategy) -> Void

    private var summary: String {
        let folderCount = conflicts.filter { $0.isFolder }.count
        let fileCount = conflicts.count - folderCount
        if folderCount > 0 && fileCount > 0 {
            return "폴더 \(folderCount)개, 파일 \(fileCount)개가 이미 존재합니다."
        } else if folderCount > 0 {
            return "폴더 \(folderCount)개가 이미 존재합니다."
        } else {
            return "파일 \(fileCount)개가 이미 존재합니다."
        }
    }

    private var hasFolders: Bool {
        conflicts.contains(where: { $0.isFolder })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 헤더 — 아이콘 + 제목
            HStack(spacing: 12) {
                if let icon = NSImage(named: NSImage.applicationIconName) {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("대상 위치에 동일한 이름이 있습니다")
                        .font(.system(size: 14, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // 충돌 항목 목록
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(conflicts.prefix(5).enumerated()), id: \.offset) { _, c in
                    HStack(spacing: 6) {
                        Image(systemName: c.isFolder ? "folder.fill" : "doc.fill")
                            .font(.system(size: 10))
                            .foregroundColor(c.isFolder ? .accentColor : .secondary)
                        Text(c.source.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if conflicts.count > 5 {
                    Text("… 외 \(conflicts.count - 5)개")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.leading, 16)
                }
            }
            .padding(.vertical, 4)

            Divider()

            // 옵션 설명
            VStack(alignment: .leading, spacing: 4) {
                Text("처리 방법")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                optionRow(name: hasFolders ? "병합 / 덮어쓰기" : "덮어쓰기",
                          desc: hasFolders ? "같은 이름을 새 걸로 대체 (폴더는 재귀 병합)" : "기존 파일을 새 걸로 대체")
                optionRow(name: "건너뛰기",
                          desc: "같은 이름은 그대로 두고, 없는 것만 채우기" + (hasFolders ? " (폴더는 재귀 병합)" : ""))
                optionRow(name: "이름 변경", desc: "복사본처럼 '_1' 접미사 자동 부여")
            }

            Spacer(minLength: 8)

            // 버튼 — 가운데 정렬, 왼→오: 병합/덮어쓰기 → 건너뛰기 → 이름 변경 → 취소
            HStack(spacing: 10) {
                Spacer()
                Button(action: { onChoice(.mergeOrOverwrite) }) {
                    Text(hasFolders ? "병합 / 덮어쓰기" : "덮어쓰기")
                        .frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)

                Button(action: { onChoice(.skip) }) {
                    Text("건너뛰기").frame(minWidth: 80)
                }

                Button(action: { onChoice(.rename) }) {
                    Text("이름 변경").frame(minWidth: 80)
                }

                Button(action: { onChoice(.cancel) }) {
                    Text("취소").frame(minWidth: 60)
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func optionRow(name: String, desc: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").font(.system(size: 10)).foregroundColor(.secondary)
            Text(name).font(.system(size: 11, weight: .semibold))
            Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}

// MARK: - Resolver

enum FileConflictResolver {

    /// 전송 대상 URL 목록에서 대상 폴더에 동일 이름이 있는지 검사.
    static func detectConflicts(sources: [URL], destFolder: URL) -> [FileConflict] {
        let fm = FileManager.default
        var result: [FileConflict] = []
        for src in sources {
            let dst = destFolder.appendingPathComponent(src.lastPathComponent)
            // 자기 자신 → 자기 자신은 충돌 아님
            if src.standardizedFileURL == dst.standardizedFileURL { continue }
            if fm.fileExists(atPath: dst.path) {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: dst.path, isDirectory: &isDir)
                result.append(FileConflict(source: src, dest: dst, isFolder: isDir.boolValue))
            }
        }
        return result
    }

    /// 사용자에게 충돌 해결 전략을 묻는 커스텀 SwiftUI 다이얼로그.
    /// **반드시 메인 스레드에서 호출해야 함.**
    /// 버튼 순서 (왼→오): 병합/덮어쓰기 · 건너뛰기 · 이름 변경 · 취소 (전부 중앙 정렬)
    static func promptUser(conflicts: [FileConflict]) -> FileConflictStrategy {
        guard !conflicts.isEmpty else { return .mergeOrOverwrite }

        var chosen: FileConflictStrategy = .cancel
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "이름 충돌 처리"
        window.isReleasedWhenClosed = false
        window.level = .modalPanel

        let view = FileConflictDialogView(conflicts: conflicts) { result in
            chosen = result
            NSApp.stopModal()
        }
        let host = NSHostingController(rootView: view)
        window.contentViewController = host
        window.center()

        NSApp.runModal(for: window)
        window.orderOut(nil)
        return chosen
    }

    // MARK: - 실제 전송 헬퍼

    /// 충돌 전략을 반영해 단일 URL 을 최종 대상 URL 로 해결.
    /// - `skip` → nil 반환 (건너뛰기)
    /// - `rename` → "_1, _2" suffix 자동 부여
    /// - `mergeOrOverwrite` → 기존 파일은 그대로 덮어씀 (파일), 폴더는 호출자가 merge 처리
    /// - `cancel` → nil 반환 (호출자가 abort 처리해야 함)
    static func resolveDestination(
        source: URL,
        destFolder: URL,
        strategy: FileConflictStrategy
    ) -> URL? {
        let fm = FileManager.default
        let dst = destFolder.appendingPathComponent(source.lastPathComponent)

        // 충돌 없음 — 그대로 반환
        if !fm.fileExists(atPath: dst.path) { return dst }

        switch strategy {
        case .skip, .cancel:
            return nil
        case .mergeOrOverwrite:
            return dst  // 호출자가 파일/폴더 타입 별로 처리
        case .rename:
            return uniqueDestination(for: source, in: destFolder)
        }
    }

    /// "name_1.ext, name_2.ext ..." 식으로 충돌하지 않는 URL 찾기.
    static func uniqueDestination(for source: URL, in destFolder: URL) -> URL {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var suffix = 1
        while true {
            let name = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
            let url = destFolder.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return url }
            suffix += 1
            if suffix > 9999 { return url }  // safeguard
        }
    }

    /// 폴더 재귀 병합: srcFolder 의 내용물을 destFolder 에 merge.
    /// 하위 파일 충돌은 `subFileMode` 에 따라 덮어쓰기 또는 건너뛰기.
    ///
    /// - Parameters:
    ///   - subFileMode: 하위 파일 이름 충돌 처리. `.skip` = 기존 보존, `.overwrite` = 덮어쓰기.
    ///   - onProgress: 각 하위 파일 처리 직후 호출. (파일 URL, 해당 파일 바이트 수) 전달.
    ///     UI 갱신은 호출자가 throttle 해야 함 (여기선 파일 건당 호출).
    ///   - shouldCancel: true 반환 시 즉시 중단.
    /// - 반환: (성공 카운트, 전송된 경로 매핑, 건너뛴 개수, 전송된 총 바이트)
    ///
    /// **무한루프 방지**: srcFolder 가 destFolder 의 조상이면 중단.
    @discardableResult
    static func mergeFolders(
        source srcFolder: URL,
        destination destFolder: URL,
        isCut: Bool,
        subFileMode: SubFileConflictMode,
        onProgress: ((_ file: URL, _ bytes: Int64) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) -> (success: Int, transferred: [(source: URL, dest: URL)], skipped: Int, bytes: Int64) {
        let fm = FileManager.default
        var success = 0
        var skipped = 0
        var bytesMoved: Int64 = 0
        var transferred: [(source: URL, dest: URL)] = []

        // 무한루프 방지: dest가 src의 하위(자기자신 포함)이면 중단
        let srcStd = srcFolder.standardizedFileURL.path
        let dstStd = destFolder.standardizedFileURL.path
        if dstStd == srcStd || dstStd.hasPrefix(srcStd + "/") {
            plog("[MERGE] 중단: dest가 src의 하위임 (\(srcStd) → \(dstStd))\n")
            return (0, [], 0, 0)
        }

        plog("[MERGE] 시작 — \(srcStd) → \(dstStd) (isCut=\(isCut), mode=\(subFileMode))\n")

        // dest 폴더 없으면 생성
        if !fm.fileExists(atPath: destFolder.path) {
            try? fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
        }

        // 한 번 스냅샷 — 이동/복사 중에 enumerator 동적으로 바뀌지 않도록
        guard let items = try? fm.contentsOfDirectory(at: srcFolder, includingPropertiesForKeys: nil) else {
            return (0, [], 0, 0)
        }

        for item in items {
            if shouldCancel?() == true { break }

            let itemDest = destFolder.appendingPathComponent(item.lastPathComponent)

            // 아이템 자체가 폴더/파일인지 한 번만 판별
            var itemIsDir: ObjCBool = false
            fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)

            var destIsDir: ObjCBool = false
            let destExists = fm.fileExists(atPath: itemDest.path, isDirectory: &destIsDir)

            if destExists {
                if itemIsDir.boolValue && destIsDir.boolValue {
                    // 폴더 → 폴더 재귀 merge (모드 전파)
                    let sub = mergeFolders(
                        source: item, destination: itemDest,
                        isCut: isCut,
                        subFileMode: subFileMode,
                        onProgress: onProgress,
                        shouldCancel: shouldCancel
                    )
                    success += sub.success
                    skipped += sub.skipped
                    bytesMoved += sub.bytes
                    transferred.append(contentsOf: sub.transferred)
                } else {
                    // 파일/혼합 충돌 — subFileMode 에 따라 처리
                    let sz = itemSize(item)
                    switch subFileMode {
                    case .skip:
                        skipped += 1
                        bytesMoved += sz
                        onProgress?(item, sz)
                    case .overwrite:
                        do {
                            try fm.removeItem(at: itemDest)
                            if isCut {
                                try fm.moveItem(at: item, to: itemDest)
                            } else {
                                try fm.copyItem(at: item, to: itemDest)
                            }
                            success += 1
                            bytesMoved += sz
                            transferred.append((item, itemDest))
                            onProgress?(item, sz)
                        } catch {
                            plog("[MERGE/OW] 실패 \(item.lastPathComponent): \(error.localizedDescription)\n")
                        }
                    }
                }
            } else {
                // 충돌 없음
                if itemIsDir.boolValue {
                    // 폴더 — bulk move 대신 재귀 (개별 파일 진행률 확보)
                    let sub = mergeFolders(
                        source: item, destination: itemDest,
                        isCut: isCut,
                        subFileMode: subFileMode,
                        onProgress: onProgress,
                        shouldCancel: shouldCancel
                    )
                    success += sub.success
                    skipped += sub.skipped
                    bytesMoved += sub.bytes
                    transferred.append(contentsOf: sub.transferred)
                } else {
                    let sz = itemSize(item)
                    do {
                        if isCut {
                            try fm.moveItem(at: item, to: itemDest)
                        } else {
                            try fm.copyItem(at: item, to: itemDest)
                        }
                        success += 1
                        bytesMoved += sz
                        transferred.append((item, itemDest))
                        onProgress?(item, sz)
                    } catch {
                        plog("[MERGE] 실패 \(item.lastPathComponent): \(error.localizedDescription)\n")
                    }
                }
            }
        }

        // Cut + 원본 폴더가 비었으면 원본 폴더 삭제 (rootFolder 삭제는 호출자 판단)
        if isCut {
            if let remaining = try? fm.contentsOfDirectory(at: srcFolder, includingPropertiesForKeys: nil),
               remaining.isEmpty {
                try? fm.removeItem(at: srcFolder)
            }
        }

        return (success, transferred, skipped, bytesMoved)
    }

    /// 단일 아이템 크기 (파일은 파일사이즈, 폴더는 재귀 합).
    static func itemSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
            var total: Int64 = 0
            for case let u as URL in e {
                if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   v.isRegularFile == true, let s = v.fileSize {
                    total += Int64(s)
                }
            }
            return total
        } else {
            if let attrs = try? fm.attributesOfItem(atPath: url.path) {
                if let s = attrs[.size] as? Int64 { return s }
                if let s = attrs[.size] as? Int { return Int64(s) }
            }
            return 0
        }
    }
}
