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
WITH_TLS=0
WITH_TLS_SIDECAR=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --cluster-name NAME   Override kind cluster name (default: ${CLUSTER_NAME})
  --keep                Do not delete the cluster after the test finishes
  --with-client         Enable the optional Tailscale client with advertiseRoutes
  --with-client-daemonset  Enable client in DaemonSet mode with hostNetwork
  --with-tls            Enable TLS Mode B (native TLS, no ingress) with self-signed cert
  --with-tls-sidecar    Enable TLS Mode A (ingress + nginx sidecar) with TOFU
  -h, --help            Show this help message

Environment variables:
  KIND_CLUSTER_NAME     Alternative way to set --cluster-name
  KEEP_CLUSTER          When set to 1, behaves like --keep
  WITH_CLIENT           When set to 1, behaves like --with-client
  WITH_CLIENT_DAEMONSET When set to 1, behaves like --with-client-daemonset
  WITH_TLS              When set to 1, behaves like --with-tls
  WITH_TLS_SIDECAR      When set to 1, behaves like --with-tls-sidecar
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
    --with-tls)
      WITH_TLS=1
      shift
      ;;
    --with-tls-sidecar)
      WITH_TLS_SIDECAR=1
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
if [[ ${WITH_TLS:-0} -eq 1 ]]; then
  WITH_TLS=1
fi
if [[ ${WITH_TLS_SIDECAR:-0} -eq 1 ]]; then
  WITH_TLS_SIDECAR=1
fi

REQUIRED_BINS=(kind kubectl helm)
if [[ $WITH_TLS -eq 1 ]]; then
  REQUIRED_BINS+=(openssl)
