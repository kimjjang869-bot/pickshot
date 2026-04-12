import SwiftUI

// MARK: - AI 스마트 셀렉 뷰

struct SmartCullView: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject var cullService = SmartCullService.shared
    @ObservedObject var styleLearner = StyleLearner.shared
    @Environment(\.dismiss) var dismiss

    @State private var mode: CullMode = .grouping
    @State private var styleScores: [UUID: Double] = [:]
    @State private var styleProcessing = false
    @State private var styleThreshold: Double = 65
    @State private var styleApplied = false
    @State private var quizPhotos: [PhotoItem] = []
    @State private var quizSelected: Set<UUID> = []
    @State private var showQuiz = false

    enum CullMode: String, CaseIterable {
        case grouping = "유사 그룹핑"
        case style = "스타일 추천"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 스마트 셀렉")
                        .font(.headline)
                    Text(mode == .grouping ? "유사 그룹핑 → A컷 추천" : "학습된 취향으로 자동 셀렉")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if styleLearner.sessionCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 10))
                        Text("학습 \(styleLearner.sessionCount)회")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.2))
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // 모드 전환
            Picker("모드", selection: $mode) {
                ForEach(CullMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            // 컨텐츠
            ScrollView {
                VStack(spacing: 16) {
                    if mode == .grouping {
                        groupingContent
                    } else {
                        styleContent
                    }
                }
                .padding(20)
            }

            Divider()

            // 하단 버튼
            HStack {
                Button("닫기") { dismiss() }

                Spacer()

                if mode == .grouping {
                    Button(action: learnFromCurrentSelection) {
                        Label("현재 셀렉 학습", systemImage: "brain.head.profile")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .disabled(store.photos.filter { $0.rating > 0 || $0.isSpacePicked }.isEmpty)

                    if !cullService.groups.isEmpty {
                        Menu {
                            Button(action: {
                                cullService.sortIntoFolders(store: store, copy: true)
                            }) {
                                Label("폴더로 복사 분류", systemImage: "doc.on.doc")
                            }
                            Button(action: {
                                cullService.sortIntoFolders(store: store, copy: false)
                            }) {
                                Label("폴더로 이동 분류", systemImage: "folder.badge.arrow.right")
                            }
                        } label: {
                            Label("폴더로 분류", systemImage: "folder.badge.plus")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 110)

                        Button("결과 초기화") {
                            cullService.groups = []
                        }
                    }
                } else {
                    if styleApplied {
                        Button("결과 초기화") {
                            styleScores = [:]
                            styleApplied = false
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 500, height: 480)
    }

    // MARK: - 유사 그룹핑

    @ViewBuilder
    private var groupingContent: some View {
        if cullService.isProcessing {
            VStack(spacing: 12) {
                ProgressView(value: cullService.progress) {
                    Text(cullService.statusMessage)
                        .font(.system(size: 12))
                }
                .progressViewStyle(.linear)

                Text("\(Int(cullService.progress * 100))%")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.purple)

                Button("취소") { cullService.cancel() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
        } else if !cullService.groups.isEmpty {
            groupResultView
        } else {
            groupStartView
        }
    }

    private var groupStartView: some View {
        VStack(spacing: 16) {
            let photoCount = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count

            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(photoCount)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                    Text("장 분석 예정")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("유사 그룹핑", systemImage: "rectangle.3.group")
                    Label("품질 기반 A컷 추천", systemImage: "star.fill")
                    Label("별점 자동 부여", systemImage: "star.leadinghalf.filled")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            // 장르 선택
            VStack(spacing: 4) {
                Text("촬영 장르")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    ForEach(SmartCullService.CullGenre.allCases) { g in
                        Button(action: { cullService.genre = g }) {
                            VStack(spacing: 2) {
                                Image(systemName: g.icon)
                                    .font(.system(size: 12))
                                Text(g.rawValue)
                                    .font(.system(size: 8))
                            }
                            .frame(width: 52, height: 36)
                            .background(cullService.genre == g ? Color.purple.opacity(0.3) : Color.gray.opacity(0.1))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(cullService.genre == g ? Color.purple : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(cullService.genre == g ? .purple : .secondary)
                    }
                }
            }

            Text("예상 소요: \(estimatedTime(photoCount))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button(action: {
                let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
                cullService.runSmartCull(photos: photos, store: store)
            }) {
                Label("분석 시작", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
        }
    }

    private var groupResultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let totalClusters = cullService.groups.flatMap(\.clusters).count
            let acuts = cullService.groups.flatMap(\.clusters).compactMap(\.bestPhotoID).count

            HStack(spacing: 0) {
                statBadge("\(cullService.groups.count)", label: "그룹", color: .blue)
                Spacer()
                statBadge("\(totalClusters)", label: "클러스터", color: .purple)
                Spacer()
                statBadge("\(acuts)", label: "A컷", color: .green)
            }

            ForEach(cullService.groups) { group in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.name)
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(group.clusters.flatMap(\.photoIDs).count)장")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            if let range = group.timeRange {
                                Text(formatTimeRange(range))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        ForEach(group.clusters) { cluster in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(cluster.bestPhotoID != nil ? Color.green : Color.gray)
                                    .frame(width: 6, height: 6)
                                Text("\(cluster.photoIDs.count)장")
                                    .font(.system(size: 11))
                                Text("유사도 \(Int(cluster.similarity * 100))%")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                if cluster.bestPhotoID != nil {
                                    Text("A컷")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.15))
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 스타일 추천

    @ViewBuilder
    private var styleContent: some View {
        if showQuiz {
            styleQuizView
        } else if styleLearner.sessionCount == 0 {
            styleNoDataView
        } else if styleProcessing {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("스타일 점수 계산 중...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 30)
        } else if styleApplied {
            styleResultView
        } else {
            styleReadyView
        }
    }

    private var styleNoDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundColor(.gray.opacity(0.4))

            Text("학습 데이터 없음")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            // 퀴즈 학습 버튼
            let photoCount = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count
            if photoCount >= 6 {
                Button(action: startQuiz) {
                    Label("사진 퀴즈로 취향 학습", systemImage: "hand.tap")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)

                Text("현재 폴더에서 랜덤 사진 6장을 보여줍니다.\n마음에 드는 사진을 선택하세요.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            Text("또는 수동 학습:")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                stepRow("1", "사진에 별점 또는 스페이스 셀렉")
                stepRow("2", "\"유사 그룹핑\" → \"현재 셀렉 학습\"")
                stepRow("3", "다른 폴더에서 \"스타일 추천\" 사용")
            }
        }
        .padding(.vertical, 8)
    }

    private func stepRow(_ num: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(num)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Color.purple.opacity(0.6))
                .cornerRadius(9)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var styleReadyView: some View {
        VStack(spacing: 16) {
            let photoCount = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count

            HStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("\(photoCount)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("장 분석 예정")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("학습 \(styleLearner.sessionCount)회 완료", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Label("내 취향 기반 점수", systemImage: "heart.fill")
                    Label("기준점 이상 자동 셀렉", systemImage: "star.fill")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            // 기준점 슬라이더
            VStack(spacing: 6) {
                HStack {
                    Text("추천 기준점")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(styleThreshold))점 이상 셀렉")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                }
                Slider(value: $styleThreshold, in: 40...90, step: 5)
                    .tint(.orange)
                HStack {
                    Text("관대 (40)")
                        .font(.system(size: 9))
                    Spacer()
                    Text("엄격 (90)")
                        .font(.system(size: 9))
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            Button(action: runStyleRecommendation) {
                Label("스타일 추천 적용", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }

    private var styleResultView: some View {
        VStack(alignment: .leading, spacing: 14) {
            let threshold = styleThreshold
            let recommended = styleScores.filter { $0.value >= threshold }
            let total = styleScores.count

            // 통계 배지
            HStack(spacing: 0) {
                statBadge("\(total)", label: "분석", color: .blue)
                Spacer()
                statBadge("\(recommended.count)", label: "추천", color: .orange)
                Spacer()
                statBadge("\(total - recommended.count)", label: "미추천", color: .gray)
            }

            // 점수 분포 차트
            VStack(alignment: .leading, spacing: 6) {
                Text("점수 분포")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(scoreDistribution(), id: \.label) { bucket in
                        VStack(spacing: 3) {
                            if bucket.count > 0 {
                                Text("\(bucket.count)")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            RoundedRectangle(cornerRadius: 3)
                                .fill(bucket.aboveThreshold ? Color.orange : Color.gray.opacity(0.35))
                                .frame(height: max(6, CGFloat(bucket.count) / CGFloat(max(1, total)) * 100))
                            Text(bucket.label)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 130, alignment: .bottom)
            }

            Divider()

            // 적용 결과
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("기준 \(Int(threshold))점 이상 \(recommended.count)장 셀렉 완료")
                        .font(.system(size: 12, weight: .medium))
                    if recommended.count > 0 {
                        Text("85+: ★★★★★  |  75~84: ★★★★  |  65~74: ★★★")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 점수 분포 계산

    struct ScoreBucket {
        let label: String
        let count: Int
        let aboveThreshold: Bool
    }

    private func scoreDistribution() -> [ScoreBucket] {
        let ranges: [(ClosedRange<Double>, String)] = [
            (0...19, "0-19"),
            (20...39, "20-39"),
            (40...59, "40-59"),
            (60...79, "60-79"),
            (80...100, "80+")
        ]
        return ranges.map { (range, label) in
            let count = styleScores.values.filter { range.contains($0) }.count
            let aboveThreshold = range.lowerBound >= styleThreshold || (range.contains(styleThreshold))
            return ScoreBucket(label: label, count: count, aboveThreshold: aboveThreshold)
        }
    }

    // MARK: - 퀴즈 뷰

    private var styleQuizView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("마음에 드는 사진을 선택하세요")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(quizSelected.count)장 선택")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.purple)
            }

            // 6장 그리드 (2x3)
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6),
                GridItem(.flexible(), spacing: 6)
            ], spacing: 6) {
                ForEach(quizPhotos) { photo in
                    let selected = quizSelected.contains(photo.id)
                    AsyncThumbnailView(url: photo.jpgURL)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? Color.purple : Color.clear, lineWidth: 3)
                        )
                        .overlay(
                            Image(systemName: selected ? "heart.fill" : "heart")
                                .font(.system(size: 16))
                                .foregroundColor(selected ? .purple : .white.opacity(0.7))
                                .shadow(radius: 2)
                                .padding(6),
                            alignment: .bottomTrailing
                        )
                        .onTapGesture {
                            if selected { quizSelected.remove(photo.id) }
                            else { quizSelected.insert(photo.id) }
                        }
                }
            }

            HStack {
                Button("취소") { showQuiz = false }
                Spacer()
                Button(action: finishQuiz) {
                    Label("학습 완료", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(quizSelected.isEmpty)
            }
        }
    }

    private func startQuiz() {
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        guard photos.count >= 6 else { return }
        // 균등 분포로 6장 선택
        let step = photos.count / 6
        quizPhotos = (0..<6).map { photos[$0 * step] }
        quizSelected = []
        showQuiz = true
    }

    private func finishQuiz() {
        let selected = quizPhotos.filter { quizSelected.contains($0.id) }
        let rejected = quizPhotos.filter { !quizSelected.contains($0.id) }
        styleLearner.learnFromSelection(selected: selected, rejected: rejected)
        showQuiz = false
    }

    // MARK: - 스타일 추천 실행

    private func runStyleRecommendation() {
        let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
        guard !photos.isEmpty else { return }

        styleProcessing = true
        styleApplied = false

        styleLearner.batchStyleScores(photos: photos) { scores in
            DispatchQueue.main.async {
                self.styleScores = scores
                self.styleProcessing = false
                self.styleApplied = true

                let threshold = self.styleThreshold
                var selectedCount = 0
                for (photoID, score) in scores {
                    if score >= threshold {
                        if let idx = store._photoIndex[photoID], idx < store.photos.count {
                            if store.photos[idx].rating == 0 {
                                let rating: Int
                                if score >= 85 { rating = 5 }
                                else if score >= 75 { rating = 4 }
                                else { rating = 3 }
                                store.photos[idx].rating = rating
                                selectedCount += 1
                            }
                        }
                    }
                }

                store.invalidateFilterCache()
                store.objectWillChange.send()
                fputs("[STYLE] 추천 적용: \(scores.count)장 분석, \(selectedCount)장 셀렉 (기준 \(Int(threshold))점)\n", stderr)
            }
        }
    }

    // MARK: - 현재 셀렉 학습

    private func learnFromCurrentSelection() {
        let allPhotos = store.photos.filter { !$0.isFolder && !$0.isParentFolder }
        let selected = allPhotos.filter { $0.rating > 0 || $0.isSpacePicked }
        let rejected = allPhotos.filter { $0.rating == 0 && !$0.isSpacePicked }
        styleLearner.learnFromSelection(selected: selected, rejected: rejected)
    }

    // MARK: - 헬퍼

    private func statBadge(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 70)
    }

    private func formatTimeRange(_ range: (start: Date, end: Date)) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: range.start))~\(fmt.string(from: range.end))"
    }

    private func estimatedTime(_ count: Int) -> String {
        count <= 100 ? "~10초" : count <= 500 ? "~30초" : count <= 2000 ? "~2분" : "~5분"
    }
}
