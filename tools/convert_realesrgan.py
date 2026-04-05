#!/usr/bin/env python3
"""
Real-ESRGAN → CoreML 변환 스크립트

PickShot의 SuperResolutionService에서 사용할 CoreML 모델을 생성합니다.
Real-ESRGAN x2 (경량) 모델을 다운로드하여 CoreML 형식으로 변환합니다.

사전 설치:
    pip install coremltools torch basicsr realesrgan

사용법:
    python convert_realesrgan.py

출력:
    RealESRGAN.mlpackage  (Xcode 프로젝트에 추가하여 사용)

변환 후 Xcode에서:
    1. RealESRGAN.mlpackage를 프로젝트에 드래그 앤 드롭
    2. Target Membership 확인
    3. 빌드 시 자동으로 .mlmodelc로 컴파일됨
"""

import os
import sys
import urllib.request

def check_dependencies():
    """필수 패키지 설치 확인"""
    missing = []
    for pkg in ['torch', 'coremltools', 'basicsr', 'realesrgan']:
        try:
            __import__(pkg)
        except ImportError:
            missing.append(pkg)

    if missing:
        print(f"[!] 누락된 패키지: {', '.join(missing)}")
        print(f"    설치: pip install {' '.join(missing)}")
        sys.exit(1)


def download_model(url: str, save_path: str):
    """모델 가중치 다운로드"""
    if os.path.exists(save_path):
        print(f"[+] 모델 파일 존재: {save_path}")
        return

    print(f"[*] 모델 다운로드 중: {url}")
    urllib.request.urlretrieve(url, save_path)
    print(f"[+] 다운로드 완료: {save_path}")


def convert_to_coreml():
    """Real-ESRGAN x2 모델을 CoreML로 변환"""
    import torch
    import coremltools as ct
    from realesrgan import RealESRGANer
    from basicsr.archs.rrdbnet_arch import RRDBNet

    print("[*] Real-ESRGAN x2 모델 구성 중...")

    # RRDBNet 아키텍처 (x2 경량 버전)
    model = RRDBNet(
        num_in_ch=3,
        num_out_ch=3,
        num_feat=64,
        num_block=23,
        num_grow_ch=32,
        scale=2
    )

    # 사전 학습 가중치 다운로드
    weight_url = (
        "https://github.com/xinntao/Real-ESRGAN/releases/download/"
        "v0.2.1/RealESRGAN_x2plus.pth"
    )
    weight_path = "RealESRGAN_x2plus.pth"
    download_model(weight_url, weight_path)

    # 가중치 로딩
    print("[*] 가중치 로딩 중...")
    loadnet = torch.load(weight_path, map_location=torch.device('cpu'))
    if 'params_ema' in loadnet:
        model.load_state_dict(loadnet['params_ema'], strict=True)
    elif 'params' in loadnet:
        model.load_state_dict(loadnet['params'], strict=True)
    else:
        model.load_state_dict(loadnet, strict=True)

    model.eval()

    # 입력 크기: 640x640 (썸네일 업스케일 용도)
    # 출력: 1280x1280 (2x)
    input_size = 640
    example_input = torch.rand(1, 3, input_size, input_size)

    print("[*] TorchScript 트레이싱 중...")
    with torch.no_grad():
        traced_model = torch.jit.trace(model, example_input)

    print("[*] CoreML 변환 중 (Neural Engine 최적화)...")
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.ImageType(
                name="input",
                shape=(1, 3, input_size, input_size),
                scale=1.0 / 255.0,
                bias=[0, 0, 0],
                color_layout="RGB"
            )
        ],
        outputs=[
            ct.ImageType(
                name="output",
                color_layout="RGB"
            )
        ],
        compute_units=ct.ComputeUnit.ALL,  # NPU + GPU + CPU
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",  # ML Program (ANE 최적화)
    )

    # 메타데이터 설정
    mlmodel.author = "PickShot"
    mlmodel.short_description = (
        "Real-ESRGAN x2 Super Resolution - "
        "썸네일을 2배 업스케일하여 선명한 프리뷰 제공"
    )
    mlmodel.version = "1.0"

    # 저장
    output_path = "RealESRGAN.mlpackage"
    mlmodel.save(output_path)
    print(f"[+] CoreML 모델 저장 완료: {output_path}")

    # 파일 크기 확인
    total_size = 0
    for dirpath, dirnames, filenames in os.walk(output_path):
        for f in filenames:
            fp = os.path.join(dirpath, f)
            total_size += os.path.getsize(fp)

    size_mb = total_size / (1024 * 1024)
    print(f"    모델 크기: {size_mb:.1f} MB")
    print(f"\n[*] 사용법:")
    print(f"    1. {output_path}를 Xcode 프로젝트에 추가")
    print(f"    2. Target Membership에서 PickShot 체크")
    print(f"    3. 빌드하면 SuperResolutionService가 자동으로 NPU 활용")

    # 가중치 파일 정리
    if os.path.exists(weight_path):
        os.remove(weight_path)
        print(f"[+] 임시 파일 삭제: {weight_path}")


if __name__ == "__main__":
    print("=" * 60)
    print("  Real-ESRGAN → CoreML 변환기 (PickShot)")
    print("=" * 60)
    print()

    check_dependencies()
    convert_to_coreml()

    print()
    print("[+] 완료!")
