<!-- lang-switch -->
[English](README.md) | **한국어**
<!-- /lang-switch -->

# AWS 엔지니어를 위한 AKS + Terraform 실습 가이드

EKS·VPC·IAM 에 익숙한 엔지니어가 **Azure Best Practice** 로 프로덕션급 **AKS(Azure Kubernetes Service)** 를 **Terraform** 으로 구축하는 실습 가이드입니다.
각 실습은 독립된 Terraform 스택이며, 모든 코드는 `terraform fmt` · `validate` · `test` 를 통과한 실제 파일에서 문서로 가져왔습니다.

**온라인으로 보기:** [한국어 HTML 가이드](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.ko.html) · [영어 HTML 가이드](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.html)

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 전체 약 4–6시간 | 03–05 스택을 켜 둔 동안 시간당 약 $2–2.5 | `terraform/*` | [01. 사전 준비](labs/ko/01-prerequisites.md) |

> [!IMPORTANT]
> 이 가이드의 코드는 **정적 검증**(`terraform fmt`, `validate`, mock provider 기반 `terraform test`)에 더해, 2026-10-13 에 **실제 Azure 구독에서 Lab 01–11 을 처음부터 끝까지 실행**해 확인했습니다. 그때 발견한 불일치는 고쳤고, 확인하지 못한 항목(Spot 스케일 업, 업그레이드 실행 등)은 [부록 A](labs/ko/99-appendix.md)에 적어 두었습니다. 영문판을 만든 뒤에도 2026-10-14 에 같은 방식으로 처음부터 끝까지 다시 실행해 같은 결과를 확인했습니다. 구독의 쿼터 · 조직 정책 · 리전 용량에 따라 결과가 다를 수 있으니 처음 실행할 때는 `terraform plan` 결과를 꼭 읽어 보세요. 실습 후에는 [Lab 11](labs/ko/11-cleanup.md) 로 반드시 정리하세요(클러스터를 켜 둔 채 방치하면 비용이 계속 발생합니다).

## 기준 버전 (2026-10-13)

| 구성 요소 | 버전 | 메모 |
|---|---|---|
| Terraform | **1.16.5** | `required_version = "~> 1.16"` |
| azurerm provider | **5.9.0** | 5.0 GA(2026-07) 이후의 메이저 버전. 4.x 코드와 호환되지 않는 변경이 많습니다. |
| AzAPI provider | 2.13.0 | azurerm 이 아직 지원하지 않는 AKS 신기능(Gateway API 등) |
| kubernetes provider | 3.3.0 | 앱/네임스페이스 배포 |
| AKS Kubernetes | **1.36** (GA 최신, 1.36.4) | AKS 기본값은 1.35, 1.37 은 preview(Oct 2026 GA 예정) |
| Azure CLI | 2.86+ | |

## 학습 경로

| 실습 | 주제 | 핵심 내용 |
|---|---|---|
| [00](labs/ko/00-aws-azure-mapping.md) | **AWS ↔ Azure 비교** | 서비스·개념·명령어·Terraform 차이 총정리 |
| [01](labs/ko/01-prerequisites.md) | 사전 준비 | 도구, 로그인, RP 등록, 쿼터, 환경 변수 |
| [02](labs/ko/02-bootstrap.md) | 원격 State | S3+DynamoDB ↔ Blob, 이름 규칙 모듈, `terraform test` |
| [03](labs/ko/03-network.md) | 네트워크 | VNet, NSG, NAT Gateway, Private DNS |
| [04](labs/ko/04-platform.md) | 플랫폼 서비스 | ACR, Key Vault, Log Analytics, Prometheus, Grafana, AKS 용 ID |
| [05](labs/ko/05-aks.md) | **AKS 클러스터** | CNI Overlay+Cilium, API Server VNet Integration, Entra RBAC, 노드 풀, 관측성 |
| [06](labs/ko/06-workload-identity.md) | Workload Identity | IRSA ↔ Entra Workload ID, Key Vault CSI |
| [07](labs/ko/07-ingress.md) | 인그레스 | ALB Controller ↔ Gateway API(approuting-istio) |
| [08](labs/ko/08-governance.md) | 거버넌스·보안 | Azure Policy, Defender, 잠금, 예산 |
| [09](labs/ko/09-operations.md) | Day-2 운영 | 업그레이드, 스케일링, 노드 교체, 테스트/CI (kubectl 워크로드 운영: 부록 E) |
| [10](labs/ko/10-aks-automatic.md) | AKS Automatic | EKS Auto Mode 에 해당하는 완전 관리형 모드 |
| [11](labs/ko/11-cleanup.md) | 정리 | 역순 `destroy`, Key Vault soft-delete, 비용 확인 |
| [99](labs/ko/99-appendix.md) | 부록 | 트러블슈팅, 프로덕션 체크리스트, **접속 경로·인터넷 노출 요약(D)**, **kubectl 로 쿠버네티스 워크로드 다루기(E)**, 참고 자료, 테스트 코드 |

## 아키텍처 개요

![이 가이드가 만드는 전체 구조](labs/ko/diagrams/overview-architecture.svg)

스택은 수명주기별로 나뉘어 있고, 앞 스택의 결과를 이름 규칙(`modules/naming`)으로 조회해 뒤 스택이 이어받습니다.

![Terraform 스택 계층과 실행 순서](labs/ko/diagrams/stack-layers.svg)

## 빠른 시작

