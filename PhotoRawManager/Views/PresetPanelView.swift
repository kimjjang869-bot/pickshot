import SwiftUI
import AppKit

/// 프리셋 저장/불러오기/삭제 UI — 플로팅 필에서 확장되는 패널.
///
/// 섹션:
/// - ❤️ My Presets (사용자 저장, 삭제 가능)
/// - 📦 Built-in (자연스러운 피부톤 · 웨딩 하이키 · 필름 톤, 삭제 불가)
struct PresetPanelView: View {
    let photoURL: URL
    @ObservedObject var store: DevelopStore = .shared
    let onDismiss: () -> Void

    @State private var presets: [DevelopSettings.Preset] = []
    @State private var showingSaveSheet = false
    @State private var newPresetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 1.0, green: 0.76, blue: 0.03))
                Text("프리셋")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { showingSaveSheet = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text("저장").font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundColor(.black)
                    .background(Capsule().fill(Color(red: 1.0, green: 0.76, blue: 0.03)))
                }
                .buttonStyle(.plain)
                .disabled(store.get(for: photoURL).isDefault)
                .help("현재 설정을 프리셋으로 저장 (Cmd+Shift+S)")
            }

            ScrollView {
                VStack(spacing: 2) {
                    if let userPresets = Optional(presets.filter { !isBuiltin($0) }), !userPresets.isEmpty {
                        sectionHeader("❤️ My Presets")
                        ForEach(userPresets) { preset in
                            presetRow(preset, isDeletable: true)
                        }
                    }

                    sectionHeader("📦 Built-in")
                    ForEach(presets.filter { isBuiltin($0) }) { preset in
                        presetRow(preset, isDeletable: false)
                    }
                }
            }
            .frame(height: 210)
        }
        .padding(10)
        .frame(width: 260)
        .onAppear { reload() }
        .sheet(isPresented: $showingSaveSheet) { savePresetSheet }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
        }
        .padding(.top, 6).padding(.bottom, 2)
    }

    // MARK: - Preset Row

    private func presetRow(_ preset: DevelopSettings.Preset, isDeletable: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: { applyPreset(preset) }) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(preset.summary)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.04))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isDeletable {
                Button(action: { deletePreset(preset) }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("프리셋 삭제")
            }
        }
    }

    // MARK: - Save Sheet

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("프리셋 저장").font(.headline)
            TextField("프리셋 이름", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            Text("요약: \(store.get(for: photoURL).shortSummary)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("취소") {
                    showingSaveSheet = false
                    newPresetName = ""
                }
                .keyboardShortcut(.cancelAction)

                Button("저장") {
                    savePreset()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Actions

    private func applyPreset(_ preset: DevelopSettings.Preset) {
        var current = store.get(for: photoURL)
        // 프리셋의 모든 컴포넌트 적용 (전체 교체)
        current.apply(preset.settings, components: Set(DevelopSettings.ComponentMask.allCases))
        store.set(current, for: photoURL)
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let current = store.get(for: photoURL)
        let preset = DevelopSettings.Preset(
            name: name,
            summary: current.shortSummary,
            settings: current
        )
        store.savePreset(preset)
        showingSaveSheet = false
        newPresetName = ""
        reload()
    }

    private func deletePreset(_ preset: DevelopSettings.Preset) {
        store.deletePreset(preset)
        reload()
    }

    private func reload() {
        presets = store.loadAllPresets()
    }

    private func isBuiltin(_ preset: DevelopSettings.Preset) -> Bool {
        let builtinNames: Set<String> = ["자연스러운 피부톤", "웨딩 하이키", "필름 톤"]
        return builtinNames.contains(preset.name)
    }
}
