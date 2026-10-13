<!-- lang-switch -->
**English** | [한국어](ko/99-appendix.md)
<!-- /lang-switch -->

# Appendix. Troubleshooting · production checklist · references · test code

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| Reference only | None | `terraform/mocks`, `scripts/`, `tools/validate-all.sh` | None |

## A. How this guide was validated, and its limits

### A-1. Static validation (no Azure needed)

| Check | Details | Result |
|---|---|---|
| `terraform fmt -check` | All stacks and modules | Passed |
| `terraform validate` | Against the actual schemas of azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · random 3.9.1 · time 0.14.2 | Passed |
| `terraform test` (mock provider) | Plan logic + variable validation of all stacks (<!-- count:test-runs -->34<!-- /count --> runs in total, including the `naming` module) | Passed |
| AzAPI body validation | Property names of `Microsoft.ContainerService/managedClusters@2026-05-01` checked against the OpenAPI spec and azapi's built-in schema | Passed |
| Built-in policy definition IDs | 8 IDs checked with `az policy definition show` | Confirmed |
| VM size / zones | Checked that `Standard_D4ds_v5` is available in koreacentral zones 1, 2, and 3 | Confirmed |
| Shell script static checks | All of `scripts/` checked with `bash -n` and ShellCheck, and also run with the macOS default bash 3.2 | Passed |

### A-2. Results of running everything end to end in a real Azure subscription (2026-10-13)

To check what static validation alone cannot reveal, the commands in the docs were run **in order from Lab 01 through Lab 11 in a real subscription**, and the results were checked with each lab's `scripts/verify.sh`. Everything was deleted with Lab 11 at the end.

| Item | Details |
|---|---|
| Subscription | Personal Visual Studio Enterprise subscription (Owner), signed in with a guest (personal) account, region koreacentral |
| Tools | Terraform 1.16.5 · azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · Azure CLI 2.86.0 · kubectl 1.37.1 · kubelogin 0.2.8 (macOS, arm64) |
| Clusters | Standard 1.36.4, Automatic 1.35.8 (the `stable` channel is N-1) |
| Quota | The subscription defaults were 20 vCPUs per family and 32 in total, so they were raised to 48 and 64 with the method in [Lab 01](01-prerequisites.md) §4, and then the default configuration (D4ds_v5) was run |

| Lab | What was run | Result |
|---|---|---|
| [01](01-prerequisites.md) | Tool installation (`brew`), RP registration, quota and VM size checks, `preflight.sh` | Passed (16/16). Fixed the role check that failed with a guest account |
| [02](02-bootstrap.md) | naming tests, apply (4 resources, 1 min 32 s), `backend.hcl`, migrating state to remote, blob listing and confirming key authentication is off, locking with concurrent plans and `-lock-timeout`, `verify.sh` | Passed (9/9) |
| [03](03-network.md) | apply (26 resources, 2 min), subnet · NAT · NSG checks, `verify.sh`, measured NSG behavior (below), the 4 code paths of `gateway_allowed_source_prefixes` | Passed (19/19) |
| [04](04-platform.md) | apply (18 resources, 4 min), ACR · Key Vault · Private Endpoint · DNS checks, `az acr import`, Grafana's Prometheus data source, PromQL `count(up)`, `verify.sh` | Passed (17/17) |
| [05](05-aks.md) | apply, kubeconfig, node · add-on · Gateway API checks, KQL, adding and removing a Spot pool, plan for switching to private, `az aks command invoke`, `verify.sh` | Passed (33/33). Fixed the first apply failure (409 race). Spot scale-up not verified because of insufficient capacity |
| [06](06-workload-identity.md) | apply, mounted secret = Key Vault value, token claims, 2-minute automatic refresh, private DNS (10.10.3.x), `verify.sh` | Passed (9/9). Fixed the first apply failure (PSS) |
| [07](07-ingress.md) | apply (22 s), public Gateway `curl` 200, HPA 3→10, NetworkPolicy blocking, switching to an internal Gateway (10.10.2.x) and back, `verify.sh` | Passed (8/8; internal mode 7/7 + 1 skipped) |
| [08](08-governance.md) | apply (9 resources), Gatekeeper constraint sync, compliance state, Deny effect, budget, lock (`ScopeLocked`), `verify.sh` | Passed (9, 1 warning). Defender subscription plan not run |
| [09](09-operations.md) | Upgrade preflight checks, autoscaler status, vm_size change plan, `az aks stop` (3 min) / `start` (5 min) | Partial. The upgrade itself could not be run |
| [10](10-aks-automatic.md) | apply (about 9 min), NAP · Deployment Safeguards, re-creating with a BYO VNet (about 11 min) and deleting it, `verify.sh` | Passed (10/10) |
| [11](11-cleanup.md) | `cleanup.sh --dry-run`, actual deletion, verifying cleanup | See *A-5* below |

