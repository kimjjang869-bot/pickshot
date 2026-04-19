import SwiftUI
import AppKit

/// 프리뷰 위에 오버레이되는 인라인 크롭 UI.
///
/// v8.6.1 부터 내부 렌더링/제스처는 **AppKit `NSCropView`** 로 위임 (SwiftUI 레이아웃 엔진의
/// 이미지-박스 정렬 불일치를 원천 차단). 이 struct 는 state/preset/toolbar/confirm-cancel 만 관리.
struct InlineCropOverlay: View {
    let photoURL: URL
    let image: NSImage                      // v8.6.1: displaySize + imageAspectRatio → image 로 단일화
    let onDismiss: () -> Void

    @ObservedObject var store: DevelopStore = .shared

    // 드래프트 상태 — confirmCrop 에서 DevelopStore 로 최종 반영.
    @State private var draftRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var draftRotation: Double = 0
    @State private var draftAspectLabel: String = "Original"
    @State private var initialSettings: DevelopSettings = DevelopSettings()

    // MARK: - Presets

    struct AspectPreset: Identifiable, Hashable {
        let id: String
        let label: String
        let ratio: Double?
        let isOriginal: Bool
    }

    private let presets: [AspectPreset] = [
        AspectPreset(id: "Free",     label: "자유",   ratio: nil, isOriginal: false),
        AspectPreset(id: "1:1",      label: "1:1",    ratio: 1.0, isOriginal: false),
        AspectPreset(id: "3:2",      label: "3:2",    ratio: 3.0 / 2.0, isOriginal: false),
        AspectPreset(id: "2:3",      label: "2:3",    ratio: 2.0 / 3.0, isOriginal: false),
        AspectPreset(id: "4:5",      label: "4:5",    ratio: 4.0 / 5.0, isOriginal: false),
        AspectPreset(id: "16:9",     label: "16:9",   ratio: 16.0 / 9.0, isOriginal: false),
        AspectPreset(id: "Original", label: "원본",   ratio: nil, isOriginal: true)
    ]

    /// 현재 선택된 preset 의 픽셀 비율 (NSCropView 의 Shift 비율 잠금용).
    private var currentAspectRatio: Double? {
        presets.first(where: { $0.id == draftAspectLabel })?.ratio
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // 이미지 + 크롭 박스 + 핸들 전부 단일 NSView 내부에서 draw() 로 렌더 →
            // SwiftUI 레이아웃 엔진 정렬 오차 없음.
            NSCropView(
                image: image,
                cropRect: $draftRect,
                rotationDegrees: $draftRotation,
                aspectLabel: $draftAspectLabel,
                aspectRatio: currentAspectRatio
            )

            // 하단 toolbar 만 SwiftUI 레이어로 오버레이.
            VStack {
                Spacer()
                cropToolbar
                    .padding(.bottom, 20)
            }
        }
        .contentShape(Rectangle())
        .onAppear { initializeDraft() }
    }

    // MARK: - Initialize / Confirm / Cancel

    private func initializeDraft() {
        initialSettings = store.get(for: photoURL)
        if let existing = initialSettings.cropRect {
            draftRect = existing
            draftAspectLabel = initialSettings.cropAspectLabel ?? "Original"
        } else {
            draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            draftAspectLabel = "Original"
        }
        draftRotation = initialSettings.cropRotation
    }

    private func selectPreset(_ preset: AspectPreset) {
        draftAspectLabel = preset.id
        if let ratio = preset.ratio, image.size.height > 0 {
            // preset ratio (픽셀 공간) → 이미지 정규화 공간 ratio 로 변환
            let imgAR = image.size.width / image.size.height
            let normalizedAspect = CGFloat(ratio) / imgAR
            let cx = draftRect.midX, cy = draftRect.midY
            var newRect = draftRect
            let currentAR = draftRect.width / max(draftRect.height, 0.0001)
            if currentAR > normalizedAspect {
                newRect.size.width = draftRect.height * normalizedAspect
            } else {
                newRect.size.height = draftRect.width / normalizedAspect
            }
            newRect.origin.x = cx - newRect.width / 2
            newRect.origin.y = cy - newRect.height / 2
            draftRect = clampNormalized(newRect)
        } else if preset.isOriginal {
            draftRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        // Free — 박스 유지
    }

    private func clampNormalized(_ r: CGRect) -> CGRect {
        var r = r
        r.origin.x = max(0, min(1, r.origin.x))
        r.origin.y = max(0, min(1, r.origin.y))
        r.size.width = min(r.size.width, 1 - r.origin.x)
        r.size.height = min(r.size.height, 1 - r.origin.y)
        r.size.width = max(0.05, r.size.width)
        r.size.height = max(0.05, r.size.height)
        return r
    }

    private func confirmCrop() {
        var s = store.get(for: photoURL)
        if draftRect.width > 0.98 && draftRect.height > 0.98 &&
           draftRect.origin.x < 0.01 && draftRect.origin.y < 0.01 {
            // 전체 영역 선택 → crop 해제
            s.cropRect = nil
            s.cropAspectLabel = nil
        } else {
            s.cropRect = draftRect
            s.cropAspectLabel = draftAspectLabel
        }
        s.cropRotation = draftRotation
        store.set(s, for: photoURL)
        onDismiss()
    }

    private func cancelCrop() {
        store.set(initialSettings, for: photoURL)
        onDismiss()
    }

    // MARK: - Toolbar

    private var cropToolbar: some View {
        HStack(spacing: 10) {
            // Aspect preset menu
            Menu {
                ForEach(presets) { preset in
                    Button(preset.label) { selectPreset(preset) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "aspectratio").font(.system(size: 11))
                    Text(displayLabel).font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundColor(.white)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 88)

            Divider().frame(height: 18).opacity(0.3)

            // Rotation slider (-45° ~ +45°)
            Image(systemName: "rotate.left")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
            DoubleClickResetSlider(
                value: $draftRotation,
                range: -45...45,
                defaultValue: 0,
                step: 0.5,
                bigStep: 5,
                format: { String(format: "%+.1f°", $0) }
            )
            .frame(width: 140)
            Text(String(format: "%+.1f°", draftRotation))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 42, alignment: .trailing)

            Divider().frame(height: 18).opacity(0.3)

            // Cancel / Confirm
            Button(action: cancelCrop) {
                Text("취소")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundColor(.white.opacity(0.85))
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: confirmCrop) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text("크롭").font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundColor(.black)
                .background(Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
        )
    }

    private var displayLabel: String {
        presets.first(where: { $0.id == draftAspectLabel })?.label ?? draftAspectLabel
    }
}
