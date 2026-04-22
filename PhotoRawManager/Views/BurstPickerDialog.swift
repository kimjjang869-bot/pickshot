//
//  BurstPickerDialog.swift
//  PhotoRawManager
//
//  v8.9: 연사 베스트 자동 선별 다이얼로그.
//  - 체크박스로 기준 선택
//  - 프리셋 (웨딩/인물/풍경/커스텀)
//  - 엄격도 슬라이더
//  - 결과 표시 방식 선택 (컬러🟢/SP/별점)
//  - 내 취향 학습 활용 옵션
//

import SwiftUI

struct BurstPickerDialog: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var store: PhotoStore

    @State private var criteria = BurstPickerCriteria.weddingEvent
    @State private var presetName: String = "웨딩/이벤트"
    @State private var timeWindowSeconds: Double = 5.0
    @State private var minSimilarity: Double = 0.88
    @State private var isProcessing = false
    @State private var progressDone = 0
    @State private var progressTotal = 0
    @State private var detectedGroupCount: Int = 0
    @State private var resultMessage: String = ""

    private let prefsService = UserPreferenceService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 18, weight: .bold))
                Text("연사 베스트 자동 선별")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // 프리셋
            HStack {
                Text("프리셋:")
                    .font(.system(size: 12, weight: .semibold))
                Picker("", selection: $presetName) {
                    Text("웨딩/이벤트").tag("웨딩/이벤트")
                    Text("인물/프로필").tag("인물/프로필")
                    Text("풍경/사물").tag("풍경/사물")
                    Text("커스텀").tag("커스텀")
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .onChange(of: presetName) { newValue in
                    switch newValue {
                    case "웨딩/이벤트": criteria = .weddingEvent
                    case "인물/프로필": criteria = .portrait
                    case "풍경/사물":  criteria = .landscape
                    default: break
                    }
                }
            }

            // 감지 설정
            HStack {
                Text("연사 간격:")
                    .font(.system(size: 11))
                Text("\(Int(timeWindowSeconds))초")
                    .font(.system(size: 11, weight: .semibold))
                Slider(value: $timeWindowSeconds, in: 1...15, step: 1)
                    .frame(width: 140)
                Spacer()
                Text("장면 유사도: \(String(format: "%.2f", minSimilarity))")
                    .font(.system(size: 11))
                Slider(value: $minSimilarity, in: 0.75...0.95, step: 0.01)
                    .frame(width: 100)
            }

            // Criteria 체크박스 — 3 섹션
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("얼굴/인물").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Toggle("눈을 뜸", isOn: $criteria.requireEyesOpen)
                    Toggle("얼굴 포커스", isOn: $criteria.requireFaceFocus)
                    Toggle("웃는 표정", isOn: $criteria.requireSmile)
                    Toggle("시선이 카메라", isOn: $criteria.requireEyeContact)
                    Toggle("서로 눈 마주침", isOn: $criteria.requireMutualGaze)
                    Toggle("얼굴 가려짐 없음", isOn: $criteria.requireNoOcclusion)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("기술 품질").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Toggle("전체 선명도", isOn: $criteria.requireOverallSharpness)
                    Toggle("정노출", isOn: $criteria.requireCorrectExposure)
                    Toggle("모션 블러 없음", isOn: $criteria.requireNoMotionBlur)
                    Toggle("하이라이트 유지", isOn: $criteria.requireNoBlownHighlights)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("구도").font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
                    Toggle("수평 맞음", isOn: $criteria.requireHorizon)
                    Toggle("주제 구도", isOn: $criteria.requireGoodComposition)
                }
            }
            .font(.system(size: 11))
            .toggleStyle(.checkbox)

            // 내 취향 학습
            Divider()
            HStack {
                Toggle(isOn: $criteria.useUserPreference) {
                    let n = prefsService.profile.positiveCount
                    Text(prefsService.profile.isTrained ?
                         "내 취향 반영 (셀렉본 \(n)장 학습됨)" :
                         "내 취향 반영 (학습 필요 — 최소 30장)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                .disabled(!prefsService.profile.isTrained)
                Spacer()
                if criteria.useUserPreference {
                    Text("가중치: \(String(format: "%.1f", criteria.userPreferenceWeight))x")
                        .font(.system(size: 10))
                    Slider(value: $criteria.userPreferenceWeight, in: 0.5...3.0, step: 0.1)
                        .frame(width: 120)
                }
            }

            // 엄격도
            HStack {
                Text("엄격도:")
                    .font(.system(size: 11, weight: .semibold))
                Slider(value: $criteria.strictness, in: 0...1, step: 0.05)
                    .frame(width: 200)
                Text(strictnessLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // 결과 표시
            HStack {
                Text("결과 표시:")
                    .font(.system(size: 11, weight: .semibold))
                Picker("", selection: $criteria.resultMarker) {
                    Text("🟢 초록 라벨").tag(BurstPickerCriteria.ResultMarker.greenLabel)
                    Text("⌨ Space Pick").tag(BurstPickerCriteria.ResultMarker.spacePick)
                    Text("★ 별 4개").tag(BurstPickerCriteria.ResultMarker.star4)
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
            }

            Divider()

            // 진행/결과 영역
            if isProcessing {
                VStack(alignment: .leading, spacing: 4) {
                    if detectedGroupCount > 0 {
                        Text("연사 그룹 \(detectedGroupCount)개 감지됨 — 점수 산정 중...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        ProgressView(value: Double(progressDone), total: Double(max(progressTotal, 1)))
                            .frame(width: 200)
                        Text("\(progressDone) / \(progressTotal)")
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            } else if !resultMessage.isEmpty {
                Text(resultMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
            }

            // 실행 버튼
            HStack {
                Spacer()
                Button("취소") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(action: run) {
                    Text(isProcessing ? "진행 중..." : "선별 시작")
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)
            }
        }
        .padding(18)
        .frame(width: 620)
    }

    private var strictnessLabel: String {
        switch criteria.strictness {
        case ..<0.3: return "느슨 (많이 선별)"
        case ..<0.7: return "보통"
        default: return "엄격 (확실한 것만)"
        }
    }

    private func run() {
        isProcessing = true
        resultMessage = ""
        let target = store.photos

        // 1. 감지
        var cfg = BurstDetectionConfig()
        cfg.timeWindowSeconds = timeWindowSeconds
        cfg.minSimilarity = Float(minSimilarity)
        DispatchQueue.global(qos: .userInitiated).async {
            let groups = BurstDetectionService.shared.detect(photos: target, config: cfg)
            DispatchQueue.main.async {
                detectedGroupCount = groups.count
                progressTotal = groups.reduce(0) { $0 + $1.count }
                if groups.isEmpty {
                    isProcessing = false
                    resultMessage = "⚠️ 연사 그룹이 감지되지 않았습니다 (최소 2장 연속)."
                    return
                }
                // 2. 선별
                BurstPickerService.shared.pickBest(
                    groups: groups,
                    criteria: criteria,
                    onProgress: { d, _ in progressDone = d },
                    onComplete: { results in
                        applyResults(results)
                        isProcessing = false
                        resultMessage = "✅ \(results.count)개 그룹에서 베스트 \(results.count)장 선별 완료 (총 \(progressTotal)장 중)"
                    }
                )
            }
        }
    }

    private func applyResults(_ results: [(group: [PhotoItem], best: PhotoItem, scores: [BurstShotScore])]) {
        for r in results {
            switch criteria.resultMarker {
            case .greenLabel:
                store.setColorLabel(.green, for: r.best.id)
            case .spacePick:
                store.toggleSpacePick(for: r.best.id)
            case .star4:
                store.setRating(4, for: r.best.id)
            }
            // 이벤트 기록 (학습용) — 베스트는 positive, 나머지는 negative
            for photo in r.group {
                let kind: SelectionEventKind = (photo.id == r.best.id) ? .aiPick : .aiReject
                SelectionEventStore.shared.record(
                    photoUUID: photo.id.uuidString,
                    photoPath: photo.jpgURL.path,
                    folderPath: photo.jpgURL.deletingLastPathComponent().path,
                    kind: kind,
                    payload: nil
                )
            }
        }
    }
}
