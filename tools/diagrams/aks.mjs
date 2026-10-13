// Network · cluster · observability diagrams
import { Diagram, t } from './lib.mjs';

// ---------------------------------------------------------------------------
// Figure: VNet design (Lab 03)
// ---------------------------------------------------------------------------
function networkTopology() {
  const title = t('VNet design: subnets · NSGs · NAT Gateway · Private DNS', 'VNet 설계: 서브넷 · NSG · NAT Gateway · Private DNS');
  const d = new Diagram('network-topology', 960, 550, {
    title,
    desc: t(
      'The 10.10.0.0/16 VNet contains node, API server, ingress and private endpoint subnets. The node subnet reaches the internet through a NAT Gateway, and the private endpoints, together with Private DNS zones, give private access to ACR and Key Vault.',
      '10.10.0.0/16 VNet 안에 노드, API 서버, Ingress, Private Endpoint 서브넷이 있고, 노드 서브넷은 NAT Gateway 로 인터넷에 나가며, Private Endpoint 는 Private DNS Zone 과 함께 ACR·Key Vault 에 사설로 접근한다.',
    ),
  });
  d.heading(
    title,
    t(
      'Subnets span the whole region (not tied to an AZ) and are split by role. Every later stack looks up this VNet as a data source.',
      '서브넷은 리전 전체에 걸치며(AZ 에 묶이지 않음) 역할별로 나눕니다. 이후 모든 스택이 이 VNet 을 data source 로 조회합니다.',
    ),
  );

  d.group(24, 92, 640, 438, {
    tone: 'net',
    label: t('VNet vnet-aksdemo-dev-krc · 10.10.0.0/16 · spans the whole koreacentral region', 'VNet vnet-aksdemo-dev-krc · 10.10.0.0/16 · koreacentral 리전 전체'),
  });
  // Top row: API server (left) / nodes (right)
  d.box(44, 124, 290, 134, {
    tone: 'net', title: 'snet-aks-apiserver', pad: 12, size: 11.5,
    lines: [
      t('10.10.1.0/28 (dedicated to AKS, min /28)', '10.10.1.0/28 (AKS 전용, 최소 /28)'),
      t('Hosts the projected API server endpoint', 'API 서버 엔드포인트가 이 서브넷에 투영'),
      t('Delegation: managedClusters', '위임(delegation): managedClusters'),
      t('No NSG attached (delegated subnet)', 'NSG 연결 없음 (위임 서브넷)'),
    ],
  });
  const nodes = d.box(354, 124, 290, 134, {
    tone: 'azure', title: 'snet-aks-nodes', pad: 12, size: 11.5,
    lines: t(
      ['10.10.0.0/24 · node IPs only', 'Pods use the overlay (10.244.0.0/16)', 'NSG: allows inbound from pods,', 'the API server and the Gateway', 'NAT Gateway attached, no default outbound'],
      ['10.10.0.0/24 · 노드 IP 전용', 'Pod 는 오버레이(10.244.0.0/16)라 IP 미사용', 'NSG: Pod · API 서버 · Gateway 인바운드 허용', 'NAT Gateway 연결 · 기본 아웃바운드 비활성화'],
    ),
  });
  // Bottom row: Ingress (left) / Private Endpoint (right)
  d.box(44, 270, 290, 124, {
    tone: 'net', title: 'snet-ingress', pad: 12, size: 11.5,
    lines: t(
      ['10.10.2.0/27', 'Internal load balancer frontend IP', '(when internal_gateway = true)', 'NSG attached (traffic is evaluated', 'by the node NSG)'],
      ['10.10.2.0/27', '내부 로드밸런서 프런트엔드 IP', '(internal_gateway = true 일 때)', 'NSG 연결 (트래픽은 노드 NSG 가 평가)'],
    ),
  });
  const pe = d.box(354, 270, 290, 124, {
    tone: 'net', title: 'snet-private-endpoints', pad: 12, size: 11.5,
    lines: [
      '10.10.3.0/27',
      t('Private endpoints for ACR · Key Vault', 'ACR · Key Vault 의 Private Endpoint'),
      t('NSG: allows only 443 from the node subnet,', 'NSG: 노드 서브넷의 443 만 허용,'),
      t('denies other inbound within the VNet', '나머지 VNet 내부 인바운드는 거부'),
    ],
  });
  d.box(44, 408, 600, 108, {
    tone: 'neutral', dashed: true, title: t('Good to know', '알아 둘 점'), pad: 12, size: 12,
    lines: [
      t(
        'Subnets span all AZs (unlike AWS); zones belong to node pools and load balancers.',
        '서브넷은 가용 영역(AZ)에 묶이지 않습니다. 영역은 노드 풀·로드밸런서의 속성입니다 (AWS 와 다름).',
      ),
      t('A NAT Gateway attaches directly to the subnet; no route table changes are needed.', 'NAT Gateway 는 서브넷에 직접 연결합니다. 라우트 테이블 수정이 필요 없습니다.'),
      t('Choose a VNet address space that does not overlap with on-premises or peered networks.', 'VNet 주소 공간은 온프레미스·피어링 대상과 겹치지 않게 정하세요.'),
    ],
  });

  // Right: NAT, internet, PaaS, Private DNS (English needs a taller PaaS box, so the first three boxes shift up by 8)
  const nat = d.box(690, t(124, 132), 246, 84, {
    tone: 'net', title: 'NAT Gateway (StandardV2)', pad: 12, titleSize: 13, size: 11.5,
    lines: [t('Zone-redundant · static public IP', '영역 중복 · 고정 공용 IP'), t('Directly attached to node subnet', '노드 서브넷에 직접 연결')],
  });
  const net = d.box(690, t(224, 232), 246, 44, { title: t('Internet (static egress IP)', '인터넷 (고정 egress IP)'), align: 'center', pad: 12, titleSize: 13 });
  const paas = d.box(690, t(284, 292), 246, t(96, 80), {
    tone: 'ok', title: 'ACR · Key Vault (PaaS)', pad: 12, titleSize: 13, size: 11.5,
    lines: t(
      ['Public access: admin IPs only', '(default Deny)', 'Nodes/pods use private endpoints'],
      ['공용 접근은 관리자 IP 만(기본 Deny)', '노드·파드는 Private Endpoint 로'],
    ),
  });
  const dns = d.box(690, 392, 246, 104, {
    tone: 'id', title: t('Private DNS zones ×2', 'Private DNS Zone ×2'), pad: 12, titleSize: 13, size: 11.5,
    lines: ['privatelink.azurecr.io', 'privatelink.vaultcore.azure.net', t('VNet link resolves to private IPs', 'VNet 링크로 사설 IP 로 해석')],
  });

  d.arrow([[nodes.r, nodes.cy], [667, nodes.cy], [667, nat.cy], [nat.l, nat.cy]], { tone: 'net' });
  d.arrow([[nat.cx, nat.b], [nat.cx, net.t]], { tone: 'net' });
  d.arrow([[pe.r, pe.cy], [paas.l, paas.cy]], { tone: 'ok' });
  d.arrow([[dns.l, dns.cy], [664, dns.cy]], { tone: 'id' });
  void paas;
  return d;
}

