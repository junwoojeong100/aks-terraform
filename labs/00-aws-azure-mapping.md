# AWS ↔ Azure 인프라 서비스 비교 (EKS 경험자용)

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 읽기 30분 | 없음 | (없음) | 없음 |

이 문서는 **AWS(EKS, VPC, IAM …)에 익숙한 엔지니어**가 Azure/AKS 를 빠르게 이해하도록 서비스·개념·Terraform 차이를 한 곳에 정리한 것입니다.
이후 모든 실습의 코드에는 `# AWS 의 … 에 해당` 형태의 주석이 달려 있으니, 막히면 이 표로 돌아오세요.

> [!NOTE]
> 공식 비교 자료: [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/) 와
> [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) (Microsoft 가 유지보수).
> 이 가이드의 표는 위 자료와 AKS 최신 문서(2026-10 기준)를 바탕으로 실습에 필요한 부분만 추렸습니다.

## 1. 먼저 바꿔야 할 사고방식 10가지

| # | AWS 에서의 직관 | Azure 에서는 |
|---|---|---|
| 1 | 계정(Account)이 격리·청구·권한 경계 | **구독(Subscription)** 이 청구·쿼터 경계, **리소스 그룹(RG)** 이 수명주기·권한·삭제 단위. 모든 리소스는 반드시 RG 안에 있어야 합니다. |
| 2 | IAM 사용자/역할/정책 JSON 을 직접 작성 | **Microsoft Entra ID**(디렉터리) + **Azure RBAC**: "누가(주체) + 무슨 역할 + 어느 범위(scope)" 를 *역할 할당* 으로 연결. 대부분 내장 역할을 씁니다. |
| 3 | 서브넷은 AZ 하나에 속함 | **서브넷은 리전 전체**에 걸쳐 있고, 가용 영역(AZ)은 VM·노드 풀·로드밸런서 같은 **리소스의 속성**입니다. |
| 4 | Security Group(상태 저장) + NACL(상태 비저장) | **NSG** 하나가 두 역할을 합니다: 상태 저장, 우선순위(숫자 작을수록 먼저), Allow/Deny 모두 가능. 서브넷 또는 NIC 에 연결. |
| 5 | Private subnet + NAT Gateway(라우트 테이블 수정) | NAT Gateway 를 **서브넷에 직접 연결**합니다. 라우트 테이블이 필요 없고, 기본 아웃바운드 IP 에 의존하는 방식은 단계적으로 폐지 중입니다. |
| 6 | Gateway/Interface VPC Endpoint | **Private Endpoint** (사설 IP 를 서비스에 할당) + **Private DNS Zone** 을 직접 구성. 자동 "Private DNS 활성화" 옵션이 없습니다. |
| 7 | Role + 신뢰 정책(Trust policy) | 리소스형 ID인 **Managed Identity**(UAMI) 를 만들고, 대상 리소스에 **역할 할당**을 추가. 키/시크릿 없음. |
| 8 | S3 + DynamoDB 로 Terraform state 잠금 | **Blob Storage** 하나로 충분: 잠금은 blob lease 로 자동 처리, 인증은 Entra ID(RBAC). |
| 9 | 서비스 사용 시 별도 활성화 불필요(대부분) | 구독마다 **Resource Provider(RP) 등록**이 필요합니다(`Microsoft.ContainerService` 등). azurerm 5.x 는 자동 등록하지 않습니다. |
| 10 | EKS 는 내 계정에 노드(EC2)가 그대로 보임 | AKS 노드는 별도의 **노드 리소스 그룹**(`MC_...` 또는 지정한 이름)에 만들어지고 AKS 가 관리합니다. |