```bash
git clone https://github.com/junwoojeong100/aks-terraform.git && cd aks-terraform
az login && az account set --subscription "<구독>"
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TF_VAR_allowed_ip_ranges="[\"$(curl -s https://api.ipify.org)/32\"]"
scripts/preflight.sh                  # 도구 · 로그인 · 쿼터 · 권한 점검 (읽기 전용)

cd terraform/02-bootstrap && terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl
cd ../03-network && terraform init -backend-config=../backend.hcl && terraform apply
# … 04 → 05 → 06 → 07 → 08 순서로 같은 패턴

cd ../.. && scripts/verify.sh         # apply 한 스택이 설계대로 만들어졌는지 확인 (읽기 전용)
scripts/cleanup.sh --dry-run          # 실습을 마치면: 지울 목록 확인 → scripts/cleanup.sh (Lab 11)
```

자세한 단계는 [Lab 01](labs/ko/01-prerequisites.md) 부터 따라가세요. **단일 HTML 가이드**는 [온라인](https://junwoojeong100.github.io/aks-terraform/aks-terraform-guide.ko.html)에서 바로 보거나, 저장소의 `aks-terraform-guide.ko.html` 을 브라우저로 여세요(오프라인 동작, 검색/복사 버튼/다크 모드/진행 체크 지원).

## 언어

이 가이드는 **영어(기본)** 와 **한국어** 로 제공합니다. 한국어판은 `README.ko.md`, `labs/ko/`, `aks-terraform-guide.ko.html` 에 있습니다. 두 판이 같은 소스 파일을 그대로 가져오므로 Terraform 코드, 코드 주석, 스크립트 메시지는 영어로만 작성합니다.

## 실습 스크립트

손으로 치던 점검·확인·삭제 명령을 스크립트로 묶었습니다 (macOS · Linux · WSL · Cloud Shell, 필요: `terraform` `az` `jq` + 05 이후 `kubectl` `kubelogin`).

| 스크립트 | 용도 |
|---|---|
| `scripts/preflight.sh` | 시작 전 점검: 도구 · 로그인 · Resource Provider · vCPU 쿼터 · VM 크기 · 권한 (읽기 전용) |
| `scripts/verify.sh [스택…]` | 각 스택을 `apply` 한 뒤 결과 검증 (읽기 전용, `✓ ✗ !` 요약과 종료 코드) |
| `scripts/cleanup.sh` | 생성의 역순 삭제 · 잠금 해제 · 남은 리소스 점검 (`--dry-run` 으로 먼저 확인) |
| `tools/validate-all.sh` | Azure 없이 `fmt` · `validate` · `terraform test` + 스크립트 문법 검사 |

## 저장소 구조

```text
.
├── README.md                    # 영어(기본). README.ko.md 가 한국어판
├── aks-terraform-guide.html     # 모든 문서 + 모든 Terraform 코드 + 다이어그램 + 스크립트를 담은 단일 HTML (영어). aks-terraform-guide.ko.html 이 한국어판
├── labs/                        # 영어 실습 문서 (코드 블록은 terraform/, scripts/ 의 실제 파일에서 자동 동기화)
│   ├── diagrams/                # 다이어그램(SVG). tools/gen-diagrams.mjs 로 생성
│   └── ko/                      # 한국어 실습 문서 (자체 diagrams/ 포함)
├── terraform/
│   ├── modules/naming/          # 이름 규칙 모듈
│   ├── mocks/                   # terraform test 용 mock 값
│   └── 02-bootstrap … 10-aks-automatic/
├── scripts/                     # preflight.sh · verify.sh(+verify/) · cleanup.sh · lib/common.sh
└── tools/
    ├── validate-all.sh          # fmt + validate + test (Azure 불필요) + 스크립트 검사
    ├── sync-code.mjs            # md 의 코드 블록/숫자를 소스와 동기화
    ├── check-docs.mjs           # 문서 검사 (취소선 오인식, 깨진 링크/파일 경로, 언어 짝)
    ├── gen-diagrams.mjs         # 다이어그램(SVG)을 두 언어로 생성
    └── build-html.mjs           # md → 단일 HTML (영어 + 한국어)
```

## 검증과 HTML 재생성

```bash
tools/validate-all.sh                    # 모든 스택 정적 검증 + mock plan 테스트 + 스크립트 검사 (구독 불필요)

cd tools && npm install && npm run build  # 코드 동기화 + 문서 검사 + 다이어그램과 두 HTML 가이드 재생성
npm run check                             # md 의 코드/숫자가 소스와 일치하는지 + 문서 검사 (CI 용)
```

`main` 에 푸시하면 GitHub Actions(`.github/workflows/pages.yml`)가 깨끗한 체크아웃에서 같은 `npm run build` 를 실행하고, 두 HTML 가이드를 [GitHub Pages](https://junwoojeong100.github.io/aks-terraform/)로 배포합니다. 사이트는 푸시한 소스로 항상 새로 빌드되므로, 저장소에 있는 HTML 파일의 오프라인용 사본을 갱신하고 싶을 때만 로컬에서 빌드하면 됩니다.

## 참고 자료

- [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) · [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/)
- [Baseline architecture for an AKS cluster](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks) · [AKS Well-Architected 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service)
- [azurerm 5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide) · [Microsoft 공식 AKS Terraform 샘플](https://github.com/Azure/terraform/tree/master/quickstart)
