<!-- lang-switch -->
**English** | [한국어](ko/03-network.md)
<!-- /lang-switch -->

# Lab 03. Networking: VNet · NSG · NAT Gateway · Private DNS

| Duration | Estimated cost | Terraform stack | Prerequisite |
|---|---|---|---|
| 20 min | NAT Gateway + Public IP (small hourly charge) | `terraform/03-network` | [02. Remote state](02-bootstrap.md) |

## What you build in this lab

![VNet design: subnets · NSGs · NAT Gateway · Private DNS](diagrams/network-topology.svg)

Here is the same design summarized as text:

```text
Internet
  ▲   1 static public IP (for allow-listing on external services' firewalls)
  │
NAT Gateway  (StandardV2, zone-redundant)  ── subnet association ──►  snet-aks-nodes

VNet 10.10.0.0/16   (rg-…-network)
  ├─ snet-aks-nodes          10.10.0.0/24   AKS nodes · NSG (allows pod · API server · Gateway inbound) · NAT Gateway attached
  ├─ snet-aks-apiserver      10.10.1.0/28   API Server VNet Integration (delegated exclusively to AKS)
  ├─ snet-ingress            10.10.2.0/27   Internal load balancer frontend IP · NSG
  └─ snet-private-endpoints  10.10.3.0/27   ACR / Key Vault Private Endpoints · NSG (allows only port 443 from the node subnet)

Private DNS Zone (VNet link):  privatelink.azurecr.io  ·  privatelink.vaultcore.azure.net
```

## Comparison for AWS engineers

| AWS | Azure | Differences / notes |
|---|---|---|
| VPC | `azurerm_virtual_network` | Subnet CIDRs can be chosen freely within the VNet address space. Azure reserves **5 IPs** per subnet (same as AWS). |
| Subnet (tied to one AZ) | `azurerm_subnet` | **Not tied to an AZ.** Node pools and load balancers specify the AZ. |
| Security Group + NACL | `azurerm_network_security_group` | Stateful, with priorities (lower number wins) and Deny rules. Attached to a subnet. |
| Private subnet + NAT GW | `azurerm_nat_gateway` + subnet association | No route table changes needed. `default_outbound_access_enabled = false` turns off "implicit internet access". |
| Interface VPC Endpoint | `azurerm_private_endpoint` + Private DNS Zone | Connected to ACR/Key Vault in the next lab, Lab 04. |
| Route 53 Private Hosted Zone | `azurerm_private_dns_zone` + `..._virtual_network_link` | Names resolve in a VNet only if the zone has a link to that VNet. |

> [!IMPORTANT]
> **IP capacity planning**: With Azure CNI Overlay, **only nodes** use VNet IPs. A `/24` node subnet (251 IPs) is plenty for a few dozen nodes, even counting the temporary nodes created during upgrades (max_surge 33%). If you plan for hundreds of nodes, grow it to `/22` or larger. The API server subnet needs at least a `/28` per cluster, and it **can't be used for anything else**.

## Design decisions (best practices)

| Decision | Why |
|---|---|
| Separate subnets by purpose (nodes / API server / ingress / Private Endpoints) | You can plan NSGs, delegation, and IPs per subnet. Keeping the ingress LB IPs in their own subnet means they don't affect the node subnet rules. |
| `default_outbound_access_enabled = false` | The default outbound IP isn't owned by you and can change, and Azure is in the process of retiring it. Explicit egress (NAT Gateway) is the recommended approach. |
| NAT Gateway **StandardV2** | Zone-redundant, and usable with AKS `userAssignedNATGateway`. Not supported in some regions (e.g., Canada East) → set the variable `nat_gateway_sku = "Standard"`. |
| Private Endpoint subnet NSG: **allow only port 443 from the node subnet + deny all other VNet-internal traffic** | Applying an NSG to Private Endpoints requires `private_endpoint_network_policies = "Enabled"`. Least-privilege network separation. |
| Node subnet NSG: **define the inbound allow rules directly in Terraform** | AKS doesn't modify an NSG that you create yourself and attach to a subnet (it doesn't add rules for Services automatically either). Without this rule, a public Gateway can't be reached. Pod and API server traffic passes under the default rules, but it breaks the moment you add a Deny rule, so the allow rules are created up front (all verified in a real subscription). See *NSG inbound rules* below. |
| Ingress subnet NSG has **no rules** | This subnet holds only the internal LB frontend IP and has no VMs (NICs). Traffic that passes through the load balancer is evaluated by the node subnet NSG, which is the backend. |
| Manage the Private DNS Zones in the network stack | In real environments they are often managed centrally in the Connectivity subscription. |

