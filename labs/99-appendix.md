<!-- lang-switch -->
**English** | [한국어](ko/99-appendix.md)
<!-- /lang-switch -->

# Appendix. Troubleshooting · production checklist · cluster access and workloads · references · test code

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| Reference only | None | `terraform/mocks`, `scripts/`, `tools/validate-all.sh` | None |

> [!TIP]
> Looking for how to reach the clusters from Cloud Shell or another PC, or how to run `kubectl` against pods and Deployments? See **D. How to reach the clusters** and **E. Handling Kubernetes workloads with kubectl** below.

## A. How this guide was validated, and its limits

### A-1. Static validation (no Azure needed)

| Check | Details | Result |
|---|---|---|
| `terraform fmt -check` | All stacks and modules | Passed |
| `terraform validate` | Against the actual schemas of azurerm 5.9.0 · azapi 2.13.0 · kubernetes 3.3.0 · random 3.9.1 · time 0.14.2 | Passed |
| `terraform test` (mock provider) | Plan logic + variable validation of all stacks (<!-- count:test-runs -->35<!-- /count --> runs in total, including the `naming` module) | Passed |
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
| 14 | Lab 08 steps 2 and 4, `05-aks` `enable_defender` | With `enable_defender=true` the Defender profile pointed at the platform workspace, which has local authentication disabled. The Defender sensor does not support that, and its `microsoft-defender-publisher` pods crash-looped (`Local authentication is disabled for the Log Analytics workspace`). The earlier runs did not look at those pods | Added `defender_log_analytics_workspace_id` (required with `enable_defender`) and a test for it, and rewrote the Lab 08 guidance to reuse the workspace that the policy attached |

### A-4. What could not be verified, and what varies by environment

