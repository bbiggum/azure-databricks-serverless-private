#!/bin/bash
# ============================================================================
# cleanup.sh - 리소스 정리 스크립트
# ============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-databricks-networking}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${RED}══════════════════════════════════════════${NC}"
echo -e "${RED}  리소스 그룹 삭제: ${RESOURCE_GROUP}${NC}"
echo -e "${RED}══════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}이 작업은 되돌릴 수 없습니다!${NC}"
echo ""

read -p "정말 삭제하시겠습니까? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "취소되었습니다."
  exit 0
fi

echo ""
echo -e "${YELLOW}[INFO]${NC} Databricks managed 리소스 그룹도 삭제됩니다..."

# Main resource group
echo -e "${YELLOW}[INFO]${NC} ${RESOURCE_GROUP} 삭제 중..."
az group delete --name "${RESOURCE_GROUP}" --yes --no-wait

# Databricks managed resource group (자동 삭제됨)
MANAGED_RG="rg-databricks-adb-serverless-test-managed"
if az group show --name "${MANAGED_RG}" >/dev/null 2>&1; then
  echo -e "${YELLOW}[INFO]${NC} ${MANAGED_RG} 도 삭제 대기 중 (자동 삭제)..."
fi

echo ""
echo -e "${GREEN}[OK]${NC} 리소스 그룹 삭제가 시작되었습니다. 완료까지 수 분 소요됩니다."
echo "  확인: az group show --name ${RESOURCE_GROUP}"
