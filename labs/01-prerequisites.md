<!-- lang-switch -->
**English** | [한국어](ko/01-prerequisites.md)
<!-- /lang-switch -->

# Lab 01. Prerequisites: tools, sign-in, permissions, environment variables

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 20–30 min | None | (none) | [00. AWS ↔ Azure comparison](00-aws-azure-mapping.md) |

## Goals of this lab

- Install Azure CLI, Terraform, kubectl, kubelogin, and jq, and verify their versions
- Sign in to Azure, select a subscription, and check the permissions you need
- Register **Resource Providers (RPs)** and check your vCPU **quota** (AWS has no equivalent step)
- Set the **environment variables** that every later lab shares
- Check all of the above automatically with a single run of **`scripts/preflight.sh`**

- [ ] You have an Azure subscription and **Owner** permission (or Contributor + User Access Administrator)
- [ ] `terraform version` reports 1.16 or later
- [ ] The azure-cli version in `az version` is 2.86 or later
- [ ] kubectl, kubelogin, and jq are installed
- [ ] `scripts/preflight.sh` finishes with no failures (✗)

## 1. Install the tools

| Tool | Minimum version | Purpose |
|---|---|---|
| Terraform | 1.16 | IaC (this guide is verified with 1.16.5) |
| Azure CLI | 2.86 | Sign-in, quota/RP queries, `az acr import`, `az aks get-credentials` |
| kubectl | Cluster version ±1 minor | Kubernetes CLI |
| kubelogin | Latest | Authenticates kubectl and the Terraform `kubernetes` provider with Entra ID tokens |
| jq | Latest | Used by the verification script (`scripts/verify.sh`) to read JSON output from `az`/`kubectl` |

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
> The shell scripts in `scripts/` run on **macOS · Linux · WSL · Azure Cloud Shell (bash)**. On Windows PowerShell, use WSL or Git Bash.

> [!TIP]
> On any OS, if you have installed only the Azure CLI, a single `az aks install-cli` installs **both kubectl and kubelogin**.

```bash
terraform version        # Terraform v1.16.x
az version -o table      # azure-cli 2.86 or later
kubectl version --client
kubelogin --version
```

## 2. Sign in and select a subscription

This is the equivalent of `aws sso login` / `AWS_PROFILE` in AWS. Terraform uses your **Azure CLI sign-in** directly.

```bash
az login                                   # Browser sign-in (including MFA)
az account list -o table                   # List subscriptions
az account set --subscription "<subscription name or ID>"
az account show -o table                   # Check the current subscription, tenant, and user
```

### Required permissions

| Task | Required Azure RBAC role | Why |
|---|---|---|
| Create resources | Contributor | RG, VNet, AKS, ACR, and so on |
| Create role assignments | **User Access Administrator** or Owner | This lab creates many `azurerm_role_assignment` resources (AcrPull, Network Contributor …) |
| Assign policies (Lab 08) | Resource Policy Contributor or Owner | `azurerm_resource_group_policy_assignment` |

> [!NOTE]
> This lab doesn't use the `azuread` provider (to create Entra groups, for example), so you **don't need Entra ID administrator permissions.**
> For lab convenience, human-facing permissions such as cluster admin (Labs 05/10) and ACR Push and Grafana Admin (Lab 04) are granted to "the currently signed-in user" as Azure RBAC roles (the `grant_current_user_admin` / `grant_current_user_roles` variables, default `true`).
> **In team and CI environments, set these variables to `false` and specify the object IDs of Entra groups in `admin_principal_ids`.** Granting permissions directly to personal accounts means the code has to change every time the person in charge changes.

## 3. Register Resource Providers

In Azure, you must register the **Resource Provider (RP)** for each service in your subscription before you can create that service's resources. Starting with azurerm 5.x, the provider doesn't register RPs automatically (the default is `none`), so you register them manually, just once.

```bash
RPS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault \
Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor \
Microsoft.Dashboard Microsoft.AlertsManagement Microsoft.ManagedIdentity Microsoft.PolicyInsights \
Microsoft.Security Microsoft.Authorization Microsoft.Consumption Microsoft.CostManagement"

for rp in $RPS; do az provider register --namespace "$rp" > /dev/null; done

# Registration is asynchronous. Check until all of them show Registered (usually 1–5 min)
for rp in $RPS; do printf "%-36s %s\n" "$rp" "$(az provider show -n "$rp" --query registrationState -o tsv)"; done
```