## 2. 조직·계정·리전

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| AWS Organizations 루트 | **Entra 테넌트** + 루트 관리 그룹 | 테넌트는 디렉터리(사용자·앱)이고, 관리 그룹은 구독을 묶는 계층입니다. |
| OU | **관리 그룹(Management Group)** | 정책·역할 할당이 하위 구독으로 상속됩니다. |
| 계정 | **구독(Subscription)** | 쿼터(vCPU 등)·청구 단위. 리전별/VM 패밀리별 vCPU 쿼터를 미리 확인하세요. |
| (없음) | **리소스 그룹(Resource Group)** | 수명주기가 같은 리소스를 묶는 컨테이너. 삭제하면 안의 리소스가 모두 삭제됩니다. 태그/잠금/RBAC 범위로도 사용. |
| SCP | **Azure Policy** + RBAC | SCP 는 권한 상한선, Azure Policy 는 *리소스 속성*을 평가/강제하는 규칙입니다(감사·거부·자동 수정). |
| Region / AZ | Region / **Availability Zone** | `koreacentral` 은 AZ 3개를 제공합니다. 영역 번호(1,2,3)는 구독마다 물리 AZ 에 매핑이 다를 수 있습니다. |
| 리소스 ARN | **리소스 ID** | `/subscriptions/<id>/resourceGroups/<rg>/providers/<RP>/<type>/<name>` 형태. Terraform 에서 `id` 로 서로 참조합니다. |
| 태그 | **태그** | 대소문자 구분 없음(키), 리소스 그룹 태그는 자동 상속되지 않습니다(Policy 로 상속 가능). 비용 분석 필터로 사용. |

## 3. 네트워킹

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| VPC | **Virtual Network (VNet)** | 리전 단위. 주소 공간 여러 개 가능. |
| Subnet (AZ 고정) | **Subnet** (AZ 비종속) | 서브넷에 **위임(delegation)** 을 걸어 특정 서비스(AKS API 서버 등)가 전용으로 쓰게 할 수 있습니다. |
| Security Group / NACL | **NSG**, ASG(Application Security Group) | NSG 는 서브넷/NIC 에 연결. ASG 는 SG 참조처럼 "논리 그룹" 을 규칙에서 쓰게 해 줍니다. |
| Internet Gateway | (별도 리소스 없음) | 공인 IP 가 있으면 인터넷 연결. 아웃바운드는 NAT/LB/방화벽 중 하나를 명시. |
| NAT Gateway + EIP | **NAT Gateway** + Public IP | `StandardV2` SKU 는 영역 중복(zone-redundant). 서브넷에 연결. |
| VPC Endpoint (Interface) | **Private Endpoint** | PaaS 별 `privatelink.*` Private DNS Zone 이 필요합니다. |
| VPC Endpoint (Gateway: S3/DDB) | **Service Endpoint** | 서브넷 → PaaS 공용 엔드포인트를 Azure 백본으로 라우팅. 신규 설계는 Private Endpoint 권장. |
| Route 53 (Public/Private zone) | **Azure DNS**, **Private DNS Zone** | Private Zone 은 VNet 링크로 해석 범위를 지정. |
| ALB / NLB | **Application Gateway**(L7), **Azure Load Balancer**(L4), **Front Door**(글로벌 L7) | AKS 에서는 Gateway API 구현 또는 **Application Gateway for Containers** 가 ALB Controller 의 대응입니다. |
| Transit Gateway / VPC Peering | **VNet Peering**, **Virtual WAN** | 허브-스포크: 허브에 Azure Firewall/Bastion/VPN, 스포크에 워크로드. |
| Network Firewall | **Azure Firewall** | 이 실습은 비용을 위해 NAT Gateway 를 쓰고, 방화벽 구성은 부록에서 다룹니다. |
| VPC Flow Logs | **VNet Flow Logs** | NSG flow logs 는 신규 생성이 중단되고 VNet flow logs 로 대체되었습니다. |

> [!IMPORTANT]
> **IP 계획이 달라집니다.** EKS 의 VPC CNI 는 파드마다 VPC IP 를 소모하지만, AKS 권장 구성인 **Azure CNI Overlay** 는 노드만 VNet IP 를 쓰고 파드는 별도 CIDR(`pod_cidr`)을 씁니다. 파드 CIDR 은 VNet/온프레미스와 겹치지만 않으면 됩니다.

