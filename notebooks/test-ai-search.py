# Databricks notebook source
# ============================================================================
# ADB Serverless → Azure AI Search 접근 테스트
# ============================================================================
# 목적: NCC Resource-based PE Rule을 통한 AI Search 접근 검증
#
# 트래픽 흐름 (Resource PE):
#   ADB Serverless → Managed Private Endpoint → Azure Backbone → AI Search
#   (고객 VNet/Firewall을 거치지 않음)
#
# 사전 조건:
#   - NCC에 searchService Resource PE Rule 추가 + 승인 완료 (ESTABLISHED)
#   - AI Search에 'products' 인덱스 + 10건 샘플 데이터 업로드 완료
#
# Serverless Compute에서 실행하세요.
# ============================================================================

# COMMAND ----------

# MAGIC %md
# MAGIC # 🔍 Azure AI Search 연동 테스트
# MAGIC
# MAGIC ## 구성 요약
# MAGIC | 구성 요소 | 값 |
# MAGIC |---|---|
# MAGIC | AI Search #1 | `ais-genai-2025gen005-eus2-adb.search.windows.net` | searchService PE |
# MAGIC | AI Search #2 | `ais-adb-test-krc01.search.windows.net` | searchService PE |
# MAGIC | 인덱스 | `products` (6 fields) | 두 서비스 동일 인덱스 |
# MAGIC | NCC PE Rule | searchService (ESTABLISHED x2) | 각각 별도 PE |
# MAGIC | 접근 경로 | Resource PE → Azure Backbone (직접) | VM/Firewall 미경유 |

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. 설정

# COMMAND ----------

# AI Search 설정 — 두 개의 Search 서비스 테스트
SEARCH_ENDPOINTS = {
    "ais-genai-2025gen005-eus2-adb": "https://ais-genai-2025gen005-eus2-adb.search.windows.net",
    "ais-adb-test-krc01": "https://ais-adb-test-krc01.search.windows.net",
}
# 테스트 대상 선택 (둘 다 테스트하려면 아래 셀들을 각각 실행)
SEARCH_ENDPOINT = SEARCH_ENDPOINTS["ais-adb-test-krc01"]  # <-- 변경 가능
INDEX_NAME = "products"
API_VERSION = "2024-07-01"

# 인증 방법: Azure AD 토큰 (API Key 불필요)
# Databricks Serverless에서 현재 로그인 사용자의 AAD 토큰으로 인증합니다.
# 사전 조건: 사용자에게 AI Search의 "Search Index Data Reader" RBAC 역할이 필요합니다.
import urllib.request, json

_token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
# Databricks 내장 credential을 통해 Azure Search 리소스용 토큰 획득
try:
    # 방법 1: dbutils credential passthrough
    SEARCH_TOKEN = dbutils.credentials.getToken("https://search.azure.com")
except Exception:
    try:
        # 방법 2: Spark conf에서 AAD 토큰 획득
        SEARCH_TOKEN = spark.conf.get("spark.databricks.azure.credentials.accessToken", "")
    except Exception:
        SEARCH_TOKEN = ""

if not SEARCH_TOKEN:
    print("⚠️ AAD 토큰 자동 획득 실패. API Key 방식으로 전환합니다.")
    print("   아래 SEARCH_API_KEY에 실제 키를 입력하세요:")
    print("   az search admin-key show -g rg-databricks-networking --service-name ais-genai-2025gen005-eus2-adb --query primaryKey -o tsv")
    SEARCH_API_KEY = dbutils.widgets.get("search_api_key") if "search_api_key" in [w.name for w in dbutils.widgets.getAll()] else ""
    if not SEARCH_API_KEY:
        SEARCH_API_KEY = "REPLACE_WITH_YOUR_AI_SEARCH_ADMIN_KEY"
        print("   Databricks widget 'search_api_key'에 키를 입력하거나 위 값을 직접 변경하세요")
    AUTH_HEADER = {"api-key": SEARCH_API_KEY}
    AUTH_MODE = "api-key"
else:
    AUTH_HEADER = {"Authorization": f"Bearer {SEARCH_TOKEN}"}
    AUTH_MODE = "Azure AD (RBAC)"

