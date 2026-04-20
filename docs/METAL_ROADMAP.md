# Metal 적용 로드맵 (PickShot)

작성: 2026-04-21
현 버전: v8.7 (integration/v8.6.1-final)
관련 브랜치: `raw-metal-engine` (libraw + Metal RAW 파이프라인 WIP)

---

## 🔴 최고 우선순위 (사용자 체감 큼)

### 1. 실시간 히스토그램 (Metal compute)
- **현재**: CPU 픽셀 샘플링 + dict 카운트 → 5616×3744 이미지에 100-150ms
- **개선**: Metal compute shader + `atomic_uint` counter array → 3-5ms
- **설계**:
  ```metal
  kernel void histogram(texture2d<float, access::read> src,
                         device atomic_uint* binsR, binsG, binsB, binsL,
                         uint2 gid) {
      float4 px = src.read(gid);
      atomic_fetch_add_explicit(&binsR[int(px.r * 255)], 1, ...);
      // ... G, B, luminance
  }
  ```
- **가치**: 드래그 중 히스토그램 실시간 갱신 가능 → 프로 툴 느낌

### 2. 배치 내보내기 Metal 파이프라인
- **현재**: CIRAWFilter 장당 2-3초, 100장 5분
- **개선**: libraw decode + Metal develop → 100장 30초 (10배)
- **의존성**: `raw-metal-engine` 브랜치의 RawDevelopEngine 먼저 머지
- **가치**: 웨딩 사진가 대량 처리 (500+장) 시 핵심 경쟁력

### 3. Loupe (돋보기) Metal 화
- **현재**: 마우스 hover 마다 CGImage crop + NSImage resize (CPU 15-25ms)
- **개선**: Metal sampler + 직접 MTKView 렌더 → <1ms, hover 즉시 응답
- **설계**: 원본 CGImage → MTLTexture 1회 업로드, 드래그 시 sampler 좌표만 변경

### 4. 롤링 썸네일 preload
- **현재**: ThumbnailCache miss 시 메인 스레드 blocking 가능성 (막 수정함)
- **개선**: Metal blit encoder 로 배경 디코드 병렬화
- **우선순위**: 위 3번 비해 낮음 (이미 async 로 많이 해결됨)

---

## 🟡 중간 우선순위 (전문 기능)

### 5. 클리핑 오버레이 (Shift+H)
- **현재**: CIColorMatrix 3회 + CISourceOverCompositing = 30-50ms
- **개선**: Metal 커널 1 패스 (lum 계산 + 임계값 체크 + 색 출력) → 2-3ms
- **커널 스케치**:
  ```metal
  kernel void clipping_overlay(texture2d<float> src, texture2d<float, access::write> dst, uint2 gid) {
      float3 rgb = src.read(gid).rgb;
      float lum = dot(rgb, float3(0.333));
      float4 out = float4(0);
      if (lum > 0.98) out = float4(1,0,0,0.7);        // 과노출 빨강
      else if (lum < 0.02) out = float4(0,0,1,0.7);    // 저노출 파랑
      dst.write(out, gid);
  }
  ```

### 6. 커브 에디터 라이브 프리뷰
- **현재**: CIToneCurve 100ms/frame → 드래그 버벅
- **개선**: Metal 1D LUT 업로드 (256 entries) + fragment shader lookup → 5ms
- **설계**: CurveEditorView → DevelopSettings.curvePoints → 256-entry LUT → MTLTexture(1D) → shader 에서 `texture.sample(sampler, rgb.r)` 등

### 7. 얼룩말 과노출 경고 (미구현 신규)
- **목적**: 라이트룸식 대각선 줄무늬 애니메이션 for overexposed/underexposed 영역
- **Metal 로 간단**: 위 클리핑 + `sin(coords.x + time)` 줄무늬 패턴

