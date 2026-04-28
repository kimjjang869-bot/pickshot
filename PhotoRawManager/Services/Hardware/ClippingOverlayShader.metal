//
//  ClippingOverlayShader.metal
//  PhotoRawManager
//
//  클리핑 오버레이 — 한 번의 dispatch 로 과노출(빨강) + 저노출(파랑) 마스크 생성.
//  Core Image 3-filter chain (30-50ms) 을 single compute kernel (2-3ms) 로 대체.
//

#include <metal_stdlib>
using namespace metal;

struct ClippingParams {
    float overExposureThreshold;   // 0.98 기본 (RGB 하나라도 이 값 이상이면 과노출)
    float underExposureThreshold;  // 0.02 기본 (RGB 셋 다 이 값 이하면 저노출)
    float overlayAlpha;            // 0.70 기본 (오버레이 투명도)
};

kernel void clipping_overlay(
    texture2d<float, access::read>  inTexture  [[texture(0)]],
    texture2d<float, access::write> outTexture [[texture(1)]],
    constant ClippingParams& p                 [[buffer(0)]],
    uint2 gid                                  [[thread_position_in_grid]]
) {
    if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) return;

    float3 rgb = inTexture.read(gid).rgb;

    // 과노출: RGB 최대값이 임계값 초과 → 빨강
    float maxC = max(max(rgb.r, rgb.g), rgb.b);
    bool over = maxC > p.overExposureThreshold;

    // 저노출: RGB 최소값이 임계값 미만 → 파랑
    float minC = min(min(rgb.r, rgb.g), rgb.b);
    bool under = minC < p.underExposureThreshold;

    float4 result;
    if (over) {
        result = float4(1.0, 0.0, 0.0, p.overlayAlpha);
    } else if (under) {
        result = float4(0.0, 0.0, 1.0, p.overlayAlpha);
    } else {
        result = float4(0.0);  // 투명 — 원본 이미지 그대로 보임
    }

    outTexture.write(result, gid);
}
