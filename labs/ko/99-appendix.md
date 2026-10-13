<!-- lang-switch -->
[English](../99-appendix.md) | **한국어**
<!-- /lang-switch -->

# 부록. 트러블슈팅 · 프로덕션 체크리스트 · 참고 자료 · 테스트 코드

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 참고용 | 없음 | `terraform/mocks`, `scripts/`, `tools/validate-all.sh` | 없음 |

## A. 이 가이드를 검증한 방법과 한계

### A-1. 정적 검증 (Azure 불필요)

| 검증 | 내용 | 결과 |
|---|---|---|
| `terraform fmt -check` | 모든 스택/모듈 | 통과 |
| `terraform validate` | azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · random 3.9.1 · time 0.14.2 실제 스키마 기준 | 통과 |
| `terraform test` (mock provider) | 모든 스택의 plan 로직 + 변수 검증(`naming` 모듈 포함 총 <!-- count:test-runs -->34<!-- /count -->개 run) | 통과 |
| AzAPI 본문 검증 | `Microsoft.ContainerService/managedClusters@2026-05-01` 의 속성명을 OpenAPI 스펙과 azapi 내장 스키마로 확인 | 통과 |
| 내장 정책 정의 ID | `az policy definition show` 로 8개 ID 확인 | 확인 |
| VM 크기/영역 | `Standard_D4ds_v5` 가 koreacentral 영역 1·2·3 에서 사용 가능한지 확인 | 확인 |
| 셸 스크립트 정적 검사 | `scripts/` 전체를 `bash -n` 과 ShellCheck 로 검사, macOS 기본 bash 3.2 로도 실행 | 통과 |

### A-2. 실제 Azure 구독에서 처음부터 끝까지 실행한 결과 (2026-10-13)

정적 검증만으로는 알 수 없는 것을 확인하려고, 문서의 명령을 **Lab 01 부터 Lab 11 까지 순서대로 실제 구독에서 실행**하고 각 Lab 의 `scripts/verify.sh` 로 결과를 확인했습니다. 마지막에 Lab 11 로 모두 삭제했습니다.

| 항목 | 내용 |
|---|---|
| 구독 | 개인 Visual Studio Enterprise 구독(Owner), 게스트(개인) 계정으로 로그인, 리전 koreacentral |
| 도구 | Terraform 1.16.5 · azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · Azure CLI 2.86.0 · kubectl 1.37.1 · kubelogin 0.2.8 (macOS, arm64) |
| 클러스터 | Standard 1.36.4, Automatic 1.35.8 (`stable` 채널은 N-1) |
| 쿼터 | 구독 기본값이 패밀리 20 · 전체 32 vCPU 여서 [Lab 01](01-prerequisites.md) §4 의 방법으로 48 · 64 로 늘린 뒤, 기본 구성(D4ds_v5)으로 실행 |

| Lab | 실행한 것 | 결과 |
|---|---|---|
| [01](01-prerequisites.md) | 도구 설치(`brew`), RP 등록, 쿼터 · VM 크기 확인, `preflight.sh` | 통과(16/16). 게스트 계정에서 역할 판정이 실패하던 점 수정 |
| [02](02-bootstrap.md) | naming 테스트, apply(4개, 1분 32초), `backend.hcl`, state 원격 이전, 블롭 조회 · 키 인증 끔 확인, 동시 plan 잠금과 `-lock-timeout`, `verify.sh` | 통과(9/9) |
| [03](03-network.md) | apply(26개, 2분), 서브넷 · NAT · NSG 확인, `verify.sh`, NSG 실측(아래), `gateway_allowed_source_prefixes` 경로 4가지 | 통과(19/19) |
| [04](04-platform.md) | apply(18개, 4분), ACR · Key Vault · Private Endpoint · DNS 확인, `az acr import`, Grafana 의 Prometheus 데이터 소스, PromQL `count(up)`, `verify.sh` | 통과(17/17) |
| [05](05-aks.md) | apply, kubeconfig, 노드 · 애드온 · Gateway API 확인, KQL, Spot 풀 추가 · 제거, private 전환 plan, `az aks command invoke`, `verify.sh` | 통과(33/33). 첫 apply 실패(409 경쟁)를 고침. Spot 스케일 업은 용량 부족으로 미확인 |
| [06](06-workload-identity.md) | apply, 시크릿 마운트 = Key Vault 값, 토큰 클레임, 2분 자동 갱신, 사설 DNS(10.10.3.x), `verify.sh` | 통과(9/9). 첫 apply 실패(PSS)를 고침 |
| [07](07-ingress.md) | apply(22초), 공용 Gateway `curl` 200, HPA 3→10, NetworkPolicy 차단, 내부 Gateway(10.10.2.x) 전환 · 복귀, `verify.sh` | 통과(8/8, 내부 모드 7/7 + 건너뜀 1) |
| [08](08-governance.md) | apply(9개), Gatekeeper 제약 동기화, 준수 상태, Deny 효과, 예산, 잠금(`ScopeLocked`), `verify.sh` | 통과(9, 경고 1). Defender 구독 플랜은 실행하지 않음 |
| [09](09-operations.md) | 업그레이드 사전 점검, 오토스케일러 상태, vm_size 변경 plan, `az aks stop`(3분) / `start`(5분) | 일부. 업그레이드 자체는 실행하지 못함 |
| [10](10-aks-automatic.md) | apply(약 9분), NAP · Deployment Safeguards, BYO VNet 으로 다시 만들기(약 11분)와 삭제, `verify.sh` | 통과(10/10) |
| [11](11-cleanup.md) | `cleanup.sh --dry-run`, 실제 삭제, 정리 확인 | 아래 *A-5* |

**NSG 규칙 실측 (Lab 03).** 규칙을 지우거나 Deny 규칙을 더해 확인한 결과입니다. 처음에는 "Pod CIDR 은 기본 Deny 에 막힌다"고 적었다가 실측과 달라 고쳤습니다.

