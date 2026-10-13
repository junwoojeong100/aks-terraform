#!/usr/bin/env bash
# Lab 02 verification: checks that the Terraform state storage (Storage Account + Blob container)
# was created securely (read-only).
#   AWS comparison: S3 bucket (Versioning, Block Public Access) + DynamoDB lock table
#   → Azure covers both with one Blob container (locking uses a blob lease).
# Usage: scripts/verify.sh 02-bootstrap
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg sa acct blobsvc containers keys
  rg="$(tf_out 02-bootstrap tfstate_resource_group_name)"
  sa="$(tf_out 02-bootstrap tfstate_storage_account_name)"

  section "02-bootstrap · state storage (${sa:-?})"
  if [ -z "$sa" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 02-bootstrap?"
    return
  fi

  acct="$(azj storage account show -g "$rg" -n "$sa")"
  if [ -z "$acct" ]; then
    fail "Storage account not found: $sa"
    return
  fi

  expect_eq "Replication (synchronous across 3 availability zones)" "$(jv "$acct" .sku.name)" "Standard_ZRS"
  expect_eq "Public blob access allowed (S3 Block Public Access)" "$(jv "$acct" .allowBlobPublicAccess)" "false"
  expect_eq "Account key (Shared Key) auth allowed → Entra ID only" "$(jv "$acct" .allowSharedKeyAccess)" "false"
  expect_eq "Minimum TLS version" "$(jv "$acct" .minimumTlsVersion)" "TLS1_2"
  expect_eq "HTTPS only" "$(jv "$acct" .enableHttpsTrafficOnly)" "true"

  blobsvc="$(azj storage account blob-service-properties show -g "$rg" --account-name "$sa")"
  expect_eq "Blob versioning (S3 Versioning)" "$(jv "$blobsvc" .isVersioningEnabled)" "true"
  expect_eq "Blob soft delete" "$(jv "$blobsvc" .deleteRetentionPolicy.enabled)" "true"

  # Listing containers/blobs is a data-plane call, so it uses --auth-mode login (Entra ID).
  containers="$(azj storage container list --account-name "$sa" --auth-mode login)"
  jq_ok "Container 'tfstate' exists (private)" "$containers" '[.[] | select(.name == "tfstate" and .properties.publicAccess == null)] | length == 1'

  keys="$(az storage blob list --account-name "$sa" -c tfstate --auth-mode login --query '[].name' -o tsv 2>/dev/null | tr '\n' ' ')"
  if [ -n "$keys" ]; then
    pass "State files: $keys"
  else
    warn "No state file yet (normal before the state migration in the last step of Lab 02)"
  fi
}

# You can also run it directly (scripts/verify/02-bootstrap.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
