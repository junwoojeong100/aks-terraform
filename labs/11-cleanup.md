# Lab 11. 정리: 비용이 새지 않게 모두 삭제하기

| 소요 시간 | 예상 비용 | Terraform 스택 | 선행 실습 |
|---|---|---|---|
| 20~40분 | 정리하지 않으면 계속 과금 | 모든 스택 (역순) | 실습을 마친 모든 Lab |

> [!CAUTION]
> AKS 노드(VM), NAT Gateway, 공인 IP, Premium ACR, Managed Grafana, Defender 플랜은 **켜 두는 동안 계속 과금**됩니다. 실습을 마쳤거나 오래 쉴 때는 반드시 정리하세요.

## 삭제 순서 (생성의 역순)

`06/07` 은 클러스터가 살아 있어야 `kubernetes` provider 가 접속해 삭제할 수 있으므로 **05 보다 먼저** 지웁니다.

```text
10-aks-automatic → 08-governance → 07-ingress → 06-workload → 05-aks → 04-platform → 03-network → 02-bootstrap
```

## 사전 점검 (잠금과 구독 단위 설정)

```bash
cd terraform

# 1) 08 에서 잠금을 켰다면 먼저 해제 (잠금이 있으면 destroy 가 ScopeLocked 로 실패)
terraform -chdir=08-governance apply -auto-approve -var enable_resource_locks=false

# 2) Defender 구독 플랜을 켰다면 08 destroy 로 함께 꺼집니다. (Terraform 밖에서 켰다면 직접 끄기)
az security pricing show -n Containers --query pricingTier -o tsv
# az security pricing create -n Containers --tier free
```

## 1단계. 스택별 destroy

```bash
for s in 10-aks-automatic 08-governance 07-ingress 06-workload 05-aks 04-platform 03-network; do
  echo "================ destroy $s"
  terraform -chdir=$s init -backend-config=../backend.hcl -input=false >/dev/null
  terraform -chdir=$s destroy -auto-approve
done
```

> [!NOTE]
> 환경 변수(`ARM_SUBSCRIPTION_ID`, `TF_VAR_allowed_ip_ranges` 등)가 설정된 터미널에서 실행하세요. `10-aks-automatic` 을 만든 적이 없다면 `destroy` 가 "No changes" 로 끝납니다.
> 각 스택의 `destroy` 는 `terraform plan -destroy` 로 먼저 삭제 목록을 확인하는 습관을 들이세요.

### 클러스터를 먼저 지워서 06/07 destroy 가 실패할 때

`kubernetes` provider 가 접속할 클러스터가 없으면 `destroy` 가 실패합니다. 이 경우 쿠버네티스 리소스를 state 에서 제거한 뒤 Azure 리소스만 삭제합니다(클러스터가 사라졌으므로 안의 리소스도 이미 없습니다).

```bash
cd 07-ingress
terraform state list | grep -E '^kubernetes_' | xargs -n1 terraform state rm
terraform destroy -auto-approve
```

## 2단계. 부트스트랩(state 저장소) 삭제

`02-bootstrap` 의 state 를 Blob 으로 이전했다면, **자기 자신이 담긴 스토리지를 지울 수 없습니다.** 먼저 로컬 state 로 되돌린 뒤 삭제합니다.

```bash
cd 02-bootstrap
# versions.tf 의 backend "azurerm" 블록을 다시 주석 처리한 뒤
terraform init -migrate-state -force-copy
terraform destroy -auto-approve
rm -f ../backend.hcl
```

## 3단계. 정리 확인

```bash
# 이 가이드가 만든 리소스 그룹 (태그 lab=aks-terraform-guide) → 비어 있어야 합니다
az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv

# AKS 가 만든 노드 리소스 그룹도 사라졌는지
az group list --query "[?contains(name,'-aks-nodes') || starts_with(name,'MC_')].name" -o tsv

# soft-delete 상태로 남은 리소스
az keyvault list-deleted --query "[].{name:name, purgeDate:properties.scheduledPurgeDate}" -o table
az monitor log-analytics workspace list-deleted-workspaces -o table 2>/dev/null

# 고아가 된 역할 할당(삭제된 주체) 정리가 필요하다면
az role assignment list --all --query "[?principalName==''].{id:id, scope:scope}" -o table
```

### Key Vault 가 남아 있는 이유

Lab 04 의 Key Vault 는 `purge_protection_enabled = true`(권장)이므로 삭제 후에도 **soft-deleted 상태로 7일간 이름을 점유**합니다. 같은 이름으로 다시 만들면 provider 가 자동 복구(`recover_soft_deleted_key_vaults = true`)합니다. 비용은 발생하지 않습니다. 곧바로 완전히 지우고 싶다면 처음부터 `-var key_vault_purge_protection_enabled=false` 로 만들고, 삭제 후 `az keyvault purge` 를 사용하세요.

## 비상 정리 (Terraform 이 실패할 때)

리소스 그룹을 통째로 삭제하는 가장 빠른 방법입니다. state 는 정리되지 않으므로 **Terraform 을 다시 쓸 계획이 없을 때만** 사용하세요.

```bash
for rg in $(az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv); do
  az group delete -n "$rg" --yes --no-wait
done
```

## 비용 확인

- 포털 → **Cost Management → Cost analysis** → 필터: 태그 `lab = aks-terraform-guide` (또는 `workload = aksdemo`)
- 삭제한 다음 날 비용이 0 에 수렴하는지 확인합니다(일부 항목은 하루 늦게 반영).
- 예산(Lab 08)을 만들었다면 정리와 함께 삭제됩니다.

- [ ] 모든 스택을 destroy 했다
- [ ] 리소스 그룹 목록이 비어 있다 (`lab=aks-terraform-guide`)
- [ ] (사용했다면) Defender 구독 플랜을 `free` 로 되돌렸다
- [ ] 로컬 `.terraform/`, `backend.hcl`, `tfplan` 파일을 삭제했다

다음 → [부록](99-appendix.md)