### 8. 포커스 피킹 오버레이 (미구현 신규)
- **목적**: 선명한 영역 강조 (동영상 촬영자 수요)
- **Metal 커널**: Sobel edge detection → 임계값 초과 영역 빨강 마킹
  ```metal
  // 3x3 Sobel
  float gx = -1*tl -2*l -1*bl +1*tr +2*r +1*br;
  float gy = -1*tl -2*t -1*tr +1*bl +2*b +1*br;
  float edge = length(float2(gx, gy));
  ```

### 9. 수평 자동 보정 프리뷰
- **현재**: CIPerspectiveCorrection + CPU 100ms
- **개선**: Metal rotation + perspective transform 셰이더

---

## 🟢 장기 과제 (Pro 플랜 차별화)

### 10. RAW 현상 전체 Metal 파이프라인 ✅
- **상태**: `raw-metal-engine` 브랜치에 구현 완료 (WIP)
- **성능**: 5616×3744 real-time 20-30ms (50fps)
- **필요 작업**: 메인 머지 전 UX 안정화, 프로파일 시스템 완성

### 11. 노이즈 리덕션
- **Metal**: Non-Local Means (NLM) 또는 BM3D 근사
- **수요**: 고감도 촬영 (ISO 6400+) 시 필수
- **복잡도**: 높음, 2-3주 작업

### 12. 샤프닝 (Unsharp Mask)
- **Metal**: Gaussian blur → subtract → scale → add
- **간단**: 1-2일 작업

### 13. 렌즈 보정 (왜곡/비네팅)
- **Metal**: lens distortion polynomial + vignette falloff
- **DB**: lensfun 프로젝트 연동 (GPL issue 있음 — MIT 대체 검토)

### 14. AI 피처 추출 전처리
- **현재**: Apple Vision → ANE (Neural Engine)
- **개선**: Metal 로 이미지 정규화 + 크롭 + 리사이즈 → Vision 입력
- **효과**: 얼굴 검색 batch 처리 속도 향상

---

## ⚪ Metal 쓸 필요 없는 곳

- 썸네일 디코드: 이미 VideoToolbox HW decode 사용
- 스크롤 자체: SwiftUI/CoreAnimation 이 알아서 GPU 합성 — NSThumbnailCollectionView 활성화가 답
- 파일 I/O: SSD/네트워크 병목, Metal 무관
- Core ML 추론: ANE 가 훨씬 효율적
- EXIF 파싱: Metal 낭비

---

## 권장 구현 순서 (ROI 기준)

1. **히스토그램 Metal 화** (반나절) — 프로 느낌 + LUT 인프라 구축
2. **커브 에디터 라이브 프리뷰** (하루) — 히스토그램에서 만든 LUT 재활용
3. **Loupe Metal 화** (반나절) — 빠른 승, 즉각 체감
4. **클리핑 + 얼룩말** (하루) — 위 LUT/compute 인프라 활용
5. **포커스 피킹** (하루) — 영상 촬영자 대상 차별화
6. **배치 내보내기** (2-3일) — RAW 브랜치 머지 후
7. **샤프닝** (반나절) — Pro 플랜 기본 기능
8. **노이즈 리덕션** (2-3주) — 고급 Pro 기능
9. **렌즈 보정** (1-2주) — 최종 프로 폴리싱

각 단계는 독립적으로 가능. 히스토그램/커브/Loupe 3개는 **2일이면 끝나고** 사용자 체감 확 달라짐.

---

## 공유 인프라 설계 제안

Metal 적용이 많아지면 공통 인프라가 필요함:

```swift
// Services/Metal/MetalImageEngine.swift (새 파일)
class MetalImageEngine {
    static let shared = MetalImageEngine()
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // 공용 텍스처 풀 (크기별 재사용)
    private var texturePool: [MTLTextureDescriptor.Hash: [MTLTexture]] = [:]

    func acquireTexture(descriptor: MTLTextureDescriptor) -> MTLTexture { ... }
    func releaseTexture(_ texture: MTLTexture) { ... }
}
```

각 기능(histogram, curve, loupe)은 자체 `.metal` 파일 + Swift 래퍼 클래스로 모듈화.
