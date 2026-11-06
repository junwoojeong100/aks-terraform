<!-- lang-switch -->
[English](README.md) | **한국어**
<!-- /lang-switch -->

# Azure 실배포 실습 녹화 · 2026-11-06

**실제 Azure에 Terraform을 실행한 별도의 무해설 실습 영상**입니다. 유튜브용 내레이션·편집본과는 다릅니다.
기준 소스: [`f9b7c04`](https://github.com/junwoojeong100/aks-terraform/tree/f9b7c047467f28e9ad2d430422bd69e3520ddbe8).

| 파일 | 내용 |
|---|---|
| [실습 동영상](AKS_Terraform_Live_Lab_2026-11-06_1080p.mp4) | 49분 41초, 53.26 MB, 1920×1080, 10 fps, H.264/AAC, 무음, 챕터 19개 |
| [챕터](chapters.txt) | 사전 준비·생성·정책 진단·검증·정리 구간 |
| [터미널 녹화](lab.cast) | asciinema v2 통합 녹화 |
| [실행 근거](evidence.json) | 실제 명령 결과·시간·해시·구성·실검증·정리·인코딩 QA |
| `commands/*.cast` | 실패도 보존한 개별 실제 명령 녹화 |
| [backend override](recording_override.tf.example) | 실제 사용한 녹화 전용 override와 근거 파일의 해시 |

연속 데스크톱 화면 캡처나 가상 Azure 포털이 아닌 **실제 터미널 출력의 충실한 replay**입니다.
실행한 프로세스의 출력과 명령 내부 대기를 기록했습니다. 10 fps로 시간을 반올림하고 약 1초의 읽기 여유를 더했으며,
명령 사이의 준비 공백은 생략했습니다. 계정 식별자·사용자·관리자 IP·로컬 경로는 가렸지만 결과나 리소스 수를 꾸며 넣지 않았습니다.

## 실제 실행 범위

| 항목 | 관찰한 구성·결과 |
|---|---|
| 지역·클러스터 | Korea Central / AKS Standard / Kubernetes 1.36.5 |
| 컴퓨트 | System 2 + User 1, `Standard_D4ds_v5`, 가용 영역 1만 사용, autoscaler 상·하한 고정 |
| 네트워크 | CNI Overlay, Cilium, NAT Gateway, API Server VNet Integration |
| 관리자 API | 녹화 장비 IP로 제한한 공개 API, 로컬 계정 비활성화 |
| 스택 | 02-bootstrap → 03-network → 04-platform → 05-aks → 07-ingress |
| 모니터링 | 실제 workspace 생성, Grafana 비활성화, Log Analytics 일일 cap 1 GB |
| 실검증 | Azure Succeeded, 인증된 API, Ready 노드 3개, 웹 rollout, Gateway Programmed, HTTP 200 |
| 정리 | 실제 역순 destroy와 데모 리소스 그룹이 없는 최종 조회 |

이 단일 AZ 축소 구성은 **가이드의 운영 HA 토폴로지가 아니며**, 과거 가이드의 비용 추정도 이번 실습의 실제 청구액이 아닙니다.

## 정책과 검증 한계

상속된 조직 정책이 새 state 저장소의 공개 네트워크 접근을 꺼서 원래 Blob backend 초기화가 실제 HTTP 403으로 실패했습니다.
정책 예외나 공개 접근 변경은 하지 않았습니다. 실제 적용한 03·04·05·07 스택은 기록한 **local backend override**를 사용했고,
state·plan은 Git에서 제외되고 접근이 제한된 녹화 작업 영역에만 보관했습니다.
**Blob 원격 상태 이전 성공을 보여주는 실행이 아닙니다.** 공동 배포에는 승인된 사설 backend 접근 경로가 필요하며,
임시 실습의 local state 선택을 공동 환경에 그대로 복사하지 마세요.

볼트 공개 접근은 **Disabled**이고 메타데이터 조회 probe는 **ForbiddenByRbac**으로 거부되었습니다.
이를 네트워크 오류만의 증거로 해석하지 않습니다. 별도 볼트 데이터 역할이나 사설 실행 경로는 추가하지 않았으며,
**06-workload의 실제 비밀 mount 검증은 수행하지 않았습니다.** 비밀 값도 읽거나 출력하지 않았습니다.
원본의 권한 예제, DNS·NSG 실험, Spot scale-up, 실제 업그레이드, Automatic 스택을 이번 실행이 새로 검증한 것은 아닙니다.
웹 listener는 HTTP 80이며 운영 TLS 검증이 아닙니다.

AKS 조회 중 CLI의 `serviceconnector` 모듈 로딩 진단이 나왔으나 명령은 성공으로 종료했고,
별도의 API·노드·앱 검증도 통과했습니다. 해당 출력도 지우지 않았습니다.
정리 시 Key Vault purge protection과 soft-delete 보존 기간을 유지했고 purge하지 않았습니다.
실제 보존 기간과 삭제 결과는 `evidence.json`에 있습니다.

유튜브용 내레이션 편집본·제작 코드·자막은 별도
[`build-and-run-it/ep03-aks-terraform`](https://github.com/junwoojeong100/build-and-run-it/tree/main/ep03-aks-terraform)에 있습니다.
녹화·replay 생성 코드는 그 리포의 `src/live.py`, `src/live_media.py`이며, 기존 공개 cast를 영상으로 만드는 작업은 Azure 리소스를 다시 생성하지 않습니다.
