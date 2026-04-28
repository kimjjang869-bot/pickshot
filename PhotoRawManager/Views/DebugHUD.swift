//
//  DebugHUD.swift
//  PhotoRawManager
//
//  통합 디버그 HUD — 미리보기 stage/사이즈 + Navigation Performance 를 한 창에 표시.
//  HUD 에 표시되는 모든 내용은 /tmp/pickshot_hud.log 에 함께 기록된다.
//
//  사용법:
//   - Cmd+Shift+D 로 NavigationPerformanceMonitor.shared.isEnabled 토글 시 HUD 가 함께 표시됨
//   - PhotoPreviewView 가 image 를 갱신할 때마다 publishPreviewState(...) 호출
//

import SwiftUI
import AppKit

// MARK: - State

@MainActor
final class DebugHUDState: ObservableObject {
    static let shared = DebugHUDState()

    @Published var previewSize: (w: Int, h: Int)? = nil { didSet { logUpdate() } }
    @Published var previewStage: String = "—" { didSet { logUpdate() } }
    @Published var stageColor: Color = .white
    @Published var selectedFile: String = "—" { didSet { logUpdate() } }
    @Published var sourceFile: String = "—" { didSet { logUpdate() } }
    @Published var ok: Bool = true { didSet { logUpdate() } }
    @Published var lastHiResMs: Int? = nil { didSet { logUpdate() } }

    // MARK: - HUD Log Writer

    private static let hudLogPath: String = {
        // 샌드박스: /tmp 직접 쓰기 차단됨 → ~/Library/Containers/<bundle>/Data/tmp/ 사용.
        // 시작 직후 stderr 에 실제 경로를 출력해 tail -f 로 따라잡을 수 있게 한다.
        let dir = NSTemporaryDirectory()
        return (dir as NSString).appendingPathComponent("pickshot_hud.log")
    }()
    private static let hudLogFile: FileHandle? = {
        let url = URL(fileURLWithPath: hudLogPath)
        let header = "[HUD-LOG] start \(ISO8601DateFormatter().string(from: Date())) path=\(hudLogPath)\n"
        _ = try? header.data(using: .utf8)?.write(to: url)
        fputs("[HUD-LOG] path=\(hudLogPath)\n", stderr)
        return try? FileHandle(forWritingTo: url)
    }()

    private var lastLoggedAt: Date = .distantPast

    private func logUpdate() {
        let now = Date()
        guard now.timeIntervalSince(lastLoggedAt) > 0.05 else { return }
        lastLoggedAt = now
        let ts = ISO8601DateFormatter().string(from: now)
        let sizeStr = previewSize.map { "\($0.w)x\($0.h)" } ?? "?"
        let okStr = ok ? "OK" : "MISMATCH"
        let hires = lastHiResMs.map { "\($0)ms" } ?? "—"
        let line = "[\(ts)] \(okStr) \(previewStage) size=\(sizeStr) sel=\(selectedFile) view=\(sourceFile) hires=\(hires)\n"
        guard let data = line.data(using: .utf8), let fh = Self.hudLogFile else { return }
        try? fh.seekToEnd()
        try? fh.write(contentsOf: data)
    }

    /// PhotoPreviewView 에서 이미지 갱신될 때 호출.
    func publishPreviewState(image: NSImage?, selected: String?, source: String?) {
        let pixW: Int
        let pixH: Int
        if let rep = image?.representations.first {
            pixW = rep.pixelsWide
            pixH = rep.pixelsHigh
        } else if let img = image {
            pixW = Int(img.size.width)
            pixH = Int(img.size.height)
        } else {
            pixW = 0
            pixH = 0
        }
        let maxPx = max(pixW, pixH)
        let stage: String
        let color: Color
        if maxPx == 0 {
            stage = "—"
            color = .gray
        } else if maxPx < 1500 {
            stage = "STAGE 1"
            color = .yellow
        } else if maxPx < 3000 {
            stage = "STAGE 2"
            color = .orange
        } else {
            stage = "STAGE 3"
            color = .green
        }
        if previewStage != stage { previewStage = stage }
        stageColor = color
        let newSize = pixW == 0 ? nil : (w: pixW, h: pixH)
        if newSize?.w != previewSize?.w || newSize?.h != previewSize?.h {
            previewSize = newSize
        }
        let sel = selected ?? "—"
        if selectedFile != sel { selectedFile = sel }
        let src = source ?? "—"
        if sourceFile != src { sourceFile = src }
        let match = (sel == "—" || src == "—" || sel == src)
        if ok != match { ok = match }
    }

    func recordHiResMs(_ ms: Int) {
        lastHiResMs = ms
    }
}

// MARK: - Unified HUD View

#if DEBUG
struct UnifiedDebugHUD: View {
    @ObservedObject private var hud = DebugHUDState.shared
    @ObservedObject private var monitor = NavigationPerformanceMonitor.shared
    @ObservedObject private var memTracker = MemoryLeakTracker.shared
    @State private var accumulated: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        if monitor.isEnabled {
            VStack(alignment: .leading, spacing: 6) {
                dragHandle
                previewSection
                Divider().background(Color.white.opacity(0.2))
                NavigationPerformanceHUD()
                if memTracker.isTracking {
                    Divider().background(Color.white.opacity(0.2))
                    MemoryLeakHUD()
                }
            }
            .padding(10)
            .frame(width: 260)  // 전체 폭 고정 — 안의 NavigationPerformanceHUD 도 이 폭 안에 맞춰짐
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
                    )
            )
            .foregroundColor(.white)
            .offset(x: accumulated.width + dragOffset.width,
                    y: accumulated.height + dragOffset.height)
        }
    }

    // 상단 드래그 핸들 — 이 막대만 잡고 끌면 이동.
    // (내부 버튼/Flush 와 충돌 방지)
    private var dragHandle: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.7))
            Text("DEBUG HUD")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            if accumulated != .zero {
                Button(action: { accumulated = .zero }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("위치 초기화")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    accumulated.width += value.translation.width
                    accumulated.height += value.translation.height
                }
        )
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: hud.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(hud.ok ? .green : .red)
                Text(hud.ok ? "OK" : "MISMATCH")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(hud.ok ? .green : .red)
                Spacer()
                Text(hud.previewStage)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(hud.stageColor)
            }
            HStack(spacing: 6) {
                Text(hud.previewSize.map { "\($0.w)×\($0.h)" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
                Spacer()
                if let ms = hud.lastHiResMs {
                    Text("\(ms)ms")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(ms > 500 ? .orange : .green)
                }
            }
            Text(hud.selectedFile)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(hud.sourceFile)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(hud.ok ? .white.opacity(0.7) : .red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
#endif