| 실험 | 결과 |
|---|---|
| 노드 NSG 에서 `AllowPodsToPods` 를 지움(기본 규칙만 남김) | 노드 간 Pod 통신과 DNS 는 **정상** → 기본 규칙으로 통과 |
| 위 상태에서 Pod → Pod Deny(4000)를 추가 | 타임아웃, DNS 실패. `AllowPodsToPods`(110)를 되돌리면 정상 |
| `AllowGatewayHttpHttps` 를 지움 | 공용 Gateway 접속 불가(타임아웃). 되돌리면 200 → **필수** |
| API 서버 서브넷 → 노드 Deny 를 추가하고 `AllowApiServerToCluster` 를 지움 | `kubectl exec` 가 `connection reset`. 규칙을 되돌리면 정상 |
| API 서버 서브넷 → Pod Deny 를 추가하고 규칙을 지움 | Gatekeeper 웹훅 호출은 정상 → Pod 대상은 방어적인 항목 |
| AKS 가 LB 규칙을 쓰는 곳 | 노드 리소스 그룹의 자체 NSG(NIC 에 연결)에만 `k8s-azure-lb_allow_…` 가 생기고, 서브넷에 연결한 NSG 는 그대로 |
| `gateway_allowed_source_prefixes` | 기본(`Internet`) · 여러 CIDR(복수 속성) · 한 개(단수 속성) · `[]`(규칙 삭제) 모두 apply 후 plan 이 깨끗 |

**영문판 재검증 (2026-10-14).** 영문판은 Terraform 코드와 스크립트의 주석 · 설명 · 메시지 문구만 바꿨습니다(이전 소스와 구조를 비교해 다른 변경이 없음을 확인). 깨진 곳이 없는지 확인하려고 같은 구독(개인 Visual Studio Enterprise, koreacentral, 같은 도구 버전)에서 영문 문서의 명령을 Lab 01 부터 Lab 11 까지 다시 실행했고, 모든 `scripts/verify.sh` 결과를 위의 실행과 비교했습니다.

| Lab | 실행한 것 | 결과 |
|---|---|---|
| [01](01-prerequisites.md) | `preflight.sh` | 통과(16/16) |
| [02](02-bootstrap.md) | apply(4개), Blob 으로 state 이전, `verify.sh` | 통과(9/9, 이전 전에는 8 통과 + 경고 1) |
| [03](03-network.md) | apply(26개), `verify.sh`, 실습의 수동 확인 | 통과(19/19) |
| [04](04-platform.md) | apply(18개), `az acr import`, `verify.sh`, 실습의 수동 확인 | 통과(17/17) |
| [05](05-aks.md) | apply(15개), kubeconfig, 노드 · GatewayClass · KQL 확인, `verify.sh` | 통과(33/33) |
| [06](06-workload-identity.md) | apply(11개), 시크릿 마운트 = Key Vault 값, 토큰 클레임, 2분 자동 갱신, `verify.sh` | 통과(9/9) |
| [07](07-ingress.md) | apply(8개), 공용 Gateway `curl` 200, NetworkPolicy 차단, 내부 Gateway(10.10.2.x) 전환 · 복귀, `verify.sh` | 통과(8/8, 내부 모드 7/7 + 건너뜀 1) |
| [08](08-governance.md) | apply(9개), Deny 효과로 privileged 파드 거부, 잠금(`ScopeLocked`), `verify.sh` | 기본 Audit 에서 통과(10/10), 잠금을 켠 상태는 9 통과 + 경고 1 |
| [09](09-operations.md) | 업그레이드 사전 점검(`az aks get-versions` · `get-upgrades`, 제거된 API, 오토스케일러 상태) | 문서대로 실행(업그레이드 자체는 실행하지 않음) |
| [10](10-aks-automatic.md) | apply(4개), Deployment Safeguards · NAP 실험, `verify.sh` | 통과(10/10) |
| [11](11-cleanup.md) | `cleanup.sh --dry-run`, `cleanup.sh --yes`, 부트스트랩 삭제, 정리 확인 | 모두 삭제(AKS 약 6분, AKS Automatic 약 8분, Managed Grafana 약 10분). 태그가 붙은 리소스 그룹은 남지 않음 |

이번에도 Azure 가 실행 중에 `NetworkWatcherRG` 와 Defender 의 기본 Log Analytics 작업 영역(`DefaultResourceGroup-…`)을 자동으로 만들어서 직접 삭제했습니다. 남은 것은 soft-delete 상태의 Key Vault 1개뿐이며, purge protection 이 켜져 있어 7일 뒤 자동 삭제되고 비용은 없습니다.

### A-3. 실행하다 발견해서 고친 불일치

