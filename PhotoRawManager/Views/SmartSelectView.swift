import SwiftUI

struct SmartSelectView: View {
    @EnvironmentObject var store: PhotoStore
    @Environment(\.dismiss) var dismiss
    @State private var criteria: SmartSelectService.Config.SelectionCriteria = .sharpness
    @State private var cullIntensity: SmartSelectService.CullIntensity = .normal
    @State private var burstThreshold: Double = 2.0
    @State private var minGroupSize: Int = 2
    @State private var applied = false
    private var result: SmartSelectService.Result? { store.smartSelectResult }

    var body: some View {
        VStack(spacing: 16) {
            Text("스마트 셀렉").font(.system(size: 18, weight: .bold))
            Text("연사/버스트 중 베스트샷을 자동으로 선택합니다").font(.system(size: 12)).foregroundColor(.secondary)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("선택 기준").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker("", selection: $criteria) {
                        ForEach(SmartSelectService.Config.SelectionCriteria.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 320)
                }
                HStack {
                    Text("컬링 강도").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker("", selection: $cullIntensity) {
                        ForEach(SmartSelectService.CullIntensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 200)
                    Text(intensityDescription).font(.system(size: 11)).foregroundColor(.secondary).frame(width: 100, alignment: .trailing)
                }
                HStack {
                    Text("연사 간격").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(burstThreshold, specifier: "%.1f")초 이내").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                    Slider(value: $burstThreshold, in: 0.5...5.0, step: 0.5).frame(width: 160)
                }
                HStack {
                    Text("최소 연사 수").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(minGroupSize)장 이상").font(.system(size: 12)).foregroundColor(.secondary).frame(width: 80, alignment: .trailing)
                    Stepper("", value: $minGroupSize, in: 2...10).labelsHidden()
                }
            }.padding(.horizontal, 8)

            if !store.hasAnalyzedForSmartSelect {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 12))
                    Text("품질 분석을 먼저 실행하면 더 정확한 베스트샷을 선택할 수 있습니다").font(.system(size: 11)).foregroundColor(.secondary)
                }.padding(8).background(Color.orange.opacity(0.1)).cornerRadius(6)
            }

            Divider()
            if let result = result { resultView(result) } else { Text("분석 결과 없음").font(.system(size: 13)).foregroundColor(.secondary) }
            Spacer()

            HStack(spacing: 12) {
                Button("닫기") { dismiss() }.keyboardShortcut(.escape)
                Button("다시 분석") { updateConfig(); store.previewSmartSelect(); applied = false }
                if let result = result, result.selectedCount > 0 {
                    Button(applied ? "적용 완료" : "베스트샷 셀렉 적용") { store.applySmartSelect(); applied = true }
                        .buttonStyle(.borderedProminent).disabled(applied).keyboardShortcut(.return)
                }
            }
        }.padding(24).frame(width: 520, height: 560)
        .onAppear { updateConfig(); store.previewSmartSelect() }
        .onChange(of: criteria) { _ in updateConfig(); store.previewSmartSelect(); applied = false }
        .onChange(of: cullIntensity) { _ in updateConfig(); store.previewSmartSelect(); applied = false }
    }

    private var intensityDescription: String {
        switch cullIntensity {
        case .strict: return "상위 20%만"
        case .normal: return "상위 40%"
        case .lenient: return "상위 60%"
        }
    }

    private func updateConfig() {
        store.smartSelectConfig = SmartSelectService.Config(burstTimeThreshold: burstThreshold, filenameNumberGap: 1, minGroupSize: minGroupSize, criteria: criteria, cullIntensity: cullIntensity)
    }

    @ViewBuilder
    private func resultView(_ result: SmartSelectService.Result) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                statBox(value: "\(result.totalGroups)", label: "연사 그룹")
                statBox(value: "\(result.totalPhotosInGroups)", label: "연사 사진")
                statBox(value: "\(result.selectedCount)", label: "베스트샷")
            }
            if result.totalGroups == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 32)).foregroundColor(.secondary.opacity(0.5))
                    Text("감지된 연사 그룹이 없습니다").font(.system(size: 13)).foregroundColor(.secondary)
                }.padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(result.groups.prefix(20), id: \.groupIndex) { group in groupRow(group) }
                        if result.groups.count > 20 {
                            Text("... 외 \(result.groups.count - 20)개 그룹").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(.accentColor)
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
        }.frame(width: 100).padding(.vertical, 8).background(Color.gray.opacity(0.1)).cornerRadius(8)
    }

    private func groupRow(_ group: SmartSelectService.BurstGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.stack").font(.system(size: 11)).foregroundColor(.secondary)
            Text("그룹 \(group.groupIndex + 1)").font(.system(size: 12, weight: .medium))
            Text("\(group.count)장").font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            if group.bestIndex < store.photos.count {
                let best = store.photos[group.bestIndex]
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.yellow)
                    Text(best.fileName).font(.system(size: 11, design: .monospaced)).foregroundColor(.accentColor).lineLimit(1)
                }
                if let q = best.quality {
                    Text("\(q.score)점").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(q.overallGrade == .good ? .green : q.overallGrade == .average ? .orange : .red)
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 5).background(Color.gray.opacity(0.08)).cornerRadius(4)
    }
}
