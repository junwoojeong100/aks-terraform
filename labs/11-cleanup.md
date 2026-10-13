<!-- lang-switch -->
**English** | [한국어](ko/11-cleanup.md)
<!-- /lang-switch -->

# Lab 11. Cleanup: delete everything so costs don't leak

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 20–40 min | Billing continues until you clean up | All stacks (reverse order) | All the labs you completed |

> [!CAUTION]
> AKS nodes (VMs), NAT Gateway, public IPs, Premium ACR, Managed Grafana, and Defender plans **keep billing as long as you leave them on**. Always clean up when you finish the labs or before a long break.

## The easiest way: the cleanup script

`scripts/cleanup.sh` handles everything in one go: deleting in reverse order of creation, removing resource locks, skipping stacks that are already deleted, and checking for leftover resources afterward. **First run it with `--dry-run` to see what it would delete** (it deletes nothing).

```bash
# Run from the repository root, in a terminal with the same environment variables as for apply (ARM_SUBSCRIPTION_ID, TF_VAR_allowed_ip_ranges)
scripts/cleanup.sh --dry-run                 # 1) print the plan only
scripts/cleanup.sh                           # 2) type 'delete' to confirm and delete stacks 03–10
scripts/cleanup.sh --yes 05-aks 04-platform  # (optional) only some stacks, no prompt
scripts/cleanup.sh --include-bootstrap       # (optional) also 02-bootstrap (state storage) — read step 2 below first
```

| Safeguard | Behavior |
|---|---|
| Confirmation prompt | Without `--yes`, you must type `delete` to start. With no input (pipe/CI), the run is canceled. |
| Subscription check | The script doesn't start if `ARM_SUBSCRIPTION_ID` differs from the current subscription in `az`. |
| Order | However you order the stacks you list, the script always sorts them into the safe deletion order (06/07 → 05 → 04 → 03). |
| Resource locks | If the `CanNotDelete` locks from 08 exist, the script first deletes only the lock resources, using `-target`. Other 08 settings, such as policy effects, are left alone and deleted later in the proper order. |
| Re-runs | Stacks that are already deleted (empty state) are skipped. If a run fails midway, fix the cause and run the same command again. |
| Cluster already deleted | The Kubernetes resources in 06/07 are removed from state only, and the Azure resources are deleted. |
| 02-bootstrap | If the state is still remote, the script doesn't delete it and instead explains how to move it back to local. |