| # | 위치 | 증상 | 수정 |
|---|---|---|---|
| 1 | `05-aks/monitoring.tf` | 첫 apply 가 `409 AnotherOperationInProgress` 로 실패. AzAPI 가 클러스터를 PUT 하는 동안 User 노드 풀 생성과 겹침 | `azapi_update_resource.control_plane_metrics` 가 노드 풀 뒤에 실행되도록 `depends_on` 추가 |
| 2 | `06-workload/kubernetes.tf`, `07-ingress/app.tf` | `kv-demo` 가 `violates PodSecurity "restricted": runAsNonRoot != true` 로 거부되어 10분 롤아웃 대기 후 실패. kubernetes provider 는 컨테이너 `security_context` 의 생략값을 `false` 로 보내 파드 수준의 `true` 를 덮어씀(07 의 앱 컨테이너도 같은 구성이었음) | 컨테이너 `security_context` 에 `run_as_non_root = true` 명시 |
| 3 | `scripts/cleanup.sh` | `tf_state \| grep -q` 가 pipefail 에서 SIGPIPE 로 결과가 뒤집혀, 클러스터가 있는데도 "이미 없음"으로 판단하고 06 의 쿠버네티스 리소스를 state 에서 지움. state 읽기 실패를 "비어 있음"으로 오해해 스택을 건너뛸 수도 있었음 | 출력을 먼저 변수에 담고, 읽기 실패는 오류로 처리 |
| 4 | `scripts/preflight.sh` | 게스트(개인) 계정은 로그인 이름으로 역할을 조회할 수 없어 "역할을 조회하지 못했습니다" 경고 | 로그인한 사용자의 객체 ID 로 조회 |
| 5 | Lab 01 §4 | 구독 기본 쿼터(예: 패밀리 20 · 전체 32)가 최소 24 vCPU 보다 작을 수 있음 | 필요량 표와 `az quota create` 예시 추가 |
| 6 | Lab 03, `03-network` 주석 | "Pod CIDR 은 VirtualNetwork 태그에 속하지 않아 기본 Deny 에 막힌다"는 설명이 실측과 다름 | 공용 Gateway 규칙만 필수, Pod · API 서버 규칙은 Deny 를 더할 때 필요한 방어용으로 정정 |
| 7 | Lab 06 1단계 | `terraform -chdir=../04-platform` 이 저장소 루트에서 실패 | `terraform -chdir=terraform/04-platform` |
| 8 | Lab 06 3단계 | JWT 를 푸는 `base64 -d` 가 패딩이 없어 macOS 에서 잘림 | python 으로 패딩을 맞춰 디코드 |
| 9 | Lab 08 3단계 | 시험 파드를 `web` 에 만들면 Pod Security(baseline)가 Gatekeeper 보다 먼저 거부해 문서의 메시지가 나오지 않음 | `default` 네임스페이스에서 시험 |
| 10 | Lab 07 3단계 | `kubectl logs deploy/…` 는 Envoy 파드 2개 중 하나만 보여 시작 로그가 나올 수 있음 | 라벨 셀렉터 + `--prefix` |
| 11 | Lab 09 §3 | vm_size 변경 plan 이 `replace` 가 아니라 `updated in-place` 로 표시됨(임시 풀 교체는 apply 중 수행) | 설명 정정 |
| 12 | Lab 10 2단계 | Automatic 이 1.35 로 만들어져 Gateway API CRD 가 없고 `kubectl get gatewayclass` 가 실패 | 1.36+ 에서만 해당한다는 안내 추가 |
| 13 | Lab 05 · 08 | plan 리소스 수 표기가 실제와 다름 | Lab 05 는 16 → 15(리소스 그룹 포함), Lab 08 은 정책 할당 8개 + `time_static` 1개 = 9개로 정정 |

### A-4. 확인하지 못했거나 환경에 따라 다른 것

- **Spot 스케일 업(Lab 05 (a))**: 풀 추가 · 제거는 확인했지만, 파드를 올리자 `SkuNotAvailable`(Capacity Restrictions: `Standard_D4ds_v5`)로 노드가 늘지 않았습니다. Spot 용량은 리전 · 시간에 따라 다릅니다.
- **업그레이드(Lab 09 §1)**: 업그레이드할 GA 버전이 없어서(1.36.4 가 최신 GA, 1.37.0 은 preview, 노드 이미지도 최신) 실행하지 못했습니다. 롤링 교체(surge · PDB)는 미확인입니다.
- **Defender 구독 플랜(Lab 08 4단계)**: 이 구독에는 이미 켜져 있어 실행하지 않았습니다(Terraform 으로 관리하면 `destroy` 때 Free 로 되돌아가 구독의 기존 설정이 바뀔 수 있습니다). 클러스터 단위 `enable_defender` 만 사용했습니다.
- **Defender 자동 프로비저닝 정책이 있는 구독**: 클러스터를 만든 직후 한동안 `Updating` 이라 `verify.sh` 의 프로비저닝 상태가 일시적으로 실패하고, 05-aks plan 에 `microsoft_defender` 제거 diff 가 계속 보입니다. `-var enable_defender=true` 로 맞추면 사라집니다([Lab 08](08-governance.md) 2단계).
- **조직 정책이 Storage 공용 접근을 끄는 구독**: 관리 그룹의 Azure Policy(Modify)가 Storage 계정의 공용 네트워크 접근을 `Disabled` 로 바꾸는 구독에서는 Lab 02 의 원격 state 접근이 `403 AuthorizationFailure` 로 실패했습니다(Terraform 이 `Enabled` 로 만들어도 정책이 바꿈). 이 가이드는 공용 엔드포인트 + Entra 인증을 전제로 하므로, 정책 예외를 받거나 다른 구독을 써야 합니다.
- **`terraform plan -detailed-exitcode`**: provider 가 `available_kubernetes_versions` 출력 값만 바꿔도 `2` 를 돌려줍니다(실제 인프라 변경 없음). CI 의 "변경 없음" 판정에는 이 값을 무시하세요.
- **실행하지 않은 것**: Windows(PowerShell) 명령, 다른 리전, 팀 환경(Entra 그룹 `admin_principal_ids`), `enable_private_cluster=true` 로 실제 배포(plan 만), TLS(443) 리스너, Application Gateway for Containers, Grafana 웹 UI 로그인, `az login` 의 대화형 로그인, [Lab 09](09-operations.md) §6 의 GitHub Actions 워크플로 예시.
- **Azure CLI 간헐 오류**: `az aks get-credentials` 가 `Error loading command module 'serviceconnector': deadlock` 으로 한 번 실패하고 다시 실행하면 성공했습니다(CLI 쪽 문제).

### A-5. 정리 결과 (Lab 11)

| 항목 | 결과 |
|---|---|
| `cleanup.sh --dry-run` | 문서와 같은 순서 · 명령으로 계획이 출력됨 |
| 스택 삭제 | `cleanup.sh --yes` 로 03–10 스택을 삭제했습니다. 오래 걸리는 것은 AKS 클러스터(약 6분), AKS Automatic(약 10분), **Managed Grafana(약 10분)** 이며, 나머지는 몇 초–몇 분입니다 |
| 부트스트랩 삭제 | 문서대로 backend 블록을 주석 처리하고 `terraform init -migrate-state -force-copy` 로 state 를 로컬로 되돌린 뒤 `cleanup.sh --yes --include-bootstrap` 으로 삭제했습니다(이미 지운 스택은 "state 가 비어 있습니다"로 건너뜀) |
| 정리 확인 | 태그 `lab=aks-terraform-guide` 리소스 그룹 없음, AKS 노드 리소스 그룹 없음, 리소스 잠금 · 예산 · 정책 할당 없음. 구독의 리소스 그룹과 리소스 수가 실행 전과 같음 |
| 남은 것 | soft-delete 상태의 Key Vault 1개. purge protection 이 켜져 있어 7일 뒤 자동으로 삭제되며 비용은 없습니다 |
| Terraform 밖의 부산물 | 실행 중 Azure 가 자동으로 만든 `NetworkWatcherRG` 와 Defender 의 기본 Log Analytics 작업 영역(`DefaultResourceGroup-…`)은 Terraform 이 모르는 리소스라 직접 지웠습니다(작업 영역은 soft-delete 상태에서 복구한 뒤 `--force` 로 완전 삭제) |
| 실행 중 찾은 문제 | `cleanup.sh` 의 `cluster_gone` 오판(A-3 의 3번). 고친 뒤 SIGPIPE 조건 단위 테스트와 실제 정리로 확인 |
| 회귀 확인 | 고친 05-aks 를 새로 한 번에 `apply`(15개, 18분 11초)해 409 없이 성공하는 것을 확인한 뒤 다시 삭제 |

