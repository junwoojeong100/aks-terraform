data "azurerm_client_config" "current" {}

module "naming" {
  source = "../modules/naming"

  workload        = var.workload
  environment     = var.environment
  location        = var.location
  subscription_id = data.azurerm_client_config.current.subscription_id
}

locals {
  tags = merge(
    {
      workload    = var.workload
      environment = var.environment
      managed_by  = "terraform"
      lab         = "aks-terraform-guide"
    },
    var.tags,
  )

  # StandardV2 NAT Gateway / Public IP are zone-redundant by default, so zones is not specified.
  nat_zones = var.nat_gateway_sku == "StandardV2" ? null : ["1"]

  # Private DNS Zones for Private Endpoints. To support a new PaaS service, just add one line here.
  private_dns_zones = {
    acr       = "privatelink.azurecr.io"
    key_vault = "privatelink.vaultcore.azure.net"
  }

  # Removes duplicates so that a source listed twice appears only once in the NSG rule.
  gateway_sources = distinct(var.gateway_allowed_source_prefixes)
}

# ---------------------------------------------------------------------------
# Resource group + VNet
# An AWS VPC is regional and its subnets are tied to an AZ, whereas
# an Azure VNet subnet spans the whole region and AZs are specified per VM/node.
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "network" {
  name     = module.naming.names.rg_network
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "this" {
  name                = module.naming.names.vnet
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  address_space       = [var.address_space]
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Subnets
# default_outbound_access_enabled = false : does not rely on the "default outbound IP";
# makes these private subnets that reach the internet only through the NAT Gateway.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "aks_nodes" {
  name                            = module.naming.names.snet_aks_nodes
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.aks_nodes]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "aks_apiserver" {
  name                            = module.naming.names.snet_aks_apiserver
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.aks_apiserver]
  default_outbound_access_enabled = false

  # API Server VNet Integration: the API server of the AKS control plane is projected into this subnet.
  delegation {
    name = "aks-apiserver"

    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "ingress" {
  name                            = module.naming.names.snet_ingress
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.ingress]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "private_endpoints" {
  name                            = module.naming.names.snet_private_endpoint
  resource_group_name             = azurerm_resource_group.network.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.private_endpoints]
  default_outbound_access_enabled = false

  # Apply NSG rules to Private Endpoints as well (the default is Disabled).
  private_endpoint_network_policies = "Enabled"
}

# ---------------------------------------------------------------------------
# NSG (plays the role of both an AWS Security Group and a NACL)
# - Stateful, attached to a subnet/NIC, lower priority numbers are evaluated first, supports both Allow and Deny
# - AKS does not modify "the NSG you attached to the subnet", and it does not add rules for Services (LoadBalancer)
#   either, so the inbound allow rules the node subnet needs are defined explicitly below with Terraform.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "aks_nodes" {
  name                = module.naming.names.nsg_aks_nodes
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# snet-ingress has only the internal LB frontend IP and no VMs (NICs). Traffic to the internal Gateway is
# evaluated by the NSG of the node subnet (the backend), so this NSG has no rules.
resource "azurerm_network_security_group" "ingress" {
  name                = module.naming.names.nsg_ingress
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = module.naming.names.nsg_private_endpoint
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

# The Private Endpoint subnet allows only "HTTPS from the AKS node subnet" and blocks all other traffic inside the VNet.
# (The default rule AllowVnetInBound has priority 65000, so a Deny rule at 4000 blocks it first.)
resource "azurerm_network_security_rule" "pe_allow_aks_nodes" {
  name                        = "AllowAksNodesHttps"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = var.subnet_cidrs.aks_nodes
  destination_address_prefix  = var.subnet_cidrs.private_endpoints
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

resource "azurerm_network_security_rule" "pe_deny_vnet" {
  name                        = "DenyOtherVnetInbound"
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
}

# ---------------------------------------------------------------------------
# Inbound allow rules for the node subnet NSG (priority: 100s = intra-cluster traffic, 200s = Gateway)
#
# What passes with the default rules alone (observed: traffic is still not blocked after the rules are deleted)
#   - node ↔ node, API server subnet → node (kubelet 10250), VNet client → internal Gateway : AllowVnetInBound (65000)
#   - Azure Load Balancer health probe                                                      : AllowAzureLoadBalancerInBound (65001)
#   - Azure CNI Overlay node → Pod, Pod ↔ Pod (including DNS)                               : passes via the default rules
#
# What you must allow yourself (required)
#   - Public Gateway: a Standard LB blocks inbound by default, so the NSG must allow it (AllowGatewayHttpHttps).
#
# What is allowed in advance (defensive)
#   - Overlay Pod traffic is not encapsulated, so the subnet NSG applies to it as is. The default rules allow it today,
#     but if an organizational policy or hardening later adds a Deny rule (e.g., DenyAllInBound at 4000), Pod-to-Pod
#     traffic between nodes and DNS break (observed: a Deny rule causes timeouts; with the allow rules below, traffic
#     passes). The allow rules the AKS docs require (node → Pod, Pod → Pod) are created up front.
# ---------------------------------------------------------------------------
resource "azurerm_network_security_rule" "nodes_allow_nodes_to_pods" {
  name                        = "AllowNodesToPods"
  description                 = "Service traffic routing: node -> Pod (Azure CNI Overlay)"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.subnet_cidrs.aks_nodes
  destination_address_prefix  = var.pod_cidr
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

resource "azurerm_network_security_rule" "nodes_allow_pods_to_pods" {
  name                        = "AllowPodsToPods"
  description                 = "Pod-to-Pod and Pod -> Service traffic (including DNS) (Azure CNI Overlay)"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.pod_cidr
  destination_address_prefix  = var.pod_cidr
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

# API Server VNet Integration: traffic from the API server (delegated subnet) to the nodes
# (kubectl exec · logs · port-forward go to kubelet 10250).
# The default rule (AllowVnetInBound) lets it through as well, but it breaks once a Deny rule is added later
# (observed: with a Deny rule added, exec fails with connection reset; with this rule, it passes).
# The Pod CIDR destination is not confirmed to be needed on the webhook call path, so it is included only defensively.
resource "azurerm_network_security_rule" "nodes_allow_apiserver" {
  name                         = "AllowApiServerToCluster"
  description                  = "API server -> node (kubelet 10250: exec, logs), Pod. Keeps kubectl exec working even if a Deny rule is added"
  priority                     = 120
  direction                    = "Inbound"
  access                       = "Allow"
  protocol                     = "*"
  source_port_range            = "*"
  destination_port_range       = "*"
  source_address_prefix        = var.subnet_cidrs.aks_apiserver
  destination_address_prefixes = [var.subnet_cidrs.aks_nodes, var.pod_cidr]
  resource_group_name          = azurerm_resource_group.network.name
  network_security_group_name  = azurerm_network_security_group.aks_nodes.name
}

# Public Gateway (Standard LB): allowed sources → HTTP/HTTPS listeners.
# The public LB's public IP is created later by AKS and is unknown at plan time, and the nodes have no public IP,
# so only the service the LB exposes on 80/443 (the Gateway) is reachable from the internet. That is why the
# destination is *. (443 is allowed in advance so the NSG doesn't need to be edited again when you add the TLS
# listener in Lab 07.)
# A single source value goes in the singular attribute and multiple values in the plural one
# (only one of the two can be set; service tags can only be used in the singular).
# If gateway_allowed_source_prefixes = [], no rule is created (internal Gateway only).
resource "azurerm_network_security_rule" "nodes_allow_gateway" {
  count = length(local.gateway_sources) > 0 ? 1 : 0

  name                        = "AllowGatewayHttpHttps"
  description                 = "Inbound HTTP/HTTPS for the public Gateway (Standard LB)"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = length(local.gateway_sources) == 1 ? local.gateway_sources[0] : null
  source_address_prefixes     = length(local.gateway_sources) > 1 ? local.gateway_sources : null
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.network.name
  network_security_group_name = azurerm_network_security_group.aks_nodes.name
}

resource "azurerm_subnet_network_security_group_association" "aks_nodes" {
  subnet_id                 = azurerm_subnet.aks_nodes.id
  network_security_group_id = azurerm_network_security_group.aks_nodes.id
}

resource "azurerm_subnet_network_security_group_association" "ingress" {
  subnet_id                 = azurerm_subnet.ingress.id
  network_security_group_id = azurerm_network_security_group.ingress.id
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------------------------------------------------------------------------
# NAT Gateway : sends the nodes' outbound (internet) traffic out through a static public IP.
# Same structure as an AWS "private subnet + NAT Gateway", but in Azure you attach it directly to the subnet.
# (No route table changes are needed.)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = module.naming.names.pip_nat_gateway
  location            = azurerm_resource_group.network.location
  resource_group_name = azurerm_resource_group.network.name
  allocation_method   = "Static"
  sku                 = var.nat_gateway_sku
  zones               = local.nat_zones
  tags                = local.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = module.naming.names.nat_gateway
  location                = azurerm_resource_group.network.location
  resource_group_name     = azurerm_resource_group.network.name
  sku_name                = var.nat_gateway_sku
  zones                   = local.nat_zones
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "aks_nodes" {
  subnet_id      = azurerm_subnet.aks_nodes.id
  nat_gateway_id = azurerm_nat_gateway.this.id

  depends_on = [azurerm_nat_gateway_public_ip_association.this]
}

# ---------------------------------------------------------------------------
# Private DNS Zone : resolves the FQDN of a Private Endpoint to a private IP.
# With an AWS Interface VPC Endpoint, enabling "Private DNS" once is enough, but in Azure you configure it yourself:
# create the Zone → link it to the VNet → attach a DNS Zone Group (on the Private Endpoint side).
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "this" {
  for_each = local.private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.network.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.private_dns_zones

  name                 = "link-${azurerm_virtual_network.this.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.this[each.key].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}
