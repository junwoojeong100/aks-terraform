// AWS ↔ Azure comparison diagrams
import { Diagram, t } from './lib.mjs';

// ---------------------------------------------------------------------------
// Figure: AWS ↔ Azure service map
// ---------------------------------------------------------------------------
// rows: [AWS, Azure, whether the concept differs a lot]
// The cards hold visible text, so they are created per call (inside build) to follow the language being generated.
const buildCards = () => [
  {
    title: t('Organization · accounts', '조직 · 계정'),
    tone: 'neutral',
    rows: [
      [t('Organizations root', 'Organizations 루트'), t('Tenant · root management group', 'Entra 테넌트 · 루트 관리 그룹')],
      ['OU', t('Management group', '관리 그룹')],
      [t('Account', '계정 (Account)'), t('Subscription', '구독 (Subscription)'), true],
      [t('(none)', '(없음)'), t('Resource group (RG)', '리소스 그룹 (RG)'), true],
      ['SCP', 'Azure Policy + RBAC', true],
      [t('Tags · ARN', '태그 · ARN'), t('Tags · resource ID', '태그 · 리소스 ID')],
    ],
  },
  {
    title: t('Networking', '네트워크'),
    tone: 'net',
    rows: [
      ['VPC', 'Virtual Network (VNet)'],
      [t('Subnet (tied to one AZ)', 'Subnet (AZ 고정)'), t('Subnet (not tied to an AZ)', 'Subnet (AZ 비종속)'), true],
      ['Security Group · NACL', 'NSG'],
      ['NAT Gateway + EIP', t('NAT Gateway (subnet-attached)', 'NAT Gateway (서브넷에 연결)'), true],
      ['VPC Endpoint', 'Private Endpoint + DNS Zone', true],
      ['ALB · NLB', 'App GW · LB · Front Door'],
    ],
  },
  {
    title: t('Containers (EKS ↔ AKS)', '컨테이너 (EKS ↔ AKS)'),
    tone: 'azure',
    rows: [
      ['EKS', t('AKS (Standard tier = SLA)', 'AKS (Standard 티어 = SLA)')],
      ['EKS Auto Mode', 'AKS Automatic'],
      ['Managed node group', 'Node pool (VMSS)'],
      ['Karpenter', t('NAP (node auto-provisioning)', 'NAP (노드 자동 프로비저닝)')],
      ['VPC CNI', 'CNI Overlay + Cilium', true],
      ['AWS LB Controller', 'Gateway API (App Routing)'],
      ['ECR', 'ACR'],
    ],
  },
  {
    title: t('Identity · security · secrets', 'ID · 보안 · 시크릿'),
    tone: 'id',
    rows: [
      ['IAM User · SSO', 'Microsoft Entra ID'],
      ['IAM Role + Policy', t('Managed Identity + RBAC role', 'Managed Identity + 역할 할당'), true],
      ['IRSA · Pod Identity', 'Workload Identity'],
      ['EKS access entries', 'Azure RBAC for Kubernetes'],
      ['KMS · Secrets Manager', 'Key Vault'],
      ['GuardDuty · Inspector', 'Defender for Containers'],
    ],
  },
  {
    title: t('Observability · governance · cost', '관측 · 거버넌스 · 비용'),
    tone: 'ok',
    rows: [
      ['CloudWatch Logs', 'Log Analytics'],
      ['AMP · AMG', t('Managed Prometheus · Grafana', '관리형 Prometheus · Grafana')],
      ['CloudTrail', t('Activity Log + diagnostics', 'Activity Log + 진단 설정')],
      ['AWS Config · Kyverno', 'Azure Policy (Gatekeeper)'],
      ['Budgets · Cost Explorer', t('Cost Management budgets', 'Cost Management 예산')],
    ],
  },
  {
    title: t('Terraform · state', 'Terraform · 상태'),
    tone: 'warn',
    rows: [
      [t('S3 + DynamoDB (lock)', 'S3 + DynamoDB (락)'), 'Blob Storage (blob lease)'],
      ['provider aws · awscc', 'azurerm · azapi'],
      ['terraform-aws-modules', 'Azure Verified Modules'],
      ['AWS_PROFILE · SSO', t('az login + subscription env var', 'az login + 구독 환경 변수')],
    ],
  },
];