구독 단위로는 `Microsoft.Quota` Resource Provider 등록과 vCPU 쿼터 증설(Lab 01 §4)이 남아 있습니다. 둘 다 비용이 없습니다.

## B. 트러블슈팅 모음

| 증상 | 원인 / 해결 |
|---|---|
| `Error: ... subscription_id is a required provider property` | `ARM_SUBSCRIPTION_ID` 환경 변수 설정 ([Lab 01](01-prerequisites.md)). |
| `MissingSubscriptionRegistration` / `ResourceProviderNotRegistered` | RP 등록 (azurerm 5.x 는 자동 등록하지 않음). `az provider register --namespace Microsoft.XXX`. |
| `AuthorizationFailed` | 현재 사용자 권한(Contributor + User Access Administrator 또는 Owner) 부족, 또는 방금 만든 역할 할당 전파 대기(최대 5분). |
| `Error acquiring the state lock` | 다른 실행이 진행 중이거나 비정상 종료. 확실할 때만 `terraform force-unlock <LOCK_ID>`. |
| `Error: Unsupported argument` / `Missing required argument` (azurerm) | 4.x 코드와 5.x 스키마 차이. `terraform validate` 로 위치를 확인하고 [5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide) 참조. |
| `Provider produced inconsistent result after apply` (kubernetes_manifest) | CRD 기본값/서버 정규화 차이. `terraform apply` 재시도 또는 `computed_fields` 사용. |
| `StorageAccountAlreadyTaken` / `VaultAlreadyExists` / ACR 이름 충돌 | 전역 고유 이름 충돌. `TF_VAR_workload` 변경 또는 soft-deleted Key Vault 복구/purge. |
| `terraform destroy` 가 `ScopeLocked` | 리소스 잠금 해제 ([Lab 08](08-governance.md), [Lab 11](11-cleanup.md)). |
| `kubectl: Unable to connect ... i/o timeout` | 내 공인 IP 변경 → `TF_VAR_allowed_ip_ranges` 갱신 후 05-aks `apply` (API 서버 authorized IP). |
| `kubelogin` 오류 / `Unauthorized` | `az login` 재실행, `kubelogin convert-kubeconfig -l azurecli`, Azure RBAC 역할 전파 대기. |
| `terraform plan` 이 매번 `node_count` 변경을 요구 | 오토스케일러와 충돌. 코드에 `node_count` 를 쓰지 말고 `min_count`/`max_count` 만 사용 ([Lab 09](09-operations.md)). |
| `409 ... AnotherOperationInProgress` (`azapi_update_resource`) | 같은 클러스터에 대한 다른 작업(노드 풀 생성 등)과 겹친 것입니다. 이 가이드 코드는 `depends_on` 으로 순서를 고정했고, 겹쳤다면 작업이 끝난 뒤 `terraform apply` 를 다시 실행하세요. |
| `kubernetes_deployment_v1` 이 10분 뒤 `Waiting for rollout to finish` 로 실패 | 파드가 만들어지지 않는 경우입니다. `kubectl -n <네임스페이스> get events` 의 `FailedCreate` 사유를 확인하세요(예: `violates PodSecurity "restricted"` → 컨테이너 `security_context` 의 `run_as_non_root`). |
| `terraform init -migrate-state` 가 `403 AuthorizationFailure` | 방금 만든 역할 할당이 전파되는 중이면 1–5분 뒤 재시도합니다. 계속되면 `az storage account show -n <계정> --query publicNetworkAccess` 를 확인하세요. `Disabled` 라면 조직 정책이 공용 접근을 꺼 둔 것이라 정책 예외나 다른 구독이 필요합니다. |

## C. 프로덕션으로 가기 전 체크리스트

이 가이드는 **학습/PoC 를 위한 비용 균형형 구성**입니다. 운영 환경에서는 Microsoft [AKS 베이스라인 아키텍처](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks)를 기준으로 아래를 추가하세요.

| 영역 | 이 가이드 | 프로덕션 권장 |
|---|---|---|
| 네트워크 토폴로지 | 단일 VNet + NAT Gateway | **허브-스포크**: 허브에 Azure Firewall(egress 통제, UDR)·Bastion·VPN/ExpressRoute, 스포크에 AKS |
| API 서버 | 공용 + authorized IP | **완전 프라이빗**(`enable_private_cluster`) + Bastion/점프 호스트/자체 호스팅 러너 |
| 인그레스 | Gateway API 공용 LB | **Application Gateway(WAF v2) 또는 Front Door** → 내부 Gateway, TLS 종단(Key Vault 인증서) |
| 레지스트리/KV | Private Endpoint + 관리자 IP 허용 | 공용 접근 **완전 차단**, CI 는 VNet 내부/관리형 러너 |
| ID | 사용자에게 직접 역할 | **Entra 그룹 + PIM(Just-in-time)**, 조건부 액세스, 접근 검토 |
| 거버넌스 | RG 범위 정책 (Audit) | 관리 그룹 범위 정책/이니셔티브 + `Deny`, 태그 상속·필수 태그 정책 |
| 보안 | 선택적 Defender | Defender for Containers + (Sentinel 커넥터), 이미지 서명/스캔 파이프라인 |
| 복원력 | 단일 리전(영역 3곳) | **Azure Backup for AKS**, 멀티 리전 + Front Door/Traffic Manager, Fleet Manager |
| 배포 | `terraform apply` + kubectl | **GitOps(Flux 확장)** 로 클러스터 부트스트랩/앱 배포, 파이프라인에서 OIDC 로그인 |
| 모듈화 | 학습용 직접 정의 | 사내 모듈 또는 **Azure Verified Modules(AVM)** 로 표준화 |
| 관측성 | 기본 대시보드 | Prometheus 알림 규칙(`azurerm_monitor_alert_prometheus_rule_group`) + Action Group, SLO 대시보드 |

