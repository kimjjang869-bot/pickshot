//
//  MemoryLeakHUD.swift
//  PhotoRawManager
//
//  v8.6.1 메모리 누수 추적 HUD.
//  Cmd+Shift+Option+M 단축키로 토글.
//

import SwiftUI

struct MemoryLeakHUD: View {
    @ObservedObject var tracker = MemoryLeakTracker.shared
    @State private var showDetails: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if showDetails {
                statsRow
                miniGraph
                stressSection
            }
        }
        .padding(10)
        .frame(width: showDetails ? 440 : 300)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.5), lineWidth: 1)
                )
        )
        .foregroundColor(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip").foregroundColor(.purple)
            Text("Memory Leak Tracker")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Spacer()
            if tracker.isTracking {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
            }
            Button(action: { showDetails.toggle() }) {
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                stat(label: "RSS", value: "\(tracker.currentRSSMB)MB",
                     color: tracker.currentRSSMB > 4000 ? .red : (tracker.currentRSSMB > 2000 ? .orange : .green))
                stat(label: "Peak", value: "\(tracker.peakRSSMB)MB", color: .yellow)
                stat(label: "증가율", value: "\(Int(tracker.growthRateMBPerMin))MB/m",
                     color: tracker.growthRateMBPerMin > 100 ? .red : .white.opacity(0.8))
                Spacer()
                HStack(spacing: 4) {
                    Button(tracker.isTracking ? "정지" : "시작") {
                        if tracker.isTracking { tracker.stop() } else { tracker.start() }
                    }
                    .font(.system(size: 10))
                    Button("🧹 해제") {
                        let msg = tracker.emergencyCleanup()
                        tracker.stressProgress = msg
                    }
                    .font(.system(size: 10))
                    .tint(.red)
                    Button("로그") { tracker.openLogFolder() }
                        .font(.system(size: 10))
                }
            }
            // 캐시별 상세
            if let last = tracker.snapshots.last {
                HStack(spacing: 14) {
                    stat(label: "Preview", value: "\(last.previewMemMB)MB / \(last.previewCount)", color: .cyan)
                    stat(label: "HiRes", value: "\(last.hiResCount)장",
                         color: last.hiResCount > 10 ? .red : .white.opacity(0.7))
                    stat(label: "Swap", value: "\(last.vmSwapMB)MB",
                         color: last.vmSwapMB > 1000 ? .red : .white.opacity(0.7))
                    stat(label: "Thumb limit", value: "\(last.thumbLimitMB)MB", color: .white.opacity(0.6))
                    Spacer()
                }
            }
        }
    }

    private func stat(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(color)
        }
    }

    private var miniGraph: some View {
        GeometryReader { geo in
            let samples = tracker.snapshots.suffix(100)
            let maxMB = CGFloat(max(samples.map { $0.rssMB }.max() ?? 1, 100))
            let step = geo.size.width / CGFloat(max(samples.count, 1))
            Path { p in
                for (i, s) in samples.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height - (CGFloat(s.rssMB) / maxMB) * geo.size.height
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.purple, lineWidth: 1.5)
            // spike 표시
            ForEach(Array(samples.enumerated()), id: \.element.id) { (i, s) in
                if s.trigger.hasPrefix("spike") {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                        .position(x: CGFloat(i) * step,
                                  y: geo.size.height - (CGFloat(s.rssMB) / maxMB) * geo.size.height)
                }
            }
        }
        .frame(height: 60)
        .background(Color.white.opacity(0.05))
        .cornerRadius(4)
    }

    private var stressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("스트레스 테스트")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text("현재 상태: \(tracker.isStressTesting ? "진행 중" : "대기")")
                    .font(.system(size: 9))
                    .foregroundColor(tracker.isStressTesting ? .yellow : .white.opacity(0.5))
                // v8.6.2: 테스트 진행 중이면 중단 버튼 노출
                if tracker.isStressTesting {
                    Button("⏹ 중단") {
                        tracker.abortStressTest()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .buttonStyle(.borderless)
                    .tint(.red)
                }
            }

            HStack(spacing: 6) {
                stressButton("열 이동",
                             detail: "20/sec\n프리뷰 부하",
                             color: .blue) {
                    tracker.runStressTest(mode: .columnNav, cycles: 50)
                }
                stressButton("행 이동",
                             detail: "10/sec\n실제 패턴",
                             color: .green) {
                    tracker.runStressTest(mode: .rowNav, cycles: 20)
                }
                stressButton("삭제 시뮬",
                             detail: "safe\n캐시만 정리",
                             color: .orange) {
                    tracker.runStressTest(mode: .deleteSimulation, cycles: 10)
                }
                stressButton("실제 삭제",
                             detail: "35장 휴지통\nCmd+Z 복원",
                             color: .red) {
                    confirmActualDelete()
                }
            }
            // v8.9.3: 랜덤 폴더 전환 + 하위 폴더 포함 모드 (행/열 모드는 cycle 사이 자동 전환)
            HStack(spacing: 6) {
                stressButton("🎲 랜덤 폴더",
                             detail: "20cycle\n폴더 전환 + 하위포함",
                             color: .purple) {
                    tracker.runStressTest(mode: .randomFolderNav, cycles: 20)
                }
            }

            if !tracker.stressProgress.isEmpty {
                Text(tracker.stressProgress)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
    }

    private func stressButton(_ title: String, detail: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text(detail)
                    .font(.system(size: 8))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(color.opacity(0.25))
            .overlay(
                RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.6), lineWidth: 1)
            )
            .cornerRadius(4)
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .disabled(tracker.isStressTesting)
    }

    private func confirmActualDelete() {
        let alert = NSAlert()
        alert.messageText = "실제 삭제 테스트"
        alert.informativeText = """
        현재 폴더의 앞 35장을 휴지통으로 이동합니다 (튜브짱 시나리오 재현).
        Cmd+Z 로 복원 가능하지만 실제 파일이 건드려집니다.
        테스트용 폴더에서만 실행하세요.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "실행")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn {
            tracker.runStressTest(mode: .actualDelete, cycles: 1)
        }
    }
}