## 4. ID·권한·시크릿

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| IAM User/Group | **Entra ID 사용자/그룹** | 로그인·MFA·조건부 액세스는 Entra 에서 관리합니다. |
| IAM Role (사람/서비스가 Assume) | **Managed Identity**(리소스에 부여) + **서비스 주체** | System-assigned(리소스 수명과 동일) / **User-assigned(UAMI, 독립 리소스)**. AKS 는 UAMI 를 권장. |
| IAM Policy (JSON) | **Role Definition + Role Assignment** | 내장 역할(Contributor, AcrPull …) 선택 → *범위(scope)* 에 할당. 사용자 정의 역할도 JSON. |
| Permission boundary | (없음) / Azure Policy, ABAC 조건 | 할당 조건(ABAC)으로 일부 구현. |
| STS AssumeRole | 토큰 발급(Entra) | 앱은 SDK 의 `DefaultAzureCredential` 로 자동 획득. |
| Instance profile | **Managed Identity** (VM/VMSS) | 노드(kubelet) ID 가 여기에 해당. |
| IRSA / EKS Pod Identity | **Microsoft Entra Workload ID** | 클러스터 **OIDC issuer** + **Federated credential**(issuer+subject) + SA annotation `azure.workload.identity/client-id`. IRSA 와 구조가 거의 같습니다. |
| KMS | **Key Vault**(Keys) / Managed HSM | 서비스 암호화 키(CMK) 관리. |
| Secrets Manager / Parameter Store | **Key Vault**(Secrets) / App Configuration | AKS 에서는 **Secrets Store CSI Driver** 로 마운트. |
| ACM | **Key Vault**(Certificates) / App Service 인증서 | Gateway TLS 인증서는 Key Vault 에서 동기화. |
| CloudTrail | **Activity Log** + **Diagnostic settings** | 관리 평면은 Activity Log, 데이터 평면(KV 접근 등)은 진단 설정으로 Log Analytics 에 보냅니다. |

## 5. 컨테이너·쿠버네티스 (EKS ↔ AKS)

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| EKS (Standard) | **AKS Standard** | 컨트롤 플레인은 둘 다 관리형. 업타임 SLA 는 AKS **Standard 티어**(유료)부터. |
| EKS Auto Mode | **AKS Automatic** | 노드·스케일·업그레이드·보안 기본값까지 맡기는 모드. 2026 년 현재 Microsoft 는 "대부분의 신규 프로덕션 워크로드에 Automatic" 을 권장합니다 → Lab 10. |
| Managed node group (ASG) | **Node pool** (VMSS) | **System 풀**(CoreDNS 등 시스템 파드)과 **User 풀**(앱)을 분리합니다. System 풀은 3노드/4 vCPU 이상 권장. |
| Karpenter | **Node Auto Provisioning (NAP)** | AKS 가 Karpenter 를 관리형으로 운영. Standard 에서는 선택, Automatic 에서는 기본. |
| Cluster Autoscaler | **Cluster Autoscaler** | 노드 풀별 min/max. 가용 영역별 풀 균형(`balance_similar_node_groups`). |
| Fargate | Virtual nodes (ACI) / **Container Apps** | 서버리스 파드는 AKS 에 1:1 대응이 없어 별도 서비스를 고려합니다. |
| ECR | **ACR** | Private Endpoint/지역 복제/영역 중복은 Premium. 노드 pull 권한은 `AcrPull` 역할. |
| VPC CNI | **Azure CNI Overlay + Cilium** | Cilium(eBPF)이 kube-proxy 와 NetworkPolicy 를 대체. kubenet 은 신규 클러스터에 비권장. |
| AWS Load Balancer Controller (ALB) | **App Routing Gateway API**(approuting-istio), **Application Gateway for Containers** | ingress-nginx 는 2026-03 유지보수 종료 → Gateway API 로 이동 → Lab 07. |
| EBS CSI / EFS CSI | **Azure Disk CSI / Azure Files CSI** | 기본 설치·활성화되어 있습니다. |
| EKS access entries (`aws-auth` 대체) | **Azure RBAC for Kubernetes** (+ Kubernetes RBAC) | 로컬 계정(정적 kubeconfig)은 **끄는 것**이 권장입니다. `kubelogin` 으로 토큰 로그인. |
| EKS control plane logging | **Diagnostic settings** (`kube-audit-admin`, `kube-apiserver` …) | Log Analytics 로 전송. `kube-audit` 은 양이 많아 `kube-audit-admin` 을 권장. |
| EKS 업그레이드(수동/Extended Support) | **자동 업그레이드 채널**(`patch`, `stable` …) + **유지보수 창** | 12 개월 지원. 지원 종료 버전은 2027-06 부터 플랫폼이 자동 업그레이드합니다. |
| Container Insights / AMP / AMG | **Container Insights**(로그) / **Managed Prometheus** / **Managed Grafana** | Azure Monitor 로 통합. DCR/DCRA 로 수집 구성을 연결합니다 → Lab 05. |
| GuardDuty EKS / Inspector | **Microsoft Defender for Containers** | 구독 단위 플랜 + 클러스터 프로필. |
| AWS Config / Kyverno | **Azure Policy for Kubernetes**(Gatekeeper) | 정책 이니셔티브를 RG/구독 범위에 할당 → Lab 08. |
| EKS 가격: 클러스터당 시간 요금 | AKS: **Free / Standard / Premium** 티어 | Free 는 SLA 없음. Standard 는 클러스터당 시간 요금(공식 가격표 확인). Premium 은 LTS 포함. |