## 4. Check your vCPU quota

The default configuration uses at least six **D4ds_v5 (4 vCPU)** nodes (3 System + 3 User), and upgrades create extra temporary (surge) nodes. The recommended headroom is **40 vCPUs** (24 vCPUs minimum plus the surge nodes).

| Quota (name in `az vm list-usage`) | Required |
|---|---|
| `standardDDSv5Family` (family quota for D4ds_v5) | 6 nodes = 24 → 28 with upgrade surge → 44 at the autoscale maximum (System 5 + User 6 = 11 nodes) |
| `cores` (Total Regional vCPUs, the sum of all families) | The value above + the AKS Automatic nodes from Lab 10 (about 8), if you use both: 36 or more |
| Spot vCPUs (optional: the Spot pool in Lab 05) | 5 nodes × 4 = 20. Counted separately from the regular vCPU quota |

```bash
az vm list-usage --location koreacentral \
  --query "[?name.value=='cores' || name.value=='standardDDSv5Family'].{name:name.localizedValue, used:currentValue, limit:limit}" -o table

# Check that the VM size you plan to use is available in the region/zones
az vm list-skus --location koreacentral --size Standard_D4ds_v5 --query "[].{name:name, zones:locationInfo[0].zones, restrictions:restrictions}" -o json
```

> [!WARNING]
> If `restrictions` contains `NotAvailableForSubscription`, you can't use that VM size/zone in your subscription. If your quota is too low, request an increase from the *Quotas* menu in the portal or through a support request, or change the `system_node_vm_size`/`user_node_vm_size` variables (Lab 05).

If your default quota is small, as with a Visual Studio subscription (for example, 20 for the family and 32 in total), you can request an increase from the CLI. A small increase is sometimes applied as soon as you request it, but this depends on the subscription type, so confirm that it took effect with the `az vm list-usage` command above.

```bash
az extension add --name quota
az provider register --namespace Microsoft.Quota           # Request only after registration finishes (Registered)
SCOPE="/subscriptions/$(az account show --query id -o tsv)/providers/Microsoft.Compute/locations/koreacentral"
az quota create --resource-name standardDDSv5Family --scope "$SCOPE" --limit-object value=48 --resource-type dedicated
az quota create --resource-name cores               --scope "$SCOPE" --limit-object value=64 --resource-type dedicated
```

Instead of requesting an increase, you can reduce `system_node_vm_size`/`user_node_vm_size` to `Standard_D2ds_v5` (2 vCPU) and still do the lab within the same family quota (20): 6 nodes = 12 vCPUs.

## 5. Set environment variables

These are the values that every stack reads. **Run the commands again each time you open a new terminal** (saving them to an `env.sh` file makes this easier).

```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"   # Required since azurerm 4.x
export TF_VAR_workload="aksdemo"        # 3–8 lowercase letters or digits. Used in resource names
export TF_VAR_environment="dev"         # dev | test | prod
export TF_VAR_location="koreacentral"   # A region that also supports AKS Automatic
# Your public IP to allow through the API server/ACR/Key Vault firewalls (JSON array format)
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
> Your public IP changes if you use a corporate VPN/proxy or switch networks. Access to Key Vault, ACR, and the API server is then blocked, so update `TF_VAR_allowed_ip_ranges` and `apply` the affected stacks again.

## 6. Check everything at once: the preflight script

Instead of checking steps 3–5 above by hand one at a time, run the **read-only** preflight script. It doesn't create or change anything.

```bash
scripts/preflight.sh
# To use a different region: LOCATION=japaneast scripts/preflight.sh
```

| Check | If it fails |
|---|---|
| Tools and versions (terraform 1.16+, az 2.86+, kubectl, kubelogin, jq) | Install instructions are printed along with the failure message |
| Azure sign-in and subscription | `az login` |
| Format of `ARM_SUBSCRIPTION_ID` and `TF_VAR_allowed_ip_ranges` | Run the `export` commands from step 5 again |
| Whether the 17 required Resource Providers are registered | Prints the registration command (`az provider register …`) ready to run |
| vCPU quota (D4ds_v5 family · whole region, minimum 24 / recommended 40) | Request an increase in the portal |
| Whether the VM size is available in zones 1, 2, and 3 and has no restrictions | Adjust the `zones` / VM size variables |
| Role assignment permissions, such as Owner | Request permissions (permissions granted through a group may not be listed, so this is reported as a warning) |

<!-- tf:include path="scripts/preflight.sh" -->
```bash title="scripts/preflight.sh"
#!/usr/bin/env bash
# Preflight check before starting the labs (read-only): tools · sign-in · environment variables ·
# Resource Providers · vCPU quota · VM size · permissions
# Runs the checks from Lab 01 in one go. Creates and changes nothing.
#
# Usage:
#   scripts/preflight.sh
#   LOCATION=japaneast scripts/preflight.sh      # another region (default: TF_VAR_location or koreacentral)
#
# Exit codes: 0 if nothing failed, 1 otherwise
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"

