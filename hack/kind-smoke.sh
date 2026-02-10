#!/usr/bin/env bash

# Simple local smoke test for the headscale Helm chart using kind.
# The script creates a temporary kind cluster (unless one already exists),
# installs the chart with extra DNS records enabled, and verifies that
# headscale renders dns.extra_records_path correctly. The cluster is deleted
# on success unless --keep is supplied or the cluster pre-existed.

set -euo pipefail

ROOT_DIR=$(
  cd -- "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd -P
)

CLUSTER_NAME="headscale-kind"
KEEP_CLUSTER=0
WITH_CLIENT=0
WITH_TAILNET_SERVICES=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --cluster-name NAME   Override kind cluster name (default: ${CLUSTER_NAME})
  --keep                Do not delete the cluster after the test finishes
  --with-client         Enable the optional Tailscale client with advertiseRoutes
  --with-tailnet-services  Enable tailnet services proxy with a smoke-test service
  -h, --help            Show this help message

Environment variables:
  KIND_CLUSTER_NAME     Alternative way to set --cluster-name
  KEEP_CLUSTER          When set to 1, behaves like --keep
  WITH_CLIENT           When set to 1, behaves like --with-client
  WITH_TAILNET_SERVICES When set to 1, behaves like --with-tailnet-services
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name)
      [[ $# -ge 2 ]] || { echo "Missing value for --cluster-name" >&2; exit 1; }
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --keep)
      KEEP_CLUSTER=1
      shift
      ;;
    --with-client)
      WITH_CLIENT=1
      shift
      ;;
    --with-tailnet-services)
      WITH_TAILNET_SERVICES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

CLUSTER_NAME=${KIND_CLUSTER_NAME:-$CLUSTER_NAME}
if [[ ${KEEP_CLUSTER:-0} -eq 1 ]]; then
  KEEP_CLUSTER=1
fi
if [[ ${WITH_CLIENT:-0} -eq 1 ]]; then
  WITH_CLIENT=1
fi
if [[ ${WITH_TAILNET_SERVICES:-0} -eq 1 ]]; then
  WITH_TAILNET_SERVICES=1
fi

for bin in kind kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "Missing dependency: $bin" >&2
    exit 1
  fi
done

CREATED_CLUSTER=0
if kind get clusters | grep -qx "$CLUSTER_NAME"; then
  echo "[kind] Reusing existing cluster '$CLUSTER_NAME'"
else
  echo "[kind] Creating cluster '$CLUSTER_NAME'"
  kind create cluster --name "$CLUSTER_NAME" --wait 90s
  CREATED_CLUSTER=1
fi

KUBECTL_CONTEXT="kind-${CLUSTER_NAME}"
kubectl config use-context "$KUBECTL_CONTEXT" >/dev/null

TMP_VALUES=$(mktemp)
cleanup() {
  rm -f "$TMP_VALUES"
  if [[ $CREATED_CLUSTER -eq 1 && $KEEP_CLUSTER -eq 0 ]]; then
    echo "[kind] Deleting cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME"
  elif [[ $KEEP_CLUSTER -eq 1 ]]; then
    echo "[kind] Cluster '$CLUSTER_NAME' retained (--keep set)"
  else
    echo "[kind] Cluster '$CLUSTER_NAME' pre-existed; leaving untouched"
  fi
}
trap cleanup EXIT

cat <<EOF >"$TMP_VALUES"
extraDnsRecords:
  enabled: true
  records:
    - name: smoke.internal.test
      type: A
      value: 100.64.0.42
EOF

if [[ $WITH_CLIENT -eq 1 ]]; then
  cat <<'EOF' >>"$TMP_VALUES"
client:
  enabled: true
  advertiseRoutes:
    - "10.99.0.0/24"
EOF
else
  cat <<'EOF' >>"$TMP_VALUES"
client:
  enabled: false
EOF
fi

if [[ $WITH_TAILNET_SERVICES -eq 1 ]]; then
  cat <<'EOF' >>"$TMP_VALUES"
