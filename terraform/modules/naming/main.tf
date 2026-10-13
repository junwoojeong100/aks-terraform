locals {
  # Follows the Cloud Adoption Framework (CAF) abbreviations, but shortens regions to short codes.
  region_codes = {
    koreacentral       = "krc"
    koreasouth         = "krs"
    japaneast          = "jpe"
    japanwest          = "jpw"
    eastasia           = "eas"
    southeastasia      = "sea"
    australiaeast      = "aue"
    eastus             = "eus"
    eastus2            = "eus2"
    westus2            = "wus2"
    westus3            = "wus3"
    centralus          = "cus"
    northeurope        = "neu"
    westeurope         = "weu"
    uksouth            = "uks"
    swedencentral      = "sec"
    germanywestcentral = "gwc"
  }

  region_code = lookup(local.region_codes, var.location, substr(var.location, 0, 4))
  base        = "${var.workload}-${var.environment}-${local.region_code}"
  flat        = "${var.workload}${var.environment}${local.region_code}"

  # A hash determined by subscription + workload. Every stack reproduces the same value, so
  # they can find each other's "globally unique names" (ACR, Key Vault, Storage) without remote state.
  suffix = substr(sha256("${var.subscription_id}/${var.workload}/${var.environment}"), 0, 5)

  names = {
    # Resource groups (separated by lifecycle)
    rg_tfstate   = "rg-${local.base}-tfstate"
    rg_network   = "rg-${local.base}-network"
    rg_platform  = "rg-${local.base}-platform"
    rg_aks       = "rg-${local.base}-aks"
    rg_aks_nodes = "rg-${local.base}-aks-nodes"
    rg_workload  = "rg-${local.base}-workload"

    # Terraform state (3–24 characters, lowercase letters + digits)
    st_tfstate = "sttfstate${var.workload}${local.suffix}"

    # Network
    vnet                  = "vnet-${local.base}"
    snet_aks_nodes        = "snet-aks-nodes"
    snet_aks_apiserver    = "snet-aks-apiserver"
    snet_ingress          = "snet-ingress"
    snet_private_endpoint = "snet-private-endpoints"
    nsg_aks_nodes         = "nsg-${local.base}-aks-nodes"
    nsg_ingress           = "nsg-${local.base}-ingress"
    nsg_private_endpoint  = "nsg-${local.base}-private-endpoints"
    nat_gateway           = "ng-${local.base}"
    pip_nat_gateway       = "pip-ng-${local.base}"

    # Platform services
    log_analytics          = "log-${local.base}"
    monitor_workspace      = "amw-${local.base}"
    grafana                = "amg-${local.base}"
    acr                    = "acr${local.flat}${local.suffix}"
    key_vault              = "kv-${var.workload}-${var.environment}-${local.suffix}"
    id_aks_cluster         = "id-aks-${local.base}-cluster"
    id_aks_kubelet         = "id-aks-${local.base}-kubelet"
    dce_prometheus         = "dce-${local.base}-prometheus"
    dcr_prometheus         = "dcr-${local.base}-prometheus"
    dcr_container_insights = "dcr-${local.base}-container-insights"

    # AKS
    aks = "aks-${local.base}"

    # AKS Automatic (Lab 10)
    rg_automatic     = "rg-${local.base}-automatic"
    aks_automatic    = "aksa-${local.base}"
    vnet_automatic   = "vnet-${local.base}-automatic"
    id_aks_automatic = "id-aks-${local.base}-automatic"
  }
}
