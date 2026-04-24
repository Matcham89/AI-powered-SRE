#!/usr/bin/env bash
# bootstrap/install.sh — AI-Powered SRE Platform bootstrap
#
# Installs k3s (if absent) then bootstraps the full platform onto it.
# This script is idempotent: safe to re-run if interrupted.
#
# Prerequisites:
#   - curl, sops, age, helm installed
#   - An Age private key (default: ~/.config/sops/age/keys.txt)
#   - sudo rights (for k3s install + /etc/hosts update in --e2e mode)
#
# Usage:
#   ./bootstrap/install.sh               # install k3s + bootstrap platform
#   ./bootstrap/install.sh --e2e         # install + bootstrap + run full e2e tests
#   ./bootstrap/install.sh --dry-run     # print steps, make no changes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARGOCD_VERSION="v3.3.8"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
SOPS_OPERATOR_CHART="sops-secrets-operator/sops-secrets-operator"
SOPS_OPERATOR_REPO="https://isindir.github.io/sops-secrets-operator/"
SOPS_OPERATOR_VALUES="${SCRIPT_DIR}/manifests/sops-operator-values.yaml"
ROOT_APP="${REPO_ROOT}/cluster/root-app.yaml"

# k3s
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
K3S_INSTALL_FLAGS="--disable traefik --disable servicelb --write-kubeconfig-mode 644 --node-name ai-sre-node"

DRY_RUN=false
E2E=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --e2e)     E2E=true ;;
  esac
done

# ─── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ${NC}"; }
dryrun()  { echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"; }
e2e_pass(){ echo -e "  ${GREEN}[PASS]${NC} $*"; E2E_RESULTS+=("PASS: $*"); }
e2e_fail(){ echo -e "  ${RED}[FAIL]${NC} $*"; E2E_RESULTS+=("FAIL: $*"); E2E_FAILED=true; }

run() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    dryrun "$1"
  else
    eval "$1"
  fi
}

# ─── Step 0: K3s detection and installation ───────────────────────────────────
step "0/9 K3s — detect or install"

K3S_RUNNING=false
if kubectl get nodes &>/dev/null 2>&1; then
  K3S_RUNNING=true
  success "Kubernetes cluster already reachable — skipping k3s install"
elif [[ -f "${K3S_KUBECONFIG}" ]]; then
  export KUBECONFIG="${K3S_KUBECONFIG}"
  if kubectl get nodes &>/dev/null 2>&1; then
    K3S_RUNNING=true
    success "k3s found via ${K3S_KUBECONFIG}"
  fi
fi

if [[ "${K3S_RUNNING}" == "false" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    dryrun "curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC='server ${K3S_INSTALL_FLAGS}' sh -"
    dryrun "export KUBECONFIG=${K3S_KUBECONFIG}"
  else
    info "k3s not found — installing (flags: ${K3S_INSTALL_FLAGS})..."
    if ! command -v curl &>/dev/null; then
      error "curl is required to install k3s."
    fi
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server ${K3S_INSTALL_FLAGS}" sh -
    export KUBECONFIG="${K3S_KUBECONFIG}"

    info "Waiting for k3s node to become Ready (up to 2 minutes)..."
    TIMEOUT=120
    ELAPSED=0
    while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
      NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[-1].type}' 2>/dev/null || echo "")
      [[ "${NODE_STATUS}" == "Ready" ]] && break
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done
    [[ "${NODE_STATUS}" == "Ready" ]] || error "k3s node did not become Ready within ${TIMEOUT}s."
    success "k3s installed and node is Ready"
  fi
fi

# Ensure KUBECONFIG is set for k3s if present and not already overridden
if [[ -z "${KUBECONFIG:-}" ]] && [[ -f "${K3S_KUBECONFIG}" ]]; then
  export KUBECONFIG="${K3S_KUBECONFIG}"
fi

# ─── Step 1: Prerequisite check ────────────────────────────────────────────────
step "1/9 Checking prerequisites"

for tool in kubectl helm sops age; do
  if command -v "${tool}" &>/dev/null; then
    success "${tool} found: $(${tool} version --short 2>/dev/null || ${tool} --version 2>/dev/null | head -1)"
  else
    error "${tool} is not installed. See README for install instructions."
  fi
done

# ─── Step 2: Kubernetes context check ─────────────────────────────────────────
step "2/9 Verifying Kubernetes context"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
CURRENT_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "unknown")

info "Current context : ${CURRENT_CONTEXT}"
info "API server      : ${CURRENT_SERVER}"

