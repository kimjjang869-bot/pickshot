//
//  VisualSearchCropWindow.swift
//  PhotoRawManager
//
//  v8.7: NSWindow 로 표시 — 비모달/드래그 가능/멀티 인스턴스.
//  여러 "검색 기준 선택" 창을 동시에 열어서 병렬 작업 가능.
//

import AppKit
import SwiftUI

final class VisualSearchCropWindowController {
    static let shared = VisualSearchCropWindowController()
    private var windows: [NSWindow] = []

    private init() {}

    /// 새 창을 열어 크롭 UI 표시. 기존 창들은 유지 (멀티 인스턴스).
    func present(
        sourceURL: URL,
        mode: VisualSearchMode,
        presetLabel: String?,
        folderPhotos: [URL],
        onConfirmed: @escaping (VisualSearchMode, [VisualSearchCropShot], String?) -> Void
    ) {
        let contentRect = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "비슷한 사진 찾기 — \(presetLabel ?? (mode == .face ? "얼굴" : "사물"))"
        window.isReleasedWhenClosed = false  // release 금지 (우리가 관리)
        window.level = .floating  // v8.7: 최상단 유지 (메인 앱 가리지 않고 드래그&드롭 편의)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // 전체화면 모드에서도 표시
        window.center()

        // 스택하게 살짝 오프셋 (여러 창이 겹치지 않게)
        if let prev = windows.last {
            var frame = prev.frame
            frame.origin.x += 30
            frame.origin.y -= 30
            window.setFrame(frame, display: false)
        }

        // SwiftUI 뷰 호스팅
        let hostingView = NSHostingView(rootView:
            VisualSearchCropView(
                sourceURL: sourceURL,
                mode: mode,
                presetLabel: presetLabel,
                folderPhotos: folderPhotos,
                onClose: { [weak self, weak window] in
                    guard let window = window else { return }
                    self?.closeWindow(window)
                },
                onConfirmedMulti: { [weak self, weak window] m, shots, label in
                    onConfirmed(m, shots, label)
                    if let window = window { self?.closeWindow(window) }
                }
            )
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        windows.append(window)
    }

    private func closeWindow(_ window: NSWindow) {
        window.orderOut(nil)
        windows.removeAll { $0 == window }
    }

    /// 모든 열린 창 닫기 (앱 종료 등)
    func closeAll() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}
