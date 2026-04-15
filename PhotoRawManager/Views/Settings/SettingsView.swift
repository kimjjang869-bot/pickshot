//
//  SettingsView.swift
//  PhotoRawManager
//
//  Extracted from SettingsView.swift split.
//

import SwiftUI

struct SettingsView: View {
    @State private var hasChanges = true  // 처음엔 활성 (초기 저장용)
    @State private var isSaved = false

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("일반", systemImage: "gear") }
                PreviewSettingsTab()
                    .tabItem { Label("미리보기", systemImage: "photo") }
                ExportSettingsTab()
                    .tabItem { Label("내보내기", systemImage: "square.and.arrow.up") }
                CacheSettingsTab()
                    .tabItem { Label("캐시", systemImage: "internaldrive") }
                PerformanceOptimizeTab()
                    .tabItem { Label("성능 최적화", systemImage: "bolt.circle") }
                AIEngineSettingsTab()
                    .tabItem { Label("AI 엔진", systemImage: "brain") }
                ShortcutsSettingsTab()
                    .tabItem { Label("단축키", systemImage: "keyboard") }
            }

            // 하단 고정 버튼
            Divider()
            HStack {
                Button("되돌리기") {
                    NotificationCenter.default.post(name: .init("SettingsResetTab"), object: nil)
                    isSaved = false
                }
                .help("현재 탭 설정을 기본값으로 초기화")

                Spacer()

                Button(isSaved ? "저장됨" : "확인") {
                    // 설정 변경 알림 → 앱 전체에 반영
                    NotificationCenter.default.post(name: .init("SettingsChanged"), object: nil)
                    isSaved = true
                    // Settings 윈도우 닫기
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if let window = NSApp.windows.first(where: { $0.title.contains("설정") || $0.title.contains("Settings") || $0.identifier?.rawValue.contains("settings") == true }) {
                            window.close()
                        } else {
                            // Fallback: keyWindow가 Settings일 가능성
                            NSApp.keyWindow?.close()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(isSaved)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 550, height: 520)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // 설정값 변경 감지 → 확인 버튼 활성화
            if isSaved { isSaved = false }
        }
    }
}

// MARK: - Tab 1: 일반 (General)