tailnetServices:
  enabled: true
  services:
    - name: smoke-test-svc
      hostname: "smoke.tailnet.test"
      targetHost: "100.64.0.99"
      ports:
        - name: http
          port: 8080
        - name: https
          port: 8443
    - name: smoke-test-svc2
      hostname: "smoke2.tailnet.test"
      targetHost: "100.64.0.100"
      ports:
        - name: https
          port: 8443
EOF
fi

if helm status headscale -n headscale >/dev/null 2>&1; then
  echo "[helm] Existing headscale release detected; uninstalling"
  helm uninstall headscale -n headscale --wait || true
fi

echo "[helm] Installing headscale chart into namespace 'headscale'"
helm upgrade --install headscale "$ROOT_DIR/headscale" \
  --namespace headscale \
  --create-namespace \
  --wait \
  --timeout 10m \
  -f "$TMP_VALUES"

echo "[kubectl] Checking deployment readiness"
kubectl rollout status deployment/headscale -n headscale --timeout=2m

if [[ $WITH_CLIENT -eq 1 ]]; then
  echo "[kubectl] Waiting for client auth secret to appear"
  for _ in $(seq 1 40); do
    if kubectl get secret headscale-client-authkey -n headscale >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done
  if ! kubectl get secret headscale-client-authkey -n headscale >/dev/null 2>&1; then
    echo "[WARN] headscale-client-authkey secret not found; tailscale client login may fail"
  fi
  echo "[kubectl] Checking client deployment readiness"
  kubectl rollout status deployment/headscale-client -n headscale --timeout=3m
fi

echo "[verify] Ensuring extra_records_path is present in rendered config"
CONFIG_YAML=$(kubectl get configmap headscale -n headscale -o jsonpath='{.data.config\.yaml}')
if ! grep -q 'extra_records_path: /etc/headscale/extra-dns-records.json' <<<"$CONFIG_YAML"; then
  echo "[ERROR] extra_records_path entry missing in config.yaml" >&2
  exit 1
fi

echo "[verify] Ensuring extra DNS ConfigMap contains our record"
EXTRA_JSON=$(kubectl get configmap headscale-extra-dns -n headscale -o jsonpath='{.data.extra-dns-records\.json}')
if ! grep -q 'smoke.internal.test' <<<"$EXTRA_JSON"; then
  echo "[ERROR] Expected DNS record not found in headscale-extra-dns ConfigMap" >&2
  exit 1
fi

if [[ $WITH_CLIENT -eq 1 ]]; then
  echo "[verify] Ensuring client pod includes tailscaled container"
  if ! kubectl get pods -n headscale -l app.kubernetes.io/component=client -o jsonpath='{.items[0].spec.containers[0].name}' | grep -q 'tailscale'; then
    echo "[ERROR] Tailscale container not found in client deployment" >&2
    exit 1
  fi

  echo "[verify] Ensuring policy ConfigMap exists with autoApprovers"
  POLICY_JSON=$(kubectl get configmap headscale-policy -n headscale -o jsonpath='{.data.policy\.json}')
  if ! grep -q 'autoApprovers' <<<"$POLICY_JSON"; then
    echo "[ERROR] autoApprovers not found in policy ConfigMap" >&2
    exit 1
  fi
  if ! grep -q '10.99.0.0/24' <<<"$POLICY_JSON"; then
    echo "[ERROR] Expected route 10.99.0.0/24 not found in policy ConfigMap" >&2
    exit 1
  fi
  if ! grep -q 'tag:in-cluster-client' <<<"$POLICY_JSON"; then
    echo "[ERROR] Expected tag:in-cluster-client not found in policy ConfigMap" >&2
    exit 1
  fi

  echo "[verify] Ensuring policy.path is set in headscale config"
  if ! grep -q 'path: /etc/headscale/policy.json' <<<"$CONFIG_YAML"; then
    echo "[ERROR] policy.path not found in config.yaml" >&2
    exit 1
  fi
fi

