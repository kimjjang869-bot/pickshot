import Foundation
import AppKit
import Metal

// MARK: - SystemSpec: 중앙화된 하드웨어 감지 + Tier 기반 리소스 할당
// 기존에 6곳(HardwareAcceleration, PhotoPreviewView, ThumbnailGridView,
// ImageAnalysisService, FileCopyService, PhotoStore+Collections)에 분산되어 있던
// RAM/코어 기반 분기 로직을 단일 진입점으로 통합한다.

/// 하드웨어 성능 티어 (M1 Pro 16GB 테스터 crystal 이슈 해결을 위해 standard tier 신설)
enum PerformanceTier: String {
    case low       // < 16GB (8GB M1 MBA 등 저사양)
    case standard  // 16GB (M1 Pro 16GB - crystal 타겟, 경계 스펙)
    case high      // 24~47GB (M2/M3 Pro 32GB)
    case extreme   // 48GB+ (M3 Max/Ultra, 포토칸 M3 Ultra 64GB+)
}

/// 사용자 프로필 (Settings에서 선택, auto면 SystemSpec 자동 tier 사용)
enum UserPerformanceProfile: String {
    case auto
    case speed     // 한 단계 아래로 내림
    case balanced  // auto와 동일
    case quality   // 한 단계 위로 올림
}

enum GPUClass {
    case intelIntegrated, appleM1, appleM2, appleM3, appleM4, unknown
}

enum DiskClass {
    case fastSSD, ssd, hdd, unknown
}

final class SystemSpec {
    static let shared = SystemSpec()

    // MARK: - 하드웨어 정보
    let ramGB: Int
    let physicalMemoryBytes: UInt64
    let coreCount: Int
    let isAppleSilicon: Bool
    let cpuBrand: String            // sysctl "machdep.cpu.brand_string"
    let macModel: String            // sysctl "hw.model" (예: "Mac15,9")
    let macModelMarketing: String   // 가능하면 "MacBook Pro (14-inch, M1 Pro, 2021)"
    let gpuName: String             // MTLDevice.name
    let gpuClass: GPUClass
    let osVersion: String           // "macOS 14.5"
    let autoTier: PerformanceTier   // 하드웨어 기반 자동 tier

    // MARK: - 사용자 프로필
    var userProfile: UserPerformanceProfile {
        get {
            let raw = UserDefaults.standard.string(forKey: "userPerformanceProfile") ?? "auto"
            return UserPerformanceProfile(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "userPerformanceProfile")
        }
    }

    /// 유저 프로필을 반영한 최종 tier
    var effectiveTier: PerformanceTier {
        switch userProfile {
        case .auto, .balanced: return autoTier
        case .speed: return stepDown(autoTier)
        case .quality: return stepUp(autoTier)
        }
    }

    private init() {
        let procInfo = ProcessInfo.processInfo
        self.physicalMemoryBytes = procInfo.physicalMemory
        self.ramGB = Int(procInfo.physicalMemory / (1024 * 1024 * 1024))
        self.coreCount = procInfo.activeProcessorCount
        self.osVersion = procInfo.operatingSystemVersionString

        // CPU brand (sysctl)
        self.cpuBrand = Self.sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"
        let hwModel = Self.sysctlString("hw.model") ?? "Unknown Model"
        self.macModel = hwModel
        self.macModelMarketing = Self.marketingNameFromModel(hwModel)

        // Apple Silicon 감지
        #if arch(arm64)
        self.isAppleSilicon = true
        #else
        self.isAppleSilicon = false
        #endif

        // GPU
        let device = MTLCreateSystemDefaultDevice()
        self.gpuName = device?.name ?? "Unknown GPU"
        self.gpuClass = Self.classifyGPU(device?.name ?? "")

        // 티어 결정 (하이브리드: 16GB 독립)
        // crystal M1 Pro 16GB = .standard (기존 >= 16GB 일괄 처리 대신 분리)
        let gb = Int(procInfo.physicalMemory / (1024 * 1024 * 1024))
        if gb < 16 {
            self.autoTier = .low
        } else if gb < 24 {          // 16~23GB → standard (M1 Pro 16GB 타겟)
            self.autoTier = .standard
        } else if gb < 48 {          // 24~47GB → high (M2/M3 Pro 32GB 등)
            self.autoTier = .high
        } else {
            self.autoTier = .extreme  // 48GB+ (M3 Max/Ultra)
        }
    }