<!-- tf:include path="scripts/cleanup.sh" -->
```bash title="scripts/cleanup.sh"
#!/usr/bin/env bash
# Deletes the lab resources in "reverse order of creation" (automates the Lab 11 procedure).
#   10-aks-automatic → 08-governance → 07-ingress → 06-workload → 05-aks → 04-platform → 03-network   (+ 02-bootstrap is optional)
#   06/07 are deleted before 05 because the kubernetes provider needs a live cluster to connect and delete them.
#
# Usage:
#   scripts/cleanup.sh --dry-run                 # prints the plan without deleting anything (run this first!)
#   scripts/cleanup.sh                           # asks you to type 'delete', then deletes stacks 03–10
#   scripts/cleanup.sh --yes 05-aks 04-platform  # only the given stacks, with no prompt
#   scripts/cleanup.sh --include-bootstrap       # also deletes 02-bootstrap (state storage); only if you moved state back to local
#
# Requires: terraform, az (signed in), terraform/backend.hcl, ARM_SUBSCRIPTION_ID and TF_VAR_allowed_ip_ranges (same as at apply)
# Stacks that are already deleted are skipped, so if a run fails midway, fix the cause and re-run the same command.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${HERE}/lib/common.sh"
cd "$ROOT" || exit 2

STACK_ORDER="10-aks-automatic 08-governance 07-ingress 06-workload 05-aks 04-platform 03-network" # deletion order
yes=0
dry=0
bootstrap=0
requested=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y | --yes) yes=1 ;;
    -n | --dry-run) dry=1 ;;
    --include-bootstrap) bootstrap=1 ;;
    -h | --help)
      sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "Unknown option: $1 (see --help)" >&2
      exit 2
      ;;
    *) requested="$requested $1" ;;
  esac
  shift
done

for r in $requested; do
  case " $STACK_ORDER " in
    *" $r "*) ;;
    *)
      echo "Unknown stack: $r (available: $STACK_ORDER)" >&2
      exit 2
      ;;
  esac
done

# Always sort the given stacks into "deletion order" (so the order you type them in doesn't matter).
targets=""
for s in $STACK_ORDER; do
  if [ -z "$requested" ] || printf ' %s ' "$requested" | grep -q " $s "; then targets="$targets $s"; fi
done
[ "$bootstrap" -eq 1 ] && targets="$targets 02-bootstrap"

# --- Run helpers --------------------------------------------------------------
# run command... : prints the command and runs it (in dry-run mode, only prints it).
run() {
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  [ "$dry" -eq 1 ] || "$@"
}

# run_quiet command... : hides the output and shows it only on failure (for noisy commands such as init).
run_quiet() {
  local out
  printf '  %s$ %s%s\n' "$C_DIM" "$*" "$C_OFF"
  [ "$dry" -eq 1 ] && return 0
  out="$("$@" 2>&1)" || {
    printf '%s\n' "$out"
    return 1
  }
}

tf_init() { run_quiet terraform -chdir="terraform/$1" init -backend-config=../backend.hcl -input=false -no-color; }
tf_state() { terraform -chdir="terraform/$1" state list 2>/dev/null; }

# Returns 0 if the 05-aks state has no cluster (= already deleted).
# Under pipefail, `tf_state | grep -q` flips the result when grep exits first and terraform gets SIGPIPE
# (the cluster is reported as "gone" although it exists), so the output is captured in a variable first.
# If the state can't be read, the cluster counts as "still there" (1), so that a read failure is never
# mistaken for "already deleted".
cluster_gone() {
  local list
  [ "$dry" -eq 1 ] && return 1
  tf_init 05-aks >/dev/null 2>&1 || return 1
  list="$(tf_state 05-aks)" || return 1
  ! grep -q '^azurerm_kubernetes_cluster\.this$' <<<"$list"
}

# If the cluster is already gone, the kubernetes provider can't connect, so its resources are only removed from state.
drop_k8s_state_if_cluster_gone() {
  local res
  cluster_gone || return 0
  warn "$1: the cluster is already gone → removing the Kubernetes resources from state, then deleting only the Azure resources"
  # Read the list through file descriptor 3 so that terraform can't take over stdin.
  while IFS= read -r res <&3; do
    run terraform -chdir="terraform/$1" state rm "$res"
  done 3< <(tf_state "$1" | grep -E '^kubernetes_')
}

# If 08 created resource locks (CanNotDelete), destroy fails with ScopeLocked, so remove them first.
# apply -var enable_resource_locks=false would also revert other settings such as policy effects and Defender,
# so only the lock resources are deleted, with -target (the rest of 08 stays until its turn in the destroy order).
unlock_resource_locks() {
  section "Remove resource locks (08-governance)"
  if ! tf_init 08-governance; then
    warn "Couldn't initialize 08-governance; skipping the lock check"
    return 0
  fi
  local unlock=(terraform -chdir=terraform/08-governance destroy -auto-approve -input=false -lock-timeout=300s -no-color
    -target=azurerm_management_lock.network -target=azurerm_management_lock.platform)
  local locks
  if [ "$dry" -eq 1 ]; then
    info "(runs only if locks exist)"
    run "${unlock[@]}"
  elif ! locks="$(tf_state 08-governance)"; then
    fail "Couldn't read the 08-governance state, so can't tell whether locks exist (check backend.hcl and your sign-in)"
    return 1
  elif grep -q '^azurerm_management_lock\.' <<<"$locks"; then
    run "${unlock[@]}" || return 1
  else
    skip "No locks to remove"
  fi
}

destroy_stack() {
  local s="$1" list
  section "destroy $s"
  if [ ! -d "terraform/$s" ]; then
    skip "Stack directory not found"
    return 0
  fi
  tf_init "$s" || {
    fail "$s: init failed (check terraform/backend.hcl and ARM_SUBSCRIPTION_ID)"
    return 1
  }
  if [ "$dry" -eq 0 ]; then
    # Mistaking an unreadable state for an empty one would skip a stack that still has resources,
    # so a read failure is treated as an error.
    list="$(tf_state "$s")" || {
      fail "$s: couldn't read the state (check terraform/backend.hcl, your sign-in and the network)"
      return 1
    }
    if [ -z "$list" ]; then
      skip "$s: state is empty (already deleted)"
      return 0
    fi
  fi
  case "$s" in 06-workload | 07-ingress) drop_k8s_state_if_cluster_gone "$s" ;; esac
  if run terraform -chdir="terraform/$s" destroy -auto-approve -input=false -lock-timeout=300s -no-color; then
    if [ "$dry" -eq 1 ]; then info "(dry-run) a real run would delete the $s stack"; else pass "$s deleted"; fi
  else
    fail "$s: destroy failed → fix the error above and re-run the same command (stacks that are already deleted are skipped)"
    case "$s" in
      06-workload | 07-ingress) info "If the API server was unreachable, it's often because your public IP changed. Update TF_VAR_allowed_ip_ranges and apply 05-aks." ;;
      03-network | 04-platform)
        info "A ScopeLocked error means a CanNotDelete lock is still in place (this script removes the 08 locks first)."
        info "Check: az lock list -o table  →  delete a lock you created yourself: az lock delete -n <lock name> -g <resource group>"
        ;;
    esac
    return 1
  fi
}

# 02-bootstrap holds the state storage itself, so delete it only if you moved the state back to local.
destroy_bootstrap() {
  section "destroy 02-bootstrap (state storage)"
  if grep -Eq '^[[:space:]]*backend "azurerm"' terraform/02-bootstrap/versions.tf; then
    fail "The 02-bootstrap state is still remote (Blob). You can't delete the storage that holds its own state, so move it back to local first:"
    info "1) Comment out the backend \"azurerm\" block in terraform/02-bootstrap/versions.tf again"
    info "2) terraform -chdir=terraform/02-bootstrap init -migrate-state -force-copy"
    info "3) Re-run this script with --include-bootstrap"
    return 1
  fi
  run_quiet terraform -chdir=terraform/02-bootstrap init -input=false -no-color || return 1
  if run terraform -chdir=terraform/02-bootstrap destroy -auto-approve -input=false -no-color; then
    run rm -f terraform/backend.hcl
    if [ "$dry" -eq 1 ]; then info "(dry-run) a real run would delete 02-bootstrap"; else pass "02-bootstrap deleted"; fi
  else
    fail "02-bootstrap: destroy failed"
    return 1
  fi
}

report_leftovers() {
  local rgs nodes kvs
  section "Cleanup check"
  rgs="$(az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv 2>/dev/null)"
  nodes="$(az group list --query "[?contains(name,'-aks-nodes') || (starts_with(name,'MC_') && contains(name,'-automatic_'))].name" -o tsv 2>/dev/null)"
  kvs="$(az keyvault list-deleted --query '[].name' -o tsv 2>/dev/null)"
  if [ -z "$rgs" ]; then
    pass "No resource groups tagged lab=aks-terraform-guide"
  else
    warn "Remaining resource groups: $(printf '%s' "$rgs" | tr '\n' ' ')"
    info "If they still won't delete (only if you don't plan to use Terraform again): az group delete -n <name> --yes --no-wait"
  fi
  [ -z "$nodes" ] || warn "AKS node resource groups still exist: $(printf '%s' "$nodes" | tr '\n' ' ') (they disappear a few minutes after the cluster is deleted)"
  info "Key Vaults in soft-deleted state: ${kvs:-none} (with purge protection they only hold the name for 7 days; there is no cost)"
}

# --- Start --------------------------------------------------------------------
section "Deletion plan"
if command -v az >/dev/null 2>&1 && az account show >/dev/null 2>&1; then
  info "Subscription: $(az account show --query "join(' ', [name, id])" -o tsv 2>/dev/null)"
fi
for s in $targets; do info "- $s"; done
[ "$dry" -eq 1 ] && info "dry-run: nothing is actually deleted."

if [ "$dry" -eq 0 ]; then
  require_cmd terraform az || exit 2
  az account show >/dev/null 2>&1 || {
    echo "az login is required." >&2
    exit 2
  }
  [ -n "${ARM_SUBSCRIPTION_ID:-}" ] || {
    echo "ARM_SUBSCRIPTION_ID is not set (Lab 01)." >&2
    exit 2
  }
  [ "$ARM_SUBSCRIPTION_ID" = "$(az account show --query id -o tsv)" ] || {
    echo "ARM_SUBSCRIPTION_ID differs from the current az subscription. Check which subscription you are deleting from." >&2
    exit 2
  }
  [ -n "${TF_VAR_allowed_ip_ranges:-}" ] || {
    echo "TF_VAR_allowed_ip_ranges is not set (use the same value as at apply)." >&2
    exit 2
  }
  [ -f terraform/backend.hcl ] || {
    echo "terraform/backend.hcl not found (the file you created in Lab 02)." >&2
    exit 2
  }
  if [ "$yes" -eq 0 ]; then
    printf '\nAll resources in the stacks above will be deleted. Type %sdelete%s to continue: ' "$C_BLD" "$C_OFF"
    read -r answer
    [ "$answer" = "delete" ] || {
      echo "Cancelled."
      exit 1
    }
  fi
fi

case " $targets " in
  *" 08-governance "* | *" 04-platform "* | *" 03-network "*) unlock_resource_locks || fail "Failed to remove locks" ;;
esac

for s in $targets; do
  if [ "$s" = "02-bootstrap" ]; then destroy_bootstrap || break; else destroy_stack "$s" || break; fi
done

if [ "$dry" -eq 1 ]; then
  printf '\n%sdry-run finished. To actually delete, run again without --dry-run.%s\n' "$C_BLD" "$C_OFF"
  [ "$FAIL" -eq 0 ]
  exit
fi

report_leftovers
summary
```
<!-- /tf:include -->

