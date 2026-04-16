//
//  NavigationPerformanceHUD.swift
//  PhotoRawManager
//
//  키 꾹 누르기 (key repeat burst) 에서의 행 이동 성능 HUD.
//  - 현재 활성 burst 표시 (fps, 이동 수, 지속 시간)
//  - 마지막 burst 결과 요약
//  - 세션 전체 통계
//  - 실시간 interval 그래프 (최근 100개)
//

import SwiftUI

struct NavigationPerformanceHUD: View {
    @ObservedObject var monitor = NavigationPerformanceMonitor.shared
    @State private var isCompact: Bool = false

    var body: some View {
        if monitor.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
                header
                if !isCompact {
                    burstSection
                    statsSection
                    graph
                    recentMoves
                }
            }
            .padding(10)
            .frame(width: isCompact ? 300 : 400)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
                    )
            )
            .foregroundColor(.white)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .foregroundColor(.yellow)
            Text("Navigation Debug")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            if let active = monitor.activeBurst, active.movesCount >= 2 {
                Text("● LIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(3)
            }
            Spacer()
            Button(action: { isCompact.toggle() }) {
                Image(systemName: isCompact ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            Button(action: { _ = monitor.exportReport() }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("CSV 리포트 저장")
            Button(action: { monitor.isEnabled = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    // 현재 활성 burst 정보
    @ViewBuilder
    private var burstSection: some View {
        if let burst = monitor.activeBurst, burst.movesCount >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                sectionLabel("진행 중인 BURST (꾹 누르기)", color: .red)
                HStack(spacing: 12) {
                    statCell("Moves", "\(burst.movesCount)", .cyan)
                    statCell("Dur", String(format: "%.0fms", burst.durationMs), .white)
                    statCell("FPS", String(format: "%.1f", burst.fps), .yellow)
                }
                HStack(spacing: 12) {
                    statCell("초반", String(format: "%.0fms", burst.earlyAvgIntervalMs), .green)
                    statCell("후반", String(format: "%.0fms", burst.lateAvgIntervalMs), slowdownColor(burst.internalSlowdown))
                    statCell("저하", String(format: "%.2fx", burst.internalSlowdown), slowdownColor(burst.internalSlowdown))
                }
            }
        } else if let burst = monitor.lastBurst, burst.movesCount >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                sectionLabel("마지막 BURST", color: .blue)
                HStack(spacing: 12) {
                    statCell("Moves", "\(burst.movesCount)", .cyan)
                    statCell("FPS", String(format: "%.1f", burst.fps), .yellow)
                    statCell("저하", String(format: "%.2fx", burst.internalSlowdown), slowdownColor(burst.internalSlowdown))
                }
                HStack(spacing: 12) {
                    statCell("초반", String(format: "%.0fms", burst.earlyAvgIntervalMs), .green)
                    statCell("후반", String(format: "%.0fms", burst.lateAvgIntervalMs), slowdownColor(burst.internalSlowdown))
                    statCell("MaxProc", String(format: "%.0fms", burst.maxProcessingMs),
                             burst.maxProcessingMs > 50 ? .orange : .green)
                }
            }
        } else {
            Text("화살표 키를 꾹 눌러 burst 를 시작하세요")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
        }
    }

    private var statsSection: some View {
        let s = monitor.stats
        return VStack(alignment: .leading, spacing: 3) {
            sectionLabel("세션 누적", color: .gray)
            HStack(spacing: 12) {
                statCell("Bursts", "\(s.totalBursts)", .cyan)
                statCell("Moves", "\(s.totalMoves)", .cyan)
                statCell("AvgProc", String(format: "%.1fms", s.avgProcessingMs),
                         s.avgProcessingMs > 30 ? .orange : .green)
            }
            HStack(spacing: 12) {
                statCell("AvgFPS", String(format: "%.1f", s.avgBurstFps), .yellow)
                statCell("MaxProc", String(format: "%.0fms", s.maxProcessingMs),
                         s.maxProcessingMs > 100 ? .red : .orange)
                statCell("Worst", String(format: "%.2fx", s.worstBurstSlowdown),
                         slowdownColor(s.worstBurstSlowdown))
            }
        }
    }

    // 최근 100개 이동 interval 그래프 (burst 색상 구분)
    private var graph: some View {
        let moves = Array(monitor.recentMoves.suffix(100))
        let maxInterval = max(moves.map(\.intervalMs).max() ?? 100, 100)
        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(moves) { m in
                    let h = m.intervalMs > 0 ? (m.intervalMs / maxInterval) * geo.size.height : 1
                    Rectangle()
                        .fill(barColor(m))
                        .frame(height: max(1, h))
                }
                if moves.count < 100 {
                    ForEach(0..<(100 - moves.count), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.gray.opacity(0.12))
                            .frame(height: 1)
                    }
                }
            }
        }
        .frame(height: 36)
    }

    private var recentMoves: some View {
        let last = Array(monitor.recentMoves.suffix(6).reversed())
        return VStack(alignment: .leading, spacing: 2) {
            sectionLabel("최근 이동", color: .gray)
            ForEach(last) { m in
                HStack(spacing: 6) {
                    Text(m.isRepeat ? "◆" : "○")
                        .foregroundColor(m.isRepeat ? .orange : .blue)
                        .frame(width: 10)
                    Text(m.direction)
                        .frame(width: 12)
                    Text("#\(m.photoIndex)")
                        .frame(width: 52, alignment: .trailing)
                        .foregroundColor(.cyan)
                    Text(m.intervalMs > 0 ? String(format: "%3.0fms", m.intervalMs) : "   —  ")
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(m.intervalMs > 100 ? .orange : .green)
                    Text(String(format: "proc %3.0fms", m.processingMs))
                        .foregroundColor(m.processingMs > 50 ? .red : .white.opacity(0.8))
                    Spacer()
                    Text("\(m.ramUsageMB)M · C\(m.previewCacheCount)")
                        .foregroundColor(.secondary)
                }
                .font(.system(size: 9, design: .monospaced))
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
    }

    private func statCell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(minWidth: 60, alignment: .leading)
    }

    private func slowdownColor(_ ratio: Double) -> Color {
        if ratio >= 1.5 { return .red }
        if ratio >= 1.2 { return .orange }
        if ratio >= 1.05 { return .yellow }
        return .green
    }

    private func barColor(_ m: NavigationPerformanceMonitor.MoveEvent) -> Color {
        // burst 내 이동은 interval 기준, 비-burst 는 회색 톤
        if !m.isRepeat {
            return .gray.opacity(0.5)
        }
        if m.intervalMs > 120 { return .red }
        if m.intervalMs > 70 { return .orange }
        if m.intervalMs > 45 { return .yellow }
        return .green
    }
}