LOCATION="${LOCATION:-${TF_VAR_location:-koreacentral}}"
VM_SIZE="${VM_SIZE:-Standard_D4ds_v5}"
VM_FAMILY="${VM_FAMILY:-standardDDSv5Family}" # If you change VM_SIZE, also set the family name from `az vm list-usage`.
MIN_VCPU=24                                   # default setup: minimum 6 nodes x 4 vCPU
REC_VCPU=40                                   # plus headroom for upgrade surge nodes and autoscaling
RESOURCE_PROVIDERS="Microsoft.ContainerService Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.KeyVault
Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Monitor Microsoft.Dashboard
Microsoft.AlertsManagement Microsoft.ManagedIdentity Microsoft.PolicyInsights Microsoft.Security Microsoft.Authorization
Microsoft.Consumption Microsoft.CostManagement"

# need command min-version install-hint : check that the command exists and its version is sufficient
need() {
  local cmd="$1" min="$2" hint="$3" ver=""
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$cmd not found → $hint"
    return
  fi
  case "$cmd" in
    terraform) ver="$(terraform version 2>/dev/null | sed -n '1s/^Terraform v//p')" ;;
    az) ver="$(az version --query '"azure-cli"' -o tsv 2>/dev/null)" ;;
    kubectl) ver="$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)" ;;
  esac
  if [ -n "$min" ] && [ -n "$ver" ]; then
    if version_ge "$ver" "$min"; then pass "$cmd $ver (min $min)"; else fail "$cmd $ver → $min or later required: $hint"; fi
  else
    pass "$cmd${ver:+ $ver}"
  fi
}

# check_quota name free-vCPUs
check_quota() {
  if [ -z "$2" ]; then
    warn "$1: couldn't query (az vm list-usage -l $LOCATION)"
  elif [ "$2" -lt "$MIN_VCPU" ]; then
    fail "$1: $2 vCPU free → at least $MIN_VCPU required (request an increase in the portal → Subscriptions → Usage + quotas)"
  elif [ "$2" -lt "$REC_VCPU" ]; then
    warn "$1: $2 vCPU free ($REC_VCPU recommended to cover upgrade surge nodes)"
  else
    pass "$1: $2 vCPU free"
  fi
}

section "1. Tools"
need terraform 1.16 "brew install hashicorp/tap/terraform (or tfenv)"
need az 2.86 "brew install azure-cli"
need kubectl "" "az aks install-cli"
need kubelogin "" "az aks install-cli"
need jq "" "brew install jq  /  sudo apt install jq   (used by the verify scripts)"
need curl "" "install it with your OS package manager"

section "2. Azure sign-in"
acct=""
if command -v az >/dev/null 2>&1; then acct="$(azj account show)"; fi
if [ -z "$acct" ]; then
  fail "Not signed in → az login"
  summary
  exit 1
fi
sub_id="$(jv "$acct" .id)"
pass "Subscription: $(jv "$acct" .name) ($sub_id)"
info "Tenant $(jv "$acct" .tenantId) · signed in as $(jv "$acct" .user.name)"

