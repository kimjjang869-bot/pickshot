//
//  NikonCameraAdapter.swift
//  PhotoRawManager
//
//  Nikon SDK 어댑터 (NDA 승인 대기 중 스켈레톤).
//
//  SDK 통합 절차:
//  1. https://sdk.nikonimaging.com/ 에서 SDK Request Form 작성
//  2. NDA 서명 → Nikon SDK (Z 시리즈 + DSLR 통합) 수신
//  3. SDK 를 Frameworks/ 에 번들
//  4. Bridging/NikonBridge.mm 작성
//

import Foundation
import AppKit
import Combine

final class NikonCameraAdapter: CameraController {
    let brand: CameraBrand = .nikon
    private(set) var modelName: String = "Nikon Camera (SDK 대기 중)"
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
        Nikon SDK 가 아직 번들되지 않았습니다.
        Nikon Developer Program (NDA) 승인 후 통합 예정.
        """)
    }

    func disconnect() async { isConnected = false }

    func read(_ property: CameraProperty) async -> CameraPropertyState? { nil }
    func write(_ property: CameraProperty, value: String) async -> Bool { false }

    func shutterHalfPress() async {}
    func shutterFullPress() async {}
    func shutterRelease() async {}

    func startLiveView() async throws {
        throw CameraControllerError.sdkNotAvailable("Nikon SDK 통합 대기 중")
    }
    func stopLiveView() async {}
}