> [!TIP]
> **AKS 의 노드 리소스 그룹**: 클러스터 RG(예: `rg-...-aks`) 와 별개로 VMSS·LB·디스크가 들어 있는 노드 RG(`rg-...-aks-nodes`) 가 생깁니다. 직접 수정하지 마세요(Automatic 은 아예 잠깁니다).

## 6. 스토리지·상태 저장

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| S3 | **Blob Storage** (Storage Account → Container) | 계정 이름이 전역 고유(소문자+숫자 3~24자). 버전 관리·소프트 삭제는 계정 옵션. |
| DynamoDB(락) | (불필요) | azurerm backend 는 blob lease 로 잠금. |
| EBS | **Managed Disk** | Premium SSD v2 / Ultra 등. Ephemeral OS 디스크는 노드 로컬 저장소 사용. |
| EFS | **Azure Files** (NFS/SMB) | AKS 기본 CSI 드라이버 포함. |

## 7. 비용 관리

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| Budgets | **Cost Management 예산** | `azurerm_consumption_budget_subscription` + 태그 필터 → Lab 08. |
| Savings Plans / RI | **Reservations / Savings plan** | 노드 VM 에도 적용 가능. |
| Spot Instances | **Spot VM** (Spot 노드 풀) | 중단 시 `Delete`/`Deallocate`. 파드에 toleration 필요. |
| Cost Explorer(EKS) | **AKS 비용 분석 애드온** | 네임스페이스/워크로드 단위 비용 보기 (`cost_analysis_enabled`). |

## 8. Terraform 관점의 차이

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| `provider "aws"` | `provider "azurerm"` (+ `azapi`, `azuread`) | **azurerm** = 핵심 리소스, **azapi** = ARM API 직접 호출(신기능·미지원 속성), **azuread** = Entra 객체. AWS 의 `awscc` 와 위치가 비슷합니다. |
| 자격 증명: `AWS_PROFILE`, SSO | `az login` + `ARM_SUBSCRIPTION_ID` | CI 에서는 **OIDC(Workload identity federation)** 로 비밀번호 없이 로그인. |
| `terraform-aws-modules` | **Azure Verified Modules (AVM)** | 공식 검증 모듈. 이 실습은 학습을 위해 리소스를 직접 정의합니다(운영에서는 AVM 도 고려). |
| 리소스에 `tags` | 리소스에 `tags` + **리소스 그룹 필수** | `resource_group_name` 인수가 거의 모든 리소스에 필요. |
| S3 backend | **azurerm backend** (`use_azuread_auth = true`) | 키 인증 대신 Entra 인증/RBAC 사용. |
| 데이터 소스(`data "aws_vpc"`) | `data "azurerm_virtual_network"` | 이 실습은 스택 간 연결에 remote state 대신 **이름 규칙 + data source** 를 사용합니다. |
| 삭제 보호/Soft delete | Key Vault soft-delete / purge protection, 리소스 잠금 | `terraform destroy` 후에도 이름이 일정 기간 점유될 수 있습니다 → Lab 11. |