## NSG inbound rules

An NSG evaluates rules from the lowest priority number upward, and if no rule matches, it applies the default rules (`AllowVnetInBound` 65000 → `AllowAzureLoadBalancerInBound` 65001 → `DenyAllInBound` 65500). The inbound traffic in this stack and how each flow is allowed are listed below. The results in the **Category** column were confirmed in a real subscription by deleting rules or adding a Deny rule ([Appendix A](99-appendix.md)).

| NSG | Traffic | Rule | Category |
|---|---|---|---|
| Node | Node ↔ node · clients inside the VNet → internal Gateway | Default rule `AllowVnetInBound` | Passes via default rule |
| Node | Azure Load Balancer health probes | Default rule `AllowAzureLoadBalancerInBound` | Passes via default rule |
| Node | Internet → public Gateway (HTTP/HTTPS) | `AllowGatewayHttpHttps` (200): `gateway_allowed_source_prefixes` (default `Internet`) → TCP 80 · 443 | **Required** — deleting it blocks access |
| Node | Node → pod · pod ↔ pod (including DNS) | `AllowNodesToPods` (100): node CIDR → `pod_cidr` · `AllowPodsToPods` (110): `pod_cidr` → `pod_cidr` | Defensive — passes via default rules; breaks if you add a Deny |
| Node | API server → node (kubelet 10250: `kubectl exec` · logs) · pod | `AllowApiServerToCluster` (120): API server subnet → node CIDR · `pod_cidr` | Defensive — passes via default rules; `exec` breaks if you add a Deny |
| Private Endpoint | Node → ACR · Key Vault | `AllowAksNodesHttps` (100): node CIDR → TCP 443. All other VNet traffic is denied by `DenyOtherVnetInbound` (4000) | Design |
| Ingress | None | No rules are defined (see *Design decisions* above) | — |

> [!IMPORTANT]
> **AKS doesn't modify an NSG that you create yourself and attach to a subnet.** Rules for Services (`LoadBalancer`) are added automatically only to resources that AKS manages ([AKS networking concepts](https://learn.microsoft.com/azure/aks/concepts-network#network-security-groups)). In practice, AKS creates its own NSG (`aks-agentpool-…-nsg`) in the node resource group, attaches it to the node NICs, and adds the `k8s-azure-lb_allow_…` rules only there, while our subnet NSG is left untouched. Inbound traffic has to pass both the subnet NSG and the NIC NSG, so without an allow rule in the subnet NSG, the public Gateway isn't reachable.

> [!IMPORTANT]
> **Pod traffic is also evaluated by the subnet NSG.** Pod traffic in Azure CNI Overlay isn't encapsulated, so the subnet NSG applies to it ([Azure CNI Overlay: NSG](https://learn.microsoft.com/azure/aks/concepts-network-azure-cni-overlay#network-security-groups)). With only the default rules, cross-node pod communication and DNS pass through unchanged, but both break the moment a Deny rule is added (e.g., a priority 4000 Deny), such as through organizational policy or hardening. With `AllowNodesToPods` / `AllowPodsToPods` in place, traffic passes even when a Deny rule exists. That's why **`pod_cidr` must be the same value as in 05-aks** (default `10.244.0.0/16`), and `scripts/verify.sh 05-aks` checks that the two values match.

