# ---------------------------------------------------------------------------
# Observability wiring: AKS ↔ Managed Prometheus / Container Insights
#
# On AWS (CloudWatch Container Insights, AMP) you wire up "agent + workspace + IAM" yourself,
# whereas on Azure a Data Collection Rule (DCR) defines "what to send where",
# and a Data Collection Rule Association (DCRA) attaches the DCR to the AKS cluster.
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
  description                 = "Managed Prometheus: sends AKS metrics to the Azure Monitor workspace"

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
  description             = "Deleting this stops Prometheus metric collection for this AKS cluster."
}

# The azurerm monitor_metrics block doesn't expose control plane metrics (apiserver, etcd, etc.), so enable them via AzAPI.
# Enable them only after the DCRA has been created, so the collector pods don't go into CrashLoop.
resource "azapi_update_resource" "control_plane_metrics" {
  type        = "Microsoft.ContainerService/managedClusters@2026-05-01"
  resource_id = azurerm_kubernetes_cluster.this.id

  body = {
    properties = {
      azureMonitorProfile = {
        metrics = {
          enabled = true # already on via the monitor_metrics block; the API schema requires it, so it is sent too
          controlPlane = {
            enabled = true
          }
        }
      }
    }
  }

  # A PUT on the same cluster that overlaps with node pool creation/changes fails with 409 AnotherOperationInProgress,
  # so this runs after the node pools.
  depends_on = [
    azurerm_monitor_data_collection_rule_association.prometheus,
    azurerm_kubernetes_cluster_node_pool.user,
    azurerm_kubernetes_cluster_node_pool.spot,
  ]
}

# --- Container Insights (logs) ---------------------------------------------------
locals {
  # Cost-optimized setup: Prometheus handles the performance metrics (Perf, InsightsMetrics),
  # so only the log and inventory streams are collected.
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
  description         = "Container Insights: sends container logs and Kubernetes inventory to Log Analytics"

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

# Container Insights requires the association name to be exactly "ContainerInsightsExtension".
resource "azurerm_monitor_data_collection_rule_association" "container_insights" {
  name                    = "ContainerInsightsExtension"
  target_resource_id      = azurerm_kubernetes_cluster.this.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.container_insights.id
  description             = "Deleting this stops Container Insights log collection for this AKS cluster."
}

# --- Control plane logs (equivalent to EKS control plane logging → CloudWatch Logs) ----
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "diag-to-log-analytics"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # use resource-specific tables such as AKSAudit/AKSControlPlane

  dynamic "enabled_log" {
    for_each = toset([
      "kube-audit-admin", # collects audit logs for change (write) operations only: much cheaper than kube-audit
      "kube-apiserver",
      "kube-controller-manager",
      "kube-scheduler",
      "cluster-autoscaler",
      "guard", # Entra ID authentication/authorization logs
    ])

    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
