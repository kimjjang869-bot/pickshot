import SwiftUI

// MARK: - AI 스마트 셀렉 뷰

struct SmartCullView: View {
    @EnvironmentObject var store: PhotoStore
    @ObservedObject var service = SmartCullService.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // 헤더
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 24))
                    .foregroundColor(.purple)
                VStack(alignment: .leading) {
                    Text("AI 스마트 셀렉")
                        .font(.headline)
                    Text("유사 그룹핑 → C컷 탈락 → A컷 추천")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            if service.isProcessing {
                // 진행 중
                VStack(spacing: 12) {
                    ProgressView(value: service.progress) {
                        Text(service.statusMessage)
                            .font(.system(size: 12))
                    }
                    .progressViewStyle(.linear)

                    Text("\(Int(service.progress * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)

                    Button("취소") {
                        service.cancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else if !service.groups.isEmpty {
                // 결과 표시
                resultView
            } else {
                // 시작 전
                startView
            }

            Divider()

            HStack {
                Button("닫기") { dismiss() }
                Spacer()
                if !service.groups.isEmpty {
                    Button("결과 초기화") {
                        service.groups = []
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 500, minHeight: 300)
    }

    private var startView: some View {
        VStack(spacing: 16) {
            let photoCount = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }.count

            HStack(spacing: 20) {
                VStack {
                    Text("\(photoCount)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                    Text("장 분석 예정")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Label("유사 그룹핑", systemImage: "rectangle.3.group")
                    Label("C컷 자동 탈락", systemImage: "xmark.circle")
                    Label("A컷 추천", systemImage: "star.fill")
                }
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }

            let estimatedTime = photoCount <= 100 ? "~10초" :
                               photoCount <= 500 ? "~30초" :
                               photoCount <= 2000 ? "~2분" : "~5분"

            Text("예상 소요 시간: \(estimatedTime)")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: {
                let photos = store.filteredPhotos.filter { !$0.isFolder && !$0.isParentFolder }
                service.runSmartCull(photos: photos, store: store)
            }) {
                Label("분석 시작", systemImage: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.large)
        }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let totalClusters = service.groups.flatMap(\.clusters).count
            let acuts = service.groups.flatMap(\.clusters).compactMap(\.bestPhotoID).count

            HStack(spacing: 20) {
                statBadge("\(service.groups.count)", label: "그룹", color: .blue)
                statBadge("\(totalClusters)", label: "클러스터", color: .purple)
                statBadge("\(acuts)", label: "A컷 추천", color: .green)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(service.groups) { group in
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
                                        Text("유사도: \(Int(cluster.similarity * 100))%")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                        if cluster.bestPhotoID != nil {
                                            Text("⭐ A컷")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
    }

    private func statBadge(_ value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 60)
    }

    private func formatTimeRange(_ range: (start: Date, end: Date)) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: range.start))~\(fmt.string(from: range.end))"
    }
}
