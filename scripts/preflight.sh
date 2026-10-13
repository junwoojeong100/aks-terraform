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
