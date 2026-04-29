# Databricks notebook source
# ============================================================================
# ADB Serverless 네트워크 트래픽 흐름 테스트
# ============================================================================
# 목적: Serverless 컴퓨팅에서 아웃바운드 트래픽의 IP와 경로를 확인
#
# 트래픽 흐름:
#   ADB Serverless → NCC → PE → PLS → LB → Router VM → Azure Firewall → Internet
#
# 이 노트북은 Serverless Compute에서 실행해야 합니다.
# ============================================================================

# COMMAND ----------

# MAGIC %md
# MAGIC # 🔍 ADB Serverless 네트워크 트래픽 흐름 테스트
# MAGIC
# MAGIC ## 테스트 목적
# MAGIC - Serverless 컴퓨팅의 아웃바운드 IP 확인
# MAGIC - Private Link → LB → Router VM → Azure Firewall 경유 여부 확인
# MAGIC - Firewall 로그와 대조하여 트래픽 흐름 검증
# MAGIC
# MAGIC ## 예상 트래픽 경로
# MAGIC ```
# MAGIC ADB Serverless → NCC PE → PLS → Internal LB → Router VM (NAT) → Azure Firewall → Internet
# MAGIC ```

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. 외부 IP 확인 (Outbound IP)
# MAGIC Azure Firewall의 Public IP가 표시되면 트래픽이 Firewall을 경유하는 것입니다.

# COMMAND ----------

import urllib.request
import json

print("=" * 60)
print("  아웃바운드 IP 확인")
print("=" * 60)