> [!NOTE]
> From *Destroy order* through *Verify the cleanup* below, the sections spell out what this script does **manually**. Use them if you work without the script or want to understand where a run failed.

## Destroy order (reverse of creation)

![Destroy order and caveats](diagrams/destroy-order.svg)

Delete `06/07` **before 05**: the `kubernetes` provider can connect and delete only while the cluster still exists.

```text
10-aks-automatic → 08-governance → 07-ingress → 06-workload → 05-aks → 04-platform → 03-network → 02-bootstrap
```

## Preflight checks (locks and subscription-level settings)

```bash
cd terraform

# 1) If you turned on locks in 08, remove them first (with locks in place, destroy fails with ScopeLocked)
#    apply -var enable_resource_locks=false also resets other settings (e.g. policy effects) to defaults, so delete only the lock resources.
terraform -chdir=08-governance destroy -auto-approve \
  -target=azurerm_management_lock.network -target=azurerm_management_lock.platform

# 2) If you turned on the Defender subscription plan, destroying 08 turns it off too. (If you turned it on outside Terraform, turn it off yourself)
az security pricing show -n Containers --query pricingTier -o tsv
# az security pricing create -n Containers --tier free
```

> [!TIP]
> If you created a lock yourself in the portal or with `az lock create`, Terraform doesn't know about it. Check with `az lock list -o table` and delete it with `az lock delete -n <lock-name> -g <resource-group>`.

