# Raspberry Pi 5 카메라 점검·설정

Raspberry Pi OS **Bookworm**에서 카메라를 점검하고, 카메라 한 대를 **CAM/DISP0**에 설정하는 스크립트입니다. 기본 실행은 읽기 전용이며, 모델을 명시한 경우에만 부팅 설정을 변경합니다.

## 다운로드와 점검

파이의 터미널에서 실행합니다.

```bash
curl -fL https://raw.githubusercontent.com/WHLee-HGU/raspberry-pi-camera-setup/main/camera-setup.sh -o camera-setup.sh
bash camera-setup.sh --check
```

다운로드가 성공한 뒤 점검 명령을 실행하세요. 파일 내용은 [camera-setup.sh](camera-setup.sh)에서 확인할 수 있습니다. 인수 없이 `bash camera-setup.sh`를 실행해도 읽기 전용 점검입니다.

점검 결과에는 인식된 센서 모델, 소프트웨어 카메라 번호, 물리 CAM/DISP0 해당 여부가 표시됩니다. **소프트웨어 번호 `0`은 물리 CAM/DISP0을 뜻하지 않습니다.** 점검은 카메라 목록을 확인하며 실제 영상 촬영 검사는 별도로 실행합니다.

## 카메라에 맞는 설정 선택

카메라 모델을 확인한 뒤 아래에서 **한 가지**를 선택합니다.

| 대상 | 설정 명령 |
| --- | --- |
| 지원되는 카메라의 자동 인식 사용 | `sudo bash camera-setup.sh auto` |
| IMX708 카메라 한 대를 CAM/DISP0에 연결 | `sudo bash camera-setup.sh imx708` |
| IMX219 카메라 한 대를 CAM/DISP0에 연결 | `sudo bash camera-setup.sh imx219` |
| OV5647 카메라 한 대를 CAM/DISP0에 연결 | `sudo bash camera-setup.sh ov5647` |

설정을 변경했다면 재부팅합니다.

```bash
sudo reboot
```

재접속 후 다시 확인합니다.

```bash
bash camera-setup.sh --check
```

`auto`는 `camera_auto_detect=1`을 설정하고 알려진 단일 센서 고정 설정을 주석으로 남깁니다. 센서를 선택하면 `camera_auto_detect=0`과 `[all]` 아래 `dtoverlay=선택한센서,cam0`을 설정합니다.

Arducam **UC-A37 Rev.A(IMX708)**의 한 검증 사례에서는 같은 케이블 연결 상태에서 자동 인식은 실패하고, `imx708` 명시 설정 후 인식과 실제 영상 수신에 성공했습니다. 카메라가 다르면 필요한 설정도 다를 수 있습니다. 이 스크립트는 모든 제조사 카메라를 자동 판별하거나 전용 드라이버를 설치하는 도구가 아닙니다.

## 실제 영상 확인

HDMI 모니터를 직접 연결한 파이의 터미널에서:

```bash
rpicam-hello -t 0
```

VNC로 접속한 **파이 바탕화면의 터미널**에서:

```bash
rpicam-hello --qt-preview -t 0
```

종료는 명령을 실행한 터미널에서 `Ctrl+C`입니다. SSH 터미널 연결만으로 영상 창이 노트북에 전달되지는 않습니다.

## 변경 범위와 복원

- 변경 전에 원래 `config.txt`를 같은 폴더의 고유한 `.bak` 파일로 정확히 백업합니다. 백업 경로는 터미널에 표시됩니다.
- 같은 설정을 반복 실행하면 설정 줄이나 백업을 중복 추가하지 않습니다.
- 기존 단일 센서 설정은 주석으로 보존합니다. 여러 카메라, 알 수 없는 overlay, `include`, 조건부 카메라 설정은 자동 변경하지 않습니다.
- 변경 대상은 검증한 단순 교육용 이미지입니다. 비카메라 overlay는 `vc4-kms-v3d`, `dwc2`, `disable-bt`만 허용합니다. 다른 HAT·제조사 overlay가 있으면 수동 검토가 필요합니다. 읽기 전용 점검은 이런 경우에도 카메라 목록을 확인합니다.
- 패키지 설치, 네트워크·계정 변경, 자동 재부팅은 하지 않습니다.
- 복원하려면 출력된 원본 백업 파일을 `/boot/firmware/config.txt`로 되돌린 뒤 재부팅합니다.

카메라와 리본 케이블을 연결하거나 다시 삽입할 때는 **파이를 정상 종료하고 USB-C 전원을 분리**하세요. 커넥터의 핀 수와 접점 방향도 확인해야 합니다.

## 이 배포본의 SHA256

```text
25b4915388288dbfa6a867ac7d0e396e91962c8775883133d04c1d7ab88ae241
```

다운로드한 파일은 `sha256sum camera-setup.sh`로 확인할 수 있습니다. 저장소의 스크립트가 갱신되면 해당 버전의 해시를 사용해야 합니다.

## 참고 문서

- [Raspberry Pi 카메라 소프트웨어](https://www.raspberrypi.com/documentation/accessories/camera-software.html)
- [Arducam IMX708 설정](https://docs.arducam.com/Raspberry-Pi-Camera/Native-camera/12MP-IMX708/)
- [Arducam 카메라 커넥터와 케이블](https://docs.arducam.com/Raspberry-Pi-Camera/raspberry-pi-camera-pinout/)

저장소: [WHLee-HGU/raspberry-pi-camera-setup](https://github.com/WHLee-HGU/raspberry-pi-camera-setup)
