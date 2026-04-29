#!/bin/bash
# ============================================================================
# deploy.sh - Azure Databricks Serverless 네트워크 환경 배포 스크립트
# ============================================================================
set -euo pipefail

# ── 설정 ────────────────────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-databricks-networking}"
LOCATION="${LOCATION:-koreacentral}"
DEPLOYMENT_NAME="adb-private-$(date +%Y%m%d-%H%M%S)"

# ── 색상 출력 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── 사전 조건 확인 ──────────────────────────────────────────────────────────
info "사전 조건 확인 중..."
command -v az >/dev/null 2>&1 || error "Azure CLI가 설치되어 있지 않습니다."

# Azure 로그인 확인
az account show >/dev/null 2>&1 || error "Azure에 로그인되어 있지 않습니다. 'az login'을 실행하세요."

SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
info "구독: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# ── SSH 키 확인 ──────────────────────────────────────────────────────────────
if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
  SSH_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
  if [[ -f "${SSH_KEY_PATH}" ]]; then
    export SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}")
    info "SSH 공개키 사용: ${SSH_KEY_PATH}"
  else
    warn "SSH 공개키가 없습니다. 새로 생성합니다..."
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N "" -q
    export SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}")
    ok "SSH 키 생성 완료"
  fi
fi

# ── 리소스 프로바이더 등록 ────────────────────────────────────────────────────
info "리소스 프로바이더 등록 확인 중..."
for ns in Microsoft.Network Microsoft.Databricks Microsoft.Compute; do
  STATE=$(az provider show --namespace "${ns}" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "${STATE}" != "Registered" ]]; then
    warn "${ns} 등록 중..."
    az provider register --namespace "${ns}" --wait
  fi
done
ok "리소스 프로바이더 등록 완료"

# ── 리소스 그룹 생성 ──────────────────────────────────────────────────────────
info "리소스 그룹 생성: ${RESOURCE_GROUP} (${LOCATION})"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none
ok "리소스 그룹 생성 완료"

# ── Bicep 검증 ───────────────────────────────────────────────────────────────
info "Bicep 템플릿 검증 중..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}/../infra"

az deployment group validate \
  --resource-group "${RESOURCE_GROUP}" \
  --template-file "${INFRA_DIR}/main.bicep" \
  --parameters "${INFRA_DIR}/main.bicepparam" \
  --output none
ok "Bicep 검증 통과"

# ── 배포 실행 ────────────────────────────────────────────────────────────────
info "인프라 배포 시작... (20~30분 소요 예상)"
echo ""
echo "  배포 구성 요소:"
echo "    ├─ VNET A (vnet-databricks, 10.0.0.0/16) - Proxy/PLS/LB/Router VM"
echo "    ├─ VNET B (vnet-hub, 10.1.0.0/16) - Azure Firewall"
echo "    ├─ VNet Peering (A ↔ B)"
echo "    ├─ Internal Standard Load Balancer"
echo "    ├─ Private Link Service"
echo "    ├─ Router VM (IP Forwarding + IPTables NAT + NGINX)"
echo "    ├─ Azure Firewall + Policy + Log Analytics"
echo "    └─ Azure Databricks Workspace (Premium)"
echo ""

az deployment group create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${DEPLOYMENT_NAME}" \
  --template-file "${INFRA_DIR}/main.bicep" \
  --parameters "${INFRA_DIR}/main.bicepparam" \
  --output json

# ── 배포 결과 출력 ────────────────────────────────────────────────────────────
echo ""
ok "=========================================="
ok "  인프라 배포 완료!"
ok "=========================================="
echo ""

# 출력 값 가져오기
OUTPUTS=$(az deployment group show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${DEPLOYMENT_NAME}" \
  --query properties.outputs -o json)

FW_PRIVATE_IP=$(echo "${OUTPUTS}" | jq -r '.firewallPrivateIp.value')
FW_PUBLIC_IP=$(echo "${OUTPUTS}" | jq -r '.firewallPublicIp.value')
PLS_RESOURCE_ID=$(echo "${OUTPUTS}" | jq -r '.plsResourceId.value')
PLS_NAME=$(echo "${OUTPUTS}" | jq -r '.plsName.value')
ROUTER_VM1_IP=$(echo "${OUTPUTS}" | jq -r '.routerVm1PrivateIp.value')
ADB_URL=$(echo "${OUTPUTS}" | jq -r '.databricksWorkspaceUrl.value')

echo -e "${CYAN}──────────────────────────────────────────${NC}"
echo -e "  Firewall Private IP : ${GREEN}${FW_PRIVATE_IP}${NC}"
echo -e "  Firewall Public IP  : ${GREEN}${FW_PUBLIC_IP}${NC}"
echo -e "  Router VM #1 IP     : ${GREEN}${ROUTER_VM1_IP}${NC}"
echo -e "  PLS Name            : ${GREEN}${PLS_NAME}${NC}"
echo -e "  Databricks URL      : ${GREEN}https://${ADB_URL}${NC}"
echo -e "${CYAN}──────────────────────────────────────────${NC}"
echo ""
echo -e "  ${YELLOW}PLS Resource ID (NCC에서 사용):${NC}"
echo -e "  ${PLS_RESOURCE_ID}"
echo ""

# ── 다음 단계 안내 ────────────────────────────────────────────────────────────
echo -e "${YELLOW}══════════════════════════════════════════${NC}"
echo -e "${YELLOW}  수동 설정 단계 (아래 순서대로 진행)${NC}"
echo -e "${YELLOW}══════════════════════════════════════════${NC}"
echo ""
echo "  1. Databricks Account Console 접속"
echo "     → https://accounts.azuredatabricks.net/"
echo ""
echo "  2. NCC (Network Connectivity Configuration) 생성"
echo "     → Security > Network connectivity configurations > Add"
echo "     → Name: ncc-databricks-${LOCATION}"
echo "     → Region: ${LOCATION}"
echo ""
echo "  3. Private Endpoint Rule 추가"
echo "     → NCC > Private endpoint rules > Add private endpoint rule"
echo "     → Azure resource ID: ${PLS_RESOURCE_ID}"
echo "     → Domain names: 테스트할 도메인 입력"
echo ""
echo "  4. Private Endpoint 승인"
echo "     → Azure Portal > Private Link services > ${PLS_NAME}"
echo "     → Private endpoint connections > 승인(Approve)"
echo ""
echo "  5. PE 상태 확인 (ESTABLISHED) 및 NCC를 Workspace에 연결"
echo "     → Account Console > Workspaces > Update workspace"
echo "     → NCC 선택 후 Update"
echo ""
echo "  자세한 내용은 README.md를 참조하세요."
echo ""