> [!NOTE]
> To open the public Gateway to specific IPs only, pass `-var 'gateway_allowed_source_prefixes=["203.0.113.10/32"]'`; if you use only an internal Gateway, pass `-var 'gateway_allowed_source_prefixes=[]'` (no rule is created). Port 443 is allowed up front so that you don't have to edit the NSG again when you add the TLS listener in Lab 07.
>
> No NSG is attached to `snet-aks-apiserver` (it's a delegated subnet, and traffic inside the VNet is allowed by default). If you attach one, first allow these inbound rules: node subnet → API server subnet on TCP 443 · 4443, and `AzureLoadBalancer` → API server subnet on TCP 9988 ([API Server VNet Integration](https://learn.microsoft.com/azure/aks/api-server-vnet-integration#network-security-group-nsg-security-rules)).

## Code

<!-- tf:include path="terraform/03-network/versions.tf" -->
```hcl title="terraform/03-network/versions.tf"
terraform {
  required_version = "~> 1.16"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.9"
    }
  }

  # storage_account_name / container_name are injected with `terraform init -backend-config=../backend.hcl`.
  backend "azurerm" {
    use_azuread_auth = true
    key              = "03-network.tfstate"
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/providers.tf" -->
```hcl title="terraform/03-network/providers.tf"
provider "azurerm" {
  # subscription_id is read from the ARM_SUBSCRIPTION_ID environment variable.
  resource_provider_registrations = "none"

  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/variables.tf" -->
```hcl title="terraform/03-network/variables.tf"
variable "workload" {
  description = "Workload name (3–8 lowercase letters or digits)"
  type        = string
  default     = "aksdemo"
}

variable "environment" {
  description = "Environment (dev, test, prod)"
  type        = string
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "koreacentral"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "address_space" {
  description = "VNet address space. Choose a range that does not overlap with on-premises or peered networks."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidrs" {
  description = <<-EOT
    Subnet CIDRs.
    - aks_nodes: node IPs only (Azure CNI Overlay is used, so Pod IPs are not taken from this subnet)
    - aks_apiserver: for API Server VNet Integration. At least /28, dedicated to AKS
    - ingress: internal load balancer frontend IP (Gateway)
    - private_endpoints: Private Endpoints for ACR / Key Vault, etc.
  EOT
  type = object({
    aks_nodes         = string
    aks_apiserver     = string
    ingress           = string
    private_endpoints = string
  })
  default = {
    aks_nodes         = "10.10.0.0/24"
    aks_apiserver     = "10.10.1.0/28"
    ingress           = "10.10.2.0/27"
    private_endpoints = "10.10.3.0/27"
  }

  validation {
    condition     = alltrue([for cidr in values(var.subnet_cidrs) : can(cidrhost(cidr, 0))])
    error_message = "All values in subnet_cidrs must be valid CIDRs and must fall within address_space."
  }
}

variable "pod_cidr" {
  description = <<-EOT
    Pod CIDR for Azure CNI Overlay. Use the same value as pod_cidr in 05-aks.
    Creates inbound rules on the node NSG for this range. Traffic works without them while only the default rules exist,
    but they are defensive: they keep cross-node Pod traffic (including DNS) working if a Deny rule is added later.
  EOT
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "pod_cidr must be a valid CIDR. Example: 10.244.0.0/16"
  }
}

variable "nat_gateway_sku" {
  description = "NAT Gateway SKU. StandardV2 is zone-redundant and available in most regions."
  type        = string
  default     = "StandardV2"

  validation {
    condition     = contains(["Standard", "StandardV2"], var.nat_gateway_sku)
    error_message = "nat_gateway_sku must be Standard or StandardV2."
  }
}

variable "gateway_allowed_source_prefixes" {
  description = <<-EOT
    Sources allowed to reach HTTP (80) / HTTPS (443) on the public Gateway (internal_gateway = false in 07-ingress).
    Either the Internet service tag or a list of CIDRs. To allow only specific IPs, list them like ["203.0.113.10/32"].
    If you use only an internal Gateway, set this to []. No rule is created, and clients inside the VNet
    connect through the default rule (AllowVnetInBound).
  EOT
  type        = list(string)
  default     = ["Internet"]

  validation {
    condition     = alltrue([for prefix in var.gateway_allowed_source_prefixes : prefix == "Internet" || can(cidrhost(prefix, 0))])
    error_message = "Values in gateway_allowed_source_prefixes must be Internet or a valid CIDR."
  }

  # An NSG rule cannot take a service tag in the list (plural) attribute.
  validation {
    condition     = !contains(var.gateway_allowed_source_prefixes, "Internet") || length(var.gateway_allowed_source_prefixes) == 1
    error_message = "The Internet service tag cannot be combined with other values. Use [\"Internet\"] alone or a list of CIDRs."
  }
}
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/main.tf" -->
```hcl title="terraform/03-network/main.tf"
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
```
<!-- /tf:include -->

<!-- tf:include path="terraform/03-network/outputs.tf" -->
```hcl title="terraform/03-network/outputs.tf"
output "resource_group_name" {
  description = "Network resource group"
  value       = azurerm_resource_group.network.name
}

output "vnet_name" {
  description = "VNet name (looked up with a data source in later stacks)"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Map of subnet IDs"
  value = {
    aks_nodes         = azurerm_subnet.aks_nodes.id
    aks_apiserver     = azurerm_subnet.aks_apiserver.id
    ingress           = azurerm_subnet.ingress.id
    private_endpoints = azurerm_subnet.private_endpoints.id
  }
}

output "nat_gateway_public_ip" {
  description = "Static public IP for cluster outbound traffic (the value to add to external services' firewall allow lists)"
  value       = azurerm_public_ip.nat.ip_address
}

output "private_dns_zone_names" {
  description = "Private DNS Zones for Private Endpoints"
  value       = [for zone in azurerm_private_dns_zone.this : zone.name]
}
```
<!-- /tf:include -->

**Unit tests** (verify the plan logic with `terraform test`, no Azure needed)

<!-- tf:include path="terraform/03-network/tests/plan.tftest.hcl" -->
```hcl title="terraform/03-network/tests/plan.tftest.hcl"
# Verify only the plan logic, without Azure: terraform -chdir=terraform/03-network test
mock_provider "azurerm" {
  source = "../mocks"
}

run "plan_defaults" {
  command = plan

  assert {
    condition     = length(azurerm_subnet.aks_apiserver.delegation) == 1
    error_message = "The API server subnet must be delegated to Microsoft.ContainerService/managedClusters."
  }

  assert {
    condition     = azurerm_subnet.aks_nodes.default_outbound_access_enabled == false
    error_message = "The node subnet must not rely on the default outbound IP (use a NAT Gateway)."
  }
}

run "plan_standard_nat" {
  command = plan

  variables {
    nat_gateway_sku = "Standard"
  }

  assert {
    condition     = azurerm_nat_gateway.this.zones == toset(["1"])
    error_message = "A Standard NAT Gateway must be placed in a single availability zone."
  }
}

# Node NSG: AKS does not modify an NSG attached to the subnet, so the required inbound allow rules must exist in Terraform.
run "nodes_nsg_allows_overlay_and_gateway_traffic" {
  command = plan

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.source_address_prefix == var.subnet_cidrs.aks_nodes &&
      azurerm_network_security_rule.nodes_allow_nodes_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "Inbound from the node subnet → Pod CIDR must be allowed (Service traffic routing in Azure CNI Overlay)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_pods_to_pods.source_address_prefix == var.pod_cidr &&
      azurerm_network_security_rule.nodes_allow_pods_to_pods.destination_address_prefix == var.pod_cidr
    )
    error_message = "Inbound between Pod CIDRs must be allowed (so cross-node Pod traffic survives a Deny rule added later)."
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_apiserver.source_address_prefix == var.subnet_cidrs.aks_apiserver &&
      azurerm_network_security_rule.nodes_allow_apiserver.destination_address_prefixes == toset([var.subnet_cidrs.aks_nodes, var.pod_cidr])
    )
    error_message = "Inbound from the API server subnet → node/Pod CIDR must be allowed."
  }

  assert {
    condition = (
      length(azurerm_network_security_rule.nodes_allow_gateway) == 1 &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "Internet" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].destination_port_ranges == toset(["80", "443"])
    )
    error_message = "With the default (public Gateway), inbound internet → 80/443 must be allowed."
  }
}