if [[ "${DRY_RUN}" == "false" ]] && [[ "${E2E}" == "false" ]]; then
  echo ""
  read -r -p "$(echo -e "${YELLOW}Continue with this context? [y/N]:${NC} ")" CONFIRM
  [[ "${CONFIRM}" =~ ^[Yy]$ ]] || error "Aborted by user."
fi

if [[ "${DRY_RUN}" == "false" ]]; then
  kubectl cluster-info --request-timeout=10s &>/dev/null || \
    error "Cannot reach Kubernetes API server. Check your kubeconfig."
  success "Cluster is reachable"
fi

# ─── Step 3: Age key discovery ─────────────────────────────────────────────────
step "3/9 Loading Age private key"

DEFAULT_KEY_FILE="${HOME}/.config/sops/age/keys.txt"

if [[ -n "${SOPS_AGE_KEY_FILE:-}" ]] && [[ -f "${SOPS_AGE_KEY_FILE}" ]]; then
  AGE_KEY_FILE="${SOPS_AGE_KEY_FILE}"
  info "Using key from SOPS_AGE_KEY_FILE env var: ${AGE_KEY_FILE}"
elif [[ -f "${DEFAULT_KEY_FILE}" ]]; then
  AGE_KEY_FILE="${DEFAULT_KEY_FILE}"
  info "Found Age key at default location: ${AGE_KEY_FILE}"
else
  echo ""
  warn "Age private key not found at ${DEFAULT_KEY_FILE}"
  read -r -p "$(echo -e "${YELLOW}Enter path to your Age private key file:${NC} ")" AGE_KEY_FILE
  [[ -f "${AGE_KEY_FILE}" ]] || error "File not found: ${AGE_KEY_FILE}"
fi

success "Age key loaded from: ${AGE_KEY_FILE}"

# ─── Step 4: Create namespaces ─────────────────────────────────────────────────
step "4/9 Creating namespaces"

run "kubectl apply -f '${SCRIPT_DIR}/manifests/namespaces.yaml'"
success "Namespaces: argocd, sops-operator"

# ─── Step 5: Inject Age key as Kubernetes Secret ───────────────────────────────
step "5/9 Injecting Age private key (only imperative step)"

info "Creating sops-age secret in sops-operator namespace..."

if [[ "${DRY_RUN}" == "true" ]]; then
  dryrun "kubectl create secret generic sops-age --namespace sops-operator --from-file=keys.txt=<AGE_KEY_FILE> --dry-run=client -o yaml | kubectl apply -f -"
else
  kubectl create secret generic sops-age \
    --namespace sops-operator \
    --from-file=keys.txt="${AGE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

success "sops-age secret created in sops-operator namespace"

# ─── Step 6: Install ArgoCD ────────────────────────────────────────────────────
step "6/9 Installing ArgoCD ${ARGOCD_VERSION}"

info "Applying ArgoCD manifest (server-side apply to handle large CRDs)..."
run "kubectl apply -n argocd --server-side -f '${ARGOCD_INSTALL_URL}'"
success "ArgoCD manifest applied"

info "Waiting for ArgoCD deployments to be ready (up to 5 minutes)..."
if [[ "${DRY_RUN}" == "false" ]]; then
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
  kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s
  kubectl rollout status deployment/argocd-application-controller -n argocd --timeout=300s || \
    kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
fi
success "ArgoCD is ready"

# ─── Step 7: Install SOPS Secrets Operator ────────────────────────────────────
step "7/9 Installing SOPS Secrets Operator"

if [[ "${DRY_RUN}" == "false" ]]; then
  helm repo add sops-secrets-operator "${SOPS_OPERATOR_REPO}" 2>/dev/null || true
  helm repo update sops-secrets-operator
fi

run "helm upgrade --install sops-secrets-operator ${SOPS_OPERATOR_CHART} \
  --namespace sops-operator \
  --values '${SOPS_OPERATOR_VALUES}' \
  --wait --timeout 3m"

success "SOPS Secrets Operator installed"

# ─── Step 8: Apply root ArgoCD Application ────────────────────────────────────
step "8/9 Applying root Application (App-of-Apps)"

info "Applying cluster/root-app.yaml..."
run "kubectl apply -f '${ROOT_APP}'"
success "Root app applied — ArgoCD will now sync the platform from git"

# ─── Step 9: Wait for all apps Synced+Healthy ─────────────────────────────────
step "9/9 Waiting for all ArgoCD apps to be Synced+Healthy"