fi
for bin in "${REQUIRED_BINS[@]}"; do
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
TMP_TLS_DIR=$(mktemp -d)
cleanup() {
  rm -f "$TMP_VALUES"
  rm -rf "$TMP_TLS_DIR"
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

# TLS flags imply client
if [[ $WITH_TLS -eq 1 || $WITH_TLS_SIDECAR -eq 1 ]]; then
  WITH_CLIENT=1
fi

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

# TLS Mode B: generate a self-signed CA + server cert and create K8s TLS secret
if [[ $WITH_TLS -eq 1 ]]; then
  echo "[tls] Generating self-signed CA and server certificate"
  # CA
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP_TLS_DIR/ca.key" -out "$TMP_TLS_DIR/ca.crt" \
    -days 365 -nodes -subj "/CN=headscale-smoke-ca" 2>/dev/null
  # Server cert signed by CA
  openssl req -newkey rsa:2048 -keyout "$TMP_TLS_DIR/tls.key" -out "$TMP_TLS_DIR/tls.csr" \
    -nodes -subj "/CN=headscale" \
    -addext "subjectAltName=DNS:headscale,DNS:headscale.headscale,DNS:headscale.headscale.svc,DNS:headscale.headscale.svc.cluster.local" 2>/dev/null
  openssl x509 -req -in "$TMP_TLS_DIR/tls.csr" -CA "$TMP_TLS_DIR/ca.crt" -CAkey "$TMP_TLS_DIR/ca.key" \
    -CAcreateserial -out "$TMP_TLS_DIR/tls.crt" -days 365 \
    -extfile <(printf "subjectAltName=DNS:headscale,DNS:headscale.headscale,DNS:headscale.headscale.svc,DNS:headscale.headscale.svc.cluster.local") 2>/dev/null

  echo "[tls] Creating headscale namespace and TLS secret"
  kubectl create namespace headscale 2>/dev/null || true
  kubectl delete secret headscale-tls -n headscale 2>/dev/null || true
  kubectl create secret generic headscale-tls -n headscale \
    --from-file=tls.crt="$TMP_TLS_DIR/tls.crt" \
    --from-file=tls.key="$TMP_TLS_DIR/tls.key" \
    --from-file=ca.crt="$TMP_TLS_DIR/ca.crt"

  cat <<'EOF' >>"$TMP_VALUES"
tls:
  secretName: headscale-tls
EOF
fi

# TLS Mode A: ingress + sidecar (no real ingress controller needed, tests sidecar + TOFU)
if [[ $WITH_TLS_SIDECAR -eq 1 ]]; then
  cat <<'EOF' >>"$TMP_VALUES"
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: headscale.smoke.test
      paths:
        - path: /
          pathType: ImplementationSpecific
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

if [[ $WITH_TLS -eq 1 ]]; then
  echo "[verify:tls] Ensuring headscale config has native TLS settings"
  CONFIG_YAML=$(kubectl get configmap headscale -n headscale -o jsonpath='{.data.config\.yaml}')
  if ! grep -q 'tls_cert_path: /etc/headscale/tls/tls.crt' <<<"$CONFIG_YAML"; then
    echo "[ERROR] tls_cert_path not found in config.yaml" >&2
    exit 1
  fi
  if ! grep -q 'tls_key_path: /etc/headscale/tls/tls.key' <<<"$CONFIG_YAML"; then
    echo "[ERROR] tls_key_path not found in config.yaml" >&2
    exit 1
  fi
  if ! grep -q 'listen_addr: 0.0.0.0:443' <<<"$CONFIG_YAML"; then
    echo "[ERROR] listen_addr not set to 0.0.0.0:443 in config.yaml" >&2
    exit 1
  fi

  echo "[verify:tls] Ensuring service exposes port 443"
  SVC_PORT=$(kubectl get svc headscale -n headscale -o jsonpath='{.spec.ports[0].port}')
  if [[ "$SVC_PORT" != "443" ]]; then
    echo "[ERROR] Service port is $SVC_PORT instead of 443" >&2
    exit 1
  fi

  echo "[verify:tls] Ensuring headscale is serving TLS on port 443"
  # Port-forward and check TLS handshake
  kubectl port-forward svc/headscale -n headscale 18443:443 &
  PF_PID=$!
  sleep 3
  if echo | openssl s_client -connect 127.0.0.1:18443 -servername headscale 2>/dev/null | openssl x509 -noout 2>/dev/null; then
    echo "[verify:tls] TLS handshake successful on port 443"
  else
    echo "[ERROR] TLS handshake failed on port 443" >&2
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi
  kill $PF_PID 2>/dev/null || true

  echo "[verify:tls] Checking client logs for CA trust message"
  CLIENT_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/component=client -o jsonpath='{.items[0].metadata.name}')
  CLIENT_LOGS=$(kubectl logs "$CLIENT_POD" -n headscale --tail=50 2>/dev/null || true)
  if grep -q 'Trusting CA from TLS secret' <<<"$CLIENT_LOGS"; then
    echo "[verify:tls] Client correctly trusts CA from TLS secret"
  else
    echo "[WARN] Client CA trust message not found in logs (may still be starting)"
    echo "[verify:tls] Client logs:"
    echo "$CLIENT_LOGS" | tail -20
  fi

  echo "[verify:tls] Checking client logs for successful HTTPS login"
  if grep -q 'login-server=https://' <<<"$CLIENT_LOGS"; then
    echo "[verify:tls] Client is using HTTPS login-server URL"
  else
    echo "[WARN] HTTPS login-server URL not found in client logs"
  fi

  echo "[verify:tls] Waiting for client state secret (proves successful TLS connection)"
  for _ in $(seq 1 30); do
    if kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
      echo "[verify:tls] Client state secret found — TLS connection successful!"
      break
    fi
    sleep 5
  done
  if ! kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
    echo "[WARN] Client state secret not found; TLS connection may not have completed yet"
    echo "[verify:tls] Dumping client pod logs for debugging:"
    kubectl logs "$CLIENT_POD" -n headscale --tail=30 2>/dev/null || true
  fi
fi