function awsAzureMap() {
  const CARDS = buildCards();
  const none = t('(none)', '(없음)');
  const rowH = 30;
  const head = 44;
  const cardH = (c) => head + c.rows.length * rowH + 12;
  const gap = 16;
  const cw = 456;
  const left = 24;
  // Two columns × three rows layout
  const lines = [
    [CARDS[0], CARDS[1]],
    [CARDS[2], CARDS[3]],
    [CARDS[4], CARDS[5]],
  ];
  const heights = lines.map(([a, b]) => Math.max(cardH(a), cardH(b)));
  const top = 96;
  const total = top + heights.reduce((s, h) => s + h, 0) + gap * 2 + 52;
  const title = t('AWS ↔ Azure service map', 'AWS ↔ Azure 서비스 대응 지도');
  const d = new Diagram('aws-azure-map', 960, total, {
    title,
    desc: t(
      'A map that places AWS services next to their Azure counterparts, grouped by category: organization and accounts, networking, containers, identity and security, observability, governance and cost, and Terraform and state. Items whose concepts differ and need extra care are marked with an exclamation mark.',
      '조직·계정, 네트워크, 컨테이너, ID·보안, 관측·거버넌스·비용, Terraform·상태 영역별로 AWS 서비스와 대응하는 Azure 서비스를 나란히 보여 주는 지도. 개념이 달라 주의가 필요한 항목에는 느낌표가 붙어 있다.',
    ),
  });
  d.heading(
    title,
    t(
      'AWS is on the left, Azure on the right. A yellow ! marks look-alike names with different concepts — be sure to read Lab 00.',
      '왼쪽이 AWS, 오른쪽이 Azure 입니다. 노란 ! 는 이름만 비슷하고 개념이 다른 항목 — Lab 00 의 설명을 꼭 읽어 보세요.',
    ),
  );

  // English labels are wider on the Azure side: that column starts earlier and may use the space up to the "!" badge
  // (rows without a badge may use even more).
  const awsMaxW = t(170, 176);
  const arrowX = t(195, 204);
  const azX = t(210, 224);
  const azMaxW = (diff) => t(diff ? 211 : 228, 198);

  let y = top;
  lines.forEach(([a, b], li) => {
    [a, b].forEach((c, ci) => {
      const x = left + ci * (cw + gap);
      const h = heights[li];
      const tone = c.tone;
      d.box(x, y, cw, h, { tone, pad: 0 });
      d.text(x + 16, y + 27, c.title, { size: 14.5, bold: true, tone: tone === 'neutral' ? null : tone });
      c.rows.forEach(([aws, az, diff], i) => {
        const by = y + head + i * rowH + 20;
        if (i > 0) d.line(x + 14, y + head + i * rowH, x + cw - 14, y + head + i * rowH, { dashed: true });
        d.text(x + 16, by, aws, { size: 12.5, tone: 'aws', muted: aws === none, maxW: awsMaxW });
        d.text(x + arrowX, by, '↔', { size: 13, muted: true, anchor: 'middle' });
        d.text(x + azX, by, az, { size: 12.5, tone: 'azure', maxW: azMaxW(diff) });
        if (diff) d.badge(x + cw - 20, by - 4, '!', { tone: 'warn', r: 9 });
      });
    });
    y += heights[li] + gap;
  });
  d.badge(40, total - 22, '!', { tone: 'warn', r: 9 });
  d.text(
    58,
    total - 17,
    t(
      'Similar names, different structure (e.g., subnets are not tied to an AZ, and resource groups add a new layer)',
      '이름은 비슷하지만 구조가 다른 항목 (예: 서브넷은 AZ 에 묶이지 않고, 리소스 그룹이라는 새 계층이 있습니다)',
    ),
    { size: 12, muted: true, maxW: 880 },
  );
  return d;
}