section "3. Environment variables"
if [ -z "${ARM_SUBSCRIPTION_ID:-}" ]; then
  fail "ARM_SUBSCRIPTION_ID is not set → export ARM_SUBSCRIPTION_ID=\"\$(az account show --query id -o tsv)\""
elif [ "$ARM_SUBSCRIPTION_ID" != "$sub_id" ]; then
  warn "ARM_SUBSCRIPTION_ID ($ARM_SUBSCRIPTION_ID) differs from the current az subscription ($sub_id)"
else
  pass "ARM_SUBSCRIPTION_ID matches the current subscription"
fi
if [ -z "${TF_VAR_allowed_ip_ranges:-}" ]; then
  fail "TF_VAR_allowed_ip_ranges is not set → export TF_VAR_allowed_ip_ranges='[\"<your public IP>/32\"]'"
elif jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$"))' \
  >/dev/null 2>&1 <<<"$TF_VAR_allowed_ip_ranges"; then
  pass "TF_VAR_allowed_ip_ranges = $TF_VAR_allowed_ip_ranges"
else
  fail "TF_VAR_allowed_ip_ranges has an invalid format (must be a JSON array of CIDR strings): $TF_VAR_allowed_ip_ranges"
fi
if [ -n "${TF_VAR_workload:-}" ]; then
  if printf '%s' "$TF_VAR_workload" | grep -Eq '^[a-z0-9]{3,8}$'; then pass "TF_VAR_workload = $TF_VAR_workload"; else fail "TF_VAR_workload must be 3–8 lowercase letters or digits: $TF_VAR_workload"; fi
fi

section "4. Resource Provider registration (azurerm 5.x does not register them automatically)"
registered="$(az provider list --query "[?registrationState=='Registered'].namespace" -o tsv 2>/dev/null)"
missing=""
for rp in $RESOURCE_PROVIDERS; do
  printf '%s\n' "$registered" | grep -qix "$rp" || missing="$missing $rp"
done
if [ -z "$missing" ]; then
  pass "All required Resource Providers are registered"
else
  fail "Not registered:$missing"
  info "Register: for rp in$missing; do az provider register --namespace \$rp; done   (takes 1–5 min)"
fi

section "5. vCPU quota ($LOCATION)"
usage="$(azj vm list-usage -l "$LOCATION")"
check_quota "VM family $VM_FAMILY" "$(jv "$usage" ".[] | select(.name.value == \"$VM_FAMILY\") | (.limit | tonumber) - (.currentValue | tonumber)")"
check_quota "Regional total (Total Regional vCPUs)" "$(jv "$usage" '.[] | select(.name.value == "cores") | (.limit | tonumber) - (.currentValue | tonumber)')"