> [!WARNING]
> **azurerm 5.x(2026-07 GA) 주요 변경**: Resource Provider 자동 등록 기본값 `none`, `azurerm_kubernetes_cluster` 의 `node_provisioning_profile` 블록 필수화, `azurerm_key_vault` 의 `rbac_authorization_enabled` 필수화, 많은 `enable_*` 인수가 `*_enabled` 로 정리됨. 4.x 코드를 복사하면 `terraform validate` 단계에서 오류가 납니다.

## 9. 명령어 치트시트

| AWS | Azure | 차이 / 주의 |
|---|---|---|
| `aws sts get-caller-identity` | `az account show` | 현재 구독/테넌트/사용자 확인 |
| `aws configure sso` / `aws sso login` | `az login` | `az account set --subscription <id>` 로 구독 선택 |
| `aws eks update-kubeconfig --name x` | `az aks get-credentials -g <rg> -n x` + `kubelogin convert-kubeconfig -l azurecli` | Entra 로그인은 kubelogin 이 처리 |
| `aws ecr get-login-password \| docker login` | `az acr login -n <acr>` | `az acr import` 로 외부 이미지를 ACR 로 서버 측 복사 |
| `aws ec2 describe-vpcs` | `az network vnet list -o table` | `-o table`, `--query`(JMESPath) 사용 |
| `aws iam list-attached-role-policies` | `az role assignment list --assignee <id> --all -o table` | 역할 할당 조회 |
| `aws logs start-query` | `az monitor log-analytics query -w <id> --analytics-query "…"` | KQL 사용 |
| `aws service-quotas get-service-quota` | `az vm list-usage -l koreacentral -o table` | vCPU 패밀리별 쿼터 |
| `eksctl upgrade` | `az aks get-upgrades -g <rg> -n <name>` → `az aks upgrade` | 이 실습: patch 는 자동 업그레이드 채널, minor 는 사전 점검 후 `az aks upgrade`(Lab 09). Terraform 은 생성 이후 버전을 `ignore_changes` 로 무시합니다(코드로 버전까지 관리하는 방법도 Lab 09 에 있습니다). |

## 10. 이 실습이 따르는 Best Practice (요약)

- **상태/구조**: 수명주기별 스택 분리(network → platform → aks → workload), Entra 인증 remote state, provider 버전 고정, `terraform fmt/validate/test` 자동 검증.
- **네트워크**: Azure CNI Overlay + Cilium, NAT Gateway(StandardV2) 로 고정 egress, 서브넷 default outbound 비활성화, Private Endpoint(ACR/Key Vault).
- **ID/보안**: UAMI + 역할 할당, **로컬 계정 비활성화**, Entra + Azure RBAC, Workload Identity, Key Vault RBAC·purge protection, ACR 익명/관리자 계정 비활성화, Azure Policy, Defender.
- **가용성/운영**: Standard 티어(SLA), 가용 영역 3곳 분산, System/User 풀 분리, PDB·HPA·topology spread, 유지보수 창 + 자동 패치 업그레이드.
- **관측성**: Managed Prometheus + Container Insights(DCR) + Managed Grafana, 컨트롤 플레인 진단 로그.
- **비용**: 일일 로그 상한, 예산 알림, Spot 풀(선택), 실습 후 `terraform destroy`.

다음 → [01. 사전 준비](01-prerequisites.md)