run "gateway_rule_with_multiple_cidrs" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["203.0.113.0/24", "198.51.100.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == toset(["203.0.113.0/24", "198.51.100.10/32"]) &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == null
    )
    error_message = "With multiple sources, only the plural attribute (source_address_prefixes) must be used."
  }
}

run "gateway_rule_with_single_cidr" {
  command = plan

  variables {
    # Duplicates are merged into one, so the singular attribute is used, just as with a single value.
    gateway_allowed_source_prefixes = ["203.0.113.10/32", "203.0.113.10/32"]
  }

  assert {
    condition = (
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefix == "203.0.113.10/32" &&
      azurerm_network_security_rule.nodes_allow_gateway[0].source_address_prefixes == null
    )
    error_message = "With only one source, only the singular attribute (source_address_prefix) must be used."
  }
}

run "no_gateway_rule_for_internal_only" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = []
  }

  assert {
    condition     = length(azurerm_network_security_rule.nodes_allow_gateway) == 0
    error_message = "If gateway_allowed_source_prefixes = [], the public Gateway allow rule must not be created."
  }
}

run "rejects_internet_tag_mixed_with_cidr" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["Internet", "203.0.113.0/24"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
}

run "rejects_invalid_gateway_source" {
  command = plan

  variables {
    gateway_allowed_source_prefixes = ["not-a-cidr"]
  }

  expect_failures = [var.gateway_allowed_source_prefixes]
}

