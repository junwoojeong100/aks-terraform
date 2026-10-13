# ---------------------------------------------------------------------------
# AKS 클러스터 (Standard 모드: 플랫폼을 직접 설계/운영)
#
# EKS 와 비교
#   - 컨트롤 플레인은 Azure 가 운영 (EKS 와 동일). sku_tier = Standard 가 업타임 SLA 를 제공합니다.
#   - 노드는 VMSS(Virtual Machine Scale Set) 기반 "node pool" (≈ EKS managed node group / ASG)
#   - 노드 VM 은 별도의 "노드 리소스 그룹"(rg-...-aks-nodes)에 생성됩니다. EKS 는 내 계정에 EC2 가 그대로 보입니다.
#   - 인증은 Entra ID + Azure RBAC (≈ IAM + EKS access entries), 파드 권한은 Workload Identity (≈ IRSA/Pod Identity)
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster" "this" {
  name                = module.naming.names.aks
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  node_resource_group = module.naming.names.rg_aks_nodes
  dns_prefix          = module.naming.names.aks

  # --- 버전 / 업그레이드 -----------------------------------------------------
  # kubernetes_version 은 생성 시점에만 사용됩니다(아래 lifecycle.ignore_changes). 이후 patch 는 AKS 가 자동 적용합니다.
  kubernetes_version        = var.kubernetes_version
  sku_tier                  = var.sku_tier
  support_plan              = "KubernetesOfficial"
  automatic_upgrade_channel = "patch"     # 같은 minor 안에서 최신 patch 를 유지보수 창에 자동 적용 (minor 는 Lab 09 절차로 직접 올림)
  node_os_upgrade_channel   = "NodeImage" # 노드 OS 이미지는 주간 유지보수 창에서 자동 교체

  # --- 보안: Entra ID 인증 + Azure RBAC, 로컬 계정(정적 kubeconfig) 차단 ----------
  role_based_access_control_enabled = true
  local_account_disabled            = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # --- 워크로드 ID (IRSA / EKS Pod Identity 에 해당) -----------------------------
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # --- 거버넌스 / 운영 기능 -------------------------------------------------------
  azure_policy_enabled         = true # Azure Policy for Kubernetes (OPA Gatekeeper 기반)
  image_cleaner_enabled        = true # 취약한 미사용 이미지 자동 삭제
  image_cleaner_interval_hours = 48
  cost_analysis_enabled        = var.sku_tier != "Free" # 네임스페이스/워크로드별 비용 분석 (Standard 이상)

  # --- API 서버 접근 -------------------------------------------------------------
  # API Server VNet Integration: API 서버 엔드포인트를 위임된 서브넷(내 VNet)에 투영합니다.
  # EKS 의 "Public + Private endpoint, CIDR 제한" 구성과 비슷하게 authorized IP ranges 로 공용 접근을 제한합니다.
  private_cluster_enabled             = var.enable_private_cluster
  private_cluster_public_fqdn_enabled = false

  api_server_access_profile {
    virtual_network_integration_enabled = true
    subnet_id                           = data.azurerm_subnet.aks_apiserver.id
    authorized_ip_ranges                = var.enable_private_cluster ? null : var.allowed_ip_ranges
  }

  # --- Identity: 직접 만든 UAMI 사용 (04-platform 에서 역할 할당까지 끝낸 상태) -------------
  identity {
    type         = "UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.cluster.id]
  }

  kubelet_identity {
    client_id                 = data.azurerm_user_assigned_identity.kubelet.client_id
    object_id                 = data.azurerm_user_assigned_identity.kubelet.principal_id
    user_assigned_identity_id = data.azurerm_user_assigned_identity.kubelet.id
  }

  # --- 네트워크: Azure CNI Overlay + Cilium, 아웃바운드는 내 NAT Gateway ----------------
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay" # Pod 는 별도 CIDR 사용 → VNet IP 를 거의 소모하지 않음 (EKS VPC CNI 와의 가장 큰 차이)
    network_data_plane  = "cilium"  # eBPF 데이터 플레인 (kube-proxy 대체)
    network_policy      = "cilium"  # NetworkPolicy 강제

    pod_cidr       = var.pod_cidr
    service_cidr   = var.service_cidr
    dns_service_ip = var.dns_service_ip

    load_balancer_sku = "standard"
    outbound_type     = "userAssignedNATGateway" # 03-network 에서 서브넷에 연결해 둔 NAT Gateway 로 egress
  }

  # --- 노드 풀: System 풀은 시스템 컴포넌트 전용 ------------------------------------
  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    zones                        = var.zones
    vnet_subnet_id               = data.azurerm_subnet.aks_nodes.id
    orchestrator_version         = var.kubernetes_version
    os_sku                       = "AzureLinux3"
    os_disk_type                 = "Ephemeral" # 노드 로컬 디스크에 OS 배치: 빠르고 디스크 요금 없음
    os_disk_size_gb              = 64
    only_critical_addons_enabled = true # CriticalAddonsOnly 테인트 → 앱 파드는 User 풀로
    auto_scaling_enabled         = true
    min_count                    = var.system_node_min_count
    max_count                    = var.system_node_max_count

    # vm_size 등 일부 속성을 바꿀 때 임시 풀로 교체(rotation)하기 위한 이름
    temporary_name_for_rotation = "systemtmp"

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }

    tags = local.tags
  }

  # Cluster Autoscaler(EKS 의 cluster-autoscaler 와 동일 계열) 사용 → 노드 풀을 직접 관리하는 "Manual" 모드.
  # Karpenter 기반 Node Auto Provisioning 을 쓰려면 mode = "Auto" (단, 노드 풀 autoscaler 는 꺼야 함).
  # AKS Automatic 은 NAP 가 기본값입니다 → Lab 10 참고.
  node_provisioning_profile {
    mode = "Manual"
  }

  auto_scaler_profile {
    balance_similar_node_groups   = true # 여러 가용 영역 풀의 노드 수를 균형 있게
    expander                      = "least-waste"
    skip_nodes_with_local_storage = true # AKS 기본값과 동일하게 명시 (블록을 쓰면 Terraform 이 false 를 보내므로)
    skip_nodes_with_system_pods   = true
  }

  # --- 유지보수 창: 업그레이드가 "언제" 일어날지 통제 (EKS 에는 없는 기능) -----------------
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

  # --- 애드온 ---------------------------------------------------------------------
  # Secrets Store CSI Driver + Azure Key Vault Provider (≈ AWS Secrets Manager CSI provider)
  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  # Container Insights (로그): ama-logs 에이전트가 Log Analytics 로 전송. DCR 은 monitoring.tf 에서 정의.
  oms_agent {
    log_analytics_workspace_id      = data.azurerm_log_analytics_workspace.this.id
    msi_auth_for_monitoring_enabled = true
  }

  # Managed Prometheus (메트릭): DCR/DCE 는 monitoring.tf 에서 정의.
  monitor_metrics {}

  # KEDA(이벤트 기반 오토스케일) + VPA(요청/제한 권장)
  workload_autoscaler_profile {
    keda_enabled                    = true
    vertical_pod_autoscaler_enabled = true
  }

  dynamic "microsoft_defender" {
    for_each = var.enable_defender ? [1] : []

    content {
      log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  tags = local.tags

  lifecycle {
    # 버전은 생성 시점에만 Terraform 이 정하고, 이후에는 AKS 자동 업그레이드 채널이 관리합니다.
    # (azurerm 5.9 까지는 patch 자동 업그레이드 뒤 alias "1.36" 과 실제 버전 "1.36.6" 이 달라 매 plan 마다 diff 가 생깁니다. 5.10 에서 개선 예정)
    # minor 업그레이드 절차와 Terraform 으로 버전을 직접 관리하는 방법은 Lab 09 를 참고하세요.
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

# ---------------------------------------------------------------------------
# User 노드 풀: 애플리케이션 워크로드용 (EKS managed node group 에 해당)
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
    ignore_changes = [orchestrator_version] # 클러스터와 동일한 이유 (자동 업그레이드가 버전을 관리)
  }
}

# ---------------------------------------------------------------------------
# (선택) Spot 노드 풀: 중단 가능한 배치/CI 워크로드용 (EC2 Spot 에 해당)
# 0 노드까지 축소되며, 파드는 toleration 이 있어야 스케줄됩니다.
# ---------------------------------------------------------------------------
resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  count = var.enable_spot_pool ? 1 : 0

  name                  = "spot"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  mode                  = "User"

  priority        = "Spot"
  eviction_policy = "Delete"
  spot_max_price  = -1 # 온디맨드 가격 상한

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
