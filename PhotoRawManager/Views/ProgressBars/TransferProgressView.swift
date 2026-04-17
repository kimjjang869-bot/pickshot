//
//  TransferProgressView.swift
//  PhotoRawManager
//
//  복사/잘라내기 붙여넣기 통합 진행 창. 드래그로 이동 가능.
//  속도 그래프 안에 속도·남은시간 오버레이.
//

import SwiftUI

struct TransferProgressView: View {
    @ObservedObject var store: PhotoStore
    /// 창 이동 오프셋 (드래그 제스처로 변경됨)
    @State private var dragOffset: CGSize = .zero
    @State private var savedOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            pathSection
            currentFileRow
            speedGraph
                .frame(height: 110)
            progressSection
            bottomBar
        }
        .padding(14)
        .frame(width: 460)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .offset(x: dragOffset.width, y: dragOffset.height)
        .gesture(
            // 헤더/배경 어디서든 드래그 가능
            DragGesture()
                .onChanged { value in
                    dragOffset = CGSize(
                        width: savedOffset.width + value.translation.width,
                        height: savedOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    savedOffset = dragOffset
                }
        )
    }

    // MARK: - Header (드래그 핸들)

    private var header: some View {
        HStack(spacing: 10) {
            // 드래그 핸들 인디케이터 (macOS style)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))

            Image(systemName: isCut ? "scissors" : "doc.on.doc.fill")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
            Text(store.bgExportLabel.isEmpty ? "파일 전송" : store.bgExportLabel)
                .font(.system(size: 14, weight: .bold))
            Spacer()
            // 이동/복사 중인 최상위 항목 이름 (폴더명 또는 파일명)
            if let item = currentTopFolder ?? currentDetailOnly {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(item)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(4)
            }
            Text("\(store.bgExportDone)/\(store.bgExportTotal) 개")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .help("드래그해서 창 이동")
    }

    /// "최상위 폴더가 없는" 단일 파일 이동 시 파일명만 반환.
    private var currentDetailOnly: String? {
        if currentTopFolder != nil { return nil }
        let name = currentDetailFile
        return name == "준비 중..." ? nil : name
    }

    // MARK: - 경로

    private var pathSection: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            // 출발
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(store.bgTransferSourcePath.isEmpty ? "—" : compactPath(store.bgTransferSourcePath))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)

            // 가운데 화살표
            Image(systemName: "arrow.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.accentColor)

            // 도착
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text(store.bgTransferDestPath.isEmpty ? "—" : compactPath(store.bgTransferDestPath))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 현재 파일

    private var currentFileRow: some View {
        HStack(spacing: 6) {
            if let folder = currentTopFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(folder)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text(currentDetailFile)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    /// 현재 처리 중인 "최상위 폴더" 이름 — merge 중이면 "🔀 folder/sub..." 에서 folder 부분 추출.
    /// 중첩 폴더 (a/b/c/file.jpg) 는 첫 슬래시 기준으로 folder = "a", 뒷부분은 detail.
    /// 단일 파일이면 nil.
    private var currentTopFolder: String? {
        let raw = store.bgTransferCurrentFile
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("⏭️ 건너뜀: ") { return nil }
        var trimmed = raw
        if raw.hasPrefix("🔀 ") { trimmed = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        if let slash = trimmed.firstIndex(of: "/") {
            return String(trimmed[..<slash])
        }
        return nil
    }

    /// 세부 경로 — merge 의 첫 슬래시 뒤 부분 전체 (중첩 폴더 포함), 또는 단일 파일명.
    private var currentDetailFile: String {
        let raw = store.bgTransferCurrentFile
        if raw.isEmpty { return "준비 중..." }
        var trimmed = raw
        if raw.hasPrefix("🔀 ") { trimmed = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        if let slash = trimmed.firstIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    // MARK: - 바이트 진행 바

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: store.bgExportProgress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
            HStack {
                Text(formatBytes(store.bgTransferBytesDone) + " / " + formatBytes(store.bgTransferBytesTotal))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", store.bgExportProgress * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - 속도 그래프 (속도·ETA·경과 오버레이)

    private var speedGraph: some View {
        GeometryReader { geo in
            let samples = store.bgTransferSpeedHistory
            // Y 스케일: max 가 아닌 상위 90 퍼센타일 기반 — 단일 스파이크로 그래프 압축 방지
            let sorted = samples.sorted()
            let pctIdx = max(0, Int(Double(sorted.count) * 0.9) - 1)
            let p90 = sorted.isEmpty ? 1.0 : max(sorted[pctIdx], 1)
            let maxSpeed = max(p90 * 1.15, 1)
            let pointCount = max(samples.count, 1)
            let w = geo.size.width
            let h = geo.size.height
            let stepX = w / CGFloat(max(pointCount - 1, 1))

            ZStack {
                // 배경 + 그리드
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.35), Color.black.opacity(0.15)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                VStack(spacing: h / 4 - 0.5) {
                    ForEach(0..<4) { _ in
                        Rectangle().fill(Color.white.opacity(0.04)).frame(height: 0.5)
                    }
                }
                .padding(.vertical, 4)

                // 면적 + 라인
                if samples.count >= 2 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for (i, sp) in samples.enumerated() {
                            let y = h - (CGFloat(sp / maxSpeed) * h * 0.85) - 2
                            path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: y))
                        }
                        path.addLine(to: CGPoint(x: CGFloat(samples.count - 1) * stepX, y: h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.55), .green.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Path { path in
                        let first = h - (CGFloat(samples[0] / maxSpeed) * h * 0.85) - 2
                        path.move(to: CGPoint(x: 0, y: first))
                        for (i, sp) in samples.enumerated().dropFirst() {
                            let y = h - (CGFloat(sp / maxSpeed) * h * 0.85) - 2
                            path.addLine(to: CGPoint(x: CGFloat(i) * stepX, y: y))
                        }
                    }
                    .stroke(Color.green, lineWidth: 1.8)
                }

                // 오버레이 — 하단 오른쪽. 순서: 경과 · 속도 · 남은시간 · 최고
                VStack(alignment: .trailing, spacing: 0) {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 16) {
                        Spacer()
                        overlayStat(label: "경과", value: elapsedText, color: .white.opacity(0.85), align: .trailing)
                        overlayStat(label: "속도", value: formatSpeed(displaySpeed), color: .green, align: .trailing)
                        overlayStat(label: "남은시간", value: formatETA(displayETA), color: .orange, align: .trailing)
                        if overallAverageSpeed > 0 {
                            overlayStat(label: "평균", value: formatSpeed(overallAverageSpeed), color: .white.opacity(0.6), compact: true, align: .trailing)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 그래프 오버레이 스탯 (속도/ETA/경과/최고)
    @ViewBuilder
    private func overlayStat(label: String, value: String, color: Color, compact: Bool = false, align: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: align, spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .font(.system(size: compact ? 10 : 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    // MARK: - Smoothed stats

    /// 마지막 5 샘플 평균 — 순간 0 이 떠도 버퍼링되어 안정적으로 표시
    private var displaySpeed: Double {
        let samples = store.bgTransferSpeedHistory
        guard !samples.isEmpty else {
            // 그래프가 아직 없으면 전체 평균으로 폴백
            return overallAverageSpeed
        }
        let tail = samples.suffix(5)
        let avg = tail.reduce(0, +) / Double(tail.count)
        return avg > 0 ? avg : overallAverageSpeed
    }

    /// 전체 평균 속도 — 시작부터 지금까지 누적 바이트 / 경과
    private var overallAverageSpeed: Double {
        guard let start = store.bgTransferStartedAt else { return 0 }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.5 else { return 0 }
        return Double(store.bgTransferBytesDone) / elapsed
    }

    /// 남은시간 — displaySpeed 기반, 0 이면 전체 평균으로 재계산
    private var displayETA: TimeInterval {
        let remaining = store.bgTransferBytesTotal - store.bgTransferBytesDone
        guard remaining > 0 else { return 0 }
        let speed = displaySpeed
        guard speed > 0 else { return 0 }
        return Double(remaining) / speed
    }

    // MARK: - 하단 취소 버튼

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button(action: { store.bgExportCancelled = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle")
                    Text("취소")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .disabled(store.bgExportCancelled)
        }
    }

    // MARK: - Helpers

    private var isCut: Bool { store.bgExportLabel.contains("잘라내기") }

    private var elapsedText: String {
        guard let start = store.bgTransferStartedAt else { return "0초" }
        return formatDuration(Date().timeIntervalSince(start))
    }

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_000_000_000 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_000_000 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1_000 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000_000 { return String(format: "%.2f GB/s", bytesPerSec / 1_073_741_824) }
        if bytesPerSec >= 1_000_000 { return String(format: "%.1f MB/s", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1_000 { return String(format: "%.0f KB/s", bytesPerSec / 1024) }
        return "\(Int(bytesPerSec)) B/s"
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds <= 0 || !seconds.isFinite { return "계산 중" }
        return formatDuration(seconds)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return "\(s/3600)시간 \((s%3600)/60)분" }
        if s >= 60 { return "\(s/60)분 \(s%60)초" }
        return "\(s)초"
    }
}
