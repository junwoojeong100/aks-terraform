# Lab 01. 사전 준비: 도구, 로그인, 권한, 환경 변수

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 20–30분 | 없음 | (없음) | [00. AWS ↔ Azure 비교](00-aws-azure-mapping.md) |

## 이번 실습의 목표

- Azure CLI·Terraform·kubectl·kubelogin·jq 설치와 버전 확인
- Azure 로그인, 구독 선택, 필요한 권한 확인
- **Resource Provider(RP) 등록**과 vCPU **쿼터** 확인 (AWS 에는 없는 단계입니다)
- 이후 모든 실습에서 공유할 **환경 변수** 설정
- **`scripts/preflight.sh`** 한 번으로 위 항목을 자동 점검

- [ ] Azure 구독이 있고 **Owner**(또는 Contributor + User Access Administrator) 권한이 있다
- [ ] `terraform version` 이 1.16 이상이다
- [ ] `az version` 의 azure-cli 가 2.86 이상이다
- [ ] kubectl, kubelogin, jq 가 설치되어 있다
- [ ] `scripts/preflight.sh` 가 실패(✗) 없이 끝난다

## 1. 도구 설치

| 도구 | 최소 버전 | 용도 |
|---|---|---|
| Terraform | 1.16 | IaC (이 가이드는 1.16.5 로 검증) |
| Azure CLI | 2.86 | 로그인, 쿼터/RP 조회, `az acr import`, `az aks get-credentials` |
| kubectl | 클러스터 ±1 minor | 쿠버네티스 CLI |
| kubelogin | 최신 | Entra ID 토큰으로 kubectl / Terraform `kubernetes` provider 인증 |
| jq | 최신 | 검증 스크립트(`scripts/verify.sh`)가 `az`/`kubectl` 의 JSON 결과를 읽을 때 사용 |

```bash
# macOS (Homebrew)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform azure-cli kubectl Azure/kubelogin/kubelogin jq
```

```powershell
# Windows (winget)
winget install Hashicorp.Terraform Microsoft.AzureCLI Kubernetes.kubectl Azure.Kubelogin jqlang.jq
```

> [!NOTE]
> `scripts/` 의 셸 스크립트는 **macOS · Linux · WSL · Azure Cloud Shell(bash)** 에서 동작합니다. Windows PowerShell 에서는 WSL 또는 Git Bash 를 쓰세요.

> [!TIP]
> 어느 OS 에서든 Azure CLI 만 설치했다면 `az aks install-cli` 한 번으로 **kubectl 과 kubelogin** 을 함께 설치할 수 있습니다.

```bash
terraform version        # Terraform v1.16.x
az version -o table      # azure-cli 2.86 이상
kubectl version --client
kubelogin --version
```

## 2. 로그인과 구독 선택

AWS 의 `aws sso login` / `AWS_PROFILE` 에 해당하는 단계입니다. Terraform 은 **Azure CLI 로그인 정보**를 그대로 사용합니다.

```bash
az login                                   # 브라우저 로그인 (MFA 포함)
az account list -o table                   # 구독 목록
az account set --subscription "<구독 이름 또는 ID>"
az account show -o table                   # 현재 구독/테넌트/사용자 확인
```

### 필요한 권한

| 작업 | 필요한 Azure RBAC 역할 | 이유 |
|---|---|---|
| 리소스 생성 | Contributor | RG, VNet, AKS, ACR 등 |
| 역할 할당 생성 | **User Access Administrator** 또는 Owner | 이 실습은 `azurerm_role_assignment` 를 많이 만듭니다 (AcrPull, Network Contributor …) |
| 정책 할당 (Lab 08) | Resource Policy Contributor 또는 Owner | `azurerm_resource_group_policy_assignment` |

> [!NOTE]
> `azuread` provider(Entra 그룹 생성 등)는 사용하지 않으므로 **Entra ID 관리자 권한은 필요하지 않습니다.**
> 실습 편의상 클러스터 관리자(Lab 05/10), ACR Push·Grafana Admin(Lab 04) 같은 사람용 권한은 "현재 로그인한 사용자"에게 Azure RBAC 역할로 부여합니다(`grant_current_user_admin` / `grant_current_user_roles` 변수, 기본값 `true`).
> **팀/CI 환경에서는 이 변수를 `false` 로 두고 Entra 그룹의 Object ID 를 `admin_principal_ids` 로 지정**하세요. 개인 계정에 직접 권한을 주면 담당자가 바뀔 때마다 코드가 흔들립니다.

## 3. Resource Provider 등록

