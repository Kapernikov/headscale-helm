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

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --cluster-name NAME   Override kind cluster name (default: ${CLUSTER_NAME})
  --keep                Do not delete the cluster after the test finishes
  --with-client         Enable the optional Tailscale client sidecar in the chart
  -h, --help            Show this help message

Environment variables:
  KIND_CLUSTER_NAME     Alternative way to set --cluster-name
  KEEP_CLUSTER          When set to 1, behaves like --keep
  WITH_CLIENT           When set to 1, behaves like --with-client
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
EOF
else
  cat <<'EOF' >>"$TMP_VALUES"
client:
  enabled: false
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
fi

echo "[success] Headscale chart smoke test completed"
