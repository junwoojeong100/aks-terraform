# AWS 엔지니어를 위한 AKS + Terraform 실습 가이드

EKS·VPC·IAM 에 익숙한 엔지니어가 **Azure Best Practice** 로 프로덕션급 **AKS(Azure Kubernetes Service)** 를 **Terraform** 으로 구축하는 실습 가이드입니다.
각 실습은 독립된 Terraform 스택이며, 모든 코드는 `terraform fmt` · `validate` · `test` 를 통과한 실제 파일에서 문서로 가져왔습니다.

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 전체 약 4–6시간 | 03–05 스택을 켜 둔 동안 시간당 약 $2–2.5 | `terraform/*` | [01. 사전 준비](labs/01-prerequisites.md) |

> [!IMPORTANT]
> 이 가이드의 코드는 **정적 검증**(`terraform fmt`, `validate`, mock provider 기반 `terraform test`)까지 마친 상태입니다. 실제 Azure 구독에 `apply` 해서 확인한 결과가 아니므로, 처음 실행할 때는 `terraform plan` 결과를 꼭 읽어 보세요. 실습 후에는 [Lab 11](labs/11-cleanup.md) 로 반드시 정리하세요(클러스터를 켜 둔 채 방치하면 비용이 계속 발생합니다).

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
| [00](labs/00-aws-azure-mapping.md) | **AWS ↔ Azure 비교** | 서비스·개념·명령어·Terraform 차이 총정리 |
| [01](labs/01-prerequisites.md) | 사전 준비 | 도구, 로그인, RP 등록, 쿼터, 환경 변수 |
| [02](labs/02-bootstrap.md) | 원격 State | S3+DynamoDB ↔ Blob, 이름 규칙 모듈, `terraform test` |
| [03](labs/03-network.md) | 네트워크 | VNet, NSG, NAT Gateway, Private DNS |
| [04](labs/04-platform.md) | 플랫폼 서비스 | ACR, Key Vault, Log Analytics, Prometheus, Grafana, AKS 용 ID |
| [05](labs/05-aks.md) | **AKS 클러스터** | CNI Overlay+Cilium, API Server VNet Integration, Entra RBAC, 노드 풀, 관측성 |
| [06](labs/06-workload-identity.md) | Workload Identity | IRSA ↔ Entra Workload ID, Key Vault CSI |
| [07](labs/07-ingress.md) | 인그레스 | ALB Controller ↔ Gateway API(approuting-istio) |
| [08](labs/08-governance.md) | 거버넌스·보안 | Azure Policy, Defender, 잠금, 예산 |
| [09](labs/09-operations.md) | Day-2 운영 | 업그레이드, 스케일링, 노드 교체, 테스트/CI |
| [10](labs/10-aks-automatic.md) | AKS Automatic | EKS Auto Mode 에 해당하는 완전 관리형 모드 |
| [11](labs/11-cleanup.md) | 정리 | 역순 `destroy`, Key Vault soft-delete, 비용 확인 |
| [99](labs/99-appendix.md) | 부록 | 트러블슈팅, 프로덕션 체크리스트, 참고 자료, 테스트 코드 |

## 아키텍처 개요

```text
 02-bootstrap ─► remote state (Blob, Entra 인증)
 03-network   ─► VNet · 서브넷 · NSG · NAT Gateway · Private DNS
 04-platform  ─► ACR · Key Vault · Log Analytics · Azure Monitor(Prometheus) · Grafana · AKS 용 UAMI
 05-aks       ─► AKS Standard (zones 1-3, CNI Overlay+Cilium, Entra RBAC, Workload ID, Gateway API)
 06-workload  ─► UAMI + Federated credential + Key Vault CSI 데모
 07-ingress   ─► Gateway/HTTPRoute + 데모 앱(PDB, HPA, NetworkPolicy)
 08-governance─► Azure Policy · Defender · 잠금 · 예산
 10-aks-automatic ─► (선택) AKS Automatic
```

## 빠른 시작

```bash
git clone https://github.com/junwoojeong100/aks-terraform.git && cd aks-terraform
az login && az account set --subscription "<구독>"
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export TF_VAR_allowed_ip_ranges="[\"$(curl -s https://api.ipify.org)/32\"]"

cd terraform/02-bootstrap && terraform init && terraform apply
terraform output -raw backend_hcl > ../backend.hcl
cd ../03-network && terraform init -backend-config=../backend.hcl && terraform apply
# … 04 → 05 → 06 → 07 → 08 순서로 같은 패턴
```

자세한 단계는 [Lab 01](labs/01-prerequisites.md) 부터 따라가세요. **단일 HTML 가이드**는 `aks-terraform-guide.html` 을 브라우저로 여세요(오프라인 동작, 검색/복사 버튼/다크 모드/진행 체크 지원).

## 저장소 구조

```text
.
├── README.md
├── aks-terraform-guide.html     # 모든 문서 + 모든 Terraform 코드를 담은 단일 HTML
├── labs/                        # 실습별 md (코드 블록은 terraform/ 의 실제 파일에서 자동 동기화)
├── terraform/
│   ├── modules/naming/          # 이름 규칙 모듈
│   ├── mocks/                   # terraform test 용 mock 값
│   └── 02-bootstrap … 10-aks-automatic/
└── tools/
    ├── validate-all.sh          # fmt + validate + test (Azure 불필요)
    ├── sync-code.mjs            # md 의 코드 블록을 terraform/ 파일과 동기화
    └── build-html.mjs           # md → 단일 HTML
```

## 검증과 HTML 재생성

```bash
tools/validate-all.sh                    # 모든 스택 정적 검증 + mock plan 테스트 (구독 불필요)

cd tools && npm install && npm run build  # md 코드 동기화 + aks-terraform-guide.html 재생성
npm run check                             # md 의 코드가 소스와 일치하는지 확인 (CI 용)
```

## 참고 자료

- [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) · [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/)
- [Baseline architecture for an AKS cluster](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks) · [AKS Well-Architected 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service)
- [azurerm 5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide) · [Microsoft 공식 AKS Terraform 샘플](https://github.com/Azure/terraform/tree/master/quickstart)
