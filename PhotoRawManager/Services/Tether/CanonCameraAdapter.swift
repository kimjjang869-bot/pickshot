//
//  CanonCameraAdapter.swift
//  PhotoRawManager
//
//  Canon EDSDK 어댑터 (NDA 승인 대기 중 스켈레톤).
//
//  EDSDK 통합 절차:
//  1. https://developercommunity.usa.canon.com/ 에서 Canon Developer Programme 가입
//  2. NDA 서명 → EDSDK 13.x (ARM64) 다운로드
//  3. EDSDK.framework 를 Frameworks/ 에 번들
//  4. Bridging/CanonBridge.m 작성 — EDSDK C API 래핑
//

import Foundation
import AppKit
import Combine

final class CanonCameraAdapter: CameraController {
    let brand: CameraBrand = .canon
    private(set) var modelName: String = "Canon Camera (SDK 대기 중)"
    private(set) var serial: String? = nil
    private(set) var isConnected: Bool = false

    private let eventSubject = PassthroughSubject<CaptureEvent, Never>()
    var eventPublisher: AnyPublisher<CaptureEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    let supportsLiveView: Bool = true

    var supportedProperties: [CameraProperty] {
        [.iso, .aperture, .shutterSpeed, .whiteBalance,
         .exposureCompensation, .focusMode, .driveMode,
         .meteringMode, .imageQuality, .batteryLevel]
    }

    private var downloadFolder: URL

    init(downloadFolder: URL) { self.downloadFolder = downloadFolder }
    func setDownloadFolder(_ url: URL) { self.downloadFolder = url }

    func connect() async throws {
        throw CameraControllerError.sdkNotAvailable("""
        Canon EDSDK 가 아직 번들되지 않았습니다.
        Canon Developer Programme (NDA) 승인 후 통합 예정.
        """)
    }

    func disconnect() async { isConnected = false }

    func read(_ property: CameraProperty) async -> CameraPropertyState? { nil }
    func write(_ property: CameraProperty, value: String) async -> Bool { false }

    func shutterHalfPress() async {}
    func shutterFullPress() async {}
    func shutterRelease() async {}

    func startLiveView() async throws {
        throw CameraControllerError.sdkNotAvailable("Canon EDSDK 통합 대기 중")
    }
    func stopLiveView() async {}
}
