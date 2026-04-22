//
//  PreferenceTrainingDialog.swift
//  PhotoRawManager
//
//  v8.9: 사용자 셀렉 학습 다이얼로그.
//  - 셀렉본 폴더 선택 / 현재 ★4+ 자동 추출 / 이벤트 원장 기반 자동 학습
//  - 다른 사람 프로필 import/export
//  - 현재 학습 상태 표시
//

import SwiftUI
import AppKit

struct PreferenceTrainingDialog: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var store: PhotoStore

    @State private var isTraining: Bool = false
    @State private var progressDone: Int = 0
    @State private var progressTotal: Int = 0
    @State private var resultMessage: String = ""
    @State private var trainingSource: TrainingSource = .currentFolderRated

    enum TrainingSource: String, CaseIterable {
        case currentFolderRated = "현재 폴더 ★4+ 셀렉본"
        case selectFolder = "셀렉본 폴더 직접 선택..."
        case eventStore = "이벤트 원장 전체 (SelectionEventStore)"
    }

    private let prefs = UserPreferenceService.shared
    @State private var stats: SelectionEventStore.Stats = SelectionEventStore.shared.stats()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 18, weight: .bold))
                Text("내 취향 학습 (AI 셀렉 프로필)")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()

            // 현재 상태
            VStack(alignment: .leading, spacing: 4) {
                Text("현재 프로필")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                HStack(spacing: 18) {
                    Label("셀렉본 \(prefs.profile.positiveCount)장",
                          systemImage: prefs.profile.isTrained ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(prefs.profile.isTrained ? .green : .secondary)
                    Label("탈락본 \(prefs.profile.negativeCount)장", systemImage: "circle")
                        .foregroundColor(.secondary)
                    if prefs.profile.updatedAt > .distantPast {
                        Text("최종 학습: \(timeAgo(prefs.profile.updatedAt))")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 11))
            }
            .padding(10)
            .background(Color.secondary.opacity(0.07))
            .cornerRadius(8)

            // 누적 이벤트 통계 (학습 원장 DB)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("누적 학습 데이터 (전체 기간)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: refreshStats) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("통계 새로고침")
                }

                HStack(spacing: 14) {
                    statBlock(title: "총 이벤트", value: "\(stats.totalEvents)")
                    statBlock(title: "고유 사진", value: "\(stats.uniquePhotos)")
                    statBlock(title: "positive", value: "\(stats.positives)", color: .green)
                    statBlock(title: "negative", value: "\(stats.negatives)", color: .red)
                    statBlock(title: "DB 크기", value: byteFormat(stats.dbSizeBytes))
                }

                if !stats.byKind.isEmpty {
                    HStack(spacing: 10) {
                        Text("종류별:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        ForEach(stats.byKind.sorted(by: { $0.value > $1.value }), id: \.key) { kind, count in
                            Text("\(kind) \(count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let first = stats.firstEventAt, let last = stats.lastEventAt {
                    Text("기간: \(dateShort(first)) ~ \(dateShort(last))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .cornerRadius(8)

            // 학습 소스 선택
            VStack(alignment: .leading, spacing: 6) {
                Text("학습 데이터 소스")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                ForEach(TrainingSource.allCases, id: \.self) { src in
                    Button(action: { trainingSource = src }) {
                        HStack {
                            Image(systemName: trainingSource == src ? "largecircle.fill.circle" : "circle")
                            Text(src.rawValue)
                            if src == .eventStore {
                                let stats = SelectionEventStore.shared.stats()
                                Text("(+\(stats.positives) / −\(stats.negatives))")
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // 협업: import/export
            HStack {
                Text("협업:")
                    .font(.system(size: 11, weight: .semibold))
                Button("프로필 export...") { exportProfile() }
                    .font(.system(size: 11))
                Button("다른 사람 프로필 import...") { importProfile() }
                    .font(.system(size: 11))
                Spacer()
            }

            // 진행/결과
            if isTraining {
                HStack {
                    ProgressView(value: Double(progressDone), total: Double(max(progressTotal, 1)))
                        .frame(width: 200)
                    Text("\(progressDone) / \(progressTotal)")
                        .font(.system(size: 10, design: .monospaced))
                }
            } else if !resultMessage.isEmpty {
                Text(resultMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
            }

            // 버튼
            HStack {
                Spacer()
                Button("닫기") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(action: runTraining) {
                    Text(isTraining ? "학습 중..." : "학습 시작")
                        .frame(width: 90)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTraining)
            }
        }
        .padding(18)
        .frame(width: 560)
    }

    // MARK: - 학습 실행

    private func runTraining() {
        isTraining = true
        resultMessage = ""

        switch trainingSource {
        case .currentFolderRated:
            trainFromCurrentFolder()
        case .selectFolder:
            trainFromFolder()
        case .eventStore:
            trainFromEventStore()
        }
    }

    private func trainFromCurrentFolder() {
        let positives = store.photos.filter { $0.rating >= 4 && !$0.isFolder }.map { $0.jpgURL }
        let negatives = store.photos.filter { $0.rating > 0 && $0.rating <= 2 && !$0.isFolder }.map { $0.jpgURL }
        runTrain(positives: positives, negatives: negatives)
    }

    private func trainFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "셀렉본이 들어있는 폴더를 선택하세요 (이 폴더의 모든 사진이 positive 샘플이 됩니다)"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else {
                self.isTraining = false
                return
            }
            let urls = collectImages(in: url)
            self.runTrain(positives: urls, negatives: [])
        }
    }

    private func trainFromEventStore() {
        let positives = SelectionEventStore.shared.recentPositivePaths(limit: 10_000).map { URL(fileURLWithPath: $0) }
        let negatives = SelectionEventStore.shared.recentNegativePaths(limit: 10_000).map { URL(fileURLWithPath: $0) }
        runTrain(positives: positives, negatives: negatives)
    }

    private func runTrain(positives: [URL], negatives: [URL]) {
        guard !positives.isEmpty else {
            self.isTraining = false
            self.resultMessage = "⚠️ 학습할 positive 샘플이 없습니다."
            return
        }
        progressTotal = positives.count + negatives.count
        progressDone = 0

        prefs.train(positiveURLs: positives, negativeURLs: negatives,
                    onProgress: { d, _ in
                        self.progressDone = d
                    },
                    onComplete: { profile in
                        self.isTraining = false
                        self.resultMessage = "✅ 학습 완료 — positive \(profile.positiveCount)장 / negative \(profile.negativeCount)장"
                    })
    }

    private func collectImages(in folder: URL) -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "nef", "cr2", "cr3", "arw", "raf", "orf", "rw2", "dng"]
        var out: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            if exts.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out
    }

    // MARK: - Import/Export

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pickshot_preference_\(Date().timeIntervalSince1970).json"
        panel.allowedContentTypes = [.json]
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try prefs.exportProfile(to: url)
                resultMessage = "✅ export 완료: \(url.lastPathComponent)"
            } catch {
                resultMessage = "❌ export 실패: \(error.localizedDescription)"
            }
        }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = "다른 사람 프로필 JSON 파일 선택"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            // 병합 전략 선택
            let alert = NSAlert()
            alert.messageText = "병합 전략 선택"
            alert.informativeText = "상대방 프로필을 어떻게 가져올까요?"
            alert.addButton(withTitle: "50/50 평균 (기본)")
            alert.addButton(withTitle: "내 프로필 70%")
            alert.addButton(withTitle: "완전히 대체")
            alert.addButton(withTitle: "취소")
            let r = alert.runModal()
            let strategy: UserPreferenceService.MergeStrategy
            switch r {
            case .alertFirstButtonReturn: strategy = .averageEqual
            case .alertSecondButtonReturn: strategy = .weightedByMine(myWeight: 0.7)
            case .alertThirdButtonReturn: strategy = .replace
            default: return
            }
            do {
                try prefs.importProfile(from: url, strategy: strategy)
                resultMessage = "✅ import 완료 (\(url.lastPathComponent))"
            } catch {
                resultMessage = "❌ import 실패: \(error.localizedDescription)"
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "ko_KR")
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    private func refreshStats() {
        stats = SelectionEventStore.shared.stats()
    }

    private func dateShort(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: d)
    }

    private func byteFormat(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0fKB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1fMB", mb) }
        return String(format: "%.1fGB", mb / 1024)
    }

    @ViewBuilder
    private func statBlock(title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}
