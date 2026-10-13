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
