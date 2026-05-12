# Databricks Serverless SNI Proxy → DMZ 방화벽 연결 문제 분석 및 가이드

> **작성일**: 2026-05-12  
> **대상**: Databricks Serverless Private Link 환경에서 SNI Proxy를 통한 외부 연결 시 DMZ 방화벽까지 트래픽이 도달하지 않는 문제

---

## 1. 현재 증상 요약

### 1.1 테스트 결과 (Databricks Serverless → pypi.org)

| 단계 | 결과 | 의미 |
|---|---|---|
| DNS 조회 | ✅ 성공 (172.18.36.117) | Private DNS를 통해 Proxy(ILB/PLS) IP로 정상 해석 |
| TCP 연결 (443) | ✅ 성공 (6.7ms) | Databricks → PLS → LB → NGINX SNI Proxy 구간 정상 |
| HTTPS 요청 | ❌ SSL handshake timeout (10초) | Proxy가 upstream에 연결 실패 |
| SSL/TLS 핸드셰이크 | ❌ Timeout (10초) | upstream으로부터 ServerHello 응답 없음 |

### 1.2 Proxy VM 로그

```
[12/May/2026:16:54:34 +0900] SNI=pypi.org upstream=151.101.64.223:443, 151.101.192.223:443, 
151.101.0.223:443, 151.101.128.223:443, [2a04:4e42:200::223]:443, ...
```

- NGINX SNI Proxy가 pypi.org의 실제 IP로 upstream 연결을 시도하고 있음
- IPv4 및 IPv6 주소 모두 시도하고 있으나 모두 실패

### 1.3 DMZ 방화벽 로그

- **차단 로그 없음**, **허용 로그 없음**
- 트래픽이 DMZ 방화벽에 **도달하지 않음**을 의미

---

## 2. 원인 분석

### 2.1 트래픽 흐름과 차단 지점

```
Databricks Serverless
    │
    ▼ (Private Endpoint)
Private Link Service (PLS)
    │
    ▼
Internal Load Balancer (ILB)
    │
    ▼
NGINX SNI Proxy (vm-router-01, 10.0.2.68)
    │
    │  ← NGINX가 pypi.org(151.101.64.223:443)로 새 TCP 연결 생성
    │  ← UDR: 0.0.0.0/0 → Next Hop: 10.78.2.x (DMZ 방화벽)
    │
    ▼
Azure SDN (라우팅 처리)
    │
    ✕  ← 여기서 패킷 DROP (DMZ 방화벽에 도달하지 못함)
    │
    ▼ (도달 실패)
DMZ 방화벽 (10.78.2.x)
```

**TCP 연결이 성공하고 SSL이 실패하는 이유:**

1. TCP 연결 성공(6.7ms)은 **클라이언트 → NGINX SNI Proxy** 구간
2. NGINX가 ClientHello에서 SNI를 읽은 후 **새 TCP 연결을 upstream으로 생성**
3. 이 upstream 연결이 실패하여 **ServerHello를 클라이언트에 전달할 수 없음**
4. 결과적으로 SSL handshake timeout 발생

### 2.2 핵심 원인: 네트워크 경로 부재

Proxy VM 서브넷(`snet-lb-backend`, 10.0.2.64/26)의 UDR에서 `0.0.0.0/0 → 10.78.2.x (Virtual Appliance)`로 설정되어 있으나, **Proxy VM이 위치한 VNet에서 DMZ 방화벽(10.78.2.x) 네트워크까지의 연결 경로가 없습니다.**

Azure SDN은 next hop IP에 도달할 수 없으면 **패킷을 사일런트(silent) drop** 합니다. 이 경우 어떤 장비에도 로그가 남지 않습니다.

### 2.3 참고 가이드와의 차이점

