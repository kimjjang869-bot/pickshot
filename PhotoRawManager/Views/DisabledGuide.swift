//
//  DisabledGuide.swift
//  PhotoRawManager
//
//  Extracted from ContentView+SupportingViews.swift split.
//

import SwiftUI

// MARK: - Disabled Button Guide

/// Shows an alert explaining why a button is disabled and offers to fix it
struct DisabledGuide {
    /// Show alert for disabled AI features
    static func showAIDisabled() {
        let alert = NSAlert()
        alert.messageText = "AI 기능을 사용하려면"
        alert.informativeText = "AI 기능은 Pro 구독이 필요합니다.\nAPI 키가 설정되어 있지 않으면 설정에서 입력해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // macOS 14+: showSettingsWindow, macOS 13: showPreferencesWindow
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else if #available(macOS 13, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
            // Cmd+, 단축키로 직접 열기 (폴백)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if NSApp.windows.first(where: { $0.title.contains("설정") || $0.title.contains("Settings") }) == nil {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    /// Show alert for compare mode
    static func showCompareDisabled(currentCount: Int) {
        let alert = NSAlert()
        alert.messageText = "비교 보기"
        alert.informativeText = "2~4장의 사진을 선택해야 비교할 수 있습니다.\n현재 \(currentCount)장 선택됨.\n\nCmd+클릭으로 여러 장을 선택하세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for G Select not logged in
    static func showGSelectLoginNeeded() {
        let alert = NSAlert()
        alert.messageText = "Google Drive 로그인 필요"
        alert.informativeText = "G셀렉을 사용하려면 Google 계정으로 로그인해야 합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            GSelectService.shared.loginToGoogle()
        }
    }

    /// Show alert for analysis in progress
    static func showAnalysisInProgress() {
        let alert = NSAlert()
        alert.messageText = "분석 진행 중"
        alert.informativeText = "현재 분석이 진행 중입니다. 완료 후 다시 시도해주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for correction in progress
    static func showCorrectionInProgress() {
        let alert = NSAlert()
        alert.messageText = "보정 진행 중"
        alert.informativeText = "현재 보정 작업이 진행 중입니다. 완료될 때까지 기다려주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    /// Show alert for no photos loaded
    static func showNoPhotos() {
        let alert = NSAlert()
        alert.messageText = "사진이 없습니다"
        alert.informativeText = "먼저 사진 폴더를 열어주세요."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "폴더 열기")
        alert.addButton(withTitle: "닫기")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Trigger folder open
            NotificationCenter.default.post(name: .init("openFolder"), object: nil)
        }
    }
}