Azure 는 서비스별로 **Resource Provider(RP)** 를 구독에 등록해야 해당 리소스를 만들 수 있습니다. azurerm 5.x 부터는 provider 가 RP 를 자동 등록하지 않으므로(기본값 `none`), 한 번만 직접 등록합니다.

```bash
RPS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault \
Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor \
Microsoft.Dashboard Microsoft.AlertsManagement Microsoft.ManagedIdentity Microsoft.PolicyInsights \
Microsoft.Security Microsoft.Authorization Microsoft.Consumption Microsoft.CostManagement"

for rp in $RPS; do az provider register --namespace "$rp" > /dev/null; done

# 등록은 비동기입니다. 모두 Registered 가 될 때까지 확인 (보통 1~5분)
for rp in $RPS; do printf "%-36s %s\n" "$rp" "$(az provider show -n "$rp" --query registrationState -o tsv)"; done
```

## 4. vCPU 쿼터 확인

기본 구성은 **D4ds_v5 (4 vCPU)** 노드를 최소 6대(System 3 + User 3) 쓰고, 업그레이드 시 임시 노드(surge)가 더 생깁니다. 권장 여유는 **40 vCPU** 입니다(최소 24 vCPU + surge 분).

```bash
az vm list-usage --location koreacentral \
  --query "[?name.value=='cores' || name.value=='standardDDSv5Family'].{name:name.localizedValue, used:currentValue, limit:limit}" -o table

# 사용할 VM 크기가 해당 리전/영역에서 사용 가능한지 확인
az vm list-skus --location koreacentral --size Standard_D4ds_v5 --query "[].{name:name, zones:locationInfo[0].zones, restrictions:restrictions}" -o json
```

> [!WARNING]
> `restrictions` 에 `NotAvailableForSubscription` 이 있으면 그 VM 크기/영역은 구독에서 쓸 수 없습니다. 쿼터가 부족하면 포털의 *쿼터* 메뉴나 지원 요청으로 증설하거나, 변수 `system_node_vm_size`/`user_node_vm_size`(Lab 05)를 바꾸세요.

## 5. 환경 변수 설정

모든 스택이 공통으로 읽는 값입니다. **새 터미널을 열 때마다 다시 실행**하세요(`env.sh` 파일로 저장해 두면 편합니다).

```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"   # azurerm 4.x 이후 필수
export TF_VAR_workload="aksdemo"        # 3~8자 소문자/숫자. 리소스 이름에 사용됩니다
export TF_VAR_environment="dev"         # dev | test | prod
export TF_VAR_location="koreacentral"   # AKS Automatic 도 지원하는 리전
# API 서버/ACR/Key Vault 방화벽에서 허용할 "내 공인 IP" (JSON 배열 형식)
export TF_VAR_allowed_ip_ranges="[\"$(curl -s https://api.ipify.org)/32\"]"
echo "$TF_VAR_allowed_ip_ranges"
```

```powershell
# Windows PowerShell
$env:ARM_SUBSCRIPTION_ID = (az account show --query id -o tsv)
$env:TF_VAR_workload = "aksdemo"
$env:TF_VAR_environment = "dev"
$env:TF_VAR_location = "koreacentral"
$ip = (Invoke-RestMethod https://api.ipify.org)
$env:TF_VAR_allowed_ip_ranges = "[`"$ip/32`"]"
```

> [!IMPORTANT]
> 회사 VPN/프록시를 쓰거나 네트워크가 바뀌면 공인 IP 가 달라집니다. 그러면 Key Vault·ACR·API 서버 접근이 막히므로 `TF_VAR_allowed_ip_ranges` 를 갱신하고 해당 스택을 다시 `apply` 하세요.

## 6. 한 번에 점검하기: preflight 스크립트

위 3–5단계를 손으로 하나씩 확인하는 대신, **읽기 전용** 점검 스크립트를 실행하세요. 아무것도 만들거나 바꾸지 않습니다.

```bash
scripts/preflight.sh
# 다른 리전을 쓴다면: LOCATION=japaneast scripts/preflight.sh
```

| 점검 항목 | 실패하면 |
|---|---|
| 도구와 버전 (terraform 1.16+, az 2.86+, kubectl, kubelogin, jq) | 설치 안내가 함께 출력됩니다 |
| Azure 로그인과 구독 | `az login` |
| `ARM_SUBSCRIPTION_ID`, `TF_VAR_allowed_ip_ranges` 형식 | 5단계의 `export` 를 다시 실행 |
| 필수 Resource Provider 17개 등록 여부 | 등록 명령(`az provider register …`)을 그대로 출력 |
| vCPU 쿼터 (D4ds_v5 패밀리 · 리전 전체, 최소 24 / 권장 40) | 포털에서 증설 |
| VM 크기가 영역 1·2·3 에서 사용 가능하고 제한이 없는지 | `zones`/VM 크기 변수 조정 |
| Owner 등 역할 할당 권한 | 권한 요청 (그룹으로 받은 권한은 목록에 안 보일 수 있어 경고로 표시) |

<!-- tf:include path="scripts/preflight.sh" -->
```bash title="scripts/preflight.sh"
#!/usr/bin/env bash
# 실습 시작 전 점검 (읽기 전용): 도구 · 로그인 · 환경 변수 · Resource Provider · vCPU 쿼터 · VM 크기 · 권한
# Lab 01 의 확인 절차를 한 번에 실행합니다. 아무것도 만들거나 바꾸지 않습니다.
#
# 사용법:
#   scripts/preflight.sh
#   LOCATION=japaneast scripts/preflight.sh      # 다른 리전 (기본: TF_VAR_location 또는 koreacentral)
#
# 종료 코드: 실패 항목이 없으면 0, 있으면 1
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

