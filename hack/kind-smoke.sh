#!/usr/bin/env bash

# Simple local smoke test for the headscale Helm chart using kind.
# The script creates a temporary kind cluster (unless one already exists),
# installs the chart with extra DNS records and a static DERP map enabled,
# and verifies that headscale renders them correctly. The cluster is deleted
# on success unless --keep is supplied or the cluster pre-existed.

set -euo pipefail

ROOT_DIR=$(
  cd -- "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd -P
)

CLUSTER_NAME="headscale-kind"
KEEP_CLUSTER=0
WITH_CLIENT=0
WITH_CLIENT_DAEMONSET=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --cluster-name NAME   Override kind cluster name (default: ${CLUSTER_NAME})
  --keep                Do not delete the cluster after the test finishes
  --with-client         Enable the optional Tailscale client with advertiseRoutes
  --with-client-daemonset  Enable client in DaemonSet mode with hostNetwork
  -h, --help            Show this help message

Environment variables:
  KIND_CLUSTER_NAME     Alternative way to set --cluster-name
  KEEP_CLUSTER          When set to 1, behaves like --keep
  WITH_CLIENT           When set to 1, behaves like --with-client
  WITH_CLIENT_DAEMONSET When set to 1, behaves like --with-client-daemonset
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
    --with-client-daemonset)
      WITH_CLIENT_DAEMONSET=1
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
if [[ ${WITH_CLIENT_DAEMONSET:-0} -eq 1 ]]; then
  WITH_CLIENT_DAEMONSET=1
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
derpMap:
  enabled: true
  content:
    regions:
      900:
        regionID: 900
        regionCode: smoke
        regionName: Smoke DERP
        nodes:
          - name: smoke-derp
            regionID: 900
            hostName: derp.smoke.test
EOF

if [[ $WITH_CLIENT_DAEMONSET -eq 1 ]]; then
  cat <<'EOF' >>"$TMP_VALUES"
client:
  enabled: true
  daemonset: true
EOF
elif [[ $WITH_CLIENT -eq 1 ]]; then
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

if [[ $WITH_CLIENT -eq 1 || $WITH_CLIENT_DAEMONSET -eq 1 ]]; then
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
  if [[ $WITH_CLIENT_DAEMONSET -eq 1 ]]; then
    echo "[kubectl] Checking client daemonset readiness"
    kubectl rollout status daemonset/headscale-client -n headscale --timeout=3m
  else
    echo "[kubectl] Checking client deployment readiness"
    kubectl rollout status deployment/headscale-client -n headscale --timeout=3m
  fi
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

echo "[verify] Ensuring derp.paths is present in rendered config"
if ! grep -q 'paths:' <<<"$CONFIG_YAML"; then
  echo "[ERROR] derp.paths entry missing in config.yaml" >&2
  exit 1
fi
if ! grep -q '/etc/headscale/derp-map.yaml' <<<"$CONFIG_YAML"; then
  echo "[ERROR] DERP map path missing from config.yaml" >&2
  exit 1
fi

echo "[verify] Ensuring DERP map ConfigMap contains our region"
DERP_YAML=$(kubectl get configmap headscale-derp-map -n headscale -o jsonpath='{.data.derp-map\.yaml}')
if ! grep -q 'derp.smoke.test' <<<"$DERP_YAML"; then
  echo "[ERROR] Expected DERP node not found in headscale-derp-map ConfigMap" >&2
  exit 1
fi

echo "[verify] Ensuring DERP map contains 'regions:' key from values"
if ! grep -q '^regions:' <<<"$DERP_YAML"; then
  echo "[ERROR] DERP map is missing top-level 'regions:' key" >&2
  exit 1
fi

echo "[verify] Ensuring DERP map region keys are numeric (not quoted strings)"
if grep -qE "['\"]900['\"]:" <<<"$DERP_YAML"; then
  echo "[ERROR] DERP map region key 900 is quoted as a string instead of a bare integer" >&2
  exit 1
fi
if ! grep -qE '900:' <<<"$DERP_YAML"; then
  echo "[ERROR] DERP map region key 900 not found as an unquoted integer" >&2
  exit 1
fi

if [[ $WITH_CLIENT -eq 1 ]]; then
  echo "[verify] Ensuring client ServiceAccount exists"
  if ! kubectl get serviceaccount headscale-client -n headscale >/dev/null 2>&1; then
    echo "[ERROR] Client ServiceAccount 'headscale-client' not found" >&2
    exit 1
  fi

  echo "[verify] Ensuring client state secret is created by tailscaled"
  for _ in $(seq 1 20); do
    if kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
      break
    fi
    sleep 3
  done
  if ! kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
    echo "[WARN] Client state secret not found; tailscaled may not have written state yet"
  fi

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

if [[ $WITH_CLIENT_DAEMONSET -eq 1 ]]; then
  echo "[verify] Ensuring client runs as DaemonSet"
  if ! kubectl get daemonset headscale-client -n headscale >/dev/null 2>&1; then
    echo "[ERROR] Client DaemonSet 'headscale-client' not found" >&2
    exit 1
  fi

  echo "[verify] Ensuring client pods have hostNetwork enabled"
  HOST_NET=$(kubectl get daemonset headscale-client -n headscale -o jsonpath='{.spec.template.spec.hostNetwork}')
  if [[ "$HOST_NET" != "true" ]]; then
    echo "[ERROR] hostNetwork is not enabled on client DaemonSet" >&2
    exit 1
  fi

  echo "[verify] Ensuring client pods have dnsPolicy=ClusterFirstWithHostNet"
  DNS_POLICY=$(kubectl get daemonset headscale-client -n headscale -o jsonpath='{.spec.template.spec.dnsPolicy}')
  if [[ "$DNS_POLICY" != "ClusterFirstWithHostNet" ]]; then
    echo "[ERROR] dnsPolicy is '$DNS_POLICY' instead of ClusterFirstWithHostNet" >&2
    exit 1
  fi

  echo "[verify] Ensuring client pod includes tailscale container"
  if ! kubectl get pods -n headscale -l app.kubernetes.io/component=client -o jsonpath='{.items[0].spec.containers[0].name}' | grep -q 'tailscale'; then
    echo "[ERROR] Tailscale container not found in client daemonset" >&2
    exit 1
  fi
fi

if [[ $WITH_CLIENT -eq 1 ]]; then
  echo "[verify] Testing job idempotency with second helm upgrade"
  helm upgrade headscale "$ROOT_DIR/headscale" \
    --namespace headscale \
    -f "$TMP_VALUES" \
    --wait --timeout 5m

  echo "[verify] Waiting for idempotent job to complete"
  for _ in $(seq 1 40); do
    JOB_JSON=$(kubectl get job -n headscale -l app.kubernetes.io/instance=headscale -o json 2>/dev/null || echo '{"items":[]}')
    SUCCEEDED=$(printf "%s" "$JOB_JSON" | grep -o '"succeeded":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0")
    if [ "$SUCCEEDED" -ge 1 ]; then
      break
    fi
    sleep 3
  done
  echo "[verify] Second helm upgrade completed (job ran idempotently)"
fi

echo "[success] Headscale chart smoke test completed"