## D. 참고 자료

| 주제 | 링크 |
|---|---|
| AWS ↔ Azure 비교 | [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/), [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) |
| 아키텍처 | [AKS 베이스라인](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks), [AKS Well-Architected 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service) |
| AKS Automatic / NAP | [AKS Automatic 소개](https://learn.microsoft.com/azure/aks/intro-aks-automatic), [Node auto-provisioning](https://learn.microsoft.com/azure/aks/node-auto-provisioning) |
| Gateway API | [App Routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api), [NGINX → Gateway API 마이그레이션](https://learn.microsoft.com/azure/aks/app-routing-nginx-to-gateway-api-migration), [Managed Gateway API CRD](https://learn.microsoft.com/azure/aks/managed-gateway-api) |
| 지원 버전/일정 | [Supported Kubernetes versions](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions), [AKS 릴리스 노트](https://github.com/Azure/AKS/releases) |
| Terraform | [azurerm 5.0 업그레이드 가이드](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide), [`azurerm_kubernetes_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster), [`azurerm_kubernetes_automatic_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_automatic_cluster), [AzAPI](https://registry.terraform.io/providers/Azure/azapi/latest/docs), [AVM](https://azure.github.io/Azure-Verified-Modules/) |
| Microsoft 공식 Terraform 샘플 | [Azure/terraform quickstart](https://github.com/Azure/terraform/tree/master/quickstart): `101-aks-application-routing-gateway-api`, `101-aks-automatic-custom-network`, `101-aks-network-isolated`, `101-aks-use-azure-policy`, `101-aks-defender-containers`, `301-aks-enterprise` |
| Prometheus 템플릿 | [Azure/prometheus-collector — AddonTerraformTemplate](https://github.com/Azure/prometheus-collector/tree/main/AddonTerraformTemplate) |

## E. Terraform 파일 전체 목록 (어느 Lab 에 있나)

| 스택 / 모듈 | 파일 | 실린 곳 |
|---|---|---|
| `modules/naming` | `variables.tf` `main.tf` `outputs.tf` `versions.tf` `tests/naming.tftest.hcl` | [Lab 02](02-bootstrap.md) |
| `02-bootstrap` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 02](02-bootstrap.md) |
| `03-network` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 03](03-network.md) |
| `04-platform` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `identity.tf` `registry.tf` `keyvault.tf` `observability.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 04](04-platform.md) |
| `05-aks` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `cluster.tf` `monitoring.tf` `prometheus-rules.tf` `gateway-api.tf` `access.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 05](05-aks.md) |
| `06-workload` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `identity.tf` `kubernetes.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 06](06-workload-identity.md) |
| `07-ingress` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `app.tf` `gateway.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 07](07-ingress.md) |
| `08-governance` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `policy.tf` `security.tf` `budget.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 08](08-governance.md) |
| `10-aks-automatic` | `versions.tf` `providers.tf` `variables.tf` `main.tf` `cluster.tf` `outputs.tf` `tests/plan.tftest.hcl` | [Lab 10](10-aks-automatic.md) |
| `mocks` | `azurerm.tfmock.hcl` | 아래 F |

> [!NOTE]
> 모든 스택은 같은 파일 구성(`versions.tf` → `providers.tf` → `variables.tf` → `main.tf` → 주제별 파일 → `outputs.tf`)을 따릅니다. 파일을 한 곳에 모아 보고 싶다면 이 HTML 의 검색창에 파일 이름(예: `cluster.tf`)을 입력하세요.

## F. 테스트/도구 코드 전체

각 스택의 `tests/plan.tftest.hcl` 은 해당 Lab 의 코드 섹션에 있습니다. 공통 mock 값과 전체 검증 스크립트는 아래와 같습니다.

**`terraform/mocks/azurerm.tfmock.hcl`** — 모든 스택의 mock 테스트가 공유하는 azurerm 모의 값

<!-- tf:include path="terraform/mocks/azurerm.tfmock.hcl" -->
```hcl title="terraform/mocks/azurerm.tfmock.hcl"
# Mock values for the azurerm provider, for use with terraform test.
#
# So that `terraform test` can verify plan-stage logic (variable validation, count/for_each, conditionals, merge, etc.)
# without an Azure subscription or sign-in, these definitions return "correctly formatted IDs/UUIDs".
# Each stack's tests/plan.tftest.hcl loads this with `mock_provider "azurerm" { source = "../mocks" }`.

mock_data "azurerm_client_config" {
  defaults = {
    client_id       = "00000000-0000-0000-0000-0000000000c1"
    tenant_id       = "00000000-0000-0000-0000-0000000000a1"
    subscription_id = "00000000-0000-0000-0000-0000000000b1"
    object_id       = "00000000-0000-0000-0000-0000000000d1"
  }
}

mock_data "azurerm_resource_group" {
  defaults = {
    id       = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock"
    location = "koreacentral"
  }
}

mock_data "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  }
}

mock_data "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock"
  }
}

mock_data "azurerm_private_dns_zone" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.net"
  }
}

mock_data "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
    client_id    = "00000000-0000-0000-0000-0000000000e1"
    principal_id = "00000000-0000-0000-0000-0000000000e2"
    tenant_id    = "00000000-0000-0000-0000-0000000000a1"
  }
}

mock_data "azurerm_log_analytics_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
}

mock_data "azurerm_monitor_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Monitor/accounts/amw-mock"
  }
}

mock_data "azurerm_container_registry" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
    login_server = "acrmock.azurecr.io"
  }
}

mock_data "azurerm_key_vault" {
  defaults = {
    id        = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock"
    vault_uri = "https://kv-mock.vault.azure.net/"
  }
}

