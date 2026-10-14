// Private API server access diagram (Appendix F)
import { Diagram, t } from './lib.mjs';

// ---------------------------------------------------------------------------
// Figure: two ways to reach a private API server
// ---------------------------------------------------------------------------
function privateApiAccess() {
  const title = t('Two ways to reach a private API server', '프라이빗 API 서버에 접속하는 2가지 방법');
  const d = new Diagram('private-api-access', 960, 632, {
    title,
    desc: t(
      'Method 1 routes clients (a jump host, a runner in a peered VNet, or a laptop over VPN or ExpressRoute) to the private IP of the API server load balancer in snet-aks-apiserver. Method 2 creates a Private Endpoint in the client VNet that connects to a Private Link Service in front of the same load balancer. Both methods need DNS to resolve the private FQDN.',
      '방법 1 은 클라이언트(점프 호스트, 피어링된 VNet 의 러너, VPN 이나 ExpressRoute 로 연결한 노트북)를 snet-aks-apiserver 에 있는 API 서버 로드밸런서의 사설 IP 로 연결한다. 방법 2 는 클라이언트 VNet 에 Private Endpoint 를 만들어 같은 로드밸런서 앞의 Private Link Service 에 연결한다. 두 방법 모두 프라이빗 FQDN 을 해석할 DNS 가 필요하다.',
    ),
  });
  d.heading(
    title,
    t(
      'The API server has only a private IP (enable_private_cluster = true). The methods differ in how the client reaches it.',
      'API 서버는 사설 IP 로만 열립니다(enable_private_cluster = true). 두 방법은 클라이언트가 그 IP 에 닿는 경로가 다릅니다.',
    ),
  );

  // Method 1: direct private IP
  d.group(24, 88, 912, 200, {
    tone: 'net',
    label: t('① Direct private IP · same VNet, peering, VPN / ExpressRoute', '① 사설 IP 로 직접 접속 · 같은 VNet · 피어링 · VPN / ExpressRoute'),
  });
  const clients = [
    [t('Jump host VM + Bastion', '점프 호스트 VM + Bastion'), t('in the AKS VNet, no public IP', 'AKS VNet 안, 공인 IP 없음')],
    [t('Self-hosted runner · VM', '자체 호스팅 러너 · VM'), t('in a peered VNet (hub / ops)', '피어링된 VNet(허브 · 운영)')],
    [t('Laptop · on-premises', '노트북 · 온프레미스'), t('over VPN or ExpressRoute', 'VPN 또는 ExpressRoute 로')],
  ];
  const c = clients.map(([name, sub], i) => d.box(40, 118 + i * 54, 236, 48, { title: name, lines: [sub], pad: 10, titleSize: 12.5, size: 11 }));
  const path = d.box(330, 118, 268, 156, {
    tone: 'net', title: t('Network path to the private IP', '사설 IP 까지의 네트워크 경로'), pad: 12, titleSize: 13, size: 11.5,
    lines: t(
      ['Same VNet · VNet peering', 'VPN gateway · ExpressRoute', 'Address spaces must not overlap', 'Peering is not transitive', 'NSG / firewall: allow TCP 443'],
      ['같은 VNet · VNet 피어링', 'VPN 게이트웨이 · ExpressRoute', '주소 공간이 겹치면 안 됩니다', '피어링은 전이되지 않습니다', 'NSG · 방화벽: TCP 443 허용'],
    ),
  });
  const api = d.box(660, 118, 260, 156, {
    tone: 'ok', title: 'snet-aks-apiserver', pad: 12, titleSize: 13, size: 11.5,
    lines: [
      t('10.10.1.0/28 (delegated)', '10.10.1.0/28 (위임)'),
      t('Internal load balancer (ILB)', '내부 로드밸런서(ILB)'),
      t('private IP · port 443', '사설 IP · 443 포트'),
      t('No public endpoint', '공용 엔드포인트 없음'),
      t('Authorized IP ranges do not apply', 'Authorized IP 범위는 적용되지 않음'),
    ],
  });
  for (const box of c) d.arrow([[box.r, box.cy], [path.l, box.cy]], { tone: 'net' });
  d.arrow([[path.r, path.cy], [api.l, path.cy]], { tone: 'ok' });

  // Method 2: Private Link
  d.group(24, 304, 912, 204, {
    tone: 'azure',
    label: t('② Private Link · Private Endpoint → Private Link Service', '② Private Link 로 접속 · Private Endpoint → Private Link Service'),
  });
  d.group(40, 336, 400, 160, { label: t('Client VNet (any subscription or tenant)', '클라이언트 VNet (다른 구독 · 테넌트)'), labelSize: 12 });
  const client = d.box(52, 366, 170, 118, {
    title: t('Client VM · runner', '클라이언트 VM · 러너'), pad: 10, titleSize: 12.5, size: 11,
    lines: t(['Any address space,', 'overlap is fine', 'No peering needed'], ['주소 공간이 겹쳐도', '상관없음', '피어링 불필요']),
  });
  const pe = d.box(258, 366, 170, 118, {
    tone: 'net', title: 'Private Endpoint', pad: 10, titleSize: 12.5, size: 11,
    lines: t(['Private IP in the client', 'subnet; an A record in', 'your DNS zone points', 'to it'], ['클라이언트 서브넷의', '사설 IP. 직접 만든', 'DNS 존의 A 레코드가', '이 IP 를 가리킴']),
  });
  d.group(520, 336, 404, 160, { label: 'AKS VNet 10.10.0.0/16', labelSize: 12 });
  const pls = d.box(532, 366, 176, 118, {
    tone: 'net', title: 'snet-pls (new)', pad: 10, titleSize: 12.5, size: 11,
    lines: t(['Private Link Service', 'in front of the API', 'server load balancer'], ['Private Link Service', 'API 서버 로드밸런서', '앞단에 연결']),
  });
  const ilb = d.box(744, 366, 168, 118, {
    tone: 'ok', title: t('API server', 'API 서버'), pad: 10, titleSize: 12.5, size: 11,
    lines: ['kube-apiserver ILB', 'snet-aks-apiserver', t('private IP · port 443', '사설 IP · 443 포트')],
  });
  d.arrow([[client.r, client.cy], [pe.l, pe.cy]], { tone: 'net' });
  d.arrow([[pe.r, pe.cy], [pls.l, pls.cy]], { tone: 'azure', label: 'Private Link' });
  d.arrow([[pls.r, pls.cy], [ilb.l, ilb.cy]], { tone: 'ok' });

  // Shared: DNS and the no-network fallback
  d.box(24, 524, 588, 92, {
    tone: 'id', title: t('DNS: the client must resolve the private FQDN', 'DNS: 클라이언트가 프라이빗 FQDN 을 해석해야 합니다'), pad: 12, titleSize: 13, size: 11.5,
    lines: t(
      ["① Link the cluster's private DNS zone to the client VNet,", 'or forward the zone to Azure DNS Private Resolver', '② Own zone + A record pointing to the Private Endpoint IP'],
      ['① 클러스터의 프라이빗 DNS 존을 클라이언트 VNet 에 연결하거나', 'Azure DNS Private Resolver 로 전달', '② 직접 만든 존 + Private Endpoint IP 를 가리키는 A 레코드'],
    ),
  });
  d.box(632, 524, 304, 92, {
    tone: 'warn', title: t('No network path yet?', '아직 네트워크 경로가 없다면?'), pad: 12, titleSize: 13, size: 11.5,
    lines: ['az aks command invoke', t('Runs through the Azure API,', 'Azure API 를 거쳐 실행,'), t('one-shot commands only (D-3)', '한 번에 끝나는 명령만 (D-3)')],
  });
  return d;
}

export const diagrams = [{ name: 'private-api-access', build: privateApiAccess }];