// ---------------------------------------------------------------------------
// Figure: AKS cluster layout (Lab 05)
// ---------------------------------------------------------------------------
function aksCluster() {
  const title = t('AKS cluster layout (Standard)', 'AKS 클러스터 구성 (Standard)');
  const d = new Diagram('aks-cluster', 960, 690, {
    title,
    desc: t(
      'The control plane, operated by Azure, talks through the API Server VNet Integration subnet to the system, user and spot node pools that span three availability zones in the node resource group of your subscription. Microsoft Entra ID and the OIDC issuer handle authentication and Workload Identity, and add-ons run in kube-system.',
      'Azure 가 운영하는 컨트롤 플레인이 API Server VNet Integration 서브넷을 통해 내 구독의 노드 리소스 그룹 안 3개 가용 영역에 걸친 system·user·spot 노드 풀과 통신하고, Entra ID 와 OIDC issuer 가 인증·Workload Identity 를 담당하며, 애드온이 kube-system 에서 실행된다.',
    ),
  });
  d.heading(
    title,
    t(
      'Azure runs the control plane (as with EKS); nodes are VMSS in a separate "node resource group" in your subscription.',
      '컨트롤 플레인은 Azure 가 운영하고(EKS 와 같음), 노드는 내 구독의 별도 "노드 리소스 그룹"에 VMSS 로 만들어집니다.',
    ),
  );

  // Top row: control plane + identity
  d.group(24, 92, 452, 128, { tone: 'ok', label: t('Control plane · run by Azure, outside your subscription', 'Azure 가 운영 · 내 구독 밖 (컨트롤 플레인)') });
  const cp = [t('API server', 'API 서버'), 'etcd', 'scheduler', 'controller'];
  cp.forEach((name, i) => d.box(36 + i * 108, 124, 100, 44, { tone: 'ok', title: name, align: 'center', pad: 8, titleSize: 12.5 }));
  d.text(40, 196, t('Standard tier: uptime SLA (99.95% when using zones)', 'Standard 티어: 업타임 SLA (영역 사용 시 99.95%)'), { size: 11.5, muted: true, maxW: 420 });

  d.group(488, 92, 448, 128, { tone: 'id', label: t('Identity · access', 'ID · 접근') });
  d.box(500, 124, 212, 84, {
    tone: 'id', title: 'Entra ID + Azure RBAC', pad: 10, titleSize: 12.5, size: 11,
    lines: t(
      ['kubectl uses the az login token', 'Local accounts disabled', '(no static kubeconfig)'],
      ['kubectl 은 az 로그인 토큰', '로컬 계정(정적 kubeconfig) 끔'],
    ),
  });
  d.box(722, 124, 202, 84, {
    tone: 'id', title: 'OIDC issuer', pad: 10, titleSize: 12.5, size: 11,
    lines: [t('Trust anchor for', 'Workload Identity 의'), t('Workload Identity (Lab 06)', '신뢰 대상 (Lab 06)')],
  });

  // Middle: API Server VNet Integration
  const bar = d.box(24, 236, 912, 40, {
    tone: 'net', align: 'center', pad: 10, titleSize: 12.5,
    title: t(
      'API Server VNet Integration: API server projected into snet-aks-apiserver (10.10.1.0/28, delegated) · authorized IPs only',
      'API Server VNet Integration: API 서버가 snet-aks-apiserver(10.10.1.0/28, 위임)에 투영됩니다 · 접근은 authorized IP 로 제한',
    ),
  });
  d.arrow([[250, 220], [250, bar.t]], { tone: 'net' });
  d.arrow([[250, bar.b], [250, 296]], { tone: 'net' });

  // Node resource group
  d.group(24, 296, 912, 252, {
    tone: 'azure', dashed: true,
    label: t(
      'Your subscription · node resource group rg-…-aks-nodes (managed by AKS · do not modify) · snet-aks-nodes 10.10.0.0/24',
      '내 구독 · 노드 리소스 그룹 rg-…-aks-nodes (AKS 가 관리 · 직접 수정 금지) · snet-aks-nodes 10.10.0.0/24',
    ),
  });
  const zx = [36, 336, 636];
  [t('Zone 1', '영역 1'), t('Zone 2', '영역 2'), t('Zone 3', '영역 3')].forEach((z, i) => {
    d.group(zx[i], 326, 288, 150, { label: z, labelSize: 12 });
    d.box(zx[i] + 10, 352, 268, 52, {
      tone: 'azure', title: t('system node', 'system 노드'), pad: 8, titleSize: 13, size: 11,
      lines: [t('D4ds_v5 · CriticalAddonsOnly taint', 'D4ds_v5 · CriticalAddonsOnly 테인트')],
    });
    d.box(zx[i] + 10, 412, 268, 52, {
      tone: 'azure', title: t('user node', 'user 노드'), pad: 8, titleSize: 13, size: 11,
      lines: [t('D4ds_v5 · app workloads', 'D4ds_v5 · 앱 워크로드')],
    });
  });
  d.text(
    40, 498,
    t(
      'system pool 3–5 · user pool 3–6 · both use the Cluster Autoscaler (node count is not fixed in code) · AzureLinux3 + ephemeral OS disk',
      'system 풀 3–5 · user 풀 3–6 · 둘 다 Cluster Autoscaler(노드 수는 코드에 고정하지 않음) · AzureLinux3 + 임시(Ephemeral) OS 디스크',
    ),
    { size: 11.5, muted: true, maxW: 880 },
  );
  d.text(
    40, 520,
    t(
      'Optional: spot pool (0–5, equivalent to EC2 Spot) · Network: Azure CNI Overlay + Cilium · Pod CIDR 10.244.0.0/16 · outbound via NAT Gateway',
      '선택: spot 풀(0–5, EC2 Spot 에 해당) · 네트워크: Azure CNI Overlay + Cilium · Pod CIDR 10.244.0.0/16 · 아웃바운드는 NAT Gateway',
    ),
    { size: 11.5, muted: true, maxW: 880 },
  );

  // Add-ons
  d.group(24, 562, 912, 112, { label: t('Add-ons (kube-system etc.)', '애드온 (kube-system 등)'), labelSize: 12 });
  const addons = [
    ['Cilium (CNI · NetworkPolicy)', 'azure'], ['CoreDNS', 'azure'], ['Key Vault CSI', 'id'], ['Azure Policy (Gatekeeper)', 'warn'],
    ['KEDA', 'ok'], ['VPA', 'ok'], ['ama-logs', 'net'], ['ama-metrics', 'net'], ['Image Cleaner', 'ok'], ['Gateway API (approuting-istio)', 'azure'],
  ];
  let px = 40;
  let py = 592;
  for (const [label, tone] of addons) {
    const w = Math.round(label.length * 6.4 + (/[\uac00-\ud7a3]/.test(label) ? 10 : 0) + 26);
    if (px + w > 920) {
      px = 40;
      py += 32;
    }
    const p = d.pill(px, py, label, { tone, size: 11.5, h: 24 });
    px += p.w + 8;
  }
  return d;
}