    // MARK: - Tier 전환
    private func stepDown(_ t: PerformanceTier) -> PerformanceTier {
        switch t {
        case .extreme: return .high
        case .high: return .standard
        case .standard: return .low
        case .low: return .low
        }
    }
    private func stepUp(_ t: PerformanceTier) -> PerformanceTier {
        switch t {
        case .low: return .standard
        case .standard: return .high
        case .high: return .extreme
        case .extreme: return .extreme
        }
    }

    // MARK: - sysctl helper
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 || size == 0 { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &bytes, &size, nil, 0) != 0 { return nil }
        return String(cString: bytes)
    }

    private static func classifyGPU(_ name: String) -> GPUClass {
        if name.contains("M4") { return .appleM4 }
        if name.contains("M3") { return .appleM3 }
        if name.contains("M2") { return .appleM2 }
        if name.contains("M1") { return .appleM1 }
        if name.contains("Intel") { return .intelIntegrated }
        return .unknown
    }

    /// hw.model → 대략적 마케팅명 (베스트-에포트, 알려진 매핑만)
    /// 실패 시 원본 hw.model 반환
    private static func marketingNameFromModel(_ hwModel: String) -> String {
        // 주요 Apple Silicon 모델 매핑 (필요 시 확장)
        let map: [String: String] = [
            "MacBookPro18,1": "MacBook Pro 16-inch (M1 Pro/Max, 2021)",
            "MacBookPro18,2": "MacBook Pro 16-inch (M1 Pro/Max, 2021)",
            "MacBookPro18,3": "MacBook Pro 14-inch (M1 Pro/Max, 2021)",
            "MacBookPro18,4": "MacBook Pro 14-inch (M1 Pro/Max, 2021)",
            "Mac14,5": "MacBook Pro 14-inch (M2 Pro/Max, 2023)",
            "Mac14,6": "MacBook Pro 16-inch (M2 Pro/Max, 2023)",
            "Mac14,7": "MacBook Pro 13-inch (M2, 2022)",
            "Mac14,9": "MacBook Pro 14-inch (M2 Pro/Max, 2023)",
            "Mac14,10": "MacBook Pro 16-inch (M2 Pro/Max, 2023)",
            "Mac15,3": "MacBook Pro 14-inch (M3, 2023)",
            "Mac15,6": "MacBook Pro 14-inch (M3 Pro/Max, 2023)",
            "Mac15,7": "MacBook Pro 16-inch (M3 Pro/Max, 2023)",
            "Mac15,8": "MacBook Pro 14-inch (M3 Max, 2023)",
            "Mac15,9": "MacBook Pro 16-inch (M3 Max, 2023)",
            "Mac15,10": "MacBook Pro 14-inch (M3 Max, 2023)",
            "Mac15,11": "MacBook Pro 16-inch (M3 Max, 2023)",
            "Mac16,1": "MacBook Pro 14-inch (M4, 2024)",
            "Mac16,6": "MacBook Pro 14-inch (M4 Pro/Max, 2024)",
            "Mac16,8": "MacBook Pro 16-inch (M4 Pro/Max, 2024)",
            "Mac14,2": "MacBook Air 13-inch (M2, 2022)",
            "Mac14,15": "MacBook Air 15-inch (M2, 2023)",
            "Mac15,12": "MacBook Air 13-inch (M3, 2024)",
            "Mac15,13": "MacBook Air 15-inch (M3, 2024)",
            "Mac14,3": "Mac mini (M2, 2023)",
            "Mac14,12": "Mac mini (M2 Pro, 2023)",
            "Mac15,4": "Mac mini (M4, 2024)",
            "Mac15,5": "Mac mini (M4 Pro, 2024)",
            "Mac13,1": "Mac Studio (M1 Max, 2022)",
            "Mac13,2": "Mac Studio (M1 Ultra, 2022)",
            "Mac14,13": "Mac Studio (M2 Max, 2023)",
            "Mac14,14": "Mac Studio (M2 Ultra, 2023)",
            "Mac15,14": "Mac Studio (M4 Max, 2025)",
            "iMac21,1": "iMac 24-inch (M1, 2021)",
            "iMac21,2": "iMac 24-inch (M1, 2021)",
        ]
        return map[hwModel] ?? hwModel
    }

    // MARK: - Tier별 리소스 할당 (이 함수들이 모든 캐시/동시성의 표준 진입점)

    /// AggressiveImageCache(HardwareAcceleration.swift) 용량 (MB)
    func aggressiveCacheLimitMB() -> Int {
        switch effectiveTier {
        case .low:      return 150
        case .standard: return 200  // M1 Pro 16GB 타겟 (기존 300MB에서 더 축소)
        case .high:     return 500
        case .extreme:  return 1024
        }
    }

    /// hiResCache(PhotoPreviewView.swift) 개수
    func hiResCacheCount() -> Int {
        switch effectiveTier {
        case .low, .standard: return 2
        case .high:           return 3
        case .extreme:        return 5
        }
    }

    /// hiResCache 총 비용(MB)
    func hiResCacheCostMB() -> Int {
        switch effectiveTier {
        case .low:      return 100
        case .standard: return 150
        case .high:     return 300
        case .extreme:  return 500
        }
    }

    /// ThumbnailCache L1(ThumbnailGridView.swift) MB
    func thumbnailCacheMB() -> Int {
        switch effectiveTier {
        case .low:      return 100
        case .standard: return 150
        case .high:     return 300
        case .extreme:  return 500
        }
    }

    /// ImageAnalysisService 동시성
    func imageAnalysisConcurrency() -> Int {
        switch effectiveTier {
        case .low:      return 2
        case .standard: return 3  // crystal: 4 → 3 한 단계 더 조임
        case .high:     return 4
        case .extreme:  return 6
        }
    }

    /// 로컬 SSD 썸네일 로드 동시성
    func ssdThumbnailConcurrency() -> Int {
        switch effectiveTier {
        case .low:      return 2
        case .standard: return 3
        case .high:     return 4
        case .extreme:  return 6
        }
    }

    /// FileCopyService 동시성
    func fileCopyConcurrency() -> Int {
        switch effectiveTier {
        case .low:      return 2
        case .standard: return 3
        case .high:     return 4
        case .extreme:  return 6
        }
    }

    /// 프리뷰 최대 해상도 (0 = 원본)
    func previewMaxPixel() -> Int {
        switch effectiveTier {
        case .low:      return 3000
        case .standard: return 0    // original (기존 >= 16GB 동일)
        case .high:     return 0
        case .extreme:  return 0
        }
    }

    /// 미리보기 Stage1 (빠른 첫 표시) 해상도
    /// low 머신은 800px로 표시 즉응성 우선, high+는 1600px로 화질 우선
    func previewStage1MaxPixel() -> CGFloat {
        switch effectiveTier {
        case .low:      return 800
        case .standard: return 1200
        case .high:     return 1600
        case .extreme:  return 1600
        }
    }

    /// 미리보기 Stage2 (후속 고화질) 해상도. 0 = 원본
    /// low: stage2도 1600px로 메모리 절감 (스파이크 ~40% 축소)
    /// extreme: 원본 로드
    func previewStage2MaxPixel() -> CGFloat {
        switch effectiveTier {
        case .low:      return 1600
        case .standard: return 2400
        case .high:     return 3200
        case .extreme:  return 0    // 원본
        }
    }

    // MARK: - Storage 감지 (경로 기반 — ThumbnailLoader와 공유)

    /// 경로의 디스크가 느린 디스크(HDD/SD/NAS)인지 판단.
    /// PhotoPreviewView가 stage2 스킵 등 정책 결정에 사용.
    /// detectStorageType과 동일 로직 — 단순화 버전.
    static func isSlowDisk(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)

        // 1) 네트워크 볼륨 (NAS) — OS metadata 우선
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal, !isLocal {
            return true
        }

        // 2) 내장 디스크 = SSD (Apple Silicon Mac)
        if !path.hasPrefix("/Volumes/") {
            return false
        }

        // 3) 외장 볼륨 — SSD 힌트 우선 검사
        let volumeName = url.pathComponents.count >= 3 ? url.pathComponents[2].lowercased() : ""
        let ssdHints = ["ssd", "extreme", "samsung t", "sandisk extreme", "nvme", "thunderbolt", "portable ssd"]
        if ssdHints.contains(where: { volumeName.contains($0) }) {
            return false
        }

        // 4) 용량 ≤256GB → SD/USB 메모리로 추정 → slow
        let mountPoint = "/Volumes/" + (url.pathComponents.count >= 3 ? url.pathComponents[2] : "")
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mountPoint),
           let totalSize = attrs[.systemSize] as? Int64 {
            let sizeGB = totalSize / (1024 * 1024 * 1024)
            if sizeGB <= 256 { return true }
        }

        // 5) 그 외 외장 — HDD 가능성 → slow 취급
        return true
    }

    // MARK: - 디버깅/로그용 요약
    var debugSummary: String {
        """
        === SystemSpec ===
        Mac: \(macModelMarketing) (\(macModel))
        CPU: \(cpuBrand) (\(coreCount) cores)
        GPU: \(gpuName)
        RAM: \(ramGB)GB
        OS: \(osVersion)
        Auto Tier: \(autoTier.rawValue)
        User Profile: \(userProfile.rawValue)
        Effective Tier: \(effectiveTier.rawValue)
        ==================
        """
    }
}