LOCATION="${LOCATION:-${TF_VAR_location:-koreacentral}}"
VM_SIZE="${VM_SIZE:-Standard_D4ds_v5}"
VM_FAMILY="${VM_FAMILY:-standardDDSv5Family}" # VM_SIZE 를 바꿨다면 `az vm list-usage` 의 패밀리 이름으로 함께 바꾸세요.
MIN_VCPU=24                                   # 기본 구성의 최소 노드 6대 x 4 vCPU
REC_VCPU=40                                   # 업그레이드 임시 노드(surge)와 오토스케일 여유까지
RESOURCE_PROVIDERS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault
Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor Microsoft.Dashboard
Microsoft.AlertsManagement Microsoft.ManagedIdentity Microsoft.PolicyInsights Microsoft.Security Microsoft.Authorization
Microsoft.Consumption Microsoft.CostManagement"

# need 명령 최소버전 설치안내 : 명령이 있고 버전이 충분한지 확인
need() {
  local cmd="$1" min="$2" hint="$3" ver=""
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$cmd 가 없습니다 → $hint"
    return
  fi
  case "$cmd" in
    terraform) ver="$(terraform version 2>/dev/null | sed -n '1s/^Terraform v//p')" ;;
    az) ver="$(az version --query '"azure-cli"' -o tsv 2>/dev/null)" ;;
    kubectl) ver="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)" ;;
  esac
  if [ -n "$min" ] && [ -n "$ver" ]; then
    if version_ge "$ver" "$min"; then pass "$cmd $ver (최소 $min)"; else fail "$cmd $ver → 최소 $min 필요: $hint"; fi
  else
    pass "$cmd${ver:+ $ver}"
  fi
}

# check_quota 이름 여유vCPU
check_quota() {
  if [ -z "$2" ]; then
    warn "$1: 조회하지 못했습니다 (az vm list-usage -l $LOCATION)"
  elif [ "$2" -lt "$MIN_VCPU" ]; then
    fail "$1 여유 $2 vCPU → 최소 $MIN_VCPU 필요 (포털 → 구독 → 사용량 + 할당량 에서 증설)"
  elif [ "$2" -lt "$REC_VCPU" ]; then
    warn "$1 여유 $2 vCPU (업그레이드 임시 노드까지 고려하면 $REC_VCPU 권장)"
  else
    pass "$1 여유 $2 vCPU"
  fi
}

section "1. 도구"
need terraform 1.16 "brew install hashicorp/tap/terraform (또는 tfenv)"
need az 2.86 "brew install azure-cli"
need kubectl "" "az aks install-cli"
need kubelogin "" "az aks install-cli"
need jq "" "brew install jq  /  sudo apt install jq   (검증 스크립트가 사용)"
need curl "" "OS 패키지 관리자로 설치"

section "2. Azure 로그인"
acct=""
if command -v az >/dev/null 2>&1; then acct="$(azj account show)"; fi
if [ -z "$acct" ]; then
  fail "로그인되어 있지 않습니다 → az login"
  summary
  exit 1
fi
sub_id="$(jv "$acct" .id)"
pass "구독: $(jv "$acct" .name) ($sub_id)"
info "테넌트 $(jv "$acct" .tenantId) · 로그인 $(jv "$acct" .user.name)"