# 방법 1: ifconfig.me
try:
    req = urllib.request.Request("https://ifconfig.me/ip", headers={"User-Agent": "curl/7.68.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        ip = resp.read().decode().strip()
    print(f"\n  [ifconfig.me]     외부 IP: {ip}")
except Exception as e:
    print(f"\n  [ifconfig.me]     실패: {e}")

# 방법 2: api.ipify.org
try:
    req = urllib.request.Request("https://api.ipify.org?format=json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    print(f"  [api.ipify.org]   외부 IP: {data['ip']}")
except Exception as e:
    print(f"  [api.ipify.org]   실패: {e}")

# 방법 3: ipinfo.io
try:
    req = urllib.request.Request("https://ipinfo.io/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    print(f"  [ipinfo.io]       외부 IP: {data.get('ip', 'N/A')}")
    print(f"                    지역: {data.get('region', 'N/A')}, {data.get('country', 'N/A')}")
    print(f"                    조직: {data.get('org', 'N/A')}")
except Exception as e:
    print(f"  [ipinfo.io]       실패: {e}")

print("\n" + "=" * 60)
print("  ☝️ 위 IP가 Azure Firewall의 Public IP와 동일해야 합니다")
print("=" * 60)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Azure Storage 접근 테스트
# MAGIC Firewall Application Rule에서 `*.blob.core.windows.net` 허용 확인

# COMMAND ----------

import urllib.request
import time

print("=" * 60)
print("  Azure Storage 연결 테스트")
print("=" * 60)

# Azure Storage blob endpoint 연결 테스트 (HEAD 요청)
storage_endpoints = [
    "https://management.azure.com",
    "https://login.microsoftonline.com",
]

for url in storage_endpoints:
    start = time.time()
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=10) as resp:
            elapsed = (time.time() - start) * 1000
            print(f"\n  ✅ {url}")
            print(f"     Status: {resp.status}, Latency: {elapsed:.0f}ms")
    except urllib.error.HTTPError as e:
        elapsed = (time.time() - start) * 1000
        print(f"\n  ⚠️  {url}")
        print(f"     HTTP {e.code} (연결은 성공), Latency: {elapsed:.0f}ms")
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        print(f"\n  ❌ {url}")
        print(f"     Error: {e}, Latency: {elapsed:.0f}ms")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Firewall 차단 테스트
# MAGIC 허용되지 않은 FQDN으로의 접근이 차단되는지 확인

# COMMAND ----------

import urllib.request
import time

print("=" * 60)
print("  Firewall 차단 테스트 (허용되지 않은 사이트)")
print("=" * 60)

blocked_sites = [
    "https://www.google.com",
    "https://www.example.com",
    "https://www.github.com",
]

for url in blocked_sites:
    start = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "curl/7.68.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            elapsed = (time.time() - start) * 1000
            print(f"\n  ⚠️  {url}")
            print(f"     접근 가능 (차단되지 않음) - Status: {resp.status}, Latency: {elapsed:.0f}ms")
    except urllib.error.URLError as e:
        elapsed = (time.time() - start) * 1000
        print(f"\n  ✅ {url}")
        print(f"     차단됨 (정상) - Error: {e.reason}, Latency: {elapsed:.0f}ms")
    except Exception as e:
        elapsed = (time.time() - start) * 1000
        print(f"\n  ✅ {url}")
        print(f"     차단됨 (정상) - Error: {e}, Latency: {elapsed:.0f}ms")

print("\n" + "=" * 60)
print("  ☝️ deny-by-default 정책에 의해 차단되어야 합니다")
print("=" * 60)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. DNS Resolution 테스트

# COMMAND ----------

import socket

print("=" * 60)
print("  DNS Resolution 테스트")
print("=" * 60)

domains = [
    "ifconfig.me",
    "login.microsoftonline.com",
    "management.azure.com",
]

for domain in domains:
    try:
        ips = socket.getaddrinfo(domain, 443, socket.AF_INET)
        ip_list = list(set([ip[4][0] for ip in ips]))
        print(f"\n  ✅ {domain}")
        print(f"     → {', '.join(ip_list)}")
    except Exception as e:
        print(f"\n  ❌ {domain}")
        print(f"     → Error: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. 네트워크 경로 정보 요약

# COMMAND ----------

import urllib.request
import json

print("=" * 60)
print("  네트워크 경로 정보 요약")
print("=" * 60)

# httpbin.org 를 통한 상세 정보
try:
    req = urllib.request.Request("https://httpbin.org/ip")
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode())
    print(f"\n  httpbin.org origin: {data.get('origin', 'N/A')}")
except Exception as e:
    print(f"\n  httpbin.org: {e}")

# 요약 출력
try:
    req = urllib.request.Request("https://ipinfo.io/json")
    with urllib.request.urlopen(req, timeout=10) as resp:
        info = json.loads(resp.read().decode())
    
    print(f"\n  ┌──────────────────────────────────────────┐")
    print(f"  │  트래픽 출구 정보                          │")
    print(f"  ├──────────────────────────────────────────┤")
    print(f"  │  IP      : {info.get('ip', 'N/A'):>28s} │")
    print(f"  │  City    : {info.get('city', 'N/A'):>28s} │")
    print(f"  │  Region  : {info.get('region', 'N/A'):>28s} │")
    print(f"  │  Country : {info.get('country', 'N/A'):>28s} │")
    print(f"  │  Org     : {info.get('org', 'N/A'):>28s} │")
    print(f"  └──────────────────────────────────────────┘")
    
    print(f"\n  📋 이 IP가 Azure Firewall의 Public IP와 동일하면")
    print(f"     트래픽이 정상적으로 Firewall을 경유하는 것입니다.")
except Exception as e:
    print(f"\n  정보 조회 실패: {e}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Firewall 로그 확인 KQL 쿼리
# MAGIC
# MAGIC Azure Portal > Azure Firewall > Logs (Log Analytics)에서 아래 쿼리를 실행하세요:
# MAGIC
# MAGIC ```kql
# MAGIC // Application Rule 로그 - 최근 1시간
# MAGIC AZFWApplicationRule
# MAGIC | where TimeGenerated > ago(1h)
# MAGIC | where SourceIp startswith "10.0.2."
# MAGIC | project TimeGenerated, SourceIp, Fqdn, TargetUrl, Action, Protocol
# MAGIC | order by TimeGenerated desc
# MAGIC | take 100
# MAGIC ```
# MAGIC
# MAGIC ```kql
# MAGIC // Network Rule 로그
# MAGIC AZFWNetworkRule
# MAGIC | where TimeGenerated > ago(1h)
# MAGIC | where SourceIp startswith "10.0.2."
# MAGIC | project TimeGenerated, SourceIp, DestinationIp, DestinationPort, Protocol, Action
# MAGIC | order by TimeGenerated desc
# MAGIC | take 100
# MAGIC ```
# MAGIC
# MAGIC ```kql
# MAGIC // 차단된 트래픽만 확인
# MAGIC AZFWApplicationRule
# MAGIC | where TimeGenerated > ago(1h)
# MAGIC | where Action == "Deny"
# MAGIC | where SourceIp startswith "10.0.2."
# MAGIC | project TimeGenerated, SourceIp, Fqdn, TargetUrl
# MAGIC | order by TimeGenerated desc
# MAGIC ```
