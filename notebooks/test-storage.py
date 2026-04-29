# Databricks notebook source
# ============================================================================
# ADB Serverless → ADLS Gen2 Storage 접근 테스트
# ============================================================================
# 목적: NCC Resource-based PE Rule을 통한 Storage Account 접근 검증
#
# 트래픽 흐름 (Resource PE):
#   ADB Serverless → Managed Private Endpoint → Azure Backbone → ADLS Gen2
#   (고객 VNet/Firewall을 거치지 않음)
#
# 사전 조건:
#   - NCC에 dfs/blob Resource PE Rule 추가 + 승인 완료
#   - Storage Credential (sc-test-storage) 생성 완료
#   - External Location (el-test-storage) 생성 완료
#   - Access Connector MI에 Storage Blob Data Contributor 역할 부여
#
# Serverless Compute에서 실행하세요.
# ============================================================================

# COMMAND ----------

# MAGIC %md
# MAGIC # 📦 ADLS Gen2 Storage 접근 테스트
# MAGIC
# MAGIC ## 구성 요약
# MAGIC | 구성 요소 | 값 |
# MAGIC |---|---|
# MAGIC | Storage Account | `adlsdbrickstest` (ADLS Gen2, HNS 활성화) |
# MAGIC | Container | `testdata` |
# MAGIC | 데이터 경로 | `sales/sample_sales.csv` |
# MAGIC | Storage Credential | `sc-test-storage` (Access Connector MI) |
# MAGIC | External Location | `el-test-storage` |
# MAGIC | NCC PE Rules | dfs + blob (ESTABLISHED) |

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. External Location 접근 테스트

# COMMAND ----------

# 1-1. External Location을 통한 직접 파일 읽기
storage_path = "abfss://testdata@adlsdbrickstest.dfs.core.windows.net/sales/sample_sales.csv"

df = spark.read.format("csv") \
    .option("header", "true") \
    .option("inferSchema", "true") \
    .load(storage_path)

print(f"✅ Storage 접근 성공!")
print(f"   레코드 수: {df.count()}")
print(f"   컬럼: {df.columns}")
df.show(5)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. 데이터 분석 쿼리

# COMMAND ----------

# 2-1. 카테고리별 매출 집계
df.createOrReplaceTempView("sales")

# COMMAND ----------

# MAGIC %sql
# MAGIC -- 카테고리별 총 매출
# MAGIC SELECT
# MAGIC   category,
# MAGIC   COUNT(*) as order_count,
# MAGIC   SUM(quantity) as total_qty,
# MAGIC   ROUND(SUM(quantity * price), 2) as total_revenue,
# MAGIC   ROUND(AVG(price), 2) as avg_price
# MAGIC FROM sales
# MAGIC GROUP BY category
# MAGIC ORDER BY total_revenue DESC

# COMMAND ----------

# MAGIC %sql
# MAGIC -- 지역별 매출 Top 5
# MAGIC SELECT
# MAGIC   region,
# MAGIC   COUNT(*) as order_count,
# MAGIC   ROUND(SUM(quantity * price), 2) as total_revenue
# MAGIC FROM sales
# MAGIC GROUP BY region
# MAGIC ORDER BY total_revenue DESC

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. Delta Table로 저장 (쓰기 테스트)

# COMMAND ----------

# 3-1. External Location에 Delta 형식으로 쓰기
delta_path = "abfss://testdata@adlsdbrickstest.dfs.core.windows.net/delta/sales"

df.write.format("delta") \
    .mode("overwrite") \
    .save(delta_path)

print(f"✅ Delta 쓰기 성공: {delta_path}")

# COMMAND ----------

# 3-2. Delta 테이블 다시 읽기
df_delta = spark.read.format("delta").load(delta_path)
print(f"✅ Delta 읽기 성공! 레코드 수: {df_delta.count()}")
df_delta.show(5)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Unity Catalog 테이블 생성 (선택 사항)

# COMMAND ----------

# MAGIC %sql
# MAGIC -- 카탈로그/스키마 생성 (없으면)
# MAGIC CREATE CATALOG IF NOT EXISTS test_catalog;
# MAGIC CREATE SCHEMA IF NOT EXISTS test_catalog.test_schema;

# COMMAND ----------

# MAGIC %sql
# MAGIC -- External Location 기반 테이블 생성
# MAGIC CREATE TABLE IF NOT EXISTS test_catalog.test_schema.sales
# MAGIC USING DELTA
# MAGIC LOCATION 'abfss://testdata@adlsdbrickstest.dfs.core.windows.net/delta/sales';
# MAGIC
# MAGIC SELECT * FROM test_catalog.test_schema.sales LIMIT 5;

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. 네트워크 경로 확인

# COMMAND ----------

# Resource PE 경로는 Azure 백본을 통해 직접 연결됩니다.
# Domain PE (ifconfig.me 등)와 다르게 고객 VNet/Firewall을 거치지 않습니다.

import subprocess

print("=" * 60)
print("🔍 네트워크 경로 비교")
print("=" * 60)

# Storage endpoint DNS 확인
print("\n📡 Storage DNS 확인:")
try:
    import socket
    for host in ["adlsdbrickstest.dfs.core.windows.net", "adlsdbrickstest.blob.core.windows.net"]:
        ips = socket.getaddrinfo(host, 443, socket.AF_INET)
        ip = ips[0][4][0] if ips else "N/A"
        is_private = ip.startswith("10.") or ip.startswith("172.") or ip.startswith("192.168.")
        marker = "🔒 Private" if is_private else "🌐 Public"
        print(f"  {host} → {ip} ({marker})")
except Exception as e:
    print(f"  DNS 조회 실패: {e}")

# 비교: Domain PE 경유 트래픽 (Firewall IP 확인)
print("\n🌐 Domain PE 경유 (Firewall) IP 확인:")
try:
    import urllib.request
    req = urllib.request.Request("https://ifconfig.me", headers={"User-Agent": "curl/7.68.0"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        public_ip = resp.read().decode().strip()
        print(f"  Outbound IP: {public_ip}")
        if public_ip == "20.249.61.72":
            print("  ✅ Azure Firewall 경유 확인됨")
except Exception as e:
    print(f"  ❌ 접근 불가: {e}")
    print("  (Network Policy deny-all에 의해 차단될 수 있음)")

print("\n" + "=" * 60)
print("📋 결론:")
print("  - Storage 접근: Resource PE → Azure Backbone (직접)")
print("  - 인터넷 접근: Domain PE → PLS → LB → VM → Firewall")
print("=" * 60)

# COMMAND ----------

# MAGIC %md
# MAGIC ## ✅ 테스트 결과 요약
# MAGIC
# MAGIC | 테스트 | 예상 결과 | 비고 |
# MAGIC |---|---|---|
# MAGIC | CSV 읽기 | ✅ 성공 | Resource PE (dfs) 경유 |
# MAGIC | SQL 집계 | ✅ 성공 | Serverless SQL |
# MAGIC | Delta 쓰기 | ✅ 성공 | Resource PE (blob+dfs) 경유 |
# MAGIC | Delta 읽기 | ✅ 성공 | Resource PE (dfs) 경유 |
# MAGIC | UC 테이블 | ✅ 성공 | External Location 기반 |
# MAGIC | DNS 확인 | Private IP | PE가 활성화되면 Private IP로 resolve |
