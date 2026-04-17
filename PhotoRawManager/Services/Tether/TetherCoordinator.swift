//
//  TetherCoordinator.swift
//  PhotoRawManager
//
//  고수준 테더링 오케스트레이션. 사용자가 선택한 (또는 자동 감지된) 카메라 브랜드에
//  맞는 CameraController 어댑터를 주입/해제한다.
//
//  구조:
//    TetherCoordinator (@MainActor)
//      ↓ 선택
//    CameraController (프로토콜)
//      ↓ 구현
//    Sony/Canon/Nikon/ImageCapture Adapter
//

import Foundation
import AppKit
import Combine
import SwiftUI

@MainActor
final class TetherCoordinator: ObservableObject {
    static let shared = TetherCoordinator()

    // MARK: 공개 상태

    @Published private(set) var activeBrand: CameraBrand? = nil
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var modelName: String = ""
    @Published private(set) var statusMessage: String = "카메라 대기 중"
    @Published private(set) var lastError: String? = nil

    // 프로퍼티 상태 (UI 바인딩)
    @Published private(set) var propertyStates: [CameraProperty: CameraPropertyState] = [:]
    @Published private(set) var liveViewImage: NSImage? = nil
    @Published private(set) var liveViewActive: Bool = false

    // 촬영 결과
    @Published var captureCount: Int = 0
    @Published var latestPhotoURL: URL? = nil

    // 출력 폴더 (기존 TetherService 와 호환)
    @Published var outputFolder: URL {
        didSet {
            UserDefaults.standard.set(outputFolder.path, forKey: "tetherOutputFolder")
            currentController?.setDownloadFolder(outputFolder)
        }
    }

    // MARK: 내부

    private var currentController: CameraController?
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("PickShot_Tethered")
        if let saved = UserDefaults.standard.string(forKey: "tetherOutputFolder") {
            self.outputFolder = URL(fileURLWithPath: saved)
        } else {
            self.outputFolder = defaultFolder
        }
    }

    // MARK: Public API

    /// 지정한 브랜드의 어댑터로 연결 시도.
    /// Sony/Canon/Nikon 은 SDK 승인 후 작동. 미승인 시 .sdkNotAvailable 에러 발생.
    func connect(to brand: CameraBrand) async {
        // 기존 연결 해제
        await disconnect()

        let controller: CameraController
        switch brand {
        case .sony:
            controller = SonyCameraAdapter(downloadFolder: outputFolder)
        case .canon:
            controller = CanonCameraAdapter(downloadFolder: outputFolder)
        case .nikon:
            controller = NikonCameraAdapter(downloadFolder: outputFolder)
        case .appleImageCapture:
            // Apple ImageCaptureCore 경로 — 기존 TetherService 사용
            // (향후 래핑 예정. 지금은 plain TetherService 가 담당.)
            statusMessage = "Apple ImageCapture 경로는 기존 TetherService 사용"
            return
        }

        activeBrand = brand
        statusMessage = "\(brand.rawValue) 카메라 연결 중..."
        lastError = nil

        // 이벤트 구독
        controller.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleEvent(event)
            }
            .store(in: &subscriptions)

        do {
            try await controller.connect()
            currentController = controller
            isConnected = controller.isConnected
            modelName = controller.modelName
            statusMessage = "\(modelName) 연결됨"
            await refreshAllProperties()
        } catch let err as CameraControllerError {
            lastError = err.errorDescription
            statusMessage = err.errorDescription ?? "연결 실패"
            currentController = nil
            activeBrand = nil
        } catch {
            lastError = error.localizedDescription
            statusMessage = "알 수 없는 에러: \(error.localizedDescription)"
            currentController = nil
            activeBrand = nil
        }
    }

    func disconnect() async {
        if let c = currentController {
            if liveViewActive { await c.stopLiveView() }
            await c.disconnect()
        }
        subscriptions.removeAll()
        currentController = nil
        activeBrand = nil
        isConnected = false
        modelName = ""
        liveViewActive = false
        liveViewImage = nil
        propertyStates = [:]
        statusMessage = "카메라 대기 중"
    }

    /// 전체 속성 재조회 (UI 초기화용)
    func refreshAllProperties() async {
        guard let c = currentController else { return }
        var states: [CameraProperty: CameraPropertyState] = [:]
        for prop in c.supportedProperties {
            if let s = await c.read(prop) {
                states[prop] = s
            }
        }
        propertyStates = states
    }

    /// 프로퍼티 값 쓰기 + UI 갱신
    func write(_ property: CameraProperty, value: String) async -> Bool {
        guard let c = currentController else { return false }
        let ok = await c.write(property, value: value)
        if ok, let s = await c.read(property) {
            propertyStates[property] = s
        }
        return ok
    }

    // MARK: 셔터

    func shutterHalfPress() async { await currentController?.shutterHalfPress() }
    func shutterFullPress() async { await currentController?.shutterFullPress() }
    func shutterRelease() async { await currentController?.shutterRelease() }

    // MARK: 라이브 뷰

    func toggleLiveView() async {
        guard let c = currentController else { return }
        if liveViewActive {
            await c.stopLiveView()
            liveViewActive = false
            liveViewImage = nil
        } else {
            do {
                try await c.startLiveView()
                liveViewActive = true
            } catch {
                lastError = (error as? CameraControllerError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    // MARK: 내부 이벤트 처리

    private func handleEvent(_ event: CaptureEvent) {
        switch event.kind {
        case .shutterFired:
            statusMessage = "촬영됨 — 파일 전송 대기 중"
        case .fileReceived(let url):
            captureCount += 1
            latestPhotoURL = url
            statusMessage = "촬영 #\(captureCount): \(url.lastPathComponent)"
        case .fileFailed(let msg):
            lastError = msg
        case .liveViewFrame(let image):
            liveViewImage = image
        case .settingsChanged(let props):
            // 변경된 속성만 재조회
            Task { @MainActor [weak self] in
                guard let self = self, let c = self.currentController else { return }
                for prop in props {
                    if let s = await c.read(prop) {
                        self.propertyStates[prop] = s
                    }
                }
            }
        }
    }
}