[Azure Databricks Serverless 네트워크 구성 가이드](https://github.com/jiyongseong/azure-tips-and-tricks/blob/main/ADB/Networking/Azure_Databricks_Serverless_%EB%84%A4%ED%8A%B8%EC%9B%8C%ED%81%AC_%EA%B5%AC%EC%84%B1_%EA%B0%80%EC%9D%B4%EB%93%9C.md)에서는 **Azure Firewall이 Hub VNet에 위치**하는 구성을 전제로 합니다:

```
[가이드 구성]
vnet-databricks (10.0.0.0/16)  ←── VNet Peering ──→  vnet-hub (10.1.0.0/16)
  └ Router VM (10.0.2.68)                               └ Azure Firewall (10.1.0.4)
      ↑ UDR: 0.0.0.0/0 → 10.1.0.4
```

이 경우 VNet Peering으로 10.1.0.4에 도달 가능하므로 정상 동작합니다.

```
[현재 구성]
vnet-databricks (10.0.0.0/16)  ←── VNet Peering ──→  vnet-hub (10.1.0.0/16)
  └ Router VM (10.0.2.68)                               └ (Azure Firewall 또는 미사용)
      ↑ UDR: 0.0.0.0/0 → 10.78.2.x
                                       ❌ 연결 없음
                              DMZ 방화벽 네트워크 (10.78.x.x)
                                └ DMZ 방화벽 (10.78.2.x)
```

**가이드에는 DMZ 방화벽이 별도 네트워크에 있는 경우, 해당 네트워크와의 연결(Peering/ExpressRoute/VPN) 구성 단계가 포함되어 있지 않습니다.**

---

## 3. 확인 절차

### 3.1 [필수] Effective Routes 확인

UDR 설정이 실제로 적용되고 있는지 확인합니다.

**Azure Portal:**
```
VM (vm-router-01) → Networking → NIC 클릭 → Help 섹션 → "Effective routes"
```

**Azure CLI:**
```bash
az network nic show-effective-route-table \
  -g rg-databricks-networking \
  -n vm-router-01-nic \
  -o table
```

**확인 포인트:**
- `0.0.0.0/0` 경로의 **State** 컬럼이 `Active`인지 `Invalid`인지 확인
- `Invalid`인 경우 → Azure가 next hop(10.78.2.x)에 도달할 수 없다고 판단한 것 → **네트워크 경로 추가 필요**
- `Active`인 경우 → 경로는 유효하지만 다른 원인 (NSG, NVA 설정 등) 추가 조사 필요

### 3.2 Network Watcher - Next Hop 확인

Azure가 판단하는 실제 next hop을 확인합니다.

```bash
az network watcher show-next-hop \
  -g rg-databricks-networking \
  --vm vm-router-01 \
  --source-ip 10.0.2.68 \
  --dest-ip 151.101.64.223 \
  -o table
```

### 3.3 NSG Outbound 차단 여부 확인

NSG에서 outbound 트래픽을 차단하고 있지 않은지 확인합니다.

```bash
az network watcher test-ip-flow \
  -g rg-databricks-networking \
  --vm vm-router-01 \
  --direction Outbound \
  --protocol TCP \
  --local 10.0.2.68:* \
  --remote 151.101.64.223:443 \
  -o table
```

> **참고**: 이 명령은 NSG 규칙만 검사합니다. UDR, Firewall 규칙, VNet Peering 도달 가능성은 검사하지 않습니다.

### 3.4 Proxy VM에서 직접 확인

SSH로 Proxy VM에 접속하여 다음 명령을 실행합니다.

```bash
# 1. NGINX error log에서 upstream 실패 상세 확인
sudo tail -20 /var/log/nginx/error.log

# 2. pypi.org IP로 직접 TCP 연결 시도
timeout 5 bash -c 'echo | nc -v 151.101.64.223 443' 2>&1

# 3. tcpdump로 패킷 발신 여부 확인
sudo tcpdump -i any host 151.101.64.223 -nn -c 10

# 4. iptables NAT 테이블 확인
sudo iptables -t nat -L -n -v
```

---

## 4. 조치 방안

### 4.1 DMZ 방화벽 네트워크 연결 (핵심)

DMZ 방화벽(10.78.2.x)이 위치한 네트워크에 따라 적절한 연결을 구성해야 합니다:

| DMZ 방화벽 위치 | 필요한 조치 |
|---|---|
| **별도 Azure VNet** | `vnet-databricks` ↔ `vnet-dmz` VNet Peering 추가 |
| **온프레미스 네트워크** | ExpressRoute 또는 VPN을 통해 10.78.x.x 경로 광고 |
| **Hub VNet 경유 연결** | Hub VNet에서 DMZ VNet으로의 transit 라우팅 구성 |

**VNet Peering 추가 시 필수 설정:**

| 설정 항목 | 값 | 이유 |
|---|---|---|
| Allow traffic to remote virtual network | **Allow** | 양방향 통신 허용 |
| Allow traffic forwarded from remote virtual network | **Allow** | Forwarded 패킷이 Peering 통과 허용 |

### 4.2 DMZ 방화벽 측 확인 사항

네트워크 경로가 확보된 후, DMZ 방화벽 측에서 다음을 확인해야 합니다:

| 확인 항목 | 설명 |
|---|---|
| **NIC IP Forwarding** | DMZ 방화벽 VM의 Azure NIC에서 IP Forwarding이 활성화되어 있어야 함. 비활성 시 Azure가 forwarded 패킷을 drop |
| **Return Route** | DMZ 방화벽에서 Proxy VM 서브넷(10.0.2.64/26)으로의 return 경로가 있어야 함. 없으면 비대칭 라우팅으로 stateful inspection에서 drop |
| **443 Outbound 허용** | DMZ 방화벽 규칙에서 pypi.org 등 대상 FQDN/IP의 HTTPS(443) outbound를 허용해야 함 |

### 4.3 NGINX SNI Proxy 개선 (권장)

현재 IPv6 주소로도 upstream 연결을 시도하여 불필요한 timeout이 발생하고 있습니다. resolver에 `ipv6=off`를 추가하여 IPv4만 사용하도록 설정합니다:

```nginx
stream {
    resolver 168.63.129.16 valid=30s ipv6=off;   # ipv6=off 추가
    resolver_timeout 5s;
    ...
}
```

**적용 방법:**
```bash
# Proxy VM에서 실행
sudo vi /etc/nginx/stream-sni-proxy.conf
# resolver 줄에 ipv6=off 추가

sudo nginx -t && sudo systemctl reload nginx
```

---

## 5. 조치 후 검증

### 5.1 Proxy VM에서 검증

```bash
# 1. upstream 연결 테스트
curl -v --connect-timeout 5 https://pypi.org 2>&1 | head -20

# 2. SNI Proxy 로그에서 bytes 확인 (0이 아니어야 정상)
tail -f /var/log/nginx/sni-proxy-access.log
```

### 5.2 DMZ 방화벽에서 검증

- Proxy VM IP(10.0.2.68)에서 발생한 HTTPS(443) 트래픽의 허용/차단 로그가 확인되어야 함
- 로그가 확인되면 네트워크 경로가 정상적으로 확보된 것

### 5.3 Azure Firewall 로그 확인 (해당 시)

```kusto
AZFWApplicationRule
| where TimeGenerated > ago(1h)
| where SourceIp startswith "10.0.2."
| project TimeGenerated, SourceIp, Fqdn, TargetUrl, Action
| order by TimeGenerated desc
| take 50
```

### 5.4 Databricks에서 검증

1. Serverless SQL Warehouse 또는 Notebook 재시작
2. 외부 리소스 접근 테스트 (예: `pip install` 또는 Storage 접근)

---

## 6. 요약

| 구분 | 내용 |
|---|---|
| **증상** | TCP 연결 성공, SSL handshake timeout, DMZ 방화벽에 로그 없음 |
| **원인** | Proxy VM VNet에서 DMZ 방화벽(10.78.2.x) 네트워크로의 연결 경로가 없어 Azure SDN이 패킷을 사일런트 drop |
| **우선 확인** | Effective Routes에서 `0.0.0.0/0` 경로의 State가 `Active`인지 `Invalid`인지 확인 |
| **핵심 조치** | Proxy VM VNet ↔ DMZ 방화벽 네트워크 간 연결 확보 (VNet Peering / ExpressRoute / VPN) |
| **부가 조치** | NGINX resolver에 `ipv6=off` 추가, DMZ 방화벽 NIC의 IP Forwarding 활성화 확인 |