**Measured NSG behavior (Lab 03).** These are the results of deleting rules or adding Deny rules and observing the effect. The guide first said that "the Pod CIDR is blocked by the default Deny", but that did not match the measurements, so it was corrected.

| Experiment | Result |
|---|---|
| Deleted `AllowPodsToPods` from the node NSG (only the default rules remain) | Pod-to-Pod traffic between nodes and DNS work **normally** → allowed by the default rules |
| From that state, added a Pod → Pod Deny (4000) | Timeouts and DNS failures. Restoring `AllowPodsToPods` (110) returns things to normal |
| Deleted `AllowGatewayHttpHttps` | Public Gateway unreachable (timeout). Restoring it returns 200 → **required** |
| Added an API server subnet → node Deny and deleted `AllowApiServerToCluster` | `kubectl exec` fails with `connection reset`. Normal again once the rule is restored |
| Added an API server subnet → Pod Deny and deleted the rule | Gatekeeper webhook calls work normally → the rule for Pods is defensive |
| Where AKS writes LB rules | `k8s-azure-lb_allow_…` rules appear only in the node resource group's own NSG (attached to the NIC); the NSG attached to the subnet is left as is |
| `gateway_allowed_source_prefixes` | Default (`Internet`) · multiple CIDRs (plural attribute) · a single CIDR (singular attribute) · `[]` (rule removed): the plan is clean after apply in every case |

**Re-run for the English edition (2026-10-14).** The English edition changes only comments, descriptions, and message text in the Terraform code and the scripts (a structural comparison with the earlier sources found no other change). To confirm that nothing broke, the commands in the English docs were run again from Lab 01 to Lab 11 in the same subscription (personal Visual Studio Enterprise, koreacentral, the same tool versions), and every `scripts/verify.sh` result was compared with the run above.

| Lab | What was run | Result |
|---|---|---|
| [01](01-prerequisites.md) | `preflight.sh` | Passed 16/16 |
| [02](02-bootstrap.md) | apply (4 resources), state migration to Blob, `verify.sh` | Passed 9/9 (8 passed + 1 warning before the migration) |
| [03](03-network.md) | apply (26), `verify.sh`, the manual checks from the lab | Passed 19/19 |
| [04](04-platform.md) | apply (18), `az acr import`, `verify.sh`, the manual checks from the lab | Passed 17/17 |
| [05](05-aks.md) | apply (15), kubeconfig, nodes · GatewayClass · KQL checks, `verify.sh` | Passed 33/33 |
| [06](06-workload-identity.md) | apply (11), secret mount = Key Vault value, token claims, 2-minute secret refresh, `verify.sh` | Passed 9/9 |
| [07](07-ingress.md) | apply (8), public Gateway `curl` 200, NetworkPolicy block, internal Gateway (10.10.2.x) and back, `verify.sh` | Passed 8/8 (internal mode 7/7 + 1 skipped) |
| [08](08-governance.md) | apply (9), the Deny effect rejects a privileged pod, locks → `ScopeLocked`, `verify.sh` | Passed 10/10 with the default Audit effect; 9 passed + 1 warning with locks on |
| [09](09-operations.md) | Upgrade pre-checks (`az aks get-versions` · `get-upgrades`, deprecated APIs, autoscaler status) | Ran as documented (the upgrade itself was not run) |
| [10](10-aks-automatic.md) | apply (4), Deployment Safeguards and NAP experiments, `verify.sh` | Passed 10/10 |
| [11](11-cleanup.md) | `cleanup.sh --dry-run`, `cleanup.sh --yes`, bootstrap deletion, cleanup check | Everything deleted (AKS about 6 min, AKS Automatic about 8 min, Managed Grafana about 10 min); no tagged resource groups left |

