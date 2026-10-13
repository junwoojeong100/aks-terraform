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
