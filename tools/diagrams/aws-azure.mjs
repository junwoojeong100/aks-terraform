// AWS ↔ Azure 비교 다이어그램
import { Diagram } from './lib.mjs';

// ---------------------------------------------------------------------------
// 그림: AWS ↔ Azure 서비스 대응 지도
// ---------------------------------------------------------------------------
// rows: [AWS, Azure, 차이가 큰 개념인가]
const CARDS = [
  {
    title: '조직 · 계정',
    tone: 'neutral',
    rows: [
      ['Organizations 루트', 'Entra 테넌트 · 루트 관리 그룹'],
      ['OU', '관리 그룹'],
      ['계정 (Account)', '구독 (Subscription)', true],
      ['(없음)', '리소스 그룹 (RG)', true],
      ['SCP', 'Azure Policy + RBAC', true],
      ['태그 · ARN', '태그 · 리소스 ID'],
    ],
  },
  {
    title: '네트워크',
    tone: 'net',
    rows: [
      ['VPC', 'Virtual Network (VNet)'],
      ['Subnet (AZ 고정)', 'Subnet (AZ 비종속)', true],
      ['Security Group · NACL', 'NSG'],
      ['NAT Gateway + EIP', 'NAT Gateway (서브넷에 연결)', true],
      ['VPC Endpoint', 'Private Endpoint + DNS Zone', true],
      ['ALB · NLB', 'App GW · LB · Front Door'],
    ],
  },
  {
    title: '컨테이너 (EKS ↔ AKS)',
    tone: 'azure',
    rows: [
      ['EKS', 'AKS (Standard 티어 = SLA)'],
      ['EKS Auto Mode', 'AKS Automatic'],
      ['Managed node group', 'Node pool (VMSS)'],
      ['Karpenter', 'NAP (노드 자동 프로비저닝)'],
      ['VPC CNI', 'CNI Overlay + Cilium', true],
      ['AWS LB Controller', 'Gateway API (App Routing)'],
      ['ECR', 'ACR'],
    ],
  },
  {
    title: 'ID · 보안 · 시크릿',
    tone: 'id',
    rows: [
      ['IAM User · SSO', 'Microsoft Entra ID'],
      ['IAM Role + Policy', 'Managed Identity + 역할 할당', true],
      ['IRSA · Pod Identity', 'Workload Identity'],
      ['EKS access entries', 'Azure RBAC for Kubernetes'],
      ['KMS · Secrets Manager', 'Key Vault'],
      ['GuardDuty · Inspector', 'Defender for Containers'],
    ],
  },
  {
    title: '관측 · 거버넌스 · 비용',
    tone: 'ok',
    rows: [
      ['CloudWatch Logs', 'Log Analytics'],
      ['AMP · AMG', '관리형 Prometheus · Grafana'],
      ['CloudTrail', 'Activity Log + 진단 설정'],
      ['AWS Config · Kyverno', 'Azure Policy (Gatekeeper)'],
      ['Budgets · Cost Explorer', 'Cost Management 예산'],
    ],
  },
  {
    title: 'Terraform · 상태',
    tone: 'warn',
    rows: [
      ['S3 + DynamoDB (락)', 'Blob Storage (blob lease)'],
      ['provider aws · awscc', 'azurerm · azapi'],
      ['terraform-aws-modules', 'Azure Verified Modules'],
      ['AWS_PROFILE · SSO', 'az login + 구독 환경 변수'],
    ],
  },
];