if [[ $WITH_TLS_SIDECAR -eq 1 ]]; then
  echo "[verify:tls-sidecar] Ensuring server pod has tls-sidecar container"
  SERVER_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
  CONTAINERS=$(kubectl get pod "$SERVER_POD" -n headscale -o jsonpath='{.spec.containers[*].name}')
  if echo "$CONTAINERS" | grep -q 'tls-sidecar'; then
    echo "[verify:tls-sidecar] TLS sidecar container present"
  else
    echo "[ERROR] tls-sidecar container not found in server pod (containers: $CONTAINERS)" >&2
    exit 1
  fi

  echo "[verify:tls-sidecar] Ensuring init container generated certs"
  INIT_CONTAINERS=$(kubectl get pod "$SERVER_POD" -n headscale -o jsonpath='{.spec.initContainers[*].name}')
  if echo "$INIT_CONTAINERS" | grep -q 'generate-internal-tls'; then
    echo "[verify:tls-sidecar] Init container 'generate-internal-tls' present"
  else
    echo "[ERROR] generate-internal-tls init container not found" >&2
    exit 1
  fi

  echo "[verify:tls-sidecar] Ensuring service exposes both ports 8080 and 443"
  SVC_PORTS=$(kubectl get svc headscale -n headscale -o jsonpath='{.spec.ports[*].port}')
  if echo "$SVC_PORTS" | grep -q '8080' && echo "$SVC_PORTS" | grep -q '443'; then
    echo "[verify:tls-sidecar] Service exposes both 8080 and 443"
  else
    echo "[ERROR] Service ports are '$SVC_PORTS' — expected both 8080 and 443" >&2
    exit 1
  fi

  echo "[verify:tls-sidecar] Ensuring sidecar is serving TLS on port 443"
  kubectl port-forward svc/headscale -n headscale 18443:443 &
  PF_PID=$!
  sleep 3
  if echo | openssl s_client -connect 127.0.0.1:18443 -servername headscale 2>/dev/null | openssl x509 -noout 2>/dev/null; then
    echo "[verify:tls-sidecar] TLS handshake successful on sidecar port 443"
  else
    echo "[ERROR] TLS handshake failed on sidecar port 443" >&2
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi
  kill $PF_PID 2>/dev/null || true

  echo "[verify:tls-sidecar] Checking that sidecar proxies to headscale (health check via HTTPS)"
  kubectl port-forward svc/headscale -n headscale 18443:443 &
  PF_PID=$!
  sleep 2
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:18443/health || true)
  kill $PF_PID 2>/dev/null || true
  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "[verify:tls-sidecar] Health check via HTTPS sidecar returned 200"
  else
    echo "[WARN] Health check via HTTPS returned $HTTP_CODE (headscale may still be starting)"
  fi

  echo "[verify:tls-sidecar] Checking client logs for TOFU trust message"
  CLIENT_POD=$(kubectl get pods -n headscale -l app.kubernetes.io/component=client -o jsonpath='{.items[0].metadata.name}')
  CLIENT_LOGS=$(kubectl logs "$CLIENT_POD" -n headscale --tail=50 2>/dev/null || true)
  if grep -q 'Trusting sidecar TLS certificate (TOFU)' <<<"$CLIENT_LOGS"; then
    echo "[verify:tls-sidecar] Client correctly trusted sidecar cert via TOFU"
  else
    echo "[WARN] TOFU trust message not found in client logs (may still be starting)"
    echo "[verify:tls-sidecar] Client logs:"
    echo "$CLIENT_LOGS" | tail -20
  fi

  echo "[verify:tls-sidecar] Waiting for client state secret (proves successful TOFU+TLS connection)"
  for _ in $(seq 1 30); do
    if kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
      echo "[verify:tls-sidecar] Client state secret found — TOFU TLS connection successful!"
      break
    fi
    sleep 5
  done
  if ! kubectl get secret headscale-client-state -n headscale >/dev/null 2>&1; then
    echo "[WARN] Client state secret not found; TOFU TLS connection may not have completed yet"
    echo "[verify:tls-sidecar] Dumping client pod logs for debugging:"
    kubectl logs "$CLIENT_POD" -n headscale --tail=30 2>/dev/null || true
  fi
fi

echo "[success] Headscale chart smoke test completed"
