# Lab 09. Day-2 운영: 업그레이드 · 스케일링 · 노드 교체 · 테스트

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 40분 (읽기 + 선택 실험) | 실험 시 노드 추가분 | 새 스택 없음 (`terraform/05-aks` 변수 변경) | [05. AKS 클러스터](05-aks.md) |

클러스터를 만드는 것보다 **계속 안전하게 운영**하는 일이 더 어렵습니다. 이 실습은 Day-2 작업을 *Terraform 변수 변경*으로 수행하는 방법과 주의점을 정리합니다.

## AWS 경험자를 위한 비교

| AWS (EKS) | Azure (AKS) | 차이 / 주의 |
|---|---|---|
| 컨트롤 플레인 minor 업그레이드 → 노드 그룹 업그레이드 | **자동 업그레이드 채널** 또는 `az aks upgrade`(컨트롤 플레인 → 노드 풀 순서) | 노드는 `max_surge` 만큼 **임시 노드를 추가**해 롤링 교체. 이 실습은 생성 이후의 버전을 AKS 가 관리하도록 Terraform 에서 무시(`ignore_changes`)하고, 버전도 코드로 관리하는 방법(C)은 아래에서 따로 소개합니다. |
| Extended Support(14개월 → +12개월, 유료) | 12개월 지원 + **LTS(Premium 티어, 선택)** | 지원 종료 버전은 2027-06 부터 플랫폼이 자동 업그레이드합니다(유지보수 창 무시, PDB 를 무시할 수도 있음 → 미리 올리세요). |
| 노드 AMI 업데이트 | `node_os_upgrade_channel` (`NodeImage`) + `maintenance_window_node_os` | 주간 창에서 노드 이미지를 자동 교체. |
| Karpenter drift / consolidation | **NAP** (`node_provisioning_profile.mode = "Auto"`) | Standard 에서 선택, Automatic 에서 기본. 이 실습의 기본은 Cluster Autoscaler(`Manual`). |
| `eksctl`/콘솔 기반 변경 | **변수 변경 → plan → apply** | 수동 변경(`az aks update`)은 Terraform 과 드리프트를 만듭니다. 변경은 코드로. (예외: Kubernetes 버전은 AKS 가 관리하도록 `ignore_changes` 처리) |

## 1. 업그레이드 전략

![업그레이드 흐름: patch · 노드 이미지 · minor](diagrams/upgrade-flow.svg)

### 자동 업그레이드 채널

| 채널 | 동작 | 이 실습 |
|---|---|---|
| `none` | 수동 | C 방식(아래)에서 사용 |
| **`patch`** | 같은 minor 의 최신 patch 자동 | ✅ **기본값** (minor 는 사전 점검 후 직접) |
| `stable` | 최신 GA minor 의 N-1 | AKS Automatic 이 사용 |
| `rapid` | 최신 GA minor | 개발 환경 |
| `node-image` | 노드 이미지만 | (대신 `node_os_upgrade_channel` 사용) |

업그레이드가 **언제** 일어나는지는 `maintenance_window_auto_upgrade`(Kubernetes 버전)와 `maintenance_window_node_os`(노드 OS 이미지)로 통제합니다(실습 코드: 일요일 02:00 KST / 토요일 02:00 KST, 4시간).

> [!IMPORTANT]
> 유지보수 창은 **자동 업그레이드**에만 적용됩니다. `az aks upgrade` 나 Terraform 으로 버전을 올리는 *수동* 업그레이드는 즉시 시작됩니다. 업무 시간 외에 실행하세요.

### minor 업그레이드 (예: 1.36 → 1.37, GA 이후)

> [!WARNING]
> 2026-10 현재 1.37 은 **preview** 이며 GA 예정입니다(자동 업그레이드는 preview 로 가지 않습니다). 운영 클러스터는 GA 이후에, 그리고 **개발 → 스테이징 → 운영** 순서로 올리세요. 아래는 GA 이후의 절차 예시입니다.