function awsAzureMap() {
  const rowH = 30;
  const head = 44;
  const cardH = (c) => head + c.rows.length * rowH + 12;
  const gap = 16;
  const cw = 456;
  const left = 24;
  // 두 열 × 세 줄 배치
  const lines = [
    [CARDS[0], CARDS[1]],
    [CARDS[2], CARDS[3]],
    [CARDS[4], CARDS[5]],
  ];
  const heights = lines.map(([a, b]) => Math.max(cardH(a), cardH(b)));
  const top = 96;
  const total = top + heights.reduce((s, h) => s + h, 0) + gap * 2 + 52;
  const d = new Diagram('aws-azure-map', 960, total, {
    title: 'AWS ↔ Azure 서비스 대응 지도',
    desc: '조직·계정, 네트워크, 컨테이너, ID·보안, 관측·거버넌스·비용, Terraform·상태 영역별로 AWS 서비스와 대응하는 Azure 서비스를 나란히 보여 주는 지도. 개념이 달라 주의가 필요한 항목에는 느낌표가 붙어 있다.',
  });
  d.heading('AWS ↔ Azure 서비스 대응 지도', '왼쪽이 AWS, 오른쪽이 Azure 입니다. 노란 ! 는 이름만 비슷하고 개념이 다른 항목 — Lab 00 의 설명을 꼭 읽어 보세요.');

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
        d.text(x + 16, by, aws, { size: 12.5, tone: 'aws', muted: aws === '(없음)', maxW: 176 });
        d.text(x + 204, by, '↔', { size: 13, muted: true, anchor: 'middle' });
        d.text(x + 224, by, az, { size: 12.5, tone: 'azure', maxW: 198 });
        if (diff) d.badge(x + cw - 20, by - 4, '!', { tone: 'warn', r: 9 });
      });
    });
    y += heights[li] + gap;
  });
  d.badge(40, total - 22, '!', { tone: 'warn', r: 9 });
  d.text(58, total - 17, '이름은 비슷하지만 구조가 다른 항목 (예: 서브넷은 AZ 에 묶이지 않고, 리소스 그룹이라는 새 계층이 있습니다)', { size: 12, muted: true, maxW: 880 });
  return d;
}

// ---------------------------------------------------------------------------
// 그림: 계정 · 리전 · 가용 영역 구조 비교
// ---------------------------------------------------------------------------
function accountHierarchy() {
  const d = new Diagram('account-hierarchy', 960, 620, {
    title: '계정 · 리전 · 가용 영역 구조 비교',
    desc: 'AWS 의 Organizations, OU, 계정, VPC, 서브넷과 Azure 의 테넌트, 관리 그룹, 구독, 리소스 그룹, VNet, 서브넷을 층별로 비교. Azure 에는 리소스 그룹이라는 계층이 더 있고 서브넷은 가용 영역에 묶이지 않는다.',
  });
  d.heading('계정 · 리전 · 가용 영역 구조 비교', '같은 높이의 상자끼리 대응합니다. 주황색이 AWS, 파란색이 Azure 입니다.');

  const aw = 380;
  const ax = 24;
  const zx = 556;
  const mid = 480;
  const top = 96;
  const rh = 66;
  const gap = 22;
  const rows = [
    ['AWS Organizations', '루트 · 조직 전체', 'Entra 테넌트 · 루트 관리 그룹', '디렉터리(사용자·앱) + 구독을 묶는 최상위'],
    ['OU (조직 단위)', 'SCP 를 상속', '관리 그룹', 'Azure Policy · 역할 할당이 하위로 상속'],
    ['계정 (Account)', '청구 · 격리 · 권한 경계', '구독 (Subscription)', '청구 · 쿼터(vCPU) 경계'],
    ['(해당 계층 없음)', '리소스는 계정 안에 바로 생성', '리소스 그룹 (Resource Group)', '수명주기 · 삭제 · RBAC · 태그 단위'],
    ['VPC', '리전 단위 · 서브넷은 AZ 에 고정', 'VNet', '리전 단위 · 서브넷은 리전 전체에 걸침'],
    ['AZ (a · b · c)', '서브넷마다 AZ 를 지정', '가용 영역 (1 · 2 · 3)', '노드 풀 · VM · LB 의 속성으로 지정'],
  ];
  rows.forEach(([aT, aS, zT, zS], i) => {
    const y = top + i * (rh + gap);
    const none = aT.startsWith('(해당');
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
  d.pill(zx + aw - 92, top + 3 * (rh + gap) - 11, 'AWS 에 없음', { tone: 'warn', size: 11 });
  return d;
}

export const diagrams = [
  { name: 'aws-azure-map', build: awsAzureMap },
  { name: 'account-hierarchy', build: accountHierarchy },
];