As before, Azure created `NetworkWatcherRG` and Defender's default Log Analytics workspace (`DefaultResourceGroup-…`) during the run, and both were deleted by hand. The only thing left is one Key Vault in the soft-deleted state (purge protection is on, so it is removed automatically after 7 days, and it costs nothing).

### A-3. Inconsistencies found and fixed during the run

| # | Location | Symptom | Fix |
|---|---|---|---|
| 1 | `05-aks/monitoring.tf` | The first apply failed with `409 AnotherOperationInProgress`: AzAPI's PUT of the cluster overlapped with the creation of the User node pool | Added `depends_on` so that `azapi_update_resource.control_plane_metrics` runs after the node pool |
| 2 | `06-workload/kubernetes.tf`, `07-ingress/app.tf` | `kv-demo` was rejected with `violates PodSecurity "restricted": runAsNonRoot != true` and failed after waiting 10 minutes for the rollout. The kubernetes provider sends omitted container `security_context` values as `false`, which overrides the pod-level `true` (the app container in 07 had the same configuration) | Set `run_as_non_root = true` explicitly in the container `security_context` |
| 3 | `scripts/cleanup.sh` | With pipefail, `tf_state \| grep -q` had its result flipped by SIGPIPE, so the cluster was judged "already gone" even though it existed, and the Kubernetes resources in 06 were removed from the state. A failure to read the state could also have been mistaken for "empty", causing a stack to be skipped | Capture the output in a variable first and treat a read failure as an error |
| 4 | `scripts/preflight.sh` | A guest (personal) account cannot look up roles by sign-in name, which produced the warning "Couldn't query roles" | Look up roles by the signed-in user's object ID |
| 5 | Lab 01 §4 | The default subscription quota (e.g., 20 per family · 32 in total) can be lower than the minimum of 24 vCPUs | Added a required-capacity table and an `az quota create` example |
| 6 | Lab 03, `03-network` comments | The explanation that "the Pod CIDR is not part of the VirtualNetwork tag, so the default Deny blocks it" did not match the measurements | Corrected: only the public Gateway rule is required; the Pod and API server rules are defensive and needed only when you add a Deny |
| 7 | Lab 06 step 1 | `terraform -chdir=../04-platform` fails from the repository root | `terraform -chdir=terraform/04-platform` |
| 8 | Lab 06 step 3 | `base64 -d`, used to decode the JWT, truncates the output on macOS because the padding is missing | Decode with python after fixing the padding |
| 9 | Lab 08 step 3 | If the test pod is created in `web`, Pod Security (baseline) rejects it before Gatekeeper does, so the message shown in the doc does not appear | Test in the `default` namespace |
| 10 | Lab 07 step 3 | `kubectl logs deploy/…` shows only one of the 2 Envoy pods, so you may see just the startup logs | Label selector + `--prefix` |
| 11 | Lab 09 §3 | The vm_size change plan is shown as `updated in-place`, not `replace` (the replacement through a temporary pool happens during apply) | Corrected the explanation |
| 12 | Lab 10 step 2 | Automatic was created at 1.35, so the Gateway API CRD is missing and `kubectl get gatewayclass` fails | Added a note that this applies only to 1.36+ |
| 13 | Lab 05 · 08 | The number of resources stated for the plan did not match reality | Lab 05: corrected 16 → 15 (including the resource group); Lab 08: corrected to 8 policy assignments + 1 `time_static` = 9 |