run "rejects_invalid_cidr" {
  command = plan

  variables {
    subnet_cidrs = {
      aks_nodes         = "not-a-cidr"
      aks_apiserver     = "10.10.1.0/28"
      ingress           = "10.10.2.0/27"
      private_endpoints = "10.10.3.0/27"
    }
  }

  expect_failures = [var.subnet_cidrs]
}
```
<!-- /tf:include -->

> [!NOTE]
> The mock values these tests reference are in `terraform/mocks/azurerm.tfmock.hcl` in the [Appendix](99-appendix.md).

## Walkthrough

```bash
cd terraform/03-network
terraform init -backend-config=../backend.hcl
terraform plan -out tfplan        # about 26 resources
terraform apply tfplan            # 2–4 min
```

### Verify

```bash
RG=$(terraform output -raw resource_group_name)
VNET=$(terraform output -raw vnet_name)

az network vnet subnet list -g "$RG" --vnet-name "$VNET" \
  --query "[].{name:name, cidr:addressPrefix, delegation:delegations[0].serviceName, natGw:natGateway.id!=null}" -o table

terraform output nat_gateway_public_ip         # the cluster's static outbound IP
az network nat gateway show -g "$RG" -n "$(az network nat gateway list -g "$RG" --query '[0].name' -o tsv)" \
  --query "{sku:sku.name, zones:zones, idleTimeout:idleTimeoutInMinutes}" -o json

# Inbound allow rules of the node NSG
NSG=$(az network nsg list -g "$RG" --query "[?ends_with(name, '-aks-nodes')].name | [0]" -o tsv)
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o table
```

Expected result: `snet-aks-nodes` shows `natGw: true`, and `snet-aks-apiserver` shows the delegation `Microsoft.ContainerService/managedClusters`. The node NSG lists `AllowNodesToPods` (100) · `AllowPodsToPods` (110) · `AllowApiServerToCluster` (120) · `AllowGatewayHttpHttps` (200).

### Automated verification script

Checks subnet delegation, the NAT Gateway association and static public IP, the NSGs, and the VNet links of the Private DNS Zones in one go (read-only).

```bash
cd ../..                          # run from the repository root
scripts/verify.sh 03-network
```

<!-- tf:include path="scripts/verify/03-network.sh" -->
```bash title="scripts/verify/03-network.sh"
#!/usr/bin/env bash
# Lab 03 verification: checks that the VNet · subnets · NSGs · NAT Gateway · Private DNS were created as designed (read-only).
#   AWS comparison: VPC + subnets + Security Group/NACL + NAT Gateway + Route 53 private hosted zone
# Usage: scripts/verify.sh 03-network
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

