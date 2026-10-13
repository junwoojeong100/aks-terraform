<!-- lang-switch -->
**English** | [한국어](ko/09-operations.md)
<!-- /lang-switch -->

# Lab 09. Day-2 operations: upgrades · scaling · node replacement · testing

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 40 min (reading + optional experiments) | Extra nodes during experiments | No new stack (variable changes in `terraform/05-aks`) | [05. AKS cluster](05-aks.md) |

**Operating a cluster safely over time** is harder than creating one. This lab explains how to carry out Day-2 tasks as *Terraform variable changes*, along with the points to watch out for.

## Comparison for AWS engineers

| AWS (EKS) | Azure (AKS) | Differences / notes |
|---|---|---|
| Control plane minor upgrade → node group upgrade | **Auto-upgrade channel** or `az aks upgrade` (control plane first, then node pools) | Nodes are replaced in a rolling fashion by **adding temporary nodes** (up to `max_surge`). In this lab, Terraform ignores the version after creation (`ignore_changes`) so that AKS manages it; managing the version in code as well (option C) is covered separately below. |
| Extended Support (14 months → +12 months, paid) | 12 months of support + **LTS (Premium tier, optional)** | From 2027-06, the platform automatically upgrades versions that are out of support (ignoring the maintenance window, and possibly PDBs too → upgrade ahead of time). |
| Node AMI updates | `node_os_upgrade_channel` (`NodeImage`) + `maintenance_window_node_os` | Automatically replaces the node image in a weekly window. |
| Karpenter drift / consolidation | **NAP** (`node_provisioning_profile.mode = "Auto"`) | Optional on Standard, default on Automatic. This lab defaults to Cluster Autoscaler (`Manual`). |
| Changes through `eksctl` or the console | **Change a variable → plan → apply** | Manual changes (`az aks update`) cause drift from Terraform, so make changes in code. (Exception: the Kubernetes version is handled with `ignore_changes` so that AKS manages it.) |

## 1. Upgrade strategy

![Upgrade flow: patch · node image · minor](diagrams/upgrade-flow.svg)

### Auto-upgrade channels

| Channel | Behavior | In this lab |
|---|---|---|
| `none` | Manual | Used in option C (below) |
| **`patch`** | Automatically moves to the latest patch of the same minor | ✅ **Default** (you upgrade minor versions yourself after a preflight check) |
| `stable` | N-1 of the latest GA minor | Used by AKS Automatic |
| `rapid` | Latest GA minor | Development environments |
| `node-image` | Node image only | (use `node_os_upgrade_channel` instead) |

**When** upgrades happen is controlled with `maintenance_window_auto_upgrade` (Kubernetes version) and `maintenance_window_node_os` (node OS image). The lab code uses Sunday 02:00 KST / Saturday 02:00 KST, 4 hours.

> [!IMPORTANT]
> The maintenance window applies only to **automatic upgrades**. A *manual* upgrade, where you raise the version with `az aks upgrade` or Terraform, starts immediately. Run it outside business hours.

### Minor upgrades (for example, 1.36 → 1.37, after GA)

> [!WARNING]
> As of 2026-10, 1.37 is in **preview** and is expected to reach GA (automatic upgrades do not move to a preview version). Upgrade production clusters after GA, and in the order **development → staging → production**. The steps below are an example of the procedure after GA.

