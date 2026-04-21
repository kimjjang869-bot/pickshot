//
//  VisualSearchHUD.swift
//  PhotoRawManager
//
//  v8.7: 참조 기반 시각 검색의 플로팅 HUD.
//  진행률, 활성 레퍼런스, 매칭 수, 임계값 조절, 해제 버튼 제공.
//

import SwiftUI

struct VisualSearchHUD: View {
    @ObservedObject var service: VisualSearchService = VisualSearchService.shared
    @EnvironmentObject var store: PhotoStore
    let onDeactivate: () -> Void

    var body: some View {
        if service.isSearching || !service.references.isEmpty {
            VStack(spacing: 8) {
                // 상단 — 상태 요약
                HStack(spacing: 10) {
                    Image(systemName: service.isSearching ? "hourglass" : "magnifyingglass.circle.fill")
                        .foregroundColor(service.isSearching ? .orange : .accentColor)
                        .font(.system(size: 16, weight: .bold))

                    if service.isSearching {
                        let pct = service.progress.total > 0 ?
                            Double(service.progress.done) / Double(service.progress.total) : 0
                        VStack(alignment: .leading, spacing: 2) {
                            Text("시각 검색 진행 중... \(service.progress.done)/\(service.progress.total)")
                                .font(.system(size: 12, weight: .semibold))
                            ProgressView(value: pct)
                                .progressViewStyle(.linear)
                                .frame(width: 260)
                        }
                    } else {
                        Text("검색 결과: \(service.matchedURLs.count)장")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    Spacer()

                    // 임계값 슬라이더 + 옵션
                    if !service.isSearching {
                        HStack(spacing: 4) {
                            Text("엄격도")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                            Slider(
                                value: $service.threshold,
                                in: 0.50...0.95,
                                step: 0.02
                            )
                            .frame(width: 110)
                            Text(String(format: "%.2f", service.threshold))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 30)

                            Toggle(isOn: $service.useBodyFallback) {
                                Text("뒷면 포함")
                                    .font(.system(size: 10))
                            }
                            .toggleStyle(.checkbox)
                            .help("얼굴 감지 실패 시 인물 영역 FeaturePrint 로 옆/뒷면 매칭 시도 (정확도↓)")

                            // v8.7: 재검색 — 엄격도/뒷면 옵션 변경 후 다시 적용
                            Button(action: reRunSearch) {
                                Label("재검색", systemImage: "arrow.clockwise.circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                            .help("현재 엄격도/옵션으로 재검색")
                        }
                    }

                    // 닫기 — 검색 해제 + 전체 썸네일 복원
                    //   순서 중요: onDeactivate (visualSearchActive=false) 먼저 호출해야
                    //   clearAll 이 matchedURLs=[] 로 트리거한 필터 재실행이 "active+empty" 상태로 0장 반환하는 버그 방지
                    Button(action: {
                        onDeactivate()
                        service.clearAll()
                        // v8.9: 시각 검색 전면 해제 시 별점/컬러/최소별점 필터도 All 로 리셋.
                        //   사용자 관점에서 "전체 썸네일 복원" 이 일관되게 작동하도록.
                        resetAllFiltersToAll()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle.fill")
                            Text("닫기")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("검색 해제 → 전체 썸네일 복원")
                }

                // 하단 — 활성 레퍼런스 칩들
                if !service.references.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(service.references) { ref in
                                HStack(spacing: 5) {
                                    if let img = ref.previewImage {
                                        Image(nsImage: img)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 22, height: 22)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    Text(ref.label ?? (ref.mode == .face ? "얼굴" : "사물"))
                                        .font(.system(size: 11, weight: .medium))
                                    Button(action: {
                                        let wasLast = service.references.count == 1
                                        service.removeReference(id: ref.id)
                                        if wasLast {
                                            // 마지막 레퍼런스 해제 → 전면 닫기와 동일 처리
                                            onDeactivate()
                                            resetAllFiltersToAll()
                                        }
                                    }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    (ref.mode == .face ? Color.orange : Color.teal).opacity(0.15)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(ref.mode == .face ? Color.orange : Color.teal, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            // 조합 모드 + 재검색
                            if service.references.count >= 2 {
                                Picker("", selection: $service.combineMode) {
                                    ForEach(VisualSearchService.CombineMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 110)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    /// v8.9: 시각 검색 전면 해제 시 별점/컬러/최소별점 필터도 All 로 리셋.
    private func resetAllFiltersToAll() {
        if !store.ratingFilters.isEmpty { store.ratingFilters = [] }
        if !store.colorLabelFilters.isEmpty { store.colorLabelFilters = [] }
        if store.minimumRatingFilter > 0 { store.minimumRatingFilter = 0 }
    }

    /// 엄격도/뒷면 옵션 변경 후 재검색
    private func reRunSearch() {
        let urls = store.photos.compactMap { p -> URL? in
            guard !p.isFolder, !p.isParentFolder else { return nil }
            return p.jpgURL
        }
        service.runSearch(on: urls)
    }
}