mock_data "azurerm_kubernetes_cluster" {
  defaults = {
    id              = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock"
    oidc_issuer_url = "https://koreacentral.oic.prod-aks.azure.com/00000000-0000-0000-0000-0000000000a1/11111111-1111-1111-1111-111111111111/"
    kube_config = [{
      host                   = "https://aks-example.hcp.koreacentral.azmk8s.io:443"
      cluster_ca_certificate = "Y2E="
      client_certificate     = ""
      client_key             = ""
      username               = "clusterUser"
      password               = ""
    }]
  }
}

mock_data "azurerm_kubernetes_service_versions" {
  defaults = {
    versions       = ["1.35.8", "1.36.3", "1.36.4"]
    latest_version = "1.36.4"
  }
}

mock_resource "azurerm_resource_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock"
  }
}

mock_resource "azurerm_virtual_network" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock"
  }
}

mock_resource "azurerm_subnet" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/virtualNetworks/vnet-mock/subnets/snet-mock"
  }
}

mock_resource "azurerm_network_security_group" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/networkSecurityGroups/nsg-mock"
  }
}

mock_resource "azurerm_public_ip" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/publicIPAddresses/pip-mock"
  }
}

mock_resource "azurerm_nat_gateway" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/natGateways/ng-mock"
  }
}

mock_resource "azurerm_private_dns_zone" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Network/privateDnsZones/privatelink.mock.net"
  }
}

mock_resource "azurerm_user_assigned_identity" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-mock"
    client_id    = "00000000-0000-0000-0000-0000000000e1"
    principal_id = "00000000-0000-0000-0000-0000000000e2"
    tenant_id    = "00000000-0000-0000-0000-0000000000a1"
  }
}

mock_resource "azurerm_container_registry" {
  defaults = {
    id           = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerRegistry/registries/acrmock"
    login_server = "acrmock.azurecr.io"
  }
}

mock_resource "azurerm_key_vault" {
  defaults = {
    id        = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.KeyVault/vaults/kv-mock"
    vault_uri = "https://kv-mock.vault.azure.net/"
  }
}

mock_resource "azurerm_log_analytics_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.OperationalInsights/workspaces/log-mock"
  }
}

mock_resource "azurerm_monitor_workspace" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Monitor/accounts/amw-mock"
  }
}

mock_resource "azurerm_dashboard_grafana" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Dashboard/grafana/amg-mock"
    identity = [{
      type         = "SystemAssigned"
      principal_id = "00000000-0000-0000-0000-0000000000f1"
      tenant_id    = "00000000-0000-0000-0000-0000000000a1"
      identity_ids = []
    }]
  }
}

mock_resource "azurerm_kubernetes_cluster" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aks-mock"
  }
}

mock_resource "azurerm_kubernetes_automatic_cluster" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.ContainerService/managedClusters/aksa-mock"
  }
}

mock_resource "azurerm_monitor_data_collection_endpoint" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Insights/dataCollectionEndpoints/dce-mock"
  }
}

mock_resource "azurerm_monitor_data_collection_rule" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Insights/dataCollectionRules/dcr-mock"
  }
}

mock_resource "azurerm_storage_account" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock"
  }
}

mock_resource "azurerm_storage_container" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-0000000000b1/resourceGroups/rg-mock/providers/Microsoft.Storage/storageAccounts/stmock/blobServices/default/containers/tfstate"
  }
}
```
<!-- /tf:include -->

**`tools/validate-all.sh`** — 구독 없이 전체 스택 검증

<!-- tf:include path="tools/validate-all.sh" -->
```bash title="tools/validate-all.sh"
#!/usr/bin/env bash
# Statically validates every Terraform stack without Azure credentials/subscription.
#   fmt -check  →  init -backend=false  →  validate  →  terraform test (mock provider)
#   (modules/naming has no provider, so only terraform test is really needed there)
# When run without arguments it also checks the shell scripts in scripts/ (bash -n, plus ShellCheck if installed).
#
# Usage:
#   tools/validate-all.sh              # all stacks + shell scripts
#   tools/validate-all.sh 05-aks       # a single stack
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/terraform"

export CHECKPOINT_DISABLE=1
export TF_IN_AUTOMATION=1

if [ "$#" -gt 0 ]; then
  stacks=("$@")
else
  stacks=()
  for d in [0-9][0-9]-*/; do
    stacks+=("${d%/}")
  done
fi

terraform version | head -1

echo
echo "== modules/naming (fmt, validate, test)"
terraform -chdir=modules/naming fmt -check -diff
terraform -chdir=modules/naming init -backend=false -input=false -no-color >/dev/null
terraform -chdir=modules/naming validate -no-color
terraform -chdir=modules/naming test -no-color

for stack in "${stacks[@]}"; do
  echo
  echo "== ${stack}"
  terraform -chdir="${stack}" fmt -check -diff
  terraform -chdir="${stack}" init -backend=false -input=false -no-color >/dev/null
  terraform -chdir="${stack}" validate -no-color
  # Validates the plan logic (variable validation, count/for_each, conditionals) with the mock provider, without Azure.
  terraform -chdir="${stack}" test -no-color
done