section "3. 환경 변수"
if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
  fail "ARM_SUBSCRIPTION_ID 가 없습니다 → export ARM_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
elif [ "$ARM_SUBSCRIPTION_ID" != "$sub_id" ]; then
  warn "ARM_SUBSCRIPTION_ID($ARM_SUBSCRIPTION_ID)가 현재 az 구독($sub_id)과 다릅니다"
else
  pass "ARM_SUBSCRIPTION_ID 가 현재 구독과 일치합니다"
fi
if [ -z "${TF_VAR_allowed_ip_ranges:-}" ]; then
  fail "TF_VAR_allowed_ip_ranges 가 없습니다 → export TF_VAR_allowed_ip_ranges='[\"<내 공인 IP>/32\"]'"
elif jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$"))' \
  >/dev/null 2>&1 <<<"$TF_VAR_allowed_ip_ranges"; then
  pass "TF_VAR_allowed_ip_ranges = $TF_VAR_allowed_ip_ranges"
else
  fail "TF_VAR_allowed_ip_ranges 형식 오류 (CIDR 문자열의 JSON 배열이어야 합니다): $TF_VAR_allowed_ip_ranges"
fi
if [ -n "${TF_VAR_workload:-}" ]; then
  if printf '%s' "$TF_VAR_workload" | grep -Eq '^[a-z0-9]{3,8}$'; then pass "TF_VAR_workload = $TF_VAR_workload"; else fail "TF_VAR_workload 는 소문자/숫자 3–8자여야 합니다: $TF_VAR_workload"; fi
fi

section "4. Resource Provider 등록 (azurerm 5.x 는 자동 등록하지 않습니다)"
registered="$(az provider list --query "[?registrationState=='Registered'].namespace" -o tsv 2>/dev/null)"
missing=""
for rp in $RESOURCE_PROVIDERS; do
  printf '%s\n' "$registered" | grep -qix "$rp" || missing="$missing $rp"
done
if [ -z "$missing" ]; then
  pass "필요한 Resource Provider 모두 등록됨"
else
  fail "미등록:$missing"
  info "등록: for rp in$missing; do az provider register --namespace \$rp; done   (1–5분 소요)"
fi

section "5. vCPU 쿼터 ($LOCATION)"
usage="$(azj vm list-usage -l "$LOCATION")"
check_quota "$VM_FAMILY 패밀리" "$(jv "$usage" ".[] | select(.name.value == \"$VM_FAMILY\") | (.limit | tonumber) - (.currentValue | tonumber)")"
check_quota "리전 전체(Total Regional vCPUs)" "$(jv "$usage" '.[] | select(.name.value == "cores") | (.limit | tonumber) - (.currentValue | tonumber)')"

