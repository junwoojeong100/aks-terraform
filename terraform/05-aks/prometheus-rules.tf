# ---------------------------------------------------------------------------
# Prometheus Recording Rules
#
# Azure Managed Grafana 의 기본 쿠버네티스 대시보드("Kubernetes / Compute Resources / ...")는
# 아래 recording rule 이 미리 계산해 둔 시계열을 사용합니다.
# 포털/CLI 로 Managed Prometheus 를 켜면 자동으로 만들어지지만, Terraform 으로 구성할 때는 직접 정의해야 합니다.
# (출처: Azure/prometheus-collector 저장소의 AddonTerraformTemplate – Linux 용 Node / Kubernetes 규칙 그룹)
# 규칙은 길기 때문에 이 파일은 "그대로 복사해서 사용" 하면 됩니다.
# ---------------------------------------------------------------------------
resource "azurerm_monitor_alert_prometheus_rule_group" "node_recording_rules" {
  name                = "NodeRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Node Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "instance:node_num_cpu:sum"
    expression = <<-EOT
      count without (cpu, mode) (  node_cpu_seconds_total{job="node",mode="idle"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_cpu_utilisation:rate5m"
    expression = <<-EOT
      1 - avg without (cpu) (  sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_load1_per_cpu:ratio"
    expression = <<-EOT
      (  node_load1{job="node"}/  instance:node_num_cpu:sum{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_memory_utilisation:ratio"
    expression = <<-EOT
      1 - (  (    node_memory_MemAvailable_bytes{job="node"}    or    (      node_memory_Buffers_bytes{job="node"}      +      node_memory_Cached_bytes{job="node"}      +      node_memory_MemFree_bytes{job="node"}      +      node_memory_Slab_bytes{job="node"}    )  )/  node_memory_MemTotal_bytes{job="node"})
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_vmstat_pgmajfault:rate5m"
    expression = <<-EOT
      rate(node_vmstat_pgmajfault{job="node"}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance_device:node_disk_io_time_weighted_seconds:rate5m"
    expression = <<-EOT
      rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[5m])
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_bytes_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_receive_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_receive_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }

  rule {
    enabled    = true
    record     = "instance:node_network_transmit_drop_excluding_lo:rate5m"
    expression = <<-EOT
      sum without (device) (  rate(node_network_transmit_drop_total{job="node", device!="lo"}[5m]))
    EOT
  }
}

resource "azurerm_monitor_alert_prometheus_rule_group" "kubernetes_recording_rules" {
  name                = "KubernetesRecordingRulesRuleGroup-${module.naming.names.aks}"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  cluster_name        = module.naming.names.aks
  description         = "Kubernetes Recording Rules Rule Group"
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [data.azurerm_monitor_workspace.this.id, azurerm_kubernetes_cluster.this.id]
  tags                = local.tags

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate"
    expression = <<-EOT
      sum by (cluster, namespace, pod, container) (  irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (  1, max by(cluster, namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_working_set_bytes"
    expression = <<-EOT
      container_memory_working_set_bytes{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_rss"
    expression = <<-EOT
      container_memory_rss{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_cache"
    expression = <<-EOT
      container_memory_cache{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "node_namespace_pod_container:container_memory_swap"
    expression = <<-EOT
      container_memory_swap{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by(namespace, pod) (1,  max by(namespace, pod, node) (kube_pod_info{node!=""}))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests"
    expression = <<-EOT
      kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_requests:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_memory:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_memory:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="memory",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:namespace:pod_cpu:active:kube_pod_container_resource_limits"
    expression = <<-EOT
      kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) ( (kube_pod_status_phase{phase=~"Pending|Running"} == 1) )
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_cpu:kube_pod_container_resource_limits:sum"
    expression = <<-EOT
      sum by (namespace, cluster) (    sum by (namespace, pod, cluster) (        max by (namespace, pod, container, cluster) (          kube_pod_container_resource_limits{resource="cpu",job="kube-state-metrics"}        ) * on(namespace, pod, cluster) group_left() max by (namespace, pod, cluster) (          kube_pod_status_phase{phase=~"Pending|Running"} == 1        )    ))
    EOT
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    label_replace(      kube_pod_owner{job="kube-state-metrics", owner_kind="ReplicaSet"},      "replicaset", "$1", "owner_name", "(.*)"    ) * on(replicaset, namespace) group_left(owner_name) topk by(replicaset, namespace) (      1, max by (replicaset, namespace, owner_name) (        kube_replicaset_owner{job="kube-state-metrics"}      )    ),    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "deployment"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="DaemonSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "daemonset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="StatefulSet"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "statefulset"
    }
  }

  rule {
    enabled    = true
    record     = "namespace_workload_pod:kube_pod_owner:relabel"
    expression = <<-EOT
      max by (cluster, namespace, workload, pod) (  label_replace(    kube_pod_owner{job="kube-state-metrics", owner_kind="Job"},    "workload", "$1", "owner_name", "(.*)"  ))
    EOT
    labels = {
      workload_type = "job"
    }
  }

  rule {
    enabled    = true
    record     = ":node_memory_MemAvailable_bytes:sum"
    expression = <<-EOT
      sum(  node_memory_MemAvailable_bytes{job="node"} or  (    node_memory_Buffers_bytes{job="node"} +    node_memory_Cached_bytes{job="node"} +    node_memory_MemFree_bytes{job="node"} +    node_memory_Slab_bytes{job="node"}  )) by (cluster)
    EOT
  }

  rule {
    enabled    = true
    record     = "cluster:node_cpu:ratio_rate5m"
    expression = <<-EOT
      sum(rate(node_cpu_seconds_total{job="node",mode!="idle",mode!="iowait",mode!="steal"}[5m])) by (cluster) /count(sum(node_cpu_seconds_total{job="node"}) by (cluster, instance, cpu)) by (cluster)
    EOT
  }
}