// ---------------------------------------------------------------------------
// Figure: accounts · regions · availability zones compared
// ---------------------------------------------------------------------------
function accountHierarchy() {
  const title = t('Accounts, regions and availability zones compared', '계정 · 리전 · 가용 영역 구조 비교');
  const d = new Diagram('account-hierarchy', 960, 620, {
    title,
    desc: t(
      'A layer-by-layer comparison of AWS Organizations, OUs, accounts, VPCs and subnets with the Azure tenant, management groups, subscriptions, resource groups, VNets and subnets. Azure has one more layer, the resource group, and its subnets are not tied to an availability zone.',
      'AWS 의 Organizations, OU, 계정, VPC, 서브넷과 Azure 의 테넌트, 관리 그룹, 구독, 리소스 그룹, VNet, 서브넷을 층별로 비교. Azure 에는 리소스 그룹이라는 계층이 더 있고 서브넷은 가용 영역에 묶이지 않는다.',
    ),
  });
  d.heading(
    title,
    t(
      'Boxes at the same height correspond to each other. Orange is AWS, blue is Azure.',
      '같은 높이의 상자끼리 대응합니다. 주황색이 AWS, 파란색이 Azure 입니다.',
    ),
  );

  const aw = 380;
  const ax = 24;
  const zx = 556;
  const mid = 480;
  const top = 96;
  const rh = 66;
  const gap = 22;
  // [AWS title, AWS subtitle, Azure title, Azure subtitle, AWS has no such layer]
  const rows = [
    [
      'AWS Organizations',
      t('Root · entire organization', '루트 · 조직 전체'),
      t('Entra tenant · root management group', 'Entra 테넌트 · 루트 관리 그룹'),
      t('Top level: directory (users · apps) + subscriptions', '디렉터리(사용자·앱) + 구독을 묶는 최상위'),
    ],
    [
      t('OU (organizational unit)', 'OU (조직 단위)'),
      t('Inherits SCPs', 'SCP 를 상속'),
      t('Management group', '관리 그룹'),
      t('Azure Policy · role assignments inherit downward', 'Azure Policy · 역할 할당이 하위로 상속'),
    ],
    [
      t('Account', '계정 (Account)'),
      t('Billing · isolation · permission boundary', '청구 · 격리 · 권한 경계'),
      t('Subscription', '구독 (Subscription)'),
      t('Billing · quota (vCPU) boundary', '청구 · 쿼터(vCPU) 경계'),
    ],
    [
      t('(no equivalent layer)', '(해당 계층 없음)'),
      t('Resources are created directly in the account', '리소스는 계정 안에 바로 생성'),
      t('Resource group', '리소스 그룹 (Resource Group)'),
      t('Unit of lifecycle · deletion · RBAC · tags', '수명주기 · 삭제 · RBAC · 태그 단위'),
      true,
    ],
    [
      'VPC',
      t('Regional · subnets are tied to one AZ', '리전 단위 · 서브넷은 AZ 에 고정'),
      'VNet',
      t('Regional · subnets span the whole region', '리전 단위 · 서브넷은 리전 전체에 걸침'),
    ],
    [
      'AZ (a · b · c)',
      t('Each subnet specifies its AZ', '서브넷마다 AZ 를 지정'),
      t('Availability zone (1 · 2 · 3)', '가용 영역 (1 · 2 · 3)'),
      t('Set as a property of node pools · VMs · LBs', '노드 풀 · VM · LB 의 속성으로 지정'),
    ],
  ];
  rows.forEach(([aT, aS, zT, zS, none = false], i) => {
    const y = top + i * (rh + gap);
    d.box(ax, y, aw, rh, { tone: none ? 'neutral' : 'aws', dashed: none, title: aT, lines: [aS], pad: 12, titleSize: 14, size: 12 });
    d.box(zx, y, aw, rh, { tone: 'azure', title: zT, lines: [zS], pad: 12, titleSize: 14, size: 12 });
    d.arrow([[ax + aw, y + rh / 2], [zx, y + rh / 2]], { tone: none ? 'warn' : null, dashed: true, head: false });
    d.rect(mid - 16, y + rh / 2 - 15, 32, 30, { cls: 'dg-chip', rx: 8 });
    d.text(mid, y + rh / 2 + 7, none ? '+' : '≈', { size: 22, bold: true, anchor: 'middle', tone: none ? 'warn' : null, muted: !none });
    if (i < rows.length - 1) {
      d.arrow([[ax + aw / 2, y + rh], [ax + aw / 2, y + rh + gap]], { tone: 'aws' });
      d.arrow([[zx + aw / 2, y + rh], [zx + aw / 2, y + rh + gap]], { tone: 'azure' });
    }
  });
  d.pill(zx + aw - 92, top + 3 * (rh + gap) - 11, t('Not in AWS', 'AWS 에 없음'), { tone: 'warn', size: 11 });
  return d;
}

export const diagrams = [
  { name: 'aws-azure-map', build: awsAzureMap },
  { name: 'account-hierarchy', build: accountHierarchy },
];