section "6. VM size ($VM_SIZE @ $LOCATION)"
skus="$(azj vm list-skus -l "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines)"
sku="$(jv "$skus" "[.[] | select(.name == \"$VM_SIZE\")][0]")"
if [ -z "$sku" ] || [ "$sku" = "null" ]; then
  fail "$VM_SIZE not found in $LOCATION (to use another size/region, change the *_node_vm_size and location variables from Lab 05)"
else
  zones="$(jv "$sku" '[.locationInfo[0].zones[]?] | sort | join(",")')"
  if [ "$zones" = "1,2,3" ]; then pass "Availability zones 1,2,3 are all available"; else warn "Available zones: ${zones:-none} (reduce var.zones to match)"; fi
  if [ "$(jv "$sku" '[.restrictions[]?] | length')" = "0" ]; then pass "No subscription restrictions"; else fail "$VM_SIZE is restricted in this subscription (restrictions)"; fi
fi

section "7. Permissions (this lab creates many role assignments)"
# Guest/personal (MSA) accounts can't be looked up by sign-in name (user.name), so prefer the object ID
# (a service principal falls back to its appId).
me="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"
[ -n "$me" ] || me="$(jv "$acct" .user.name)"
roles="$(az role assignment list --assignee "$me" --all --include-inherited --query '[].roleDefinitionName' -o tsv 2>/dev/null)"
if printf '%s\n' "$roles" | grep -qx 'Owner'; then
  pass "Has the Owner role"
elif printf '%s\n' "$roles" | grep -qx 'Contributor' && printf '%s\n' "$roles" | grep -qxE 'User Access Administrator|Role Based Access Control Administrator'; then
  pass "Has Contributor + permission to assign roles"
elif [ -z "$roles" ]; then
  warn "Couldn't query roles (permissions granted through groups may not be listed). Check in the portal → Subscriptions → Access control (IAM)."
else
  warn "Owner, or Contributor + User Access Administrator, is required. Roles found: $(printf '%s' "$roles" | tr '\n' ',')"
fi

summary
```
<!-- /tf:include -->

> [!NOTE]
> The common functions shared by the scripts (`scripts/lib/common.sh`) are in [Appendix G](99-appendix.md). All the verification scripts report their results in the same format: `✓ passed / ✗ failed / ! warnings / - skipped`.

## 7. Repository structure

```text
aks-terraform/
├── README.md                    # Overview (English, default)
├── README.ko.md                 # Overview (Korean)
├── aks-terraform-guide.html     # ← Single-file HTML version of this guide (English, default)
├── aks-terraform-guide.ko.html  # ← Korean single-file HTML version
├── labs/                        # Lab docs (md), English
│   ├── diagrams/                # Diagrams used in the docs (SVG)
│   └── ko/                      # Korean lab docs + their own diagrams/
├── terraform/
│   ├── modules/naming/          # Naming-convention module shared by all stacks (+ terraform test)
│   ├── mocks/                   # azurerm mock values for terraform test
│   ├── 02-bootstrap/            # Lab 02  Remote state storage
│   ├── 03-network/              # Lab 03  VNet / NSG / NAT Gateway / Private DNS
│   ├── 04-platform/             # Lab 04  ACR / Key Vault / monitoring / identities for AKS
│   ├── 05-aks/                  # Lab 05  AKS cluster + node pools + observability
│   ├── 06-workload/             # Lab 06  Workload Identity + Key Vault CSI
│   ├── 07-ingress/              # Lab 07  Gateway API + demo app
│   ├── 08-governance/           # Lab 08  Azure Policy / Defender / budgets
│   └── 10-aks-automatic/        # Lab 10  AKS Automatic (optional)
├── scripts/                     # Scripts you run during the labs
│   ├── preflight.sh             #   Preflight check (Lab 01)
│   ├── verify.sh, verify/       #   Per-stack result verification (Lab 02–10)
│   ├── cleanup.sh               #   Delete in reverse order (Lab 11)
│   └── lib/common.sh            #   Shared functions
└── tools/                       # md code sync + HTML build + docs checks, full static validation script
```

Each `terraform/NN-*` directory is an **independent Terraform root module (= independent state)**. The code shown in the doc for lab N is identical to the files in the corresponding directory.

## 8. (Optional) Validate the code without Azure

You can run `fmt` → `validate` → `terraform test` (mock provider) for every stack without signing in or having a subscription. The full run also includes a syntax check of the shell scripts in `scripts/` (`bash -n`, plus shellcheck if it is installed).

```bash
tools/validate-all.sh            # All stacks
tools/validate-all.sh 05-aks     # A single stack only
```

## 9. Cost overview (rough estimates)

| Lab | Main billable items | Approximate hourly cost |
|---|---|---|
| 02 | Storage (small amount) | Almost 0 |
| 03 | NAT Gateway + Public IP | About $0.05 + data processed |
| 04 | ACR Premium, Managed Grafana, 2 Private Endpoints, Log Analytics | About $0.2–0.3 |
| 05 | **AKS Standard tier + 6 or more D4ds_v5 nodes** | **About $1.7–2** |
| 06–07 | App pods + load balancer/public IP | Small amount |
| 10 | AKS Automatic (Standard tier) + automatically provisioned nodes | About $0.5–1.5 |

> [!CAUTION]
> The amounts above are **estimates** that vary by region, exchange rate, and time. Check exact amounts with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).
> If you leave a cluster running unattended, you can be billed tens of dollars a day, so always work through [11. Cleanup](11-cleanup.md) when you finish the labs.

Next → [Lab 02. Terraform remote state: S3 + DynamoDB ↔ Blob Storage](02-bootstrap.md)
