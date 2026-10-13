# ---------------------------------------------------------------------------
# 관측성 연결: AKS ↔ Managed Prometheus / Container Insights
#
# AWS(CloudWatch Container Insights, AMP) 에서는 "에이전트 + 워크스페이스 + IAM" 을 직접 연결하지만,
# Azure 는 Data Collection Rule(DCR) 이 "무엇을 어디로 보낼지" 를 정의하고,
# Data Collection Rule Association(DCRA) 이 DCR 을 AKS 클러스터에 연결합니다.
# ---------------------------------------------------------------------------

# --- Managed Prometheus ----------------------------------------------------------
resource "azurerm_monitor_data_collection_endpoint" "prometheus" {
  name                = module.naming.names.dce_prometheus
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "prometheus" {
  name                        = module.naming.names.dcr_prometheus
  location                    = azurerm_resource_group.aks.location
  resource_group_name         = azurerm_resource_group.aks.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.prometheus.id
  kind                        = "Linux"
  description                 = "Managed Prometheus: AKS 메트릭을 Azure Monitor workspace 로 전송"

  destinations {
    monitor_account {
      monitor_account_id = data.azurerm_monitor_workspace.this.id
      name               = "MonitoringAccount1"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["MonitoringAccount1"]
  }

  data_sources {
    prometheus_forwarder {
      name    = "PrometheusDataSource"
      streams = ["Microsoft-PrometheusMetrics"]
    }
  }

  tags = local.tags
}

resource "azurerm_monitor_data_collection_rule_association" "prometheus" {
  name                    = "dcra-${module.naming.names.aks}-prometheus"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.prometheus.id
  description             = "삭제하면 이 AKS 클러스터의 Prometheus 메트릭 수집이 중단됩니다."
}

# azurerm 의 monitor_metrics 블록은 컨트롤 플레인 메트릭(apiserver, etcd 등)을 노출하지 않으므로 AzAPI 로 켭니다.
# DCRA 가 먼저 만들어진 뒤에 켜야 수집 파드가 CrashLoop 하지 않습니다.
resource "azapi_update_resource" "control_plane_metrics" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      azureMonitorProfile = {
        metrics = {
          enabled = true # monitor_metrics 블록으로 이미 켜져 있는 값. API 스키마상 필수라 함께 보냅니다.
          controlPlane = {
            enabled = true
          }
        }
      }
    }
  }

  # 같은 클러스터에 대한 PUT 이 노드 풀 생성/변경과 겹치면 409 AnotherOperationInProgress 로 실패하므로 노드 풀 뒤에 실행합니다.
  depends_on = [
    azurerm_monitor_data_collection_rule_association.prometheus,
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_kubernetes_cluster_node_pool.spot,
  ]
}

# --- Container Insights (로그) -----------------------------------------------------
locals {
  # 비용 최적화 구성: 성능 지표(Perf, InsightsMetrics)는 Prometheus 가 담당하므로 로그/인벤토리 스트림만 수집합니다.
  container_insights_streams = [
    "Microsoft-ContainerLogV2",
    "Microsoft-KubeEvents",
    "Microsoft-KubePodInventory",
    "Microsoft-KubeNodeInventory",
    "Microsoft-KubeServices",
    "Microsoft-KubePVInventory",
  ]
}

resource "azurerm_monitor_data_collection_rule" "container_insights" {
  name                = module.naming.names.dcr_container_insights
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  kind                = "Linux"
  description         = "Container Insights: 컨테이너 로그/쿠버네티스 인벤토리를 Log Analytics 로 전송"

  destinations {
    log_analytics {
      name                  = "ciworkspace"
      workspace_resource_id = data.azurerm_log_analytics_workspace.this.id
    }
  }

  data_flow {
    streams      = local.container_insights_streams
    destinations = ["ciworkspace"]
  }

  data_sources {
    extension {
      name           = "ContainerInsightsExtension"
      extension_name = "ContainerInsights"
      streams        = local.container_insights_streams

      extension_json = jsonencode({
        dataCollectionSettings = {
          interval               = "1m"
          namespaceFilteringMode = "Exclude"
          namespaces             = ["kube-system", "gatekeeper-system", "azure-arc"]
          enableContainerLogV2   = true
        }
      })
    }
  }

  tags = local.tags
}

# Container Insights 는 연결 이름이 반드시 "ContainerInsightsExtension" 이어야 합니다.
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "삭제하면 이 AKS 클러스터의 Container Insights 로그 수집이 중단됩니다."
}

# --- 컨트롤 플레인 로그 (EKS 의 control plane logging → CloudWatch Logs 에 해당) ---------------
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # AKSAudit/AKSControlPlane 등 리소스 전용 테이블 사용

  dynamic "enabled_log" {
    for_each = toset([
      "kube-audit-admin", # 변경(쓰기) 작업 감사 로그만 수집: kube-audit 보다 훨씬 저렴
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard", # Entra ID 인증/인가 로그
    ])

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