### A-4. What could not be verified, and what varies by environment

- **Spot scale-up (Lab 05 (a))**: Adding and removing the pool was verified, but when pods were deployed, no nodes were added because of `SkuNotAvailable` (Capacity Restrictions: `Standard_D4ds_v5`). Spot capacity varies by region and time.
- **Upgrade (Lab 09 §1)**: It could not be run because there was no GA version to upgrade to (1.36.4 is the latest GA, 1.37.0 is in preview, and the node image is also the latest). Rolling replacement (surge · PDB) is unverified.
- **Defender subscription plan (Lab 08 step 4)**: It was already enabled in this subscription, so it was not run (if Terraform manages it, `destroy` reverts it to Free, which can change the subscription's existing settings). Only the cluster-level `enable_defender` was used.
- **Subscriptions with a Defender auto-provisioning policy**: Right after the cluster is created, it stays in `Updating` for a while, so the provisioning-state check in `verify.sh` fails temporarily, and the 05-aks plan keeps showing a diff that removes `microsoft_defender`. Matching it with `-var enable_defender=true` makes the diff disappear ([Lab 08](08-governance.md) step 2).
- **Subscriptions where an organization policy turns off public access to Storage**: In a subscription where an Azure Policy (Modify) at the management group changes a storage account's public network access to `Disabled`, remote state access in Lab 02 failed with `403 AuthorizationFailure` (even if Terraform creates the account with `Enabled`, the policy changes it). This guide assumes a public endpoint + Entra authentication, so you need a policy exemption or a different subscription.
- **`terraform plan -detailed-exitcode`**: It returns `2` even when the provider changes only the `available_kubernetes_versions` output value (no actual infrastructure change). Ignore this value when your CI decides whether there are "no changes".
- **Not run**: Windows (PowerShell) commands, other regions, team environments (Entra group `admin_principal_ids`), an actual deployment with `enable_private_cluster=true` (plan only), a TLS (443) listener, Application Gateway for Containers, signing in to the Grafana web UI, interactive sign-in with `az login`, and the GitHub Actions workflow example in [Lab 09](09-operations.md) §6.
- **Intermittent Azure CLI error**: `az aks get-credentials` failed once with `Error loading command module 'serviceconnector': deadlock` and succeeded when run again (a problem on the CLI side).

### A-5. Cleanup results (Lab 11)

| Item | Result |
|---|---|
| `cleanup.sh --dry-run` | The plan was printed in the same order and with the same commands as in the doc |
| Stack deletion | The 03–10 stacks were deleted with `cleanup.sh --yes`. The slow ones are the AKS cluster (about 6 min), AKS Automatic (about 10 min), and **Managed Grafana (about 10 min)**; the rest take from a few seconds to a few minutes |
| Bootstrap deletion | As described in the doc, the backend block was commented out, the state was moved back to local with `terraform init -migrate-state -force-copy`, and the bootstrap was deleted with `cleanup.sh --yes --include-bootstrap` (stacks that were already deleted were skipped with "state is empty") |
| Cleanup check | No resource groups tagged `lab=aks-terraform-guide`, no AKS node resource groups, and no resource locks · budgets · policy assignments. The subscription's resource group and resource counts are the same as before the run |
| What remains | One Key Vault in the soft-deleted state. Purge protection is on, so it is deleted automatically after 7 days, and it costs nothing |
| Byproducts outside Terraform | `NetworkWatcherRG`, which Azure created automatically during the run, and Defender's default Log Analytics workspace (`DefaultResourceGroup-…`) are resources Terraform does not know about, so they were deleted by hand (the workspace was recovered from the soft-deleted state and then permanently deleted with `--force`) |
| Problem found during the run | The `cluster_gone` misjudgment in `cleanup.sh` (item 3 in A-3). After the fix, confirmed with a unit test of the SIGPIPE condition and an actual cleanup |
| Regression check | The fixed 05-aks was created from scratch in a single `apply` (15 resources, 18 min 11 s), succeeded without a 409, and was then deleted again |

At the subscription level, the `Microsoft.Quota` Resource Provider registration and the vCPU quota increase (Lab 01 §4) remain. Neither costs anything.

## B. Troubleshooting collection

| Symptom | Cause / fix |
|---|---|
| `Error: ... subscription_id is a required provider property` | Set the `ARM_SUBSCRIPTION_ID` environment variable ([Lab 01](01-prerequisites.md)). |
| `MissingSubscriptionRegistration` / `ResourceProviderNotRegistered` | Register the RP (azurerm 5.x does not register providers automatically). `az provider register --namespace Microsoft.XXX`. |
| `AuthorizationFailed` | The current user lacks permissions (Contributor + User Access Administrator, or Owner), or a role assignment you just created is still propagating (up to 5 min). |
| `Error acquiring the state lock` | Another run is in progress, or a previous run exited abnormally. Use `terraform force-unlock <LOCK_ID>` only when you are sure. |
| `Error: Unsupported argument` / `Missing required argument` (azurerm) | Differences between 4.x code and the 5.x schema. Locate the problem with `terraform validate` and see the [5.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide). |
| `Provider produced inconsistent result after apply` (kubernetes_manifest) | CRD defaults / server-side normalization differences. Retry `terraform apply` or use `computed_fields`. |
| `StorageAccountAlreadyTaken` / `VaultAlreadyExists` / ACR name conflict | Globally unique name conflict. Change `TF_VAR_workload`, or recover/purge the soft-deleted Key Vault. |
| `terraform destroy` fails with `ScopeLocked` | Remove the resource lock ([Lab 08](08-governance.md), [Lab 11](11-cleanup.md)). |
| `kubectl: Unable to connect ... i/o timeout` | Your public IP changed → update `TF_VAR_allowed_ip_ranges`, then `apply` 05-aks (API server authorized IP). |
| `kubelogin` error / `Unauthorized` | Rerun `az login`, run `kubelogin convert-kubeconfig -l azurecli`, and wait for the Azure RBAC role to propagate. |
| `terraform plan` asks for a `node_count` change every time | Conflict with the autoscaler. Don't set `node_count` in the code; use only `min_count`/`max_count` ([Lab 09](09-operations.md)). |
| `409 ... AnotherOperationInProgress` (`azapi_update_resource`) | It overlapped with another operation on the same cluster (such as node pool creation). The code in this guide fixes the order with `depends_on`; if they still overlapped, rerun `terraform apply` after the other operation finishes. |
| `kubernetes_deployment_v1` fails after 10 minutes with `Waiting for rollout to finish` | This happens when the pods are not being created. Check the `FailedCreate` reason in `kubectl -n <namespace> get events` (e.g., `violates PodSecurity "restricted"` → `run_as_non_root` in the container `security_context`). |
| `terraform init -migrate-state` fails with `403 AuthorizationFailure` | If the role assignment you just created is still propagating, retry after 1–5 minutes. If it persists, check `az storage account show -n <account> --query publicNetworkAccess`. If it is `Disabled`, an organization policy has turned off public access, so you need a policy exemption or a different subscription. |

## C. Checklist before going to production

This guide is a **cost-balanced setup for learning and PoCs**. For production, use the Microsoft [AKS baseline architecture](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks) as your reference and add the following.

| Area | This guide | Production recommendation |
|---|---|---|
| Network topology | Single VNet + NAT Gateway | **Hub-and-spoke**: Azure Firewall (egress control, UDR) · Bastion · VPN/ExpressRoute in the hub, AKS in the spoke |
| API server | Public + authorized IP | **Fully private** (`enable_private_cluster`) + Bastion / jump host / self-hosted runner |
| Ingress | Gateway API public LB | **Application Gateway (WAF v2) or Front Door** → internal Gateway, TLS termination (Key Vault certificate) |
| Registry / KV | Private Endpoint + admin IP allowed | Public access **fully blocked**, CI on in-VNet / managed runners |
| Identity | Roles assigned directly to users | **Entra groups + PIM (just-in-time)**, Conditional Access, access reviews |
| Governance | Policy at RG scope (Audit) | Policies / initiatives at management group scope + `Deny`, tag inheritance and required-tag policies |
| Security | Optional Defender | Defender for Containers + (Sentinel connector), image signing / scanning pipeline |
| Resilience | Single region (3 zones) | **Azure Backup for AKS**, multi-region + Front Door / Traffic Manager, Fleet Manager |
| Deployment | `terraform apply` + kubectl | **GitOps (Flux extension)** for cluster bootstrapping / app deployment, OIDC sign-in from pipelines |
| Modularization | Defined directly, for learning | Standardize on in-house modules or **Azure Verified Modules (AVM)** |
| Observability | Default dashboards | Prometheus alert rules (`azurerm_monitor_alert_prometheus_rule_group`) + Action Group, SLO dashboards |

## D. References

| Topic | Links |
|---|---|
| AWS ↔ Azure comparison | [Azure for AWS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/), [AKS for Amazon EKS professionals](https://learn.microsoft.com/azure/architecture/aws-professional/eks-to-aks/) |
| Architecture | [AKS baseline](https://learn.microsoft.com/azure/architecture/reference-architectures/containers/aks/baseline-aks), [AKS Well-Architected guide](https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service) |
| AKS Automatic / NAP | [Introduction to AKS Automatic](https://learn.microsoft.com/azure/aks/intro-aks-automatic), [Node auto-provisioning](https://learn.microsoft.com/azure/aks/node-auto-provisioning) |
| Gateway API | [App Routing Gateway API](https://learn.microsoft.com/azure/aks/app-routing-gateway-api), [NGINX → Gateway API migration](https://learn.microsoft.com/azure/aks/app-routing-nginx-to-gateway-api-migration), [Managed Gateway API CRD](https://learn.microsoft.com/azure/aks/managed-gateway-api) |
| Supported versions / schedule | [Supported Kubernetes versions](https://learn.microsoft.com/azure/aks/supported-kubernetes-versions), [AKS release notes](https://github.com/Azure/AKS/releases) |
| Terraform | [azurerm 5.0 upgrade guide](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/5.0-upgrade-guide), [`azurerm_kubernetes_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_cluster), [`azurerm_kubernetes_automatic_cluster`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/kubernetes_automatic_cluster), [AzAPI](https://registry.terraform.io/providers/Azure/azapi/latest/docs), [AVM](https://azure.github.io/Azure-Verified-Modules/) |
| Official Microsoft Terraform samples | [Azure/terraform quickstart](https://github.com/Azure/terraform/tree/master/quickstart): `101-aks-application-routing-gateway-api`, `101-aks-automatic-custom-network`, `101-aks-network-isolated`, `101-aks-use-azure-policy`, `101-aks-defender-containers`, `301-aks-enterprise` |
| Prometheus template | [Azure/prometheus-collector — AddonTerraformTemplate](https://github.com/Azure/prometheus-collector/tree/main/AddonTerraformTemplate) |

## E. Complete list of Terraform files (which lab has each)

| Stack / module | Files | Included in |
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
| `mocks` | `azurerm.tfmock.hcl` | F below |

> [!NOTE]
> All stacks follow the same file layout (`versions.tf` → `providers.tf` → `variables.tf` → `main.tf` → topic-specific files → `outputs.tf`). To see the files in one place, type a file name (e.g., `cluster.tf`) into the search box of this HTML page.

## F. Complete test and tooling code

Each stack's `tests/plan.tftest.hcl` is in the Code section of its lab. The shared mock values and the script that validates all stacks are below.

**`terraform/mocks/azurerm.tfmock.hcl`** — azurerm mock values shared by the mock tests of all stacks

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

**`tools/validate-all.sh`** — validates all stacks without a subscription

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

## G. Verification and cleanup scripts

The check and delete commands you type by hand during the labs are bundled into scripts. They all live in `scripts/` at the repository root and run on macOS · Linux · WSL · Azure Cloud Shell (bash) (requires `terraform`, `az`, `jq`, and, from 05 onward, `kubectl` and `kubelogin`).

| Script | When | What it does | Source included in |
|---|---|---|---|
| `scripts/preflight.sh` | Lab 01, before you start the labs | Checks tools · sign-in · environment variables · Resource Providers · vCPU quota · VM size · permissions (read-only) | [Lab 01](01-prerequisites.md) |
| `scripts/verify.sh [stack…]` | Right after you `apply` each stack | Finds names with `terraform output` and verifies the results with `az`/`kubectl`; prints a `✓ ✗ ! -` summary and an exit code (read-only) | This appendix |
| `scripts/verify/02…10.sh` | Called by the script above (can also be run directly) | Per-stack verification items | [02](02-bootstrap.md) [03](03-network.md) [04](04-platform.md) [05](05-aks.md) [06](06-workload-identity.md) [07](07-ingress.md) [08](08-governance.md) [10](10-aks-automatic.md) |
| `scripts/cleanup.sh` | Lab 11, after you finish the labs | `destroy` in reverse order of creation, resource lock removal, safe to re-run, check for leftover resources (supports `--dry-run`) | [Lab 11](11-cleanup.md) |
| `scripts/lib/common.sh` | The scripts above `source` it | Result output (`pass`/`fail`/`warn`), value comparison (`expect_*`), JSON helpers (`jq`), `terraform output`/`az`/`kubectl` wrappers | This appendix |
| `tools/validate-all.sh` | After you change the code | `fmt` · `validate` · `terraform test` (no subscription needed) + script syntax checks | F above |

```bash
scripts/verify.sh                    # verify every stack you applied (stacks not yet applied are skipped)
scripts/verify.sh 05-aks 07-ingress  # specific stacks only
scripts/cleanup.sh --dry-run         # show the deletion plan only
```

> [!TIP]
> The verification scripts are **read-only** (apart from running `printenv`/`test -s` inside a pod, they change nothing). `kubectl` uses a temporary kubeconfig, so `~/.kube/config` is not modified. If you set an option that you can choose with a variable (`sku_tier`, `enable_private_cluster`, `enable_gateway_api`, `nat_gateway_sku`, etc.) to something other than its default, the scripts show the value or mark it as a warning (!) or skipped (-) instead of reporting a failure (✗). To add verification for a new stack, create a `verify_stack` function in `scripts/verify/NN-name.sh` and add the name to `ALL_STACKS` in `verify.sh`.

**`scripts/lib/common.sh`** — common functions for all scripts

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

**`scripts/verify.sh`** — entry point that calls the per-stack verification scripts

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

**`.shellcheckrc`** — ShellCheck configuration (resolves `source` paths relative to the script location)

<!-- tf:include path=".shellcheckrc" -->
```text title=".shellcheckrc"
# ShellCheck configuration: resolve source paths relative to the script location.
#   shellcheck scripts/*.sh scripts/lib/*.sh scripts/verify/*.sh tools/*.sh
source-path=SCRIPTDIR
external-sources=true
```
<!-- /tf:include -->