if [ "$#" -eq 0 ]; then
  echo
  echo "== scripts (bash -n, shellcheck)"
  scripts=("${ROOT}"/scripts/*.sh "${ROOT}"/scripts/lib/*.sh "${ROOT}"/scripts/verify/*.sh)
  for f in "${scripts[@]}"; do bash -n "$f"; done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${scripts[@]}"
    echo "OK (${#scripts[@]} scripts)"
  else
    echo "shellcheck is not installed, so only the syntax check (bash -n) ran (brew install shellcheck)."
  fi
fi

echo
echo "All checks passed."
```
<!-- /tf:include -->

**`terraform/.gitignore`**

<!-- tf:include path="terraform/.gitignore" -->
```text title="terraform/.gitignore"
# Terraform
.terraform/
*.tfstate
*.tfstate.*
crash.log
*.tfplan
tfplan
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# Environment-specific values (created in Lab 02 / saved in Lab 01)
backend.hcl
env.sh
*.auto.tfvars
terraform.tfvars

# Committing .terraform.lock.hcl is recommended (it pins provider versions/checksums).
# At first, check the file that terraform init created, then add the checksums of other OSes with `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64`.
```
<!-- /tf:include -->

## G. 검증 · 정리 스크립트

실습 중 손으로 치던 확인/삭제 명령을 스크립트로 묶었습니다. 모두 저장소 루트의 `scripts/` 에 있으며 macOS · Linux · WSL · Azure Cloud Shell(bash)에서 동작합니다(필요: `terraform`, `az`, `jq`, 그리고 05 이후는 `kubectl`, `kubelogin`).

| 스크립트 | 언제 | 하는 일 | 소스가 실린 곳 |
|---|---|---|---|
| `scripts/preflight.sh` | Lab 01, 실습 시작 전 | 도구 · 로그인 · 환경 변수 · Resource Provider · vCPU 쿼터 · VM 크기 · 권한 점검 (읽기 전용) | [Lab 01](01-prerequisites.md) |
| `scripts/verify.sh [스택…]` | 각 스택을 `apply` 한 직후 | `terraform output` 으로 이름을 찾아 `az`/`kubectl` 로 결과 검증, `✓ ✗ ! -` 요약과 종료 코드 (읽기 전용) | 이 부록 |
| `scripts/verify/02…10.sh` | 위 스크립트가 호출 (직접 실행도 가능) | 스택별 검증 항목 | [02](02-bootstrap.md) [03](03-network.md) [04](04-platform.md) [05](05-aks.md) [06](06-workload-identity.md) [07](07-ingress.md) [08](08-governance.md) [10](10-aks-automatic.md) |
| `scripts/cleanup.sh` | Lab 11, 실습을 마친 뒤 | 생성의 역순 `destroy`, 잠금 해제, 재실행 안전, 남은 리소스 점검 (`--dry-run` 지원) | [Lab 11](11-cleanup.md) |
| `scripts/lib/common.sh` | 위 스크립트들이 `source` | 결과 출력(`pass`/`fail`/`warn`), 값 비교(`expect_*`), JSON 헬퍼(`jq`), `terraform output`/`az`/`kubectl` 래퍼 | 이 부록 |
| `tools/validate-all.sh` | 코드를 고친 뒤 | `fmt` · `validate` · `terraform test` (구독 불필요) + 스크립트 문법 검사 | 위 F |

```bash
scripts/verify.sh                    # apply 한 모든 스택 검증 (안 한 스택은 건너뜀)
scripts/verify.sh 05-aks 07-ingress  # 특정 스택만
scripts/cleanup.sh --dry-run         # 삭제 계획만 보기
```

> [!TIP]
> 검증 스크립트는 **읽기 전용**입니다(파드 안에서 `printenv`/`test -s` 를 실행하는 것 외에는 아무것도 바꾸지 않습니다). `kubectl` 은 임시 kubeconfig 를 써서 `~/.kube/config` 를 수정하지 않습니다. 변수로 고를 수 있는 설정(`sku_tier`, `enable_private_cluster`, `enable_gateway_api`, `nat_gateway_sku` 등)을 기본값과 다르게 썼다면 실패(✗) 대신 값을 보여 주거나 경고(!)·건너뜀(-)으로 표시합니다. 새 스택용 검증을 추가하려면 `scripts/verify/NN-이름.sh` 에 `verify_stack` 함수를 만들고 `verify.sh` 의 `ALL_STACKS` 에 이름을 더하세요.

**`scripts/lib/common.sh`** — 모든 스크립트의 공통 함수

<!-- tf:include path="scripts/lib/common.sh" -->
```bash title="scripts/lib/common.sh"
#!/usr/bin/env bash
# Common functions shared by the verify and cleanup scripts. Don't run it directly; source it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"      # from scripts/verify/*.sh
#
# Contents: result output (pass/fail/warn), value comparison (expect_*), JSON helpers (jq),
# and wrappers for terraform output / az / kubectl.
# Works with the default macOS bash (3.2), so newer syntax such as associative arrays is not used.
# shellcheck shell=bash

# Load only once, even if sourced several times.
[ -n "${_AKS_LAB_COMMON_LOADED:-}" ] && return 0
_AKS_LAB_COMMON_LOADED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="${ROOT}/terraform"

# --- Result output ------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_DIM=''; C_OFF=''
fi

PASS=0; FAIL=0; WARN=0; SKIP=0

section() { printf '\n%s== %s%s\n' "$C_BLD" "$*" "$C_OFF"; }
pass() { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s\n' "$C_RED" "$C_OFF" "$*"; }
warn() { WARN=$((WARN + 1)); printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '  %s-%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# Call once at the end. Exit code 1 if there is at least one failure.
summary() {
  printf '\n%sSummary%s  passed %s%d%s · failed %s%d%s · warnings %d · skipped %d\n' \
    "$C_BLD" "$C_OFF" "$C_GRN" "$PASS" "$C_OFF" "$C_RED" "$FAIL" "$C_OFF" "$WARN" "$SKIP"
  [ "$FAIL" -eq 0 ]
}

# --- Value comparison ---------------------------------------------------------
expect_eq() { # description actual expected
  if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: expected '$3' / actual '${2:-(none)}'"; fi
}

expect_set() { # description value  (fails if empty or null)
  if [ -n "$2" ] && [ "$2" != "null" ]; then pass "$1: $2"; else fail "$1: no value"; fi
}

expect_ge() { # description actual minimum
  if [ "${2:-0}" -ge "$3" ] 2>/dev/null; then pass "$1: $2 (min $3)"; else fail "$1: expected at least $3 / actual '${2:-(none)}'"; fi
}

jq_ok() { # description json jq-condition  → passes if the condition is true
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else fail "$1"; fi
}

jq_warn() { # description json jq-condition  → warns if the condition is false (for items that are recommended, not required)
  if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then pass "$1"; else warn "$1"; fi
}

# --- JSON / external command wrappers -----------------------------------------
# jv JSON 'jq-filter' : extracts a value as a string (null becomes an empty string; empty input is not an error)
jv() {
  jq -r "($2) | if . == null then \"\" else tostring end" <<<"$1" 2>/dev/null
}

# azj <az args...> : runs az with JSON output. Returns an empty string on failure
# (so the script doesn't stop when a resource doesn't exist).
azj() { az "$@" -o json 2>/dev/null || true; }

# kj <kubectl args...> : gets kubectl output as JSON. Gives up after 20 seconds even if the API server doesn't respond.
kj() { kubectl --request-timeout=20s "$@" -o json 2>/dev/null || true; }

# tf_out stack output-name : terraform output -raw (empty string if there is no value or apply hasn't run yet)
tf_out() { terraform -chdir="${TF_DIR}/$1" output -raw "$2" 2>/dev/null || true; }

# nodes_nsg_rules network-resource-group : gets the rules of the 03-network node subnet NSG (…-aks-nodes) as JSON
#   (empty string if there is no NSG)
nodes_nsg_rules() {
  local nsg
  nsg="$(az network nsg list -g "$1" --query "[?ends_with(name, '-aks-nodes')].name | [0]" -o tsv 2>/dev/null)"
  [ -n "$nsg" ] || return 0
  azj network nsg rule list -g "$1" --nsg-name "$nsg"
}

# tf_applied stack : returns 0 if there is at least one output (= init and apply are done)
tf_applied() {
  local out
  out="$(terraform -chdir="${TF_DIR}/$1" output -json 2>/dev/null)" || return 1
  [ -n "$out" ] && [ "$out" != "{}" ]
}

# has_role description principalId role-name scope-prefix
#   Passes if the principal has the role assigned at or below that scope (case-insensitive).
#   AWS comparison: "is a policy attached to the IAM Role?" → in Azure, an assignment has three parts:
#   "principal + role + scope".
has_role() {
  local roles
  roles="$(azj role assignment list --assignee "$2" --all)"
  if jq -e --arg role "$3" --arg scope "$4" \
    'any(.[]; .roleDefinitionName == $role and ((.scope | ascii_downcase) | startswith($scope | ascii_downcase)))' \
    >/dev/null 2>&1 <<<"$roles"; then
    pass "$1"
  else
    fail "$1"
  fi
}

# require_cmd command... : returns 0 if all exist; otherwise prints a message and returns 1
require_cmd() {
  local missing=0 c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "Required command not found: $c" >&2; missing=1; }
  done
  return "$missing"
}

# version_ge current minimum : returns 0 if the current version >= the minimum version (e.g. version_ge 1.16.5 1.16)
version_ge() {
  local -a a b
  IFS=. read -r -a a <<<"${1#v}"
  IFS=. read -r -a b <<<"${2#v}"
  local i x y
  for i in 0 1 2; do
    x="${a[$i]:-0}"; y="${b[$i]:-0}"
    x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
  done
  return 0
}

# --- kubectl access -----------------------------------------------------------
# kube_login resource-group cluster
#   Creates a temporary kubeconfig for this script and points KUBECONFIG at it (your ~/.kube/config is not modified).
#   Does the same as `az aks get-credentials` + `kubelogin convert-kubeconfig` from Lab 05.
kube_login() {
  [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP" # Remove the previous temp file when verifying several stacks.
  _KUBECONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/aks-lab-kubeconfig.XXXXXX")"
  export KUBECONFIG="$_KUBECONFIG_TMP"
  az aks get-credentials -g "$1" -n "$2" --file "$KUBECONFIG" --overwrite-existing >/dev/null 2>&1 &&
    kubelogin convert-kubeconfig -l azurecli --kubeconfig "$KUBECONFIG" >/dev/null 2>&1
}

_aks_lab_cleanup() { [ -z "${_KUBECONFIG_TMP:-}" ] || rm -f "$_KUBECONFIG_TMP"; }
trap _aks_lab_cleanup EXIT
```
<!-- /tf:include -->

**`scripts/verify.sh`** — 스택별 검증 스크립트를 호출하는 진입점

<!-- tf:include path="scripts/verify.sh" -->
```bash title="scripts/verify.sh"
#!/usr/bin/env bash
# Lab results verification (read-only): checks with az / kubectl that each stack was built as designed.
# Names are looked up from each stack's `terraform output`, so run this after init + apply in that stack.
#
# Usage:
#   scripts/verify.sh                       # every applied stack (stacks not applied yet are skipped)
#   scripts/verify.sh 05-aks                # one stack only
#   scripts/verify.sh 03-network 04-platform
#
# Requires: terraform, az (signed in), jq   (from 05 on: kubectl, kubelogin)
# Exit codes: 0 = all passed / 1 = any failure / 2 = usage error
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

ALL_STACKS="02-bootstrap 03-network 04-platform 05-aks 06-workload 07-ingress 08-governance 10-aks-automatic"

case "${1:-}" in
  -h | --help)
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

require_cmd terraform az jq || exit 2
if ! az account show >/dev/null 2>&1; then
  echo "az login is required." >&2
  exit 2
fi

explicit=0
stacks="$ALL_STACKS"
if [ "$#" -gt 0 ]; then
  explicit=1
  stacks="$*"
fi
for s in $stacks; do
  case " $ALL_STACKS " in
    *" $s "*) ;;
    *)
      echo "Unknown stack: $s (available: $ALL_STACKS)" >&2
      exit 2
      ;;
  esac
done

info "Subscription: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"

for s in $stacks; do
  if ! tf_applied "$s"; then
    section "$s"
    if [ "$explicit" -eq 1 ]; then
      fail "Not applied yet, or init is required (terraform -chdir=terraform/$s init -backend-config=../backend.hcl)"
    else
      skip "Stack not applied yet; skipping"
    fi
    continue
  fi
  # shellcheck source=/dev/null
  source "${HERE}/verify/${s}.sh"
  verify_stack
done

summary
```
<!-- /tf:include -->

**`.shellcheckrc`** — ShellCheck 설정 (`source` 경로를 스크립트 위치 기준으로 해석)

<!-- tf:include path=".shellcheckrc" -->
```text title=".shellcheckrc"
# ShellCheck configuration: resolve source paths relative to the script location.
#   shellcheck scripts/*.sh scripts/lib/*.sh scripts/verify/*.sh tools/*.sh
source-path=SCRIPTDIR
external-sources=true
```
<!-- /tf:include -->