verify_stack() {
  local rg vnet_name nat_ip vnet sn nat natsku pips zones zone links rules r
  rg="$(tf_out 03-network resource_group_name)"
  vnet_name="$(tf_out 03-network vnet_name)"
  nat_ip="$(tf_out 03-network nat_gateway_public_ip)"

  section "03-network · VNet (${vnet_name:-?})"
  if [ -z "$rg" ]; then
    fail "Can't read terraform output. Did you finish init/apply in 03-network?"
    return
  fi

  vnet="$(azj network vnet show -g "$rg" -n "$vnet_name")"
  if [ -z "$vnet" ]; then
    fail "VNet not found: $vnet_name"
    return
  fi
  expect_set "Address space" "$(jv "$vnet" '.addressSpace.addressPrefixes | join(",")')"

  # Azure subnets aren't tied to an AZ; they span the whole region (in AWS, each subnet is pinned to an AZ).
  for sn in snet-aks-nodes snet-aks-apiserver snet-ingress snet-private-endpoints; do
    jq_ok "Subnet $sn exists" "$vnet" "[.subnets[] | select(.name == \"$sn\")] | length == 1"
  done
  jq_ok "API server subnet is delegated to managedClusters (API Server VNet Integration)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-apiserver") | .delegations | any(.serviceName == "Microsoft.ContainerService/managedClusters")'
  jq_ok "NAT Gateway attached to the node subnet (static egress)" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .natGateway.id != null'
  jq_ok "Default outbound access disabled on the node subnet" "$vnet" \
    '.subnets[] | select(.name == "snet-aks-nodes") | .defaultOutboundAccess == false'
  for sn in snet-aks-nodes snet-ingress snet-private-endpoints; do
    jq_ok "NSG attached: $sn" "$vnet" ".subnets[] | select(.name == \"$sn\") | .networkSecurityGroup.id != null"
  done

  # AKS doesn't modify an NSG attached to the subnet, so the node NSG's inbound allow rules
  # must be the ones Terraform created.
  rules="$(nodes_nsg_rules "$rg")"
  if [ -z "$rules" ]; then
    fail "Can't read the rules of the node subnet NSG (…-aks-nodes)"
  else
    for r in AllowNodesToPods AllowPodsToPods AllowApiServerToCluster; do
      jq_ok "Node NSG inbound allow: $r (Azure CNI Overlay / API Server VNet Integration)" "$rules" \
        "any(.[]; .name == \"$r\" and .direction == \"Inbound\" and .access == \"Allow\")"
    done
    # If gateway_allowed_source_prefixes = [] (internal Gateway only), it's normal for this rule to be absent.
    jq_warn "Node NSG inbound allow: AllowGatewayHttpHttps (public Gateway 80/443. Fine if you only use an internal Gateway)" "$rules" \
      'any(.[]; .name == "AllowGatewayHttpHttps" and .direction == "Inbound" and .access == "Allow")'
  fi

  nat="$(azj network nat gateway list -g "$rg")"
  natsku="$(jv "$nat" '.[0].sku.name')" # nat_gateway_sku variable: StandardV2 (default) / Standard
  case "$natsku" in
    StandardV2) pass "NAT Gateway SKU = StandardV2 (zone-redundant)" ;;
    Standard) warn "NAT Gateway SKU = Standard (not zone-redundant. Use it only in regions that don't support StandardV2)" ;;
    *) fail "NAT Gateway SKU: expected StandardV2 or Standard / actual '${natsku:-(none)}'" ;;
  esac
  pips="$(azj network public-ip list -g "$rg")"
  expect_eq "NAT public IP = terraform output" "$(jv "$pips" '[.[] | select(.name | startswith("pip-ng-"))][0].ipAddress')" "$nat_ip"

  # The Private DNS Zones for Private Endpoints must be linked to this VNet so that the names resolve to private IPs.
  zones="$(az network private-dns zone list -g "$rg" --query '[].name' -o tsv 2>/dev/null)"
  for zone in privatelink.azurecr.io privatelink.vaultcore.azure.net; do
    if printf '%s\n' "$zones" | grep -qx "$zone"; then
      links="$(azj network private-dns link vnet list -g "$rg" -z "$zone")"
      jq_ok "Private DNS Zone $zone linked to the VNet" "$links" "any(.[]; .virtualNetwork.id | endswith(\"/$vnet_name\"))"
    else
      fail "Private DNS Zone not found: $zone"
    fi
  done
}

# You can also run it directly (scripts/verify/03-network.sh).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then verify_stack; summary; fi
```
<!-- /tf:include -->

## Common issues

| Symptom | Cause / fix |
|---|---|
| `SubnetsHaveNoAddressPrefixes` / CIDR conflict | Set an `address_space` that doesn't overlap with your on-premises or peered VNets. |
| `StandardV2 NAT gateway is not supported in region` | Use `-var nat_gateway_sku=Standard` (in this case `zones = ["1"]`, a single zone). |
| Connections to the Private Endpoint subnet fail | Check the NSG rule priorities (100 allow → 4000 deny) and the source (node subnet CIDR). |
| Cross-node pod communication and DNS don't work (after Lab 05) | Check that no Deny rule was added to the node NSG, and that `AllowPodsToPods` covers the same range as `pod_cidr` in 05-aks. If they differ, make `pod_cidr` the same in both stacks and apply 03-network again. |
| `kubectl exec` · `logs` fail with `connection reset` / timeout | If the node NSG has a Deny rule, check that `AllowApiServerToCluster` (API server subnet → node port 10250) is still there. |
| The public Gateway times out (Lab 07) | Check that the node NSG has `AllowGatewayHttpHttps` and that `gateway_allowed_source_prefixes` includes your IP (`az network nsg rule list`). An internal Gateway can't be reached from outside the VNet. |

Next → [Lab 04. Platform services: ACR · Key Vault · monitoring · identities for AKS](04-platform.md)