if [[ $WITH_TAILNET_SERVICES -eq 1 ]]; then
  echo "[kubectl] Waiting for proxy auth key secret to appear"
  for _ in $(seq 1 40); do
    if kubectl get secret headscale-proxy-authkey -n headscale >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done
  if ! kubectl get secret headscale-proxy-authkey -n headscale >/dev/null 2>&1; then
    echo "[WARN] headscale-proxy-authkey secret not found; tailnet proxy login may fail"
  fi

  echo "[kubectl] Checking tailnet-proxy deployment readiness"
  kubectl rollout status deployment/headscale-tailnet-proxy -n headscale --timeout=3m

  echo "[verify] Ensuring Envoy ConfigMap contains SNI listener for shared port"
  ENVOY_CONFIG=$(kubectl get configmap headscale-tailnet-proxy -n headscale -o jsonpath='{.data.envoy\.yaml}')
  if ! grep -q 'tls-passthrough-8443' <<<"$ENVOY_CONFIG"; then
    echo "[ERROR] Expected SNI listener tls-passthrough-8443 not found in Envoy ConfigMap" >&2
    exit 1
  fi
  if ! grep -q 'smoke-test-svc-http' <<<"$ENVOY_CONFIG"; then
    echo "[ERROR] Expected simple listener smoke-test-svc-http not found in Envoy ConfigMap" >&2
    exit 1
  fi

  echo "[verify] Ensuring Envoy ConfigMap contains server_names for both hostnames"
  if ! grep -q 'smoke.tailnet.test' <<<"$ENVOY_CONFIG"; then
    echo "[ERROR] Expected server_names entry for smoke.tailnet.test not found in Envoy ConfigMap" >&2
    exit 1
  fi
  if ! grep -q 'smoke2.tailnet.test' <<<"$ENVOY_CONFIG"; then
    echo "[ERROR] Expected server_names entry for smoke2.tailnet.test not found in Envoy ConfigMap" >&2
    exit 1
  fi

  echo "[verify] Ensuring K8s Service for smoke-test-svc exists with both ports"
  SVC_JSON=$(kubectl get service headscale-ts-smoke-test-svc -n headscale -o json)
  if ! echo "$SVC_JSON" | grep -q '"http"'; then
    echo "[ERROR] Expected port 'http' not found in service headscale-ts-smoke-test-svc" >&2
    exit 1
  fi
  if ! echo "$SVC_JSON" | grep -q '"https"'; then
    echo "[ERROR] Expected port 'https' not found in service headscale-ts-smoke-test-svc" >&2
    exit 1
  fi

  echo "[verify] Ensuring K8s Service for smoke-test-svc2 exists"
  if ! kubectl get service headscale-ts-smoke-test-svc2 -n headscale >/dev/null 2>&1; then
    echo "[ERROR] Expected service headscale-ts-smoke-test-svc2 not found" >&2
    exit 1
  fi

  echo "[verify] Ensuring DNS ConfigMap contains rewrite rules for both services"
  DNS_SNIPPET=$(kubectl get configmap headscale-tailnet-dns -n headscale -o jsonpath='{.data.tailnet-services\.snippet}')
  if ! grep -q 'smoke.tailnet.test' <<<"$DNS_SNIPPET"; then
    echo "[ERROR] Expected rewrite rule for smoke.tailnet.test not found in DNS ConfigMap" >&2
    exit 1
  fi
  if ! grep -q 'smoke2.tailnet.test' <<<"$DNS_SNIPPET"; then
    echo "[ERROR] Expected rewrite rule for smoke2.tailnet.test not found in DNS ConfigMap" >&2
    exit 1
  fi

  echo "[verify] Ensuring proxy pod has both containers (tailscale + envoy)"
  PROXY_CONTAINERS=$(kubectl get pods -n headscale -l app.kubernetes.io/component=tailnet-proxy -o jsonpath='{.items[0].spec.containers[*].name}')
  if ! echo "$PROXY_CONTAINERS" | grep -q 'tailscale'; then
    echo "[ERROR] Tailscale container not found in tailnet-proxy pod" >&2
    exit 1
  fi
  if ! echo "$PROXY_CONTAINERS" | grep -q 'envoy'; then
    echo "[ERROR] Envoy container not found in tailnet-proxy pod" >&2
    exit 1
  fi
fi

echo "[success] Headscale chart smoke test completed"