section "6. VM 크기 ($VM_SIZE @ $LOCATION)"
skus="$(azj vm list-skus -l "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines)"
sku="$(jv "$skus" "[.[] | select(.name == \"$VM_SIZE\")][0]")"
if [ -z "$sku" ] || [ "$sku" = "null" ]; then
  fail "$VM_SIZE 를 $LOCATION 에서 찾을 수 없습니다 (다른 크기/리전을 쓰려면 Lab 05 의 *_node_vm_size, location 변수를 바꾸세요)"
else
  zones="$(jv "$sku" '[.locationInfo[0].zones[]?] | sort | join(",")')"
  if [ "$zones" = "1,2,3" ]; then pass "가용 영역 1,2,3 모두 사용 가능"; else warn "사용 가능한 영역: ${zones:-없음} (var.zones 를 이에 맞게 줄이세요)"; fi
  if [ "$(jv "$sku" '[.restrictions[]?] | length')" = "0" ]; then pass "구독 제한(restrictions) 없음"; else fail "이 구독에서 $VM_SIZE 사용이 제한되어 있습니다 (restrictions)"; fi
fi

section "7. 권한 (이 실습은 역할 할당을 많이 만듭니다)"
me="$(jv "$acct" .user.name)"
roles="$(az role assignment list --assignee "$me" --all --include-inherited --query '[].roleDefinitionName' -o tsv 2>/dev/null)"
if printf '%s\n' "$roles" | grep -qx 'Owner'; then
  pass "Owner 역할 보유"
elif printf '%s\n' "$roles" | grep -qx 'Contributor' && printf '%s\n' "$roles" | grep -qxE 'User Access Administrator|Role Based Access Control Administrator'; then
  pass "Contributor + 역할 할당 권한 보유"
elif [ -z "$roles" ]; then
  warn "역할을 조회하지 못했습니다 (그룹으로 받은 권한은 보이지 않을 수 있음). 포털 → 구독 → 액세스 제어(IAM)에서 확인하세요."
else
  warn "Owner 또는 Contributor + User Access Administrator 가 필요합니다. 확인된 역할: $(printf '%s' "$roles" | tr '\n' ',')"
fi

summary
```
<!-- /tf:include -->

> [!NOTE]
> 스크립트들이 함께 쓰는 공통 함수(`scripts/lib/common.sh`)는 [부록 G](99-appendix.md) 에 있습니다. 실행 결과의 `✓ 통과 / ✗ 실패 / ! 경고 / - 건너뜀` 은 모든 검증 스크립트가 같은 형식으로 보여 줍니다.

## 7. 저장소 구조

```text
aks-terraform/
├── README.md                    # 개요
├── aks-terraform-guide.html     # ← 이 가이드의 단일 HTML 버전
├── labs/                        # 실습별 문서(md)
│   └── diagrams/                # 문서에 쓰인 다이어그램(SVG)
├── terraform/
│   ├── modules/naming/          # 모든 스택이 공유하는 이름 규칙 모듈 (+ terraform test)
│   ├── mocks/                   # terraform test 용 azurerm mock 값
│   ├── 02-bootstrap/            # Lab 02  원격 state 저장소
│   ├── 03-network/              # Lab 03  VNet / NSG / NAT Gateway / Private DNS
│   ├── 04-platform/             # Lab 04  ACR / Key Vault / 모니터링 / AKS 용 ID
│   ├── 05-aks/                  # Lab 05  AKS 클러스터 + 노드 풀 + 관측성
│   ├── 06-workload/             # Lab 06  Workload Identity + Key Vault CSI
│   ├── 07-ingress/              # Lab 07  Gateway API + 데모 앱
│   ├── 08-governance/           # Lab 08  Azure Policy / Defender / 예산
│   └── 10-aks-automatic/        # Lab 10  AKS Automatic (선택)
├── scripts/                     # 실습 중 실행하는 스크립트
│   ├── preflight.sh             #   시작 전 점검 (Lab 01)
│   ├── verify.sh, verify/       #   스택별 결과 검증 (Lab 02–10)
│   ├── cleanup.sh               #   역순 삭제 (Lab 11)
│   └── lib/common.sh            #   공통 함수
└── tools/                       # md 코드 동기화 + HTML 빌드 + 문서 검사, 전체 정적 검증 스크립트
```

각 `terraform/NN-*` 디렉터리가 **독립된 Terraform 루트 모듈(= 독립된 state)** 입니다. 실습 N 의 문서에 실린 코드는 해당 디렉터리의 파일과 동일합니다.

## 8. (선택) Azure 없이 코드 검증하기

로그인이나 구독 없이도 모든 스택의 `fmt` → `validate` → `terraform test`(mock provider)를 실행할 수 있습니다. 전체 실행에는 `scripts/` 의 셸 스크립트 문법 검사(`bash -n`, shellcheck 가 있으면 함께)도 포함됩니다.

```bash
tools/validate-all.sh            # 전체 스택
tools/validate-all.sh 05-aks     # 특정 스택만
```

## 9. 비용 안내 (대략적인 추정)

| 실습 | 주요 과금 항목 | 대략적인 시간당 비용 |
|---|---|---|
| 02 | Storage(소량) | 거의 0 |
| 03 | NAT Gateway + Public IP | 약 $0.05 + 데이터 처리량 |
| 04 | ACR Premium, Managed Grafana, Private Endpoint 2개, Log Analytics | 약 $0.2–0.3 |
| 05 | **AKS Standard 티어 + D4ds_v5 노드 6대 이상** | **약 $1.7–2** |
| 06–07 | 앱 파드 + 로드밸런서/공인 IP | 소액 |
| 10 | AKS Automatic(Standard 티어) + 자동 프로비저닝 노드 | 약 $0.5–1.5 |

> [!CAUTION]
> 위 금액은 리전·환율·시점에 따라 달라지는 **추정치**입니다. 정확한 금액은 [Azure 가격 계산기](https://azure.microsoft.com/pricing/calculator/)로 확인하세요.
> 클러스터를 켜 둔 채 방치하면 하루 수십 달러가 청구될 수 있으므로, 실습이 끝나면 반드시 [Lab 11. 정리](11-cleanup.md)를 진행하세요.

다음 → [Lab 02. Terraform 원격 State (S3 + DynamoDB ↔ Blob)](02-bootstrap.md)