// ---------------------------------------------------------------------------
// Figure: observability pipeline (Lab 05)
// ---------------------------------------------------------------------------
function observability() {
  const title = t('Observability pipeline: logs · metrics · control plane logs', '관측성 파이프라인: 로그 · 메트릭 · 컨트롤 플레인 로그');
  const d = new Diagram('observability-pipeline', 960, 520, {
    title,
    desc: t(
      'ama-logs sends container logs through a DCR to Log Analytics; ama-metrics sends metrics through a DCE and DCR to the Azure Monitor workspace (Managed Prometheus); control plane diagnostic logs reach Log Analytics through a diagnostic setting; and Managed Grafana reads from Prometheus.',
      'ama-logs 는 DCR 을 거쳐 Log Analytics 로, ama-metrics 는 DCE/DCR 을 거쳐 Azure Monitor workspace(Managed Prometheus)로, 컨트롤 플레인 진단 로그는 진단 설정을 거쳐 Log Analytics 로 가며, Managed Grafana 가 Prometheus 를 읽는다.',
    ),
  });
  d.heading(
    title,
    t(
      'Everything is unified in Azure Monitor. A DCR (Data Collection Rule) and a DCRA (association) declare what to collect (Lab 05).',
      'Azure Monitor 하나로 통합됩니다. 수집 구성은 DCR(Data Collection Rule)과 DCRA(연결)로 선언합니다 (Lab 05).',
    ),
  );

  // Column headers
  d.text(24, 96, t('Sources (AKS)', '수집 대상 (AKS)'), { size: 12.5, bold: true, muted: true });
  d.text(344, 96, t('Collection (declared in Terraform)', '수집 구성 (Terraform 으로 선언)'), { size: 12.5, bold: true, muted: true });
  d.text(676, 96, t('Storage · visualization', '저장 · 시각화'), { size: 12.5, bold: true, muted: true });

  const row = (y, tone, src, cfg) => {
    const a = d.box(24, y, 280, 96, { tone: 'neutral', title: src[0], lines: src.slice(1), pad: 12, titleSize: 13.5, size: 11.5 });
    const b = d.box(344, y, 290, 96, { tone, title: cfg[0], lines: cfg.slice(1), pad: 12, titleSize: 13, size: 11.5 });
    d.arrow([[a.r, a.cy], [b.l, b.cy]], { tone });
    return b;
  };

  const logs = row(
    108, 'net',
    [t('Container logs', '컨테이너 로그'), 'ama-logs (DaemonSet)', '≈ CloudWatch Container Insights'],
    ['DCR container-insights', 'ContainerLogV2 · KubeEvents', t('Pod/Node/Service inventory', 'Pod/Node/Service 인벤토리')],
  );
  const cpl = row(
    220, 'id',
    [t('Control plane logs', '컨트롤 플레인 로그'), 'kube-audit-admin · kube-apiserver', 'scheduler · autoscaler · guard'],
    [t('Diagnostic setting', '진단 설정 (Diagnostic setting)'), '≈ EKS control plane logging', t('Dedicated tables (AKSAudit, etc.)', '전용 테이블(AKSAudit 등)')],
  );
  const prom = row(
    332, 'azure',
    [t('Metrics', '메트릭'), t('ama-metrics (Prometheus scraping)', 'ama-metrics (Prometheus 수집)'), t('≈ remote write to AMP', '≈ AMP 로 remote write')],
    ['DCE + DCR prometheus', 'Microsoft-PrometheusMetrics', t('Linked to the cluster via DCRA', 'DCRA 로 클러스터에 연결')],
  );

  // Storage: Log Analytics receives both log rows, Prometheus goes to the Azure Monitor workspace
  const la = d.box(676, 108, 260, 208, {
    tone: 'ok', title: 'Log Analytics workspace', pad: 12, titleSize: 13.5, size: 11.5,
    lines: [
      t('Container logs (ContainerLogV2 …)', '컨테이너 로그 (ContainerLogV2 …)'),
      t('Control plane logs (AKSAudit …)', '컨트롤 플레인 로그 (AKSAudit …)'),
      '',
      t('Query with KQL · a daily ingestion', 'KQL 로 질의 · 일일 수집 상한으로'),
      t('cap prevents runaway costs', '비용 폭주 방지'),
      '',
      '≈ CloudWatch Logs + Logs Insights',
    ],
  });
  // In the English layout the gap between these two boxes is taller so the PromQL label stays clear of their borders
  const amw = d.box(676, t(340, 332), 260, t(80, 96), {
    tone: 'ok', title: 'Azure Monitor workspace', pad: 12, titleSize: 13, size: 11.5,
    lines: ['Managed Prometheus', t('+ recording rules (for dashboards)', '+ recording rule (대시보드용)')],
  });
  const g = d.box(676, t(448, 444), 260, t(58, 62), {
    tone: 'ok', title: 'Managed Grafana', pad: 12, titleSize: 13.5, size: 11,
    lines: [t('Prometheus data source auto-connected', 'Prometheus 데이터 소스 자동 연결')],
  });

  d.arrow([[logs.r, logs.cy], [la.l, 156]], { tone: 'net' });
  d.arrow([[cpl.r, cpl.cy], [la.l, 268]], { tone: 'id' });
  d.arrow([[prom.r, prom.cy], [amw.l, amw.cy]], { tone: 'azure' });
  d.arrow([[amw.cx, amw.b], [amw.cx, g.t]], { tone: 'ok', label: 'PromQL', at: 0.5, dx: 40 });
  d.text(24, 466, t('Grafana reads Prometheus with the "Monitoring Data Reader" role,', 'Grafana 는 "Monitoring Data Reader" 역할로 Prometheus 를 읽고,'), { size: 11.5, muted: true, maxW: 640 });
  d.text(24, 484, t('and operators sign in with the "Grafana Admin" role (role assignments in Lab 04).', '운영자는 "Grafana Admin" 역할로 로그인합니다 (Lab 04 의 역할 할당).'), { size: 11.5, muted: true, maxW: 640 });
  return d;
}

export const diagrams = [
  { name: 'network-topology', build: networkTopology },
  { name: 'aks-cluster', build: aksCluster },
  { name: 'observability-pipeline', build: observability },
];
