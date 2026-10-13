#!/usr/bin/env bash
# Lab 02 검증: Terraform state 저장소(Storage Account + Blob 컨테이너)가 안전하게 만들어졌는지 확인합니다 (읽기 전용).
#   AWS 비교: S3 버킷(Versioning, Block Public Access) + DynamoDB 락 테이블 → Azure 는 Blob 하나로 해결합니다(락은 blob lease).
# 사용법: scripts/verify.sh 02-bootstrap
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg sa acct blobsvc containers keys
  rg="$(tf_out 02-bootstrap tfstate_resource_group_name)"
  sa="$(tf_out 02-bootstrap tfstate_storage_account_name)"

  section "02-bootstrap · state 저장소 (${sa:-?})"
  if [ -z "$sa" ]; then
    fail "terraform output 을 읽을 수 없습니다. 02-bootstrap 에서 init/apply 를 마쳤나요?"
    return
  fi

  acct="$(azj storage account show -g "$rg" -n "$sa")"
  if [ -z "$acct" ]; then
    fail "스토리지 계정을 찾을 수 없습니다: $sa"
    return
  fi

  expect_eq "복제 방식 (가용 영역 3곳 동기 복제)" "$(jv "$acct" .sku.name)" "Standard_ZRS"
  expect_eq "공개 Blob 접근 허용 (S3 Block Public Access)" "$(jv "$acct" .allowBlobPublicAccess)" "false"
  expect_eq "계정 키(Shared Key) 인증 허용 → Entra ID 만 사용" "$(jv "$acct" .allowSharedKeyAccess)" "false"
  expect_eq "최소 TLS 버전" "$(jv "$acct" .minimumTlsVersion)" "TLS1_2"
  expect_eq "HTTPS 전용" "$(jv "$acct" .enableHttpsTrafficOnly)" "true"

  blobsvc="$(azj storage account blob-service-properties show -g "$rg" --account-name "$sa")"
  expect_eq "Blob 버전 관리 (S3 Versioning)" "$(jv "$blobsvc" .isVersioningEnabled)" "true"
  expect_eq "Blob soft delete" "$(jv "$blobsvc" .deleteRetentionPolicy.enabled)" "true"

  # 컨테이너/blob 조회는 데이터 평면 호출이라 --auth-mode login(Entra ID)을 씁니다.
  containers="$(azj storage container list --account-name "$sa" --auth-mode login)"
  jq_ok "컨테이너 'tfstate' 존재 (비공개)" "$containers" '[.[] | select(.name == "tfstate" and .properties.publicAccess == null)] | length == 1'

  keys="$(az storage blob list --account-name "$sa" -c tfstate --auth-mode login --query '[].name' -o tsv 2>/dev/null | tr '\n' ' ')"
  if [ -n "$keys" ]; then
    pass "state 파일: $keys"
  else
    warn "아직 state 파일이 없습니다 (Lab 02 마지막 단계의 state 이전 전이면 정상)"
  fi
}

# 직접 실행(scripts/verify/02-bootstrap.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
