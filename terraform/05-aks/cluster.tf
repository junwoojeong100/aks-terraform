# ---------------------------------------------------------------------------
# AKS cluster (Standard mode: you design and operate the platform yourself)
#
# Compared with EKS
#   - Azure operates the control plane (same as EKS). sku_tier = Standard provides the uptime SLA.
#   - Nodes are "node pools" built on VMSS (Virtual Machine Scale Sets) (≈ EKS managed node group / ASG)
#   - Node VMs are created in a separate "node resource group" (rg-...-aks-nodes).
#     With EKS, the EC2 instances appear directly in your own account.
#   - Authentication uses Entra ID + Azure RBAC (≈ IAM + EKS access entries);
#     pod permissions use Workload Identity (≈ IRSA/Pod Identity)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  node_resource_group = module.naming.names.rg_aks_nodes
  dns_prefix          = module.naming.names.aks

  # --- Version / upgrades --------------------------------------------------------
  # kubernetes_version is used only at creation time (see lifecycle.ignore_changes below).
  # After that, AKS applies patches automatically.
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  support_plan              = "KubernetesOfficial"
  automatic_upgrade_channel = "patch"     # latest patch auto-applied in the maintenance window (minor: manual, Lab 09)
  node_os_upgrade_channel   = "NodeImage" # node OS image auto-replaced in the weekly maintenance window

  # --- Security: Entra ID auth + Azure RBAC, local accounts (static kubeconfig) disabled ---
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # --- Workload identity (equivalent to IRSA / EKS Pod Identity) -----------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- Governance / operations features ------------------------------------------
  azure_policy_enabled         = true # Azure Policy for Kubernetes (based on OPA Gatekeeper)
  image_cleaner_enabled        = true # automatically removes unused, vulnerable images
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free" # per-namespace/workload cost analysis (Standard tier or higher)

  # --- API server access ---------------------------------------------------------
  # API Server VNet Integration: projects the API server endpoint into a delegated subnet in your own VNet.
  # Like the EKS "public + private endpoint with restricted CIDRs" setup, authorized IP ranges limit public access.
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = data.azurerm_subnet.aks_apiserver.id
    authorized_ip_ranges                = var.enable_private_cluster ? null : var.allowed_ip_ranges
  }

  # --- Identity: use your own UAMI (roles already assigned in 04-platform) -------
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # --- Network: Azure CNI Overlay + Cilium, outbound through your own NAT Gateway ----
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # pods use a separate CIDR: almost no VNet IPs (the key difference from EKS VPC CNI)
    network_data_plane  = "cilium"  # eBPF data plane (replaces kube-proxy)
    network_policy      = "cilium"  # enforces NetworkPolicy

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway" # egress through the NAT Gateway attached to the subnet in 03-network
  }

  # --- Node pools: the System pool is dedicated to system components -------------
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    zones                        = var.zones
    vnet_subnet_id               = data.azurerm_subnet.aks_nodes.id
    orchestrator_version         = var.kubernetes_version
    os_sku                       = "AzureLinux3"
    os_disk_type                 = "Ephemeral" # OS on the node's local disk: fast, no disk charge
    os_disk_size_gb              = 64
    only_critical_addons_enabled = true # CriticalAddonsOnly taint → app pods go to the User pool
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count

    # Name of the temporary pool used for rotation when changing properties such as vm_size
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = local.tags
  }

  # Uses Cluster Autoscaler (same family as EKS cluster-autoscaler) → "Manual" mode: you manage the node pools.
  # To use Karpenter-based Node Auto Provisioning, set mode = "Auto" (the node pool autoscaler must then be off).
  # AKS Automatic uses NAP by default → see Lab 10.
  node_provisioning_profile {
    mode = "Manual"
  }

  auto_scaler_profile {
    balance_similar_node_groups   = true # balance node counts across pools in different availability zones
    expander                      = "least-waste"
    skip_nodes_with_local_storage = true # explicitly set to the AKS default (the block makes Terraform send false)
    skip_nodes_with_system_pods   = true
  }

  # --- Maintenance windows: control "when" upgrades happen (no EKS equivalent) ----
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Saturday"
    start_time  = "02:00"
    utc_offset  = var.maintenance_utc_offset
  }

  # --- Add-ons -------------------------------------------------------------------
  # Secrets Store CSI Driver + Azure Key Vault Provider (≈ AWS Secrets Manager CSI provider)
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Container Insights (logs): the ama-logs agent sends data to Log Analytics. The DCR is defined in monitoring.tf.
  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus (metrics): the DCR/DCE are defined in monitoring.tf.
  monitor_metrics {}

  # KEDA (event-driven autoscaling) + VPA (requests/limits recommendations)
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []

    content {
      log_analytics_workspace_id = var.defender_log_analytics_workspace_id
    }
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = !var.enable_defender || var.defender_log_analytics_workspace_id != null
      error_message = "If enable_defender = true, set defender_log_analytics_workspace_id to a workspace that allows local authentication. The platform workspace does not, and the Defender sensor cannot use it."
    }

    # Terraform sets the version only at creation time; after that, the AKS auto-upgrade channel manages it.
    # (Through azurerm 5.9, after an automatic patch upgrade the alias "1.36" no longer matches the actual version
    # "1.36.6", so every plan shows a diff. An improvement is planned for 5.10.)
    # For the minor upgrade procedure and how to manage the version directly with Terraform, see Lab 09.
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User node pool: for application workloads (equivalent to an EKS managed node group)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  os_disk_type         = "Ephemeral"
  os_disk_size_gb      = 64
  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  temporary_name_for_rotation = "usertmp"

  node_labels = {
    "workload-type" = "general"
  }

  upgrade_settings {
    max_surge                     = "33%"
    drain_timeout_in_minutes      = 30
    node_soak_duration_in_minutes = 0
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version] # same reason as the cluster (auto-upgrade manages the version)
  }
}

# ---------------------------------------------------------------------------
# (Optional) Spot node pool: for interruptible batch/CI workloads (equivalent to EC2 Spot)
# Scales down to 0 nodes, and pods are scheduled only if they have a toleration.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # capped at the on-demand price

  vm_size              = var.user_node_vm_size
  zones                = var.zones
  vnet_subnet_id       = data.azurerm_subnet.aks_nodes.id
  orchestrator_version = var.kubernetes_version
  os_sku               = "AzureLinux3"
  auto_scaling_enabled = true
  min_count            = 0
  max_count            = 5

  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }

  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule",
  ]

  tags = local.tags

  lifecycle {
    ignore_changes = [orchestrator_version]
  }
}