- **Spot scale-up (Lab 05 (a))**: Adding and removing the pool was verified, but when pods were deployed, no nodes were added because of `SkuNotAvailable` (Capacity Restrictions: `Standard_D4ds_v5`). Spot capacity varies by region and time.
- **Upgrade (Lab 09 §1)**: It could not be run because there was no GA version to upgrade to (1.36.4 is the latest GA, 1.37.0 is in preview, and the node image is also the latest). Rolling replacement (surge · PDB) is unverified.
- **Defender subscription plan (Lab 08 step 4)**: It was already enabled in this subscription, so it was not run (if Terraform manages it, `destroy` reverts it to Free, which can change the subscription's existing settings).
- **Subscriptions with a Defender auto-provisioning policy**: Right after the cluster is created, it stays in `Updating` for a while, so the provisioning-state check in `verify.sh` fails temporarily, and the 05-aks plan keeps showing a diff that removes `microsoft_defender`. Declaring the same profile (`enable_defender=true` plus `defender_log_analytics_workspace_id` set to the workspace that the policy used) makes the diff disappear ([Lab 08](08-governance.md) steps 2 and 4). Do not use the platform workspace for it (fix 14 in A-3).
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
| `kubectl: Unable to connect ... i/o timeout` | The API server only accepts the IPs in `allowed_ip_ranges`. Your public IP changed, or you are on another network, Cloud Shell or CI → see section D (D-3 and D-4): update `TF_VAR_allowed_ip_ranges` and `apply` `04-platform`, `05-aks` and `10-aks-automatic`; meanwhile use `az aks command invoke`. |
| `kubectl` changes the wrong cluster | With two clusters, `az aks get-credentials` switches the current context to the cluster you fetched last. Check `kubectl config current-context`, then `kubectl config use-context <name>` (see D-1). |
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

## D. How to reach the clusters, and what is exposed to the internet

After Lab 05 and Lab 10 you have **two** clusters in the same subscription. This section shows how to tell them apart, which traffic can enter and leave, and what to do when you are not on the laptop you used for the labs (Azure Cloud Shell, another PC, CI).

### D-1. The two clusters

| | Standard (Lab 05) | Automatic (Lab 10) |
|---|---|---|
| Terraform stack | `terraform/05-aks` (builds on the network and platform stacks 03 and 04) | `terraform/10-aks-automatic` (independent of Lab 03–05) |
| Default name | `aks-aksdemo-dev-krc` in `rg-aksdemo-dev-krc-aks` | `aksa-aksdemo-dev-krc` in `rg-aksdemo-dev-krc-automatic` |
| SKU in `az aks list` | `Base` (tier `Standard`) | `Automatic` (tier `Standard`) |
| Nodes | System and user pools that you size (default 3 + 3) | A managed system pool, plus nodes that node auto-provisioning (NAP) adds on demand |
| `kubectl` context | Same as the cluster name | Same as the cluster name |

The names depend on `TF_VAR_workload`, `TF_VAR_environment` and `TF_VAR_location`; read the exact values from the `cluster_name` and `resource_group_name` outputs of each stack.

```bash
# Which clusters do I have, and what kind is each?
az aks list --query "[].{name:name, rg:resourceGroup, sku:sku.name, tier:sku.tier, version:currentKubernetesVersion, power:powerState.code}" -o table

# Which cluster does kubectl talk to right now? (* marks the current context)
kubectl config get-contexts
kubectl config current-context

kubectl config use-context aks-aksdemo-dev-krc     # switch the default cluster
kubectl --context aksa-aksdemo-dev-krc get nodes   # or address the other cluster for a single command
```

> [!WARNING]
> `az aks get-credentials` makes the cluster you fetched **last** the current context. After Lab 10 step 1, every plain `kubectl` command goes to the Automatic cluster until you run `kubectl config use-context` again. Check `kubectl config current-context` before any `apply` or `delete`. The `scripts/verify.sh` scripts are not affected because they use a temporary kubeconfig.

### D-2. What can connect to what

| | Standard cluster | Automatic cluster |
|---|---|---|
| Outbound (cluster → internet) | Yes, through the NAT Gateway from Lab 03 (static public IP, `nat_gateway_public_ip` output) | Yes, through the NAT Gateway that AKS manages in the node resource group (`MC_…`) |
| API server | Public endpoint with API Server VNet Integration. **Only the IPs in `allowed_ip_ranges` can use it** | Same |
| Apps reachable from the internet | The Lab 07 Gateway has a public IP on ports 80 and 443 (node NSG rule `AllowGatewayHttpHttps`); `internal_gateway=true` makes it private | None: the guide deploys no `LoadBalancer` Service here |
| Images from the Lab 04 ACR | Pulled over the Private Endpoint; only this cluster's kubelet identity has `AcrPull` | **Cannot pull** (`ErrImagePull … 403 Forbidden`). Use public images such as `mcr.microsoft.com`, or give your own registry `AcrPull` and network access |

The platform services from Lab 04 do not belong to one cluster: the ACR and Key Vault public endpoints accept only the IPs in `allowed_ip_ranges`, and Grafana has a public endpoint behind Entra ID sign-in.

**Check the outbound IP from inside a cluster.** The pod below also follows the Automatic cluster's Deployment Safeguards (resource requests are mandatory there), so the same manifest works on both clusters.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: { name: egress-test, namespace: default }
spec:
  restartPolicy: Never
  containers:
  - name: t
    image: mcr.microsoft.com/cbl-mariner/busybox:2.0
    command: ["sh", "-c", "wget -qO- -T 15 http://api.ipify.org; echo"]
    resources:
      requests: { cpu: 50m, memory: 32Mi }
      limits: { cpu: 100m, memory: 64Mi }
    readinessProbe: { exec: { command: ["true"] } }
    livenessProbe: { exec: { command: ["true"] } }
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1000
      capabilities: { drop: ["ALL"] }
      seccompProfile: { type: RuntimeDefault }
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/egress-test --timeout=180s
kubectl logs egress-test          # the public IP that the internet sees for this cluster
kubectl delete pod egress-test

# Compare it with the NAT Gateway's address
terraform -chdir=terraform/03-network output -raw nat_gateway_public_ip        # Standard cluster
NODE_RG=$(az aks show -g <automatic-rg> -n <automatic-cluster> --query nodeResourceGroup -o tsv)
az network public-ip list -g "$NODE_RG" --query "[].ipAddress" -o tsv            # Automatic cluster
```

### D-3. Where can I run kubectl from?

| From | `kubectl` to the API servers | Why |
|---|---|---|
| The laptop whose IP is in `allowed_ip_ranges` | Works | The IP is authorized |
| Another network (other Wi-Fi, VPN, tethering) or a teammate's PC | Blocked | The IP is not authorized |
| Azure Cloud Shell | Blocked | Cloud Shell runs on Microsoft-managed Azure addresses that are not in your list, and a fixed address is not guaranteed |
| CI runners (for example GitHub-hosted runners) | Blocked | Same reason |
| Anywhere, with `az aks command invoke` or the portal **Run command** | Works | The command runs inside the cluster through the Azure API, not over your network path |

A blocked request gets no answer at all, so `kubectl` ends with `Unable to connect to the server: dial tcp …:443: i/o timeout`. (Measured for this guide: from an unauthorized address the TCP connection opens but the HTTPS request gets no response, while the same request from an authorized address returns HTTP 401, which means it reached the API server.)

**`az aks command invoke`** runs a command in the cluster through the Azure API, so it works from anywhere you are signed in to Azure:

```bash
az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes"
az aks command invoke -g <rg> -n <cluster> --command "kubectl -n web get pods -o wide"
```

- You need Azure RBAC permission on the cluster for the actions `Microsoft.ContainerService/managedClusters/runcommand/action` and `Microsoft.ContainerService/managedClusters/commandResults/read` (Owner, Contributor and the AKS Contributor role have them).
- AKS runs the command in a short-lived pod in the `aks-command` namespace and returns the text output. There is no interactive shell, `exec -it` or `port-forward`; keep each call to commands that finish on their own, and attach files such as a manifest with `--file`.
- The portal offers the same feature as **AKS cluster → Run command**.
- Tested on both clusters of this guide.

### D-4. When your public IP changes, or a teammate needs access

1. Look up the new address ([Lab 01](01-prerequisites.md), step 5): `curl -s https://api.ipify.org`.
2. Put every machine that needs access into `TF_VAR_allowed_ip_ranges` (a JSON list with one `/32` per machine) and save it in your `env.sh`, for example `export TF_VAR_allowed_ip_ranges='["203.0.113.10/32","198.51.100.7/32"]'`.
3. Re-apply the three stacks that use the list:

| Stack | What the IP list opens | Command (from the repository root) |
|---|---|---|
| `04-platform` | ACR and Key Vault firewalls (needed for `az acr import` and Key Vault secrets) | `terraform -chdir=terraform/04-platform apply` |
| `05-aks` | Standard cluster API server | `terraform -chdir=terraform/05-aks apply` |
| `10-aks-automatic` | Automatic cluster API server | `terraform -chdir=terraform/10-aks-automatic apply` |

These applies talk to Azure Resource Manager only, so they work even while `kubectl` is blocked. A new list takes up to two minutes to propagate. Until then, use `az aks command invoke`.

> [!WARNING]
> Do not run the Lab 01 one-liner (`curl … api.ipify.org`) inside Cloud Shell to fill `TF_VAR_allowed_ip_ranges`: it would register Cloud Shell's address instead of your laptop's. Run Terraform from your own machine, and use `az aks command invoke` from Cloud Shell. From an unauthorized address, the `kubectl` steps of `scripts/verify.sh` and the stacks that use the `kubernetes` provider (06 and 07) cannot reach the API server either.

## E. Handling Kubernetes workloads with kubectl

Labs 01–10 build the platform. This section is about the Kubernetes objects that run on it: how to look at them, change them and debug them, and how that fits with Terraform and Azure RBAC. Every command here was run against a cluster from this guide in a throwaway namespace; they work on both clusters unless noted.

### E-1. Pick the cluster and namespace

```bash
kubectl config current-context        # which cluster? (two clusters: see D-1)
kubectl get ns                        # which namespaces exist?
kubectl -n practice get pods          # -n selects a namespace
kubectl get pods -A                   # -A means all namespaces
kubectl config set-context --current --namespace=practice    # optional: make practice the default namespace
```

### E-2. Create a practice namespace and a first Deployment

Practice in a namespace of your own so that you never touch the Lab 06 and Lab 07 apps (`demo`, `web`).

```bash
kubectl create namespace practice
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: { name: hello, namespace: practice }
spec:
  replicas: 2
  selector: { matchLabels: { app: hello } }
  template:
    metadata: { labels: { app: hello } }
    spec:
      containers:
      - name: hello
        image: mcr.microsoft.com/dotnet/samples:aspnetapp
        ports: [{ containerPort: 8080 }]
        resources:
          requests: { cpu: 100m, memory: 128Mi }
          limits: { cpu: 500m, memory: 256Mi }
        readinessProbe: { httpGet: { path: /, port: 8080 } }
        livenessProbe: { httpGet: { path: /, port: 8080 } }
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          runAsUser: 1654
          capabilities: { drop: ["ALL"] }
          seccompProfile: { type: RuntimeDefault }
---
apiVersion: v1
kind: Service
metadata: { name: hello, namespace: practice }
spec:
  selector: { app: hello }
  ports: [{ port: 80, targetPort: 8080 }]
EOF
kubectl -n practice rollout status deploy/hello
```

The manifest follows the same rules as the Lab 07 app, so it passes on both clusters:

- `resources.requests` and `limits`: on the Automatic cluster ([Lab 10](10-aks-automatic.md)), Deployment Safeguards **reject** a bare pod without requests, and add default values (with a warning) to a Deployment that has none. The scheduler needs them everywhere.
- Probes: the readiness probe decides when a pod receives traffic, and the liveness probe restarts a stuck container. Deployment Safeguards warn when they are missing.
- `runAsNonRoot`, `allowPrivilegeEscalation: false`, `drop: ["ALL"]` and `seccompProfile`: the Pod Security rules and the Lab 08 policies.
- The image is a public sample so that it also runs on the Automatic cluster (see the ACR row in D-2).

### E-3. Look at things (read-only)

```bash
kubectl -n practice get all                          # common kinds only: ConfigMaps, Secrets and Ingresses are not included
kubectl -n practice get pods -o wide                 # node and pod IP
kubectl -n practice get pods --show-labels
kubectl -n practice get pods -l app=hello            # filter by label
kubectl -n practice get pods -w                      # watch changes (Ctrl+C to stop)
kubectl get pods -A --field-selector=status.phase!=Running      # what is not running, in all namespaces

# Pick exactly the fields you need
kubectl -n practice get pods -o jsonpath='{.items[*].metadata.name}'
kubectl -n practice get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IP:.status.podIP
kubectl -n practice get deploy hello -o yaml         # the full object as the cluster stores it

kubectl -n practice describe deploy hello            # settings + recent events
kubectl -n practice get events --sort-by=.lastTimestamp

# Logs
kubectl -n practice logs deploy/hello --tail=20      # one pod of the Deployment
kubectl -n practice logs -l app=hello --prefix --tail=5    # every pod, prefixed with its name
kubectl -n practice logs <pod> -f                    # follow
kubectl -n practice logs <pod> --previous            # the container before the last restart
kubectl -n practice logs <pod> -c <container>        # pods with more than one container

# Resource usage (metrics-server is built into AKS)
kubectl -n practice top pods
kubectl top nodes

kubectl explain deploy.spec.strategy                 # documentation of any field
```

### E-4. Get inside a pod

```bash
kubectl -n practice exec -it deploy/hello -- sh                 # a shell in the container
kubectl -n practice port-forward svc/hello 8080:80              # then open http://localhost:8080
kubectl -n practice cp <pod>:/etc/hostname ./hostname           # copy a file out (needs tar in the image)

# An image without a shell? Attach a temporary debug container to the running pod
kubectl -n practice debug -it pod/<pod> --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 --target=hello -- sh

# Call a Service from inside the cluster with a throw-away pod
kubectl -n practice run tmp --rm -it --restart=Never --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- wget -qO- http://hello
```

- `exec`, `logs`, `cp` and `port-forward` go through the API server, so they work only from where `kubectl` works (see D-3).
- A debug container stays in the pod's spec until the pod is replaced.
- On the Automatic cluster, `kubectl run` cannot set resource requests, so the throw-away pod is rejected. Use a manifest with requests, as in D-2.

### E-5. Change things

```bash
kubectl apply -f deploy.yaml                         # declarative: the recommended way, keep manifests in Git
kubectl diff -f deploy.yaml                          # preview (exit code 1 means there are differences)
kubectl apply --dry-run=server -f deploy.yaml        # validate against the server, including admission and policies

kubectl -n practice scale deploy/hello --replicas=3
kubectl -n practice set env deploy/hello MODE=demo   # changes the pod template, so it starts a rolling update
kubectl -n practice set image deploy/hello hello=<new-image>

kubectl -n practice rollout status deploy/hello      # wait for the rollout
kubectl -n practice rollout history deploy/hello
kubectl -n practice rollout undo deploy/hello        # back to the previous revision
kubectl -n practice rollout restart deploy/hello     # recreate the pods without changing the spec

kubectl -n practice patch deploy hello -p '{"spec":{"replicas":2}}'
kubectl -n practice label pod <pod> tier=frontend
kubectl -n practice annotate deploy hello kubernetes.io/change-cause="set MODE=demo"    # shown in rollout history
kubectl -n practice autoscale deploy hello --min=2 --max=4 --cpu-percent=70
kubectl -n practice edit deploy hello                # opens the object in $EDITOR
kubectl -n practice delete pod <pod>                 # the Deployment creates a replacement
```

A rolling update protects you from a bad release. Try `kubectl -n practice set image deploy/hello hello=mcr.microsoft.com/dotnet/samples:does-not-exist`: only the **new** pod goes to `ImagePullBackOff`, the old pods keep serving, `rollout status` eventually fails with `timed out waiting for the condition`, and `kubectl -n practice rollout undo deploy/hello` restores the working revision. With an autoscaler (HPA) the HPA owns the replica count, so a manual `kubectl scale` is overridden.

### E-6. Configuration data and batch jobs

```bash
kubectl -n practice create configmap app-config --from-literal=MODE=demo
kubectl -n practice create secret generic db --from-literal=password='<demo-value>'
kubectl -n practice set env deploy/hello --from=configmap/app-config         # inject as environment variables
kubectl -n practice exec deploy/hello -- printenv MODE

kubectl -n practice create job hello-job --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 -- sh -c 'echo job-done'
kubectl -n practice wait --for=condition=complete job/hello-job --timeout=90s
kubectl -n practice logs job/hello-job

kubectl -n practice create cronjob tick --image=mcr.microsoft.com/cbl-mariner/busybox:2.0 --schedule="*/5 * * * *" -- sh -c 'date'
kubectl -n practice create job manual-run --from=cronjob/tick                # run a CronJob once, right now
```

> [!WARNING]
> A Kubernetes Secret is only **base64-encoded**, not encrypted: `kubectl get secret db -o jsonpath='{.data.password}'` prints a value that anyone with read access can decode. Do not commit Secret manifests, and keep real secrets out of your shell history. For real applications read secrets from Key Vault ([Lab 06](06-workload-identity.md)).

### E-7. When something is wrong: a triage playbook

Start with these three commands, then use the table.

```bash
kubectl get pods -A --field-selector=status.phase!=Running      # what is not running?
kubectl -n practice describe pod <pod>                          # read the Events at the bottom first
kubectl get events -A --sort-by=.lastTimestamp | tail -20       # what happened recently?
```

| Symptom | Where to look | Usual cause and fix |
|---|---|---|
| `Pending` | `describe pod` → Events, for example `0/6 nodes are available: 3 Insufficient cpu, 3 node(s) had untolerated taint(s)` | The requests are larger than any node can offer, or only tainted nodes are left (the system pool accepts critical add-ons only). Lower the requests; if nodes cannot be added, check the vCPU quota ([Lab 01](01-prerequisites.md) step 4) |
| `ImagePullBackOff` / `ErrImagePull` | The event message of `describe pod` | A typo in the image or tag; the image was not imported into the ACR ([Lab 04](04-platform.md), [Lab 06](06-workload-identity.md)); the cluster has no `AcrPull` or is blocked by the registry firewall (`403 Forbidden`, see D-2) |
| `CrashLoopBackOff` / `Error` | `kubectl logs <pod>`, `--previous`, `describe` → Last State and Exit Code | The application exits: a wrong command, environment variable or config; a failing liveness probe; a missing ConfigMap or Secret (`CreateContainerConfigError`). `--previous` can be unavailable for a container that restarts very fast, so read the current logs as well |
| `OOMKilled` (exit code 137) | `describe pod` → Last State | The memory limit is lower than what the process needs. Raise `limits.memory` or fix the leak; compare with `kubectl top pod` |
| The pod disappeared, or `Evicted` | `get events` | Node pressure, or node consolidation (NAP on the Automatic cluster evicts under-used nodes). A bare pod with no owner is not recreated, so run workloads through a Deployment or Job |
| `Forbidden` on create or apply | The message names the rule | `denied the request` from Gatekeeper or Deployment Safeguards ([Lab 08](08-governance.md), [Lab 10](10-aks-automatic.md)), `violates PodSecurity`, or an RBAC error (`kubectl auth can-i create deployments -n practice`) |
| A Service returns nothing | `kubectl -n practice get endpoints hello` | No endpoints: the selector does not match the pod labels (`get pods --show-labels`), or the readiness probe fails |
| `Unable to connect … i/o timeout` | Your public IP | The IP is not authorized: see D-3 and D-4 |
| `You must be logged in to the server (Unauthorized)` | Your sign-in | Run `az login` and `kubelogin convert-kubeconfig -l azurecli` again |

Try it: a pod that exits at once (`command: ["sh","-c","echo boom; exit 1"]`) shows `Error` and then `CrashLoopBackOff`, and its output is in `kubectl logs`. A pod that asks for `cpu: "64"` stays `Pending` with the scheduler event above.

### E-8. Terraform-managed or kubectl-managed?

The Lab 06 and Lab 07 workloads (`kv-demo`, `aspnetapp`, the Gateway) belong to **Terraform**. If you change a field that Terraform manages with `kubectl`, the next `terraform plan` shows a difference and the next `apply` reverts your change:

```bash
kubectl -n web patch svc aspnetapp -p '{"spec":{"sessionAffinity":"ClientIP"}}'
terraform -chdir=terraform/07-ingress plan        # ~ session_affinity = "ClientIP" -> "None"
kubectl -n web patch svc aspnetapp -p '{"spec":{"sessionAffinity":"None"}}'      # put it back
```

Rules of thumb:

1. **Experiments** belong in your own namespace and are done with `kubectl` (this section).
2. **Permanent changes** to the Lab 06 and Lab 07 workloads are made in the Terraform code or its variables, then applied.
3. Fields that a controller owns are excluded on purpose: the replica count of the Lab 07 Deployment is `ignore_changes` because the HPA manages it, so scaling it by hand does not show up as a difference.
4. To find manual changes, run `terraform plan -detailed-exitcode` regularly ([Lab 09](09-operations.md)).

### E-9. Who may do what: Azure RBAC for Kubernetes

Local accounts are disabled, so permissions come from Azure roles ([Lab 05](05-aks.md)):

| Role | Scope | What it allows |
|---|---|---|
| Azure Kubernetes Service RBAC Reader | Cluster or namespace | Read most objects |
| Azure Kubernetes Service RBAC Writer | Cluster or namespace | Read and write most objects |
| Azure Kubernetes Service RBAC Admin | Cluster or namespace | Read and write most objects, and manage roles and role bindings in the namespace |
| Azure Kubernetes Service RBAC Cluster Admin | Cluster | Everything in every namespace (the lab gives this to the signed-in user) |

To give an application team access to one namespace only, assign the role at namespace scope. They also need the **Azure Kubernetes Service Cluster User Role** on the cluster (to run `az aks get-credentials`) and their IP in `allowed_ip_ranges` (D-4):

```bash
CLUSTER_ID=$(az aks show -g <rg> -n <cluster> --query id -o tsv)
az role assignment create --assignee <user-or-group-object-id> \
  --role "Azure Kubernetes Service RBAC Writer" --scope "$CLUSTER_ID/namespaces/practice"
az role assignment list --scope "$CLUSTER_ID/namespaces/practice" -o table

kubectl -n practice auth can-i create deployments       # check your own permission: yes or no
```

`kubectl auth can-i --list` is incomplete on a cluster that uses Azure RBAC (it warns that the webhook authorizer does not support rule resolution), so check one permission at a time. In a team, prefer Entra groups over individual users.

### E-10. Clean up the practice namespace

```bash
kubectl config current-context        # make sure it is the cluster you mean
kubectl delete namespace practice     # removes everything inside: Deployments, Pods, Services, Jobs, ConfigMaps, Secrets
```

This does not touch the Lab 06 and Lab 07 workloads or any Azure resource.

## F. References

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

## G. Complete list of Terraform files (which lab has each)

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

## H. Complete test and tooling code

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

## I. Verification and cleanup scripts

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