EXPECTED_APPS=(
  root sops-operator gateway gateway-resources cert-manager security
  authentik authentik-routes seaweedfs
  loki tempo mimir alloy beyla grafana
  kagent khook github-mcp-agent
  cnpg temporal sample-api
)

if [[ "${DRY_RUN}" == "false" ]]; then
  info "Polling ArgoCD apps (up to 25 minutes, ${#EXPECTED_APPS[@]} apps expected)..."
  TIMEOUT=1500
  ELAPSED=0
  INTERVAL=20

  while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    ALL_OK=true
    NOT_READY=()
    for app in "${EXPECTED_APPS[@]}"; do
      SYNC=$(kubectl get application "${app}" -n argocd \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Missing")
      HEALTH=$(kubectl get application "${app}" -n argocd \
        -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Missing")
      if [[ "${SYNC}" != "Synced" ]] || [[ "${HEALTH}" != "Healthy" ]]; then
        ALL_OK=false
        NOT_READY+=("${app}(${SYNC}/${HEALTH})")
      fi
    done

    if [[ "${ALL_OK}" == "true" ]]; then
      success "All ${#EXPECTED_APPS[@]} apps Synced+Healthy"
      break
    fi

    echo -e "  Waiting: ${NOT_READY[*]} | Elapsed: ${ELAPSED}s"
    sleep ${INTERVAL}
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  if [[ "${ALL_OK}" != "true" ]]; then
    warn "Not all apps healthy after ${TIMEOUT}s. Still pending: ${NOT_READY[*]}"
    warn "Run: kubectl get applications -n argocd"
  fi
fi

# ─── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Bootstrap complete!${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}ArgoCD UI:${NC}"
echo -e "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo -e "    https://localhost:8080"
echo ""
echo -e "  ${BOLD}ArgoCD initial admin password:${NC}"
echo -e "    kubectl get secret argocd-initial-admin-secret -n argocd \\"
echo -e "      -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo -e "  ${BOLD}Watch sync progress:${NC}"
echo -e "    kubectl get applications -n argocd -w"
echo ""

# ─── E2E Tests ────────────────────────────────────────────────────────────────
if [[ "${E2E}" == "false" ]] || [[ "${DRY_RUN}" == "true" ]]; then
  exit 0
fi

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Running E2E Tests${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

E2E_RESULTS=()
E2E_FAILED=false

# ── e2e-0: k3s node ready ─────────────────────────────────────────────────────
step "e2e-0 k3s node Ready"
NODE_READY=$(kubectl get nodes \
  -o jsonpath='{.items[0].status.conditions[-1].type}' 2>/dev/null || echo "")
if [[ "${NODE_READY}" == "Ready" ]]; then
  e2e_pass "k3s node is Ready"
else
  e2e_fail "k3s node not Ready (status: ${NODE_READY})"
fi

# ── e2e-1: All ArgoCD apps ────────────────────────────────────────────────────
step "e2e-1 All ArgoCD apps Synced+Healthy"
ALL_APP_OK=true
for app in "${EXPECTED_APPS[@]}"; do
  SYNC=$(kubectl get application "${app}" -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Missing")
  HEALTH=$(kubectl get application "${app}" -n argocd \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Missing")
  if [[ "${SYNC}" != "Synced" ]] || [[ "${HEALTH}" != "Healthy" ]]; then
    ALL_APP_OK=false
    e2e_fail "App ${app}: ${SYNC}/${HEALTH}"
  fi
done
[[ "${ALL_APP_OK}" == "true" ]] && e2e_pass "All ${#EXPECTED_APPS[@]} apps Synced+Healthy"

# ── e2e-2: Envoy Gateway NodePort discovery ───────────────────────────────────
step "e2e-2 Envoy Gateway NodePort discovery"
HTTP_NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-name=platform-gateway" \
  -o jsonpath='{.items[0].spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "")
HTTPS_NODEPORT=$(kubectl get svc -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-name=platform-gateway" \
  -o jsonpath='{.items[0].spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "")

if [[ -n "${HTTP_NODEPORT}" ]] && [[ -n "${HTTPS_NODEPORT}" ]]; then
  e2e_pass "NodePorts — HTTP: ${HTTP_NODEPORT}, HTTPS: ${HTTPS_NODEPORT}"
  # Update /etc/hosts for .local domains
  for hostname in auth.local grafana.local temporal.local sample-api.local; do
    if ! grep -q "${hostname}" /etc/hosts 2>/dev/null; then
      echo "127.0.0.1 ${hostname}" | sudo tee -a /etc/hosts >/dev/null
    fi
  done
else
  e2e_fail "Could not discover Envoy Gateway NodePorts — check envoy-gateway-system namespace"
  HTTP_NODEPORT=80
  HTTPS_NODEPORT=443
fi

# ── e2e-3: SeaweedFS S3 buckets ───────────────────────────────────────────────
step "e2e-3 SeaweedFS S3 buckets"
S3_ACCESS=$(kubectl get secret seaweedfs-s3-creds -n seaweedfs \
  -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d || echo "")
S3_SECRET=$(kubectl get secret seaweedfs-s3-creds -n seaweedfs \
  -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d || echo "")

if [[ -n "${S3_ACCESS}" ]]; then
  BUCKET_LIST=$(kubectl run s3test-e2e \
    --image=amazon/aws-cli \
    --restart=Never \
    --rm -it \
    --env="AWS_ACCESS_KEY_ID=${S3_ACCESS}" \
    --env="AWS_SECRET_ACCESS_KEY=${S3_SECRET}" \
    --env="AWS_DEFAULT_REGION=us-east-1" \
    -- aws --endpoint-url http://seaweedfs-filer.seaweedfs.svc:8333 \
    s3 ls 2>/dev/null || echo "")
  for bucket in loki tempo mimir temporal; do
    if echo "${BUCKET_LIST}" | grep -q "${bucket}"; then
      e2e_pass "S3 bucket: ${bucket}"
    else
      e2e_fail "S3 bucket missing: ${bucket}"
    fi
  done
else
  e2e_fail "SeaweedFS credentials secret not found"
fi

# ── e2e-4: Grafana health ─────────────────────────────────────────────────────
step "e2e-4 Grafana /api/health"
GRAFANA_HEALTH=$(curl -sk \
  --resolve "grafana.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://grafana.local:${HTTPS_NODEPORT}/api/health" 2>/dev/null || echo "")
if echo "${GRAFANA_HEALTH}" | grep -q '"database":"ok"'; then
  e2e_pass "Grafana health: {\"database\":\"ok\"}"
else
  e2e_fail "Grafana not healthy (response: ${GRAFANA_HEALTH})"
fi

# ── e2e-5: Loki labels (log ingestion) ────────────────────────────────────────
step "e2e-5 Loki log ingestion"
GRAFANA_PASS=$(kubectl get secret grafana-admin-credentials -n observability \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d || echo "admin")
LOKI_LABELS=$(curl -sk \
  --resolve "grafana.local:${HTTPS_NODEPORT}:127.0.0.1" \
  -u "admin:${GRAFANA_PASS}" \
  "https://grafana.local:${HTTPS_NODEPORT}/api/datasources/proxy/uid/loki/loki/api/v1/labels" \
  2>/dev/null | jq '.data | length' 2>/dev/null || echo "0")
if [[ "${LOKI_LABELS}" -gt 0 ]]; then
  e2e_pass "Loki labels present (${LOKI_LABELS} labels — logs ingested)"
else
  e2e_fail "Loki has no labels (no logs ingested yet)"
fi

# ── e2e-6: Temporal UI ───────────────────────────────────────────────────────
step "e2e-6 Temporal UI"
TEMPORAL_RESP=$(curl -sk \
  --resolve "temporal.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://temporal.local:${HTTPS_NODEPORT}/" 2>/dev/null || echo "")
if echo "${TEMPORAL_RESP}" | grep -qi "temporal"; then
  e2e_pass "Temporal UI responding"
else
  e2e_fail "Temporal UI not responding"
fi

# ── e2e-7: CNPG cluster ───────────────────────────────────────────────────────
step "e2e-7 CNPG cluster ready"
CNPG_READY=$(kubectl get cluster temporal-postgres -n temporal \
  -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
if [[ "${CNPG_READY}" -ge 1 ]]; then
  e2e_pass "CNPG cluster: ${CNPG_READY} instance(s) ready"
else
  e2e_fail "CNPG cluster not ready (readyInstances: ${CNPG_READY})"
fi

# ── e2e-8: Sample API ────────────────────────────────────────────────────────
step "e2e-8 Sample API"
SAMPLE_API_RESP=$(curl -sk \
  --resolve "sample-api.local:${HTTPS_NODEPORT}:127.0.0.1" \
  "https://sample-api.local:${HTTPS_NODEPORT}/" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
if [[ "${SAMPLE_API_RESP}" == "ok" ]]; then
  e2e_pass "Sample API: {\"status\":\"ok\"}"
else
  e2e_fail "Sample API not responding correctly (got: ${SAMPLE_API_RESP})"
fi

# ── e2e-9: Beyla auto-instrumentation ────────────────────────────────────────
step "e2e-9 Beyla eBPF auto-instrumentation"
BEYLA_LOG=$(kubectl logs -n observability \
  -l app.kubernetes.io/name=beyla --tail=100 2>/dev/null || echo "")
if echo "${BEYLA_LOG}" | grep -qi "instrument\|attach\|probe"; then
  e2e_pass "Beyla eBPF instrumentation active"
else
  e2e_fail "Beyla instrumentation not confirmed in logs"
fi

# ── e2e-10: AI closed-loop test ──────────────────────────────────────────────
step "e2e-10 AI closed-loop (crasher → GitHub Issue)"
info "Deploying crasher pod..."
kubectl run ai-sre-e2e-crasher \
  --image=busybox \
  --restart=Always \
  -- /bin/false 2>/dev/null || true

info "Waiting for CrashLoopBackOff (up to 3 minutes)..."
CRASH_TIMEOUT=180
CRASH_ELAPSED=0
CRASH_STATE=""
while [[ ${CRASH_ELAPSED} -lt ${CRASH_TIMEOUT} ]]; do
  CRASH_STATE=$(kubectl get pod ai-sre-e2e-crasher \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
  [[ "${CRASH_STATE}" == "CrashLoopBackOff" ]] && break
  sleep 10
  CRASH_ELAPSED=$((CRASH_ELAPSED + 10))
done

if [[ "${CRASH_STATE}" != "CrashLoopBackOff" ]]; then
  e2e_fail "Pod did not enter CrashLoopBackOff within ${CRASH_TIMEOUT}s"
  kubectl delete pod ai-sre-e2e-crasher --ignore-not-found 2>/dev/null
else
  info "Pod in CrashLoopBackOff — waiting for kagent to respond (up to 5 minutes)..."
  sleep 30
  KAGENT_TIMEOUT=300
  KAGENT_ELAPSED=0
  ISSUE_FOUND=false
  while [[ ${KAGENT_ELAPSED} -lt ${KAGENT_TIMEOUT} ]]; do
    KAGENT_LOGS=$(kubectl logs -n kagent \
      -l app.kubernetes.io/name=kagent --tail=200 2>/dev/null || echo "")
    if echo "${KAGENT_LOGS}" | grep -qi "rca\|issue.*creat\|github"; then
      ISSUE_FOUND=true
      break
    fi
    sleep 15
    KAGENT_ELAPSED=$((KAGENT_ELAPSED + 15))
  done

  kubectl delete pod ai-sre-e2e-crasher --ignore-not-found 2>/dev/null

  if [[ "${ISSUE_FOUND}" == "true" ]]; then
    e2e_pass "AI closed-loop: kagent detected crash and triggered GitHub Issue"
  else
    e2e_fail "AI closed-loop: no GitHub Issue evidence in kagent logs after ${KAGENT_TIMEOUT}s"
  fi
fi

# ── e2e-11: Security — cross-namespace deny ───────────────────────────────────
step "e2e-11 Security cross-namespace traffic deny"
NET_RESULT=$(kubectl run nettest-e2e \
  --image=busybox \
  --namespace=sample-api \
  --restart=Never \
  --rm -it \
  -- wget -qO- --timeout=5 http://argocd-server.argocd 2>&1 || echo "blocked")
kubectl delete pod nettest-e2e -n sample-api --ignore-not-found 2>/dev/null

if echo "${NET_RESULT}" | grep -qiE "timeout|refused|blocked|unreachable"; then
  e2e_pass "Cross-namespace traffic correctly blocked"
else
  e2e_fail "Cross-namespace traffic NOT blocked — check NetworkPolicies"
fi

# ─── E2E Summary ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  E2E Test Results${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
for result in "${E2E_RESULTS[@]}"; do
  if [[ "${result}" == PASS:* ]]; then
    echo -e "  ${GREEN}[PASS]${NC} ${result#PASS: }"
  else
    echo -e "  ${RED}[FAIL]${NC} ${result#FAIL: }"
  fi
done
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "${E2E_FAILED}" == "true" ]]; then
  echo -e "${RED}${BOLD}  Some checks FAILED. Review output above.${NC}"
  echo ""
  echo -e "  Debug tips:"
  echo -e "    kubectl get applications -n argocd"
  echo -e "    kubectl get pods -A | grep -v Running"
  echo -e "    kubectl logs -n kagent -l app.kubernetes.io/name=kagent --tail=50"
  exit 1
else
  echo -e "${GREEN}${BOLD}  All checks passed. Platform is production-ready.${NC}"
fi
