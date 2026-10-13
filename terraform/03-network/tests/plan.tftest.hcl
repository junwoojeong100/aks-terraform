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