## Step 1. Destroy each stack

```bash
for s in 10-aks-automatic 08-governance 07-ingress 06-workload 05-aks 04-platform 03-network; do
  echo "================ destroy $s"
  terraform -chdir=$s init -backend-config=../backend.hcl -input=false >/dev/null
  terraform -chdir=$s destroy -auto-approve
done
```

> [!NOTE]
> Run this in a terminal where the environment variables (`ARM_SUBSCRIPTION_ID`, `TF_VAR_allowed_ip_ranges`, and so on) are set. If you never created `10-aks-automatic`, its `destroy` finishes with "No changes".
> Before each stack's `destroy`, get in the habit of checking the deletion list with `terraform plan -destroy`.

### When destroy fails for 06/07 because you deleted the cluster first

If there is no cluster for the `kubernetes` provider to connect to, `destroy` fails. In that case, remove the Kubernetes resources from the state and delete only the Azure resources (the cluster is gone, so the resources inside it are already gone too).

```bash
cd 07-ingress
terraform state list | grep -E '^kubernetes_' | xargs -n1 terraform state rm
terraform destroy -auto-approve
```

## Step 2. Delete the bootstrap (state storage)

If you moved the `02-bootstrap` state to Blob Storage, **you can't delete the storage that holds the state itself.** First move the state back to local, then delete.

