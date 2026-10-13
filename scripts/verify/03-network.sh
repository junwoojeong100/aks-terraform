#!/usr/bin/env bash
# Lab 03 검증: VNet · 서브넷 · NSG · NAT Gateway · Private DNS 가 설계대로 만들어졌는지 확인합니다 (읽기 전용).
#   AWS 비교: VPC + 서브넷 + Security Group/NACL + NAT Gateway + Route 53 private hosted zone
# 사용법: scripts/verify.sh 03-network
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg vnet_name nat_ip vnet sn nat pips zones zone links
  rg="$(tf_out 03-network resource_group_name)"
  vnet_name="$(tf_out 03-network vnet_name)"
  nat_ip="$(tf_out 03-network nat_gateway_public_ip)"

  section "03-network · VNet (${vnet_name:-?})"
  if [ -z "$rg" ]; then
    fail "terraform output 을 읽을 수 없습니다. 03-network 에서 init/apply 를 마쳤나요?"
    return
  fi

  vnet="$(azj network vnet show -g "$rg" -n "$vnet_name")"
  if [ -z "$vnet" ]; then
    fail "VNet 을 찾을 수 없습니다: $vnet_name"
    return
  fi
  expect_set "주소 공간" "$(jv "$vnet" '.addressSpace.addressPrefixes | join(",")')"

  # Azure 서브넷은 AZ 에 묶이지 않고 리전 전체에 걸칩니다 (AWS 는 서브넷마다 AZ 를 지정).
  for sn in snet-aks-nodes snet-aks-apiserver snet-ingress snet-private-endpoints; do
    jq_ok "서브넷 $sn 존재" "$vnet" "[.subnets[] | select(.name == \"$sn\")] | length == 1"
  done
  jq_ok "API 서버 서브넷이 managedClusters 로 위임됨 (API Server VNet Integration)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-apiserver") | .delegations | any(.serviceName == "Microsoft.ContainerService/managedClusters")'
  jq_ok "노드 서브넷에 NAT Gateway 연결 (고정 egress)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .natGateway.id != null'
  jq_ok "노드 서브넷의 기본 아웃바운드 접근 비활성화" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .defaultOutboundAccess == false'
  for sn in snet-aks-nodes snet-ingress snet-private-endpoints; do
    jq_ok "NSG 연결: $sn" "$vnet" ".subnets[] | select(.name == \"$sn\") | .networkSecurityGroup.id != null"
  done

  nat="$(azj network nat gateway list -g "$rg")"
  expect_eq "NAT Gateway SKU (영역 중복)" "$(jv "$nat" '.[0].sku.name')" "StandardV2"
  pips="$(azj network public-ip list -g "$rg")"
  expect_eq "NAT 공인 IP = terraform output" "$(jv "$pips" '[.[] | select(.name | startswith("pip-ng-"))][0].ipAddress')" "$nat_ip"

  # Private Endpoint 용 Private DNS Zone 이 이 VNet 에 연결되어 있어야 이름이 사설 IP 로 풀립니다.
  zones="$(az network private-dns zone list -g "$rg" --query '[].name' -o tsv 2>/dev/null)"
  for zone in privatelink.azurecr.io privatelink.vaultcore.azure.net; do
    if printf '%s\n' "$zones" | grep -qx "$zone"; then
      links="$(azj network private-dns link vnet list -g "$rg" -z "$zone")"
      jq_ok "Private DNS Zone $zone → VNet 연결" "$links" "any(.[]; .virtualNetwork.id | endswith(\"/$vnet_name\"))"
    else
      fail "Private DNS Zone 이 없습니다: $zone"
    fi
  done
}

# 직접 실행(scripts/verify/03-network.sh)도 가능합니다.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
