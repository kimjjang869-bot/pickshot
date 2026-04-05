#!/usr/bin/env python3
"""
NIMA (Neural Image Assessment) CoreML 변환 스크립트
idealo/image-quality-assessment → CoreML .mlmodel

사용법:
    pip install tensorflow coremltools pillow
    python convert_nima.py

출력:
    ../PhotoRawManager/Models/NIMAAesthetic.mlmodel
"""

import os
import sys
import urllib.request

# 모델 다운로드 URL (idealo GitHub releases)
MODEL_URL = "https://github.com/idealo/image-quality-assessment/releases/download/v0.3.0/weights_mobilenet_aesthetic_0.07.hdf5"
MODEL_FILE = "weights_mobilenet_aesthetic_0.07.hdf5"
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "PhotoRawManager", "Models")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "NIMAAesthetic.mlmodel")


def download_model():
    """NIMA MobileNet Aesthetic 모델 다운로드"""
    if os.path.exists(MODEL_FILE):
        print(f"[OK] 모델 파일 존재: {MODEL_FILE}")
        return

    print(f"[DOWNLOAD] {MODEL_URL}")
    print("  다운로드 중... (약 13MB)")
    urllib.request.urlretrieve(MODEL_URL, MODEL_FILE)
    print(f"[OK] 다운로드 완료: {MODEL_FILE}")


def build_nima_model():
    """NIMA MobileNet 모델 재구성 + 가중치 로딩"""
    import tensorflow as tf
    from tensorflow.keras.applications.mobilenet import MobileNet
    from tensorflow.keras.layers import Dense, Dropout
    from tensorflow.keras.models import Model

    # MobileNet base (ImageNet weights) + NIMA head
    base_model = MobileNet(
        input_shape=(224, 224, 3),
        include_top=False,
        pooling='avg',
        weights='imagenet'
    )

    x = Dropout(0.75)(base_model.output)
    x = Dense(10, activation='softmax')(x)

    model = Model(inputs=base_model.input, outputs=x)

    # NIMA 가중치 로딩
    model.load_weights(MODEL_FILE)
    print(f"[OK] 모델 구성 완료: {model.count_params():,} 파라미터")

    return model


def convert_to_coreml(model):
    """Keras 모델 → CoreML 변환"""
    import coremltools as ct

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # CoreML 변환
    mlmodel = ct.convert(
        model,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 224, 224, 3),
            scale=1.0/127.5,
            bias=[-1, -1, -1],  # MobileNet preprocessing: [0,255] → [-1,1]
        )],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
    )

    # 메타데이터
    mlmodel.author = "PickShot (idealo/image-quality-assessment)"
    mlmodel.short_description = "NIMA MobileNet Aesthetic - 사진 미적 품질 점수 (1~10)"
    mlmodel.version = "1.0"

    # 저장
    mlmodel.save(OUTPUT_FILE)
    file_size = os.path.getsize(OUTPUT_FILE) / (1024 * 1024)
    print(f"[OK] CoreML 변환 완료: {OUTPUT_FILE} ({file_size:.1f}MB)")


def test_model():
    """변환된 모델 테스트"""
    import coremltools as ct
    from PIL import Image
    import numpy as np

    print("\n[TEST] 모델 테스트...")
    mlmodel = ct.models.MLModel(OUTPUT_FILE)

    # 테스트 이미지 (그라데이션)
    test_img = Image.fromarray(
        np.random.randint(0, 255, (224, 224, 3), dtype=np.uint8)
    )

    result = mlmodel.predict({"image": test_img})
    output_key = list(result.keys())[0]
    probs = result[output_key]

    # Mean score 계산
    if hasattr(probs, 'flatten'):
        probs = probs.flatten()
    mean_score = sum(p * (i + 1) for i, p in enumerate(probs))

    print(f"  출력 키: {output_key}")
    print(f"  확률 분포: {[f'{p:.3f}' for p in probs]}")
    print(f"  미적 점수: {mean_score:.2f} / 10")
    print("[OK] 테스트 통과!")


if __name__ == "__main__":
    print("=" * 50)
    print("NIMA CoreML 변환")
    print("=" * 50)

    try:
        download_model()
        model = build_nima_model()
        convert_to_coreml(model)
        test_model()
        print("\n[완료] NIMAAesthetic.mlmodel 생성 성공!")
        print(f"  위치: {OUTPUT_FILE}")
        print("  Xcode에 드래그 앤 드롭하세요.")
    except ImportError as e:
        print(f"\n[ERROR] 필요한 패키지 설치:")
        print(f"  pip install tensorflow coremltools pillow")
        print(f"  오류: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