print(f"✅ AI Search 엔드포인트: {SEARCH_ENDPOINT}")
print(f"   인덱스: {INDEX_NAME}")
print(f"   인증 방식: {AUTH_MODE}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1-1. ADLS Gen2 Storage 연결 확인 (Resource PE)

# COMMAND ----------

# ADLS Gen2 연결 확인 (dfs/blob PE)
STORAGE_PATH = "abfss://testdata@adlsdbrickstest.dfs.core.windows.net/sales/sample_sales.csv"

try:
    df_sales = spark.read.format("csv") \
        .option("header", "true") \
        .option("inferSchema", "true") \
        .load(STORAGE_PATH)
    
    df_sales.createOrReplaceTempView("sales")
    print(f"✅ ADLS Gen2 연결 성공!")
    print(f"   경로: {STORAGE_PATH}")
    print(f"   레코드 수: {df_sales.count()}")
    print(f"   컬럼: {df_sales.columns}")
    df_sales.show(5)
except Exception as e:
    print(f"❌ ADLS Gen2 접근 실패: {e}")
    print("   NCC Resource PE (dfs/blob) 설정을 확인하세요.")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1-2. DNS 확인 — Storage + AI Search

# COMMAND ----------

import socket

print("=" * 60)
print("DNS Resolution Check (Resource PE)")
print("=" * 60)

hosts = [
    ("adlsdbrickstest.dfs.core.windows.net", "ADLS Gen2 (dfs)"),
    ("adlsdbrickstest.blob.core.windows.net", "ADLS Gen2 (blob)"),
    ("ais-genai-2025gen005-eus2-adb.search.windows.net", "AI Search #1"),
    ("ais-adb-test-krc01.search.windows.net", "AI Search #2"),
]

for host, label in hosts:
    try:
        ips = socket.getaddrinfo(host, 443, socket.AF_INET)
        ip = ips[0][4][0] if ips else "N/A"
        is_private = ip.startswith("10.") or ip.startswith("172.") or ip.startswith("192.168.")
        marker = "Private" if is_private else "Public"
        print(f"  {label:20s} {host}")
        print(f"  {'':20s} -> {ip} ({marker})")
    except Exception as e:
        print(f"  {label:20s} {host}")
        print(f"  {'':20s} -> FAILED: {e}")
    print()

print("=" * 60)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. 연결 테스트 — 인덱스 정보 확인

# COMMAND ----------

import urllib.request
import json

# 인덱스 정보 조회
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}?api-version={API_VERSION}",
    headers=AUTH_HEADER
)
with urllib.request.urlopen(req, timeout=10) as resp:
    index_info = json.loads(resp.read().decode())
    print(f"✅ 인덱스 연결 성공: {index_info['name']}")
    print(f"   필드 수: {len(index_info['fields'])}")
    for f in index_info['fields']:
        print(f"   - {f['name']} ({f['type']}) {'🔑' if f.get('key') else ''}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. 전체 문서 검색

# COMMAND ----------

# 전체 문서 검색 (search=*)
search_body = json.dumps({"search": "*", "count": True}).encode()
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}/docs/search?api-version={API_VERSION}",
    data=search_body,
    headers={**AUTH_HEADER, "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    results = json.loads(resp.read().decode())
    print(f"✅ 전체 검색 — 문서 수: {results.get('@odata.count', 'N/A')}")
    print()
    for doc in results['value']:
        print(f"  [{doc['id']}] {doc['name']:25s} | {doc['category']:12s} | ₩{doc['price']:,.0f} | {doc['region']}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. 키워드 검색

# COMMAND ----------

# "노트북" 키워드 검색
search_body = json.dumps({
    "search": "노트북",
    "searchFields": "name,description",
    "select": "id,name,description,price,region",
    "count": True
}).encode()
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}/docs/search?api-version={API_VERSION}",
    data=search_body,
    headers={**AUTH_HEADER, "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    results = json.loads(resp.read().decode())
    print(f"🔍 '노트북' 검색 결과: {results.get('@odata.count', 0)}건")
    for doc in results['value']:
        print(f"  [{doc['id']}] {doc['name']} — ₩{doc['price']:,.0f}")
        print(f"       {doc['description']}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. 필터 + 정렬 검색

# COMMAND ----------

# Electronics 카테고리, 가격 내림차순
search_body = json.dumps({
    "search": "*",
    "filter": "category eq 'Electronics'",
    "orderby": "price desc",
    "select": "id,name,price,region",
    "count": True
}).encode()
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}/docs/search?api-version={API_VERSION}",
    data=search_body,
    headers={**AUTH_HEADER, "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    results = json.loads(resp.read().decode())
    print(f"🔍 Electronics 카테고리 (가격 내림차순): {results.get('@odata.count', 0)}건")
    for doc in results['value']:
        print(f"  [{doc['id']}] {doc['name']:25s} | ₩{doc['price']:,.0f} | {doc['region']}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Facet 집계

# COMMAND ----------

# 카테고리/지역별 Facet 집계
search_body = json.dumps({
    "search": "*",
    "facets": ["category", "region"],
    "count": True,
    "top": 0
}).encode()
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}/docs/search?api-version={API_VERSION}",
    data=search_body,
    headers={**AUTH_HEADER, "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    results = json.loads(resp.read().decode())
    print(f"📊 Facet 집계 (전체 {results.get('@odata.count', 0)}건)")
    
    print("\n카테고리별:")
    for f in results.get('@search.facets', {}).get('category', []):
        print(f"  {f['value']:15s} → {f['count']}건")
    
    print("\n지역별:")
    for f in results.get('@search.facets', {}).get('region', []):
        print(f"  {f['value']:15s} → {f['count']}건")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. Spark DataFrame 연동 — 검색 결과를 DataFrame으로

# COMMAND ----------

# AI Search 결과를 Spark DataFrame으로 변환
search_body = json.dumps({"search": "*", "top": 100}).encode()
req = urllib.request.Request(
    f"{SEARCH_ENDPOINT}/indexes/{INDEX_NAME}/docs/search?api-version={API_VERSION}",
    data=search_body,
    headers={**AUTH_HEADER, "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req, timeout=10) as resp:
    results = json.loads(resp.read().decode())

# DataFrame 변환
rows = [{k: v for k, v in doc.items() if not k.startswith('@')} for doc in results['value']]
df_search = spark.createDataFrame(rows)
df_search.show()
df_search.createOrReplaceTempView("search_products")
print(f"✅ DataFrame 생성 완료: {df_search.count()}행")

# COMMAND ----------

# MAGIC %sql
# MAGIC -- AI Search 데이터와 SQL 분석
# MAGIC SELECT 
# MAGIC   category,
# MAGIC   COUNT(*) as product_count,
# MAGIC   ROUND(AVG(price), 2) as avg_price,
# MAGIC   ROUND(SUM(price), 2) as total_value
# MAGIC FROM search_products
# MAGIC GROUP BY category
# MAGIC ORDER BY total_value DESC

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8. AI Search + ADLS Gen2 조인 테스트
# MAGIC
# MAGIC 섹션 1-1에서 로드한 `sales` 뷰와 섹션 7의 `search_products` 뷰를 조인합니다.

# COMMAND ----------

# MAGIC %sql
# MAGIC -- AI Search 상품 마스터 + ADLS Gen2 판매 데이터 조인
# MAGIC SELECT 
# MAGIC   p.name as product_name,
# MAGIC   p.category,
# MAGIC   p.price as list_price,
# MAGIC   s.quantity,
# MAGIC   ROUND(s.quantity * s.price, 2) as revenue,
# MAGIC   s.region as sales_region,
# MAGIC   s.order_date
# MAGIC FROM search_products p
# MAGIC JOIN sales s ON LOWER(p.category) = LOWER(s.category)
# MAGIC WHERE p.price > 100
# MAGIC ORDER BY revenue DESC
# MAGIC LIMIT 20

# COMMAND ----------

# MAGIC %md
# MAGIC ## 9. 네트워크 경로 확인

# COMMAND ----------

import socket

print("=" * 60)
print("🔍 AI Search 네트워크 경로 확인")
print("=" * 60)

# DNS 확인 (두 AI Search 모두)
for search_name, search_url in SEARCH_ENDPOINTS.items():
    host = search_url.replace("https://", "")
    try:
        ips = socket.getaddrinfo(host, 443, socket.AF_INET)
        ip = ips[0][4][0] if ips else "N/A"
        is_private = ip.startswith("10.") or ip.startswith("172.") or ip.startswith("192.168.")
        marker = "Private" if is_private else "Public"
        print(f"\n  {search_name}: {ip} ({marker})")
    except Exception as e:
        print(f"\n  {search_name}: FAILED - {e}")

print(f"\n📋 접근 경로: Resource PE → Azure Backbone → AI Search")
print(f"   고객 VNet(PLS/LB/VM/Firewall)을 경유하지 않음")
print("=" * 60)

# COMMAND ----------

# MAGIC %md
# MAGIC ## ✅ 테스트 결과 요약
# MAGIC
# MAGIC ### Resource PE 연결
# MAGIC | 리소스 | PE group_id | 테스트 | 비고 |
# MAGIC |---|---|---|---|
# MAGIC | ADLS Gen2 (`adlsdbrickstest`) | dfs, blob | ✅ CSV 읽기 성공 | Storage Resource PE |
# MAGIC | AI Search #1 (`ais-genai-...`) | searchService | ✅ 인덱스 조회 성공 | Search Resource PE |
# MAGIC | AI Search #2 (`ais-adb-test-krc01`) | searchService | ✅ 인덱스 조회 성공 | Search Resource PE |
# MAGIC
# MAGIC ### AI Search 기능 테스트
# MAGIC | 테스트 | 예상 결과 | 비고 |
# MAGIC |---|---|---|
# MAGIC | 인덱스 정보 조회 | ✅ 성공 | Resource PE (searchService) 경유 |
# MAGIC | 전체 문서 검색 | ✅ 10건 | search=* |
# MAGIC | 키워드 검색 | ✅ 성공 | "노트북" → Laptop Pro 16 |
# MAGIC | 필터 + 정렬 | ✅ 성공 | Electronics, 가격 내림차순 |
# MAGIC | Facet 집계 | ✅ 성공 | 카테고리/지역별 집계 |
# MAGIC | DataFrame 변환 | ✅ 성공 | Spark SQL 분석 가능 |
# MAGIC | ADLS Gen2 조인 | ✅ 성공 | Search + Storage 크로스 소스 |
# MAGIC | DNS 확인 | Private IP | PE 활성화 시 Private IP resolve |