```bash
cd 02-bootstrap
# After commenting out the backend "azurerm" block in versions.tf again
terraform init -migrate-state -force-copy
terraform destroy -auto-approve
rm -f ../backend.hcl
```

## Step 3. Verify the cleanup

```bash
# Resource groups this guide created (tag lab=aks-terraform-guide) → the list should be empty
az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv

# Check that the node resource groups AKS created (this guide's naming convention) are gone too
az group list --query "[?contains(name,'-aks-nodes') || (starts_with(name,'MC_') && contains(name,'-automatic_'))].name" -o tsv

# Resources left in a soft-deleted state
az keyvault list-deleted --query "[].{name:name, purgeDate:properties.scheduledPurgeDate}" -o table
az monitor log-analytics workspace list-deleted-workspaces -o table 2>/dev/null

# If you need to clean up orphaned role assignments (deleted principals)
az role assignment list --all --query "[?principalName==''].{id:id, scope:scope}" -o table
```

### Why the Key Vault is still there

The Key Vault from Lab 04 has `purge_protection_enabled = true` (recommended), so even after deletion it **holds its name in a soft-deleted state for 7 days**. If you recreate it with the same name, the provider recovers it automatically (`recover_soft_deleted_key_vaults = true`). It incurs no cost. If you want to remove it completely right away, create it with `-var key_vault_purge_protection_enabled=false` from the start and use `az keyvault purge` after deleting it.

## Emergency cleanup (when Terraform fails)

Deleting the resource groups outright is the fastest method. It doesn't clean up the state, so use it **only when you don't plan to use Terraform again**.

```bash
for rg in $(az group list --query "[?tags.lab=='aks-terraform-guide'].name" -o tsv); do
  az group delete -n "$rg" --yes --no-wait
done
```

## Check costs

- Portal → **Cost Management → Cost analysis** → filter: tag `lab = aks-terraform-guide` (or `workload = aksdemo`)
- The day after you delete, confirm that the cost falls to 0 (some items are reflected a day late).
- If you created a budget (Lab 08), it's deleted during the cleanup.

- [ ] (If you used the cleanup script) Checked the list of resources to delete with `--dry-run` first
- [ ] Destroyed all stacks
- [ ] The resource group list is empty (`lab=aks-terraform-guide`)
- [ ] (If you used it) Set the Defender subscription plan back to `free`
- [ ] Deleted the local `.terraform/`, `backend.hcl`, and `tfplan` files

Next → [Appendix](99-appendix.md)
