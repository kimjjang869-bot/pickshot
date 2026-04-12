#!/usr/bin/env python3
"""
NIMA Technical Quality CoreML 변환 스크립트
idealo/image-quality-assessment → CoreML .mlmodel

기술적 품질: 선명도, 노이즈, 노출, 색상 정확성 등
미적 품질(NIMAAesthetic)과 함께 사용하면 종합 품질 점수 정확도 향상

사용법:
    pip install tensorflow coremltools pillow
    python convert_nima_technical.py

출력:
    ../PhotoRawManager/Models/NIMATechnical.mlmodel
"""

import os
import sys
import urllib.request

# Technical Quality 모델
MODEL_URL = "https://github.com/idealo/image-quality-assessment/releases/download/v0.3.0/weights_mobilenet_technical_0.11.hdf5"
MODEL_FILE = "weights_mobilenet_technical_0.11.hdf5"
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "..", "PhotoRawManager", "Models")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "NIMATechnical.mlmodel")


def download_model():
    if os.path.exists(MODEL_FILE):
        print(f"[OK] 모델 파일 존재: {MODEL_FILE}")
        return
    print(f"[DOWNLOAD] {MODEL_URL}")
    urllib.request.urlretrieve(MODEL_URL, MODEL_FILE)
    print(f"[OK] 다운로드 완료: {MODEL_FILE}")


def build_nima_model():
    import tensorflow as tf
    from tensorflow.keras.applications.mobilenet import MobileNet
    from tensorflow.keras.layers import Dense, Dropout
    from tensorflow.keras.models import Model

    base_model = MobileNet(
        input_shape=(224, 224, 3),
        include_top=False,
        pooling='avg',
        weights='imagenet'
    )
    x = Dropout(0.75)(base_model.output)
    x = Dense(10, activation='softmax')(x)
    model = Model(inputs=base_model.input, outputs=x)
    model.load_weights(MODEL_FILE)
    print(f"[OK] Technical 모델 구성 완료: {model.count_params():,} 파라미터")
    return model


def convert_to_coreml(model):
    import coremltools as ct
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    mlmodel = ct.convert(
        model,
        inputs=[ct.ImageType(
            name="image",
            shape=(1, 224, 224, 3),
            scale=1.0/127.5,
            bias=[-1, -1, -1],
        )],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
    )

    mlmodel.author = "PickShot (idealo/image-quality-assessment)"
    mlmodel.short_description = "NIMA MobileNet Technical - 사진 기술적 품질 점수 (1~10)"
    mlmodel.version = "1.0"

    mlmodel.save(OUTPUT_FILE)
    file_size = os.path.getsize(OUTPUT_FILE) / (1024 * 1024)
    print(f"[OK] CoreML 변환 완료: {OUTPUT_FILE} ({file_size:.1f}MB)")


if __name__ == "__main__":
    print("=" * 50)
    print("NIMA Technical CoreML 변환")
    print("=" * 50)

    try:
        download_model()
        model = build_nima_model()
        convert_to_coreml(model)
        print(f"\n[완료] NIMATechnical.mlmodel 생성 성공!")
    except ImportError as e:
        print(f"\n[ERROR] pip install tensorflow coremltools pillow")
        sys.exit(1)
    except Exception as e:
        print(f"\n[ERROR] {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