> [!IMPORTANT]
> **Why does Terraform "ignore" the Kubernetes version?** When AKS automatically upgrades the patch version of a cluster created with a minor alias such as `kubernetes_version = "1.36"`, the actual version (for example, 1.36.6) no longer matches the alias, so in azurerm **5.9.0 and earlier** every `plan` shows a needless diff of `1.36.6 -> 1.36` ([#26946](https://github.com/hashicorp/terraform-provider-azurerm/issues/26946)). A fix that suppresses this ([PR #32625](https://github.com/hashicorp/terraform-provider-azurerm/pull/32625)) has been merged and is included in **v5.10.0 (scheduled for 2026-10-15)**. To be safe on any provider version, this lab sets the version **only at creation time** and afterwards lets AKS manage it with `lifecycle { ignore_changes = [kubernetes_version, default_node_pool[0].orchestrator_version] }` (`[orchestrator_version]` for the User/Spot pools). Of the three options below, pick the one that fits your team's operating model.

| Option | Who upgrades the version | Best for | In this lab |
|---|---|---|---|
| **A. Automatic channel** (`stable`/`rapid`) | AKS, automatically up to the minor version, in the maintenance window | Minimal operational burden; dev and small environments (same model as AKS Automatic) | Change only the `automatic_upgrade_channel` value and `apply` |
| **B. Manual `az aks upgrade`** | A person: preflight check first, then control plane → node pools | Production clusters where you want patches to be automatic but minor upgrades under your control | ✅ **Default setup** (`patch` channel + `ignore_changes`) |
| **C. Terraform as the single source of truth** | Change the version variable in a PR and `apply` | Organizations that need every change recorded through code review | See *C-1 / C-2* below |

Preflight check (shared by B and C):

```bash
RG="$(terraform output -raw resource_group_name)"; CLUSTER="$(terraform output -raw cluster_name)"
az aks get-versions -l koreacentral -o table 2>/dev/null      # supported versions / upgrade paths (warning messages go to stderr)
az aks get-upgrades -g "$RG" -n "$CLUSTER" -o table

# Are you using removed (deprecated) APIs? Upgrades can get blocked automatically, but check ahead of time
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis | head
```

**B. Manual upgrade (default setup)**

```bash
# 1) Upgrade only the control plane first, then confirm that apps and add-ons are healthy
az aks upgrade -g "$RG" -n "$CLUSTER" --kubernetes-version "<1.37.x from get-upgrades>" --control-plane-only

# 2) Upgrade the node pools one at a time (rolling replacement, adding temporary nodes up to max_surge)
az aks nodepool upgrade -g "$RG" --cluster-name "$CLUSTER" -n system --kubernetes-version "<1.37.x>"
az aks nodepool upgrade -g "$RG" --cluster-name "$CLUSTER" -n user   --kubernetes-version "<1.37.x>"
```

Version changes are ignored through `ignore_changes`, so `terraform plan` shows no diff. However, when you **add a new node pool** later (for example, `enable_spot_pool = true`), the new pool is created with `var.kubernetes_version`, so align it by passing `-var kubernetes_version=<current cluster minor>`.

**C. Managing the version with Terraform as well (how to switch)**

Common to both: remove the `kubernetes_version` / `orchestrator_version` entries from `lifecycle { ignore_changes }` in `cluster.tf` and in the node pools (`user`, `spot`). Then pick one of the two.

- **C-1. Pin the full patch version (works with every provider version)**: set `automatic_upgrade_channel = "none"` (keep `node_os_upgrade_channel = "NodeImage"` for node OS replacement), and set `kubernetes_version` to a **full patch version** instead of an alias (for example, `1.36.4`). Patch security updates are also applied by hand through variable change → PR → apply.
- **C-2. Keep the alias (requires azurerm ≥ 5.10)**: keep `automatic_upgrade_channel = "patch"` and leave the `kubernetes_version = "1.36"` alias as it is. AKS raises the patch version (the provider treats the alias as equivalent to the actual patch version, which suppresses the diff), and when you raise the alias to `"1.37"`, the minor upgrade shows up in the plan. 5.10.0 has not been released yet, so this guide was verified with 5.9.0. After the release, upgrade with `terraform init -upgrade`, confirm that `plan` shows no needless diff, and then use it.

```bash
export TF_VAR_kubernetes_version=1.37.1   # C-1: full version confirmed with az aks get-upgrades (example). For C-2, use 1.37
terraform plan -out tfplan      # ~ kubernetes_version, default_node_pool/orchestrator_version, user pool orchestrator_version
terraform apply tfplan          # control plane → system pool → user pool. A few minutes per node.
```

What to watch during the upgrade:

```bash
kubectl get nodes -w                         # temporary (surge) node added → cordon/drain → old node removed
kubectl get pdb -A                           # PDBs limit the drain speed (the app in Lab 07 uses maxUnavailable=1)
kubectl get events -A --field-selector reason=Evicted
```

> [!TIP]
> When the upgrade finishes, run `scripts/verify.sh 05-aks` from the repository root to check, read-only, that all nodes are Ready and the add-on pods are Running. If you changed the upgrade channel (option A / C-1), the changed value is shown as-is.

| Checklist | Why |
|---|---|
| PDBs, replicas ≥ 2, readiness probes | Availability during drains |
| Spare subnet IPs (enough for a `max_surge` of 33%) | Temporary nodes consume IPs |
| Check the list of APIs being removed | Manifest/Helm chart compatibility |
| Add-on/CRD compatibility (the Gateway API bundle is **upgraded automatically to match the cluster version**) | Managed Gateway API CRD v1.5.1 (1.36) → v1.6.1 (1.37+) |

## 2. Scaling

| Layer | Tool | Setup in this lab |
|---|---|---|
| Pod count | **HPA** (CPU/memory), **KEDA** (event-driven: Service Bus, Kafka …) | HPA: Lab 07 / KEDA: `workload_autoscaler_profile.keda_enabled` |
| Pod size | **VPA** (recommends requests/limits) | `vertical_pod_autoscaler_enabled` |
| Node count | **Cluster Autoscaler** (min/max per node pool) | system 3–5, user 3–6 |
| Node type | **NAP** (Karpenter) | Try it in Lab 10 |
| Cost | **Spot pool** | `-var enable_spot_pool=true` |

```bash
# Node autoscaler events and current status
kubectl -n kube-system get configmap cluster-autoscaler-status -o yaml | head -40
kubectl get events -A | grep -i -E "TriggeredScaleUp|ScaleDown"

# Why Terraform doesn't fight the autoscaler: the code doesn't set node_count and declares only min/max.
```

> [!TIP]
> **Don't hard-code the node count.** When `auto_scaling_enabled = true`, declare only `min_count`/`max_count`. If you set `node_count`, it keeps conflicting with the values the autoscaler changes (if you must set it, use `lifecycle.ignore_changes`).

## 3. Changing and replacing node pools

Changing `vm_size`, `os_disk_*`, `zones`, `vnet_subnet_id`, and similar attributes **replaces** the node pool. This lab sets `temporary_name_for_rotation` (`systemtmp`, `usertmp`) so that a temporary pool is created first and the replacement happens afterwards. That is why the plan shows **`will be updated in-place`** instead of `replace`; the provider performs the actual replacement (create the temporary pool → remove the old pool) during apply.

```bash
terraform plan -var user_node_vm_size=Standard_D8ds_v5   # vm_size: D4ds_v5 -> D8ds_v5 (user pool updated in-place)
```

> [!CAUTION]
> Rotation removes the old pool **without cordon/drain**, so pods can be interrupted. In production, a blue-green approach (*add a new pool → cordon/drain the existing pool → confirm the pods have moved → remove the existing pool*) is safer. Even for workloads that have a PDB, always run this during planned maintenance time.

## 4. Operating habits that save money

```bash
# Taking a break during the lab: stop the control plane and nodes (node VM billing stops; some setups such as Spot pools may have limitations, so check the docs)
az aks stop  -g <rg> -n <cluster>
az aks start -g <rg> -n <cluster>

# Cost per namespace/workload (cost_analysis_enabled) → portal: AKS → Cost Management → Cost analysis
```

## 5. Backup and disaster recovery (concepts)

| Need | Azure service | Notes |
|---|---|---|
| Cluster resource / PV backup | **Azure Backup for AKS** (Backup vault + extension) | The managed counterpart of Velero. Includes PV snapshots. |
| Multi-region | A cluster per region + **Azure Front Door**/Traffic Manager; **Fleet Manager** for multiple clusters | The mission-critical pattern from the WAF guide. Design the IP ranges so they don't overlap across regions. |
| GitOps | **Flux extension** (`azurerm_kubernetes_flux_configuration`) | Bootstrap clusters and deploy apps from Git. |

## 6. Terraform code quality and CI

This repository provides a **three-stage static validation** that runs without an Azure subscription.

```bash
tools/validate-all.sh            # 1) fmt -check  2) validate  3) terraform test (mock provider)
```

| Stage | What it catches |
|---|---|
| `terraform fmt -check` | Formatting consistency |
| `terraform validate` | Provider schema violations (for example, arguments removed in azurerm 5.x) — **run this first when you upgrade versions** |
| `terraform test` (mock) | **Plan logic** such as variable validation, `count`/`for_each`, conditional expressions, and tag and naming-convention rules |

A real PR pipeline adds plan review and security scanning (for example, `trivy config`, `checkov`) on top of this. Here is a GitHub Actions (OIDC) example that signs in without passwords (replace the action versions with the latest ones).

```yaml
name: terraform-plan
on: pull_request
permissions: { id-token: write, contents: read }
jobs:
  plan:
    runs-on: ubuntu-latest
    env:
      ARM_USE_OIDC: "true"                 # Workload identity federation (no passwords/keys)
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
> **Drift detection**: running `terraform plan -detailed-exitcode` periodically from a scheduler lets you find settings that someone changed through the portal or CLI (exit code 2).

Next → [Lab 10. AKS Automatic](10-aks-automatic.md)