> [!IMPORTANT]
> **왜 Terraform 이 Kubernetes 버전을 "무시"하나요?** `kubernetes_version = "1.36"` 같은 minor alias 로 만든 클러스터는 AKS 가 patch 를 자동 업그레이드하면 실제 버전(예: 1.36.6)이 alias 와 달라져, azurerm **5.9.0 까지는** 매 `plan` 마다 `1.36.6 -> 1.36` 이라는 불필요한 diff 가 생깁니다([#26946](https://github.com/hashicorp/terraform-provider-azurerm/issues/26946)). 이를 억제하는 수정([PR #32625](https://github.com/hashicorp/terraform-provider-azurerm/pull/32625))이 병합되어 **v5.10.0(2026-10-15 예정)** 에 포함됩니다. 어느 provider 버전에서도 안전하도록 이 실습은 **생성 시점에만** 버전을 정하고, 이후에는 `lifecycle { ignore_changes = [kubernetes_version, default_node_pool[0].orchestrator_version] }`(User/Spot 풀은 `[orchestrator_version]`)로 AKS 가 관리하게 합니다. 아래 세 가지 방식 중 팀의 운영 모델에 맞는 것을 고르세요.

| 방식 | 누가 버전을 올리나 | 적합한 경우 | 이 실습 |
|---|---|---|---|
| **A. 자동 채널** (`stable`/`rapid`) | AKS 가 유지보수 창에서 minor 까지 자동 | 운영 부담 최소화, 개발/소규모 환경 (AKS Automatic 과 같은 모델) | `automatic_upgrade_channel` 값만 바꿔 `apply` |
| **B. 수동 `az aks upgrade`** | 사람이 사전 점검 후 컨트롤 플레인 → 노드 풀 순서로 | patch 는 자동, minor 는 통제하고 싶은 운영 클러스터 | ✅ **기본 구성** (`patch` 채널 + `ignore_changes`) |
| **C. Terraform 이 단일 출처** | PR 로 버전 변수를 바꾸고 `apply` | 모든 변경을 코드 리뷰로 남겨야 하는 조직 | 아래 *C-1 / C-2* 참고 |

사전 점검(B, C 공통):

```bash
RG="$(terraform output -raw resource_group_name)"; CLUSTER="$(terraform output -raw cluster_name)"
az aks get-versions -l koreacentral -o table 2>/dev/null      # 지원 버전/업그레이드 경로 (경고 메시지는 stderr)
az aks get-upgrades -g "$RG" -n "$CLUSTER" -o table

# 제거된 API(deprecated) 사용 여부: 업그레이드가 자동으로 막히기도 하지만 미리 확인
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis | head
```

**B. 수동 업그레이드 (기본 구성)**

```bash
# 1) 컨트롤 플레인만 먼저 올리고, 앱/애드온이 정상인지 확인한 뒤
az aks upgrade -g "$RG" -n "$CLUSTER" --kubernetes-version "<get-upgrades 로 확인한 1.37.x>" --control-plane-only

# 2) 노드 풀을 하나씩 올립니다 (max_surge 만큼 임시 노드를 추가하며 롤링 교체)
az aks nodepool upgrade -g "$RG" --cluster-name "$CLUSTER" -n system --kubernetes-version "<1.37.x>"
az aks nodepool upgrade -g "$RG" --cluster-name "$CLUSTER" -n user   --kubernetes-version "<1.37.x>"
```

버전 변경은 `ignore_changes` 로 무시되므로 `terraform plan` 에 diff 가 나오지 않습니다. 다만 나중에 **노드 풀을 새로 추가**할 때(예: `enable_spot_pool = true`)는 새 풀이 `var.kubernetes_version` 으로 만들어지므로, `-var kubernetes_version=<현재 클러스터 minor>` 로 맞춰 주세요.

**C. Terraform 으로 버전까지 관리하기 (전환 방법)**

공통: `cluster.tf` 와 노드 풀(`user`, `spot`)의 `lifecycle { ignore_changes }` 에서 `kubernetes_version` / `orchestrator_version` 항목을 제거합니다. 그 다음 둘 중 하나를 고르세요.

- **C-1. 전체 patch 버전을 고정 (모든 provider 버전에서 동작)**: `automatic_upgrade_channel = "none"` (노드 OS 교체 `node_os_upgrade_channel = "NodeImage"` 는 유지), `kubernetes_version` 은 alias 가 아닌 **전체 patch 버전**(예: `1.36.4`). patch 보안 업데이트도 변수 변경 → PR → apply 로 직접 올립니다.
- **C-2. alias 유지 (azurerm ≥ 5.10 필요)**: `automatic_upgrade_channel = "patch"` 를 유지하고 `kubernetes_version = "1.36"` alias 를 그대로 둡니다. patch 는 AKS 가 올리고(provider 가 alias ≡ 실제 patch 로 취급해 diff 를 억제), alias 를 `"1.37"` 로 올리면 minor 업그레이드가 plan 에 나타납니다. 5.10.0 은 아직 릴리스 전이라 이 가이드는 5.9.0 으로 검증했습니다. 릴리스 후 `terraform init -upgrade` 로 올려 `plan` 에 불필요한 diff 가 없는지 확인한 뒤 사용하세요.

```bash
export TF_VAR_kubernetes_version=1.37.1   # C-1: az aks get-upgrades 로 확인한 전체 버전 (예시). C-2 는 1.37
terraform plan -out tfplan      # ~ kubernetes_version, default_node_pool/orchestrator_version, user 풀 orchestrator_version
terraform apply tfplan          # 컨트롤 플레인 → system 풀 → user 풀 순서. 노드당 수 분.
```

진행 중 관찰 포인트:

```bash
kubectl get nodes -w                         # 임시(surge) 노드 추가 → cordon/drain → 이전 노드 제거
kubectl get pdb -A                           # PDB 가 드레인 속도를 제한 (Lab 07 의 앱은 maxUnavailable=1)
kubectl get events -A --field-selector reason=Evicted
```

> [!TIP]
> 업그레이드가 끝나면 저장소 루트에서 `scripts/verify.sh 05-aks` 를 실행해 노드가 모두 Ready 인지, 애드온 파드가 Running 인지 읽기 전용으로 확인하세요. 업그레이드 채널(방식 A / C-1)을 바꿨다면 바뀐 값이 그대로 표시됩니다.

| 체크리스트 | 이유 |
|---|---|
| PDB, 레플리카 ≥ 2, readiness probe | 드레인 중 가용성 |
| 서브넷 IP 여유 (`max_surge` 33% 만큼) | 임시 노드가 IP 를 소모 |
| 제거되는 API 목록 확인 | 매니페스트/Helm 차트 호환 |
| 애드온/CRD 호환 (Gateway API 번들은 **클러스터 버전에 맞게 자동 업그레이드**) | Managed Gateway API CRD v1.5.1(1.36) → v1.6.1(1.37+) |

## 2. 스케일링

| 계층 | 도구 | 이 실습의 구성 |
|---|---|---|
| 파드 수 | **HPA** (CPU/메모리), **KEDA**(이벤트 기반: Service Bus, Kafka …) | HPA: Lab 07 / KEDA: `workload_autoscaler_profile.keda_enabled` |
| 파드 크기 | **VPA** (요청/제한 권장) | `vertical_pod_autoscaler_enabled` |
| 노드 수 | **Cluster Autoscaler** (노드 풀별 min/max) | system 3–5, user 3–6 |
| 노드 종류 | **NAP**(Karpenter) | Lab 10 에서 체험 |
| 비용 | **Spot 풀** | `-var enable_spot_pool=true` |

```bash
# 노드 오토스케일러 이벤트와 현재 상태
kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml | head -40
kubectl get events -A | grep -i -E "TriggeredScaleUp|ScaleDown"

# Terraform 이 오토스케일러와 싸우지 않는 이유: node_count 를 코드에 쓰지 않고 min/max 만 선언했기 때문입니다.
```

> [!TIP]
> **노드 수를 코드에 고정하지 마세요.** `auto_scaling_enabled = true` 일 때는 `min_count`/`max_count` 만 선언합니다. `node_count` 를 쓰면 오토스케일러가 바꾼 값과 계속 충돌합니다(꼭 써야 한다면 `lifecycle.ignore_changes`).

## 3. 노드 풀 변경과 교체

`vm_size`, `os_disk_*`, `zones`, `vnet_subnet_id` 등을 바꾸면 노드 풀이 **교체**됩니다. 이 실습은 `temporary_name_for_rotation`(`systemtmp`, `usertmp`)을 설정해 임시 풀을 만든 뒤 교체합니다.

```bash
terraform plan -var user_node_vm_size=Standard_D8ds_v5   # user 풀 교체 계획 확인
```

> [!CAUTION]
> 순환 교체(rotation)는 **cordon/drain 없이** 이전 풀을 제거하므로 파드가 중단될 수 있습니다. 운영에서는 *새 풀을 추가 → 기존 풀 cordon/drain → 파드 이동 확인 → 기존 풀 제거*(blue-green)가 더 안전합니다. PDB 가 있는 워크로드라도 반드시 점검 시간에 실행하세요.

## 4. 비용을 아끼는 운영 습관

```bash
# 실습 중 쉬는 시간: 컨트롤 플레인과 노드 중지 (노드 VM 과금 중지. Spot 풀 등 일부 구성은 제약이 있을 수 있으니 문서 확인)
az aks stop  -g <rg> -n <cluster>
az aks start -g <rg> -n <cluster>

# 네임스페이스/워크로드별 비용 (cost_analysis_enabled) → 포털: AKS → Cost Management → Cost analysis
```

## 5. 백업 · 재해 복구 (개념)

| 필요 | Azure 서비스 | 메모 |
|---|---|---|
| 클러스터 리소스/PV 백업 | **Azure Backup for AKS** (Backup vault + 확장) | Velero 에 해당하는 관리형. PV 스냅샷 포함. |
| 멀티 리전 | 리전별 클러스터 + **Azure Front Door**/Traffic Manager, 여러 클러스터는 **Fleet Manager** | WAF 가이드의 미션 크리티컬 패턴. IP 대역을 리전 간 겹치지 않게 설계. |
| GitOps | **Flux 확장**(`azurerm_kubernetes_flux_configuration`) | 클러스터 부트스트랩/앱 배포를 Git 으로. |

## 6. Terraform 코드 품질과 CI

이 저장소는 Azure 구독 없이 실행되는 **3단계 정적 검증**을 제공합니다.

```bash
tools/validate-all.sh            # 1) fmt -check  2) validate  3) terraform test (mock provider)
```

| 단계 | 잡아내는 것 |
|---|---|
| `terraform fmt -check` | 포맷 일관성 |
| `terraform validate` | provider 스키마 위반(예: azurerm 5.x 에서 제거된 인수) — **버전을 올릴 때 가장 먼저 돌려 보세요** |
| `terraform test` (mock) | 변수 검증, `count`/`for_each`, 조건식, 태그/이름 규칙 같은 **plan 로직** |

실제 PR 파이프라인은 여기에 plan 검토와 보안 스캔(예: `trivy config`, `checkov`)을 더합니다. 비밀번호 없이 로그인하는 GitHub Actions(OIDC) 예시입니다(액션 버전은 최신으로 바꿔 쓰세요).

```yaml
name: terraform-plan
on: pull_request
permissions: { id-token: write, contents: read }
jobs:
  plan:
    runs-on: ubuntu-latest
    env:
      ARM_USE_OIDC: "true"                 # Workload identity federation (비밀번호/키 없음)
      ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
      ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: 1.16.5 }
      - run: tools/validate-all.sh
      - run: |
          echo "$BACKEND_HCL" > terraform/backend.hcl
          terraform -chdir=terraform/05-aks init -backend-config=../backend.hcl
          terraform -chdir=terraform/05-aks plan -lock-timeout=300s -no-color
        env: { BACKEND_HCL: "${{ vars.BACKEND_HCL }}" }
```

> [!NOTE]
> **드리프트 감지**: `terraform plan -detailed-exitcode` 를 스케줄러로 주기 실행하면 누군가 포털/CLI 로 바꾼 설정(종료 코드 2)을 찾아낼 수 있습니다.

다음 → [Lab 10. AKS Automatic](10-aks-automatic.md)
