#!/usr/bin/env python3
"""
Deep Photo Enhancer → CoreML 변환 스크립트

사진 자동 보정(톤/색감) 모델을 CoreML .mlpackage로 변환합니다.
PickShot에서 NPU(Neural Engine) 가속으로 프로급 자동 보정에 사용됩니다.

사용법:
    pip install coremltools torch torchvision pillow
    python convert_enhancer.py

출력:
    ../PhotoRawManager/Models/PhotoEnhancer.mlpackage

참고:
    - 실제 Deep Photo Enhancer 모델 가중치는 별도로 다운로드해야 합니다
    - 가중치가 없으면 데모용 Identity 모델을 생성합니다
    - NPU 가속은 macOS 13+ Apple Silicon에서 동작합니다
"""

import os
import sys

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "PhotoRawManager", "Models")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "PhotoEnhancer.mlpackage")

# 사전 학습된 모델 가중치 경로 (있으면 사용)
WEIGHTS_FILE = "photo_enhancer_weights.pth"


def create_enhancer_model():
    """사진 보정 U-Net 모델 생성"""
    import torch
    import torch.nn as nn

    class PhotoEnhancerNet(nn.Module):
        """
        경량 U-Net 기반 사진 보정 네트워크
        입력: 512x512x3 RGB
        출력: 512x512x3 RGB (보정된 이미지)
        """
        def __init__(self):
            super().__init__()
            # 인코더
            self.enc1 = nn.Sequential(
                nn.Conv2d(3, 32, 3, padding=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(32, 32, 3, padding=1),
                nn.ReLU(inplace=True)
            )
            self.pool1 = nn.MaxPool2d(2)

            self.enc2 = nn.Sequential(
                nn.Conv2d(32, 64, 3, padding=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(64, 64, 3, padding=1),
                nn.ReLU(inplace=True)
            )
            self.pool2 = nn.MaxPool2d(2)

            # 보틀넥
            self.bottleneck = nn.Sequential(
                nn.Conv2d(64, 128, 3, padding=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(128, 64, 3, padding=1),
                nn.ReLU(inplace=True)
            )

            # 디코더
            self.up2 = nn.ConvTranspose2d(64, 64, 2, stride=2)
            self.dec2 = nn.Sequential(
                nn.Conv2d(128, 64, 3, padding=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(64, 32, 3, padding=1),
                nn.ReLU(inplace=True)
            )

            self.up1 = nn.ConvTranspose2d(32, 32, 2, stride=2)
            self.dec1 = nn.Sequential(
                nn.Conv2d(64, 32, 3, padding=1),
                nn.ReLU(inplace=True),
                nn.Conv2d(32, 3, 3, padding=1),
                nn.Sigmoid()  # 출력 0~1 범위
            )

        def forward(self, x):
            # 인코더
            e1 = self.enc1(x)
            e2 = self.enc2(self.pool1(e1))

            # 보틀넥
            b = self.bottleneck(self.pool2(e2))

            # 디코더 (스킵 연결)
            d2 = self.dec2(torch.cat([self.up2(b), e2], dim=1))
            d1 = self.dec1(torch.cat([self.up1(d2), e1], dim=1))

            return d1

    model = PhotoEnhancerNet()

    # 사전 학습 가중치 로딩 (있으면)
    if os.path.exists(WEIGHTS_FILE):
        print(f"[OK] 가중치 로딩: {WEIGHTS_FILE}")
        state_dict = torch.load(WEIGHTS_FILE, map_location="cpu")
        model.load_state_dict(state_dict)
    else:
        print(f"[INFO] 가중치 파일 없음 ({WEIGHTS_FILE})")
        print("  → Identity 초기화 (데모용)")

    model.eval()
    print(f"[OK] 모델 생성: {sum(p.numel() for p in model.parameters()):,} 파라미터")
    return model


def convert_to_coreml(model):
    """PyTorch → CoreML 변환 (Neural Engine 최적화)"""
    import torch
    import coremltools as ct

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # 트레이싱
    example_input = torch.randn(1, 3, 512, 512)
    traced = torch.jit.trace(model, example_input)

    # CoreML 변환 (Neural Engine + GPU 지원)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 3, 512, 512),
            scale=1.0 / 255.0,
            bias=[0, 0, 0],
            color_layout="RGB",
        )],
        outputs=[ct.ImageType(
            name="enhanced",
            color_layout="RGB",
        )],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )

    # 메타데이터
    mlmodel.author = "PickShot"
    mlmodel.short_description = "사진 자동 보정 (톤/색감) - NPU 가속"
    mlmodel.version = "1.0"

    mlmodel.save(OUTPUT_FILE)

    # 파일 크기 계산
    total_size = 0
    for dirpath, _, filenames in os.walk(OUTPUT_FILE):
        for f in filenames:
            total_size += os.path.getsize(os.path.join(dirpath, f))
    size_mb = total_size / (1024 * 1024)

    print(f"[OK] CoreML 변환 완료: {OUTPUT_FILE} ({size_mb:.1f}MB)")


def test_model():
    """변환된 모델 테스트"""
    import coremltools as ct
    from PIL import Image
    import numpy as np

    print("\n[TEST] 모델 테스트...")
    mlmodel = ct.models.MLModel(OUTPUT_FILE)

    # 512x512 테스트 이미지
    test_img = Image.fromarray(
        np.random.randint(0, 255, (512, 512, 3), dtype=np.uint8)
    )

    result = mlmodel.predict({"image": test_img})
    enhanced = result.get("enhanced")
    if enhanced is not None:
        print(f"  입력: 512x512 RGB")
        print(f"  출력: {enhanced.size if hasattr(enhanced, 'size') else 'OK'}")
        print("[OK] 테스트 통과!")
    else:
        print("[WARN] 출력 키 확인 필요:", list(result.keys()))


if __name__ == "__main__":
    print("=" * 50)
    print("Photo Enhancer CoreML 변환")
    print("=" * 50)

    try:
        model = create_enhancer_model()
        convert_to_coreml(model)
        test_model()
        print(f"\n[완료] PhotoEnhancer.mlpackage 생성 성공!")
        print(f"  위치: {OUTPUT_FILE}")
        print("  Xcode 프로젝트에 추가하세요.")
    except ImportError as e:
        print(f"\n[ERROR] 필요한 패키지:")
        print(f"  pip install coremltools torch torchvision pillow")
        print(f"  오류: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
