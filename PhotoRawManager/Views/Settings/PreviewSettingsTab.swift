//
//  PreviewSettingsTab.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI


struct PreviewSettingsTab: View {
    @AppStorage("previewMaxResolution") private var previewMaxResolution = "original"
    @AppStorage("rawPreviewMode") private var rawPreviewMode = "fast"
    @AppStorage("preferRAWOverJPG") private var preferRAWOverJPG = false
    @AppStorage("colorProfile") private var colorProfile = "display"
    @AppStorage("previewCacheSize") private var previewCacheSize = 50.0  // v8.6.2 기본값 통일
    // v8.9.4: FRV 식 prefetch depth — 0=자동(tier 기반), >0=수동 ±N장
    @AppStorage("previewPrefetchDepth") private var previewPrefetchDepth = 0.0
    @AppStorage("defaultThumbnailSize") private var defaultThumbnailSize = 150.0
    @AppStorage("defaultViewMode") private var defaultViewMode = "gridPreview"
    @AppStorage("defaultSortMode") private var defaultSortMode = "captureTime"
    @AppStorage("showHistogramByDefault") private var showHistogramByDefault = false
    @AppStorage("showExifByDefault") private var showExifByDefault = false
    @AppStorage("enableTransition") private var enableTransition = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("미리보기 설정")
                    .font(.title3.bold())
                Text("이미지 미리보기와 표시 방식을 설정합니다.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                GroupBox("해상도 및 캐시") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("미리보기 해상도", selection: $previewMaxResolution) {
                            Text("원본").tag("original")
                            Text("4000px").tag("4000")
                            Text("3000px").tag("3000")
                            Text("2000px").tag("2000")
                            Text("1000px (저사양)").tag("1000")
                            Text("500px (초저사양)").tag("500")
                        }

                        Picker("RAW 미리보기 모드", selection: $rawPreviewMode) {
                            Text("빠른 미리보기 (내장 프리뷰)").tag("fast")
                            Text("픽쳐스타일 미리보기 (CIRAWFilter)").tag("ciraw")
                        }
                        .help("빠른 미리보기: 카메라 내장 JPEG 사용 (빠름, 픽쳐스타일 적용됨)\n픽쳐스타일 미리보기: CIRAWFilter 사용 (느림, 정밀한 색상)")

                        // v8.9.4: FRV 식 "외부 JPEG vs RAW 임베디드" 정책 명시화
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("RAW+JPG 페어 표시 소스", selection: $preferRAWOverJPG) {
                                Text("외부 JPG 우선 (빠름, 추천)").tag(false)
                                Text("RAW 임베디드 우선 (정밀)").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            Text(preferRAWOverJPG
                                 ? "RAW 파일의 임베디드 프리뷰 사용. 카메라의 픽쳐스타일·WB가 그대로 반영. 디코드 약간 느림."
                                 : "기존 JPG 파일을 직접 사용. 가장 빠름. 보정용 JPG가 카메라 JPG 와 다른 색감일 수 있음.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Picker("RAW 색공간", selection: $colorProfile) {
                            Text("모니터 맞춤 (자동)").tag("display")
                            Text("sRGB").tag("srgb")
                            Text("Display P3").tag("p3")
                            Text("Adobe RGB").tag("adobeRGB")
                        }
                        .help("CIRAWFilter 모드에서 사용할 출력 색공간")

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("미리보기 캐시 크기: \(Int(previewCacheSize))장")
                            Slider(value: $previewCacheSize, in: 5...300, step: 5)
                            if previewCacheSize > 50 {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange)
                                    Text("50장 이상은 메모리 사용량이 크게 증가할 수 있습니다 (RAM 16GB 이상 권장)")
                                        .font(.system(size: 10)).foregroundColor(.orange)
                                }
                            }
                        }

                        // v8.9.4: FastRawViewer 식 prefetch depth 슬라이더
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("미리 읽기 거리 (선택 사진 ±)")
                                Spacer()
                                Text(previewPrefetchDepth == 0 ? "자동 (tier 기반)" : "±\(Int(previewPrefetchDepth))장")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $previewPrefetchDepth, in: 0...30, step: 1)
                            Text("0 = 시스템 자동 (RAM tier 기반). 값 증가 시 방향키 이동이 즉시 부드러워지지만 RAM 사용량 ↑")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        // 썸네일 크기 — 자동 설정 (스토리지 타입에 따라 최적화)
                        HStack {
                            Text("썸네일 크기: 자동 (SSD 140 / HDD 100 / SD 90)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(4)
                }

                GroupBox("보기 옵션") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("기본 보기 모드", selection: $defaultViewMode) {
                            Text("그리드+미리보기").tag("gridPreview")
                            Text("필름스트립").tag("filmstrip")
                        }

                        Divider()

                        Picker("기본 정렬", selection: $defaultSortMode) {
                            Text("촬영시간").tag("captureTime")
                            Text("파일명").tag("fileName")
                            Text("별점").tag("rating")
                        }

                        Divider()

                        Toggle("히스토그램 기본 표시", isOn: $showHistogramByDefault)

                        Divider()

                        Toggle("EXIF 정보 기본 표시", isOn: $showExifByDefault)

                        Divider()

                        Toggle("이미지 전환 애니메이션", isOn: $enableTransition)
                    }
                    .padding(4)
                }

            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("SettingsResetTab"))) { _ in
            previewMaxResolution = "1000"; rawPreviewMode = "fast"; colorProfile = "display"
            previewCacheSize = 50.0; defaultThumbnailSize = 150.0
            defaultViewMode = "gridPreview"; defaultSortMode = "captureTime"
            showHistogramByDefault = false; showExifByDefault = false; enableTransition = true
        }
    }
}

// MARK: - Tab 3: 내보내기 (Export)
