# Client-only mode (join external headscale) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `server.enabled` toggle so the chart can deploy *only* the Tailscale client and join an external headscale, with no local server.

**Architecture:** A new top-level `server.enabled` (default `true`) gates every server-side resource. When `false`, the client Deployment/DaemonSet points `--login-server` at `client.loginServer`, gets its preauth key from an inline value or referenced Secret (no `kubectl exec` key-gen), and optionally trusts a custom CA. A render-time validation helper enforces that external-mode values and server-mode are mutually exclusive.

**Tech Stack:** Helm 3 (templating with `fail`/`include`), bash smoke test on kind, GitHub Actions (helm lint/template).

**Testing approach:** This is a Helm chart, so "tests" are `helm template` render assertions piped to `grep` (fast, local, helm v3.10.1 is installed) plus the kind smoke test for end-to-end. Each task writes a failing render assertion first, then implements until it passes.

**Backward compatibility:** Every existing install omits `server:` → defaults to `enabled: true` → all current behavior is unchanged. Verify this with `helm template headscale headscale/` (no values) after every task.

---

## File Structure

**New files:**
- `headscale/templates/validate.yaml` — invokes the validation helper (renders empty).
- `headscale/templates/client-authkey-secret.yaml` — creates the authkey Secret from `client.authKey` (external mode, inline key only).

**Modified files:**
- `headscale/values.yaml` — add `server.enabled`; add `client.loginServer`, `client.authKey`, `client.authKeySecret`, `client.caSecretName`.
- `headscale/templates/_helpers.tpl` — add `headscale.validate`.
- `headscale/templates/client-deployment.yaml` — external-mode branch (login server, auth mount, CA trust, skip init container).
- Server resource gating (prepend `.Values.server.enabled` to guards): `deployment.yaml`, `service.yaml`, `configmap.yaml`, `ingress.yaml`, `pvc.yaml`, `serviceaccount.yaml`, `poddisruptionbudget.yaml`, `policy-configmap.yaml`, `derp-map-configmap.yaml`, `extra-dns-configmap.yaml`, `tls-sidecar-configmap.yaml`, `ui-deployment.yaml`, `ui-service.yaml`, `ui-ingress.yaml`, `ui-pvc.yaml`, `ui-poddisruptionbudget.yaml`, `ui-configmap.yaml`, `forbidden-node-names-cronjob.yaml`, `forbidden-node-names-rbac.yaml`, `forbidden-node-names-script-configmap.yaml`, `client-cronjob.yaml`, `client-secret-job-rbac.yaml`, `client-job-script-configmap.yaml`.
- `hack/kind-smoke.sh` — add `--with-external-client`.
- `.github/workflows/lint.yaml` — add an external-mode `helm template` render check.
- `headscale/README.md` — regenerated docs + usage note (via `generate_helm_docs.sh`).

---

## Task 1: Add values and the validation helper

**Files:**
- Modify: `headscale/values.yaml`
- Create: `headscale/templates/validate.yaml`
- Modify: `headscale/templates/_helpers.tpl`

- [ ] **Step 1: Write the failing render assertion**

Create `/tmp/ext-bad-loginserver.yaml`:

```yaml
client:
  enabled: true
  loginServer: https://hs.example.com
```

Run: `helm template headscale headscale/ -f /tmp/ext-bad-loginserver.yaml 2>&1`
Expected now: renders successfully (no validation yet) — this is the failing state (we WANT it to error).

- [ ] **Step 2: Add the `server` block to `headscale/values.yaml`**

Insert at the very top, immediately after the 3 header comment lines (before `image:`):

```yaml
# Deploy the headscale server. Set to false for "client-only" mode: the chart
# then deploys ONLY the Tailscale client and joins an EXTERNAL headscale (set
# client.loginServer). When false, all server-side resources (server Deployment,
# Service, ConfigMaps, Ingress, PVC, UI, key-gen Job/CronJob, forbidden-node-name
# renamer) are skipped. ACLs and subnet-route approval then live on the remote
# headscale and are managed by its administrator.
server:
  enabled: true

```

- [ ] **Step 3: Add external-mode client values to `headscale/values.yaml`**

In the `client:` block, immediately after the `enabled: true` line (currently around line 238, the `# -- Enable or disable the tailscale client container.` / `enabled: true`), insert:

```yaml
  # -- URL of an EXTERNAL headscale to join (client-only mode). Required when
  # server.enabled=false; FORBIDDEN when server.enabled=true. Include the scheme,
  # e.g. https://headscale.example.com
  loginServer: ""
  # -- Inline preauth key for external mode. The chart creates a Secret from it.
  # Mutually exclusive with authKeySecret. Only valid when server.enabled=false.
  authKey: ""
  # -- Reference an existing Secret holding the preauth key (external mode).
  # Mutually exclusive with authKey. Only valid when server.enabled=false.
  authKeySecret:
    name: ""
    key: authkey
  # -- Optional Secret containing a ca.crt to trust the external headscale's TLS
  # certificate (self-signed / private CA). Empty = rely on the system CA bundle
  # (covers Let's Encrypt and other public CAs). Only valid when server.enabled=false.
  caSecretName: ""
```

- [ ] **Step 4: Add the validation helper to `headscale/templates/_helpers.tpl`**

Append at the end of the file:

```
{{/*
Validate server/client mode combinations. Each external-mode value is legal in
exactly one mode. Called from templates/validate.yaml so it always evaluates.
*/}}
{{- define "headscale.validate" -}}
{{- $c := .Values.client -}}
{{- if .Values.server.enabled -}}
  {{- if $c.loginServer -}}{{ fail "client.loginServer is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.authKey -}}{{ fail "client.authKey is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.authKeySecret.name -}}{{ fail "client.authKeySecret.name is only valid when server.enabled=false" }}{{- end -}}
  {{- if $c.caSecretName -}}{{ fail "client.caSecretName is only valid when server.enabled=false" }}{{- end -}}
{{- else -}}
  {{- if not $c.enabled -}}{{ fail "server.enabled=false requires client.enabled=true (nothing to deploy otherwise)" }}{{- end -}}
  {{- if not $c.loginServer -}}{{ fail "client.loginServer is required when server.enabled=false" }}{{- end -}}
  {{- if and (not $c.authKey) (not $c.authKeySecret.name) -}}{{ fail "a preauth key is required when server.enabled=false: set client.authKey or client.authKeySecret.name" }}{{- end -}}
  {{- if and $c.authKey $c.authKeySecret.name -}}{{ fail "set only one of client.authKey or client.authKeySecret.name" }}{{- end -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 5: Create `headscale/templates/validate.yaml`**

```
{{- include "headscale.validate" . -}}
```

(Produces empty output; Helm skips empty manifests. Its only job is to force the helper to run on every render.)

- [ ] **Step 6: Run the assertions to verify they now fail correctly**

Run: `helm template headscale headscale/ -f /tmp/ext-bad-loginserver.yaml 2>&1 | grep -c "only valid when server.enabled=false"`
Expected: `1` (helm errors with the forbidden-value message).

Create `/tmp/ext-missing-key.yaml`:

```yaml
server:
  enabled: false
client:
  enabled: true
  loginServer: https://hs.example.com
```

Run: `helm template headscale headscale/ -f /tmp/ext-missing-key.yaml 2>&1 | grep -c "a preauth key is required"`
Expected: `1`

Run (default still works): `helm template headscale headscale/ >/dev/null 2>&1 && echo OK`
Expected: `OK`

- [ ] **Step 7: Commit**

```bash
git add headscale/values.yaml headscale/templates/_helpers.tpl headscale/templates/validate.yaml
git commit -m "feat: add server.enabled toggle and external-mode validation"
```

---

## Task 2: Gate all server-side resources behind `server.enabled`

**Files:** the server/UI/maintenance/key-gen templates listed in File Structure.

- [ ] **Step 1: Write the failing render assertion**

Create `/tmp/ext-valid.yaml`:

```yaml
server:
  enabled: false
client:
  enabled: true
  daemonset: true
  loginServer: https://hs.example.com
  authKey: tskey-auth-EXAMPLE
```

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -E "^kind: (Deployment|Service|Ingress|PersistentVolumeClaim|ConfigMap)" | sort -u`
Expected now (failing state): server `Deployment`, `Service`, `ConfigMap` still appear. We want only the client DaemonSet to remain after implementation.

- [ ] **Step 2: Wrap `deployment.yaml`**

Add as the new FIRST line of `headscale/templates/deployment.yaml`:

```
{{- if .Values.server.enabled }}
```

Add as the new LAST line:

```
{{- end }}
```

- [ ] **Step 3: Wrap `service.yaml`**

Add as the new FIRST line of `headscale/templates/service.yaml`:

```
{{- if .Values.server.enabled }}
```

Add as the new LAST line:

```
{{- end }}
```

- [ ] **Step 4: Prepend `.Values.server.enabled` to existing single-condition guards**

Edit each file's opening guard exactly as shown (left → right):

- `configmap.yaml`: `{{- if .Values.configMap.create }}` → `{{- if and .Values.server.enabled .Values.configMap.create }}`
- `ingress.yaml`: `{{- if .Values.ingress.enabled -}}` → `{{- if and .Values.server.enabled .Values.ingress.enabled -}}`
- `pvc.yaml`: `{{- if and .Values.persistence.enabled (not .Values.persistence.existingClaim) }}` → `{{- if and .Values.server.enabled .Values.persistence.enabled (not .Values.persistence.existingClaim) }}`
- `serviceaccount.yaml`: `{{- if .Values.serviceAccount.create -}}` → `{{- if and .Values.server.enabled .Values.serviceAccount.create -}}` AND `{{- if .Values.policy.hotReload.enabled }}` → `{{- if and .Values.server.enabled .Values.policy.hotReload.enabled }}`
- `poddisruptionbudget.yaml`: `{{- if .Values.podDisruptionBudget.enabled }}` → `{{- if and .Values.server.enabled .Values.podDisruptionBudget.enabled }}`
- `derp-map-configmap.yaml`: `{{- if and .Values.derpMap.enabled .Values.derpMap.configMap.create }}` → `{{- if and .Values.server.enabled .Values.derpMap.enabled .Values.derpMap.configMap.create }}`
- `extra-dns-configmap.yaml`: `{{- if and $extra.enabled $extra.configMap.create }}` → `{{- if and .Values.server.enabled $extra.enabled $extra.configMap.create }}`
- `tls-sidecar-configmap.yaml`: `{{- if and .Values.client.enabled .Values.ingress.enabled }}` → `{{- if and .Values.server.enabled .Values.client.enabled .Values.ingress.enabled }}`
- `ui-deployment.yaml`: `{{- if .Values.ui.enabled }}` → `{{- if and .Values.server.enabled .Values.ui.enabled }}`
- `ui-service.yaml`: `{{- if .Values.ui.enabled }}` → `{{- if and .Values.server.enabled .Values.ui.enabled }}`
- `ui-ingress.yaml`: `{{- if and .Values.ingress.enabled .Values.ui.enabled }}` → `{{- if and .Values.server.enabled .Values.ingress.enabled .Values.ui.enabled }}`
- `ui-pvc.yaml`: `{{- if and .Values.ui.enabled .Values.ui.persistence.enabled (not .Values.ui.persistence.existingClaim) }}` → `{{- if and .Values.server.enabled .Values.ui.enabled .Values.ui.persistence.enabled (not .Values.ui.persistence.existingClaim) }}`
- `ui-poddisruptionbudget.yaml`: `{{- if and .Values.ui.enabled (.Values.ui.podDisruptionBudget.enabled | default false) }}` → `{{- if and .Values.server.enabled .Values.ui.enabled (.Values.ui.podDisruptionBudget.enabled | default false) }}`
- `ui-configmap.yaml`: `{{- if and .Values.ui.enabled $uiCm.enabled $uiCm.create }}` → `{{- if and .Values.server.enabled .Values.ui.enabled $uiCm.enabled $uiCm.create }}`
- `forbidden-node-names-cronjob.yaml`: `{{- if .Values.forbiddenNodeNames.enabled }}` → `{{- if and .Values.server.enabled .Values.forbiddenNodeNames.enabled }}`
- `forbidden-node-names-rbac.yaml`: `{{- if .Values.forbiddenNodeNames.enabled }}` → `{{- if and .Values.server.enabled .Values.forbiddenNodeNames.enabled }}`
- `forbidden-node-names-script-configmap.yaml`: `{{- if .Values.forbiddenNodeNames.enabled }}` → `{{- if and .Values.server.enabled .Values.forbiddenNodeNames.enabled }}`
- `client-cronjob.yaml`: `{{- if and .Values.client.enabled .Values.client.job.cronjob.enabled }}` → `{{- if and .Values.server.enabled .Values.client.enabled .Values.client.job.cronjob.enabled }}`
- `client-secret-job-rbac.yaml`: `{{- if .Values.client.enabled }}` → `{{- if and .Values.server.enabled .Values.client.enabled }}`
- `client-job-script-configmap.yaml`: `{{- if .Values.client.enabled }}` → `{{- if and .Values.server.enabled .Values.client.enabled }}`

- [ ] **Step 5: Handle the `policy-configmap.yaml` compound guard**

Edit `headscale/templates/policy-configmap.yaml` line 3:

```
{{- if or $policyCreate (and $clientRoutes (not .Values.policy.enabled)) }}
```

to:

```
{{- if and .Values.server.enabled (or $policyCreate (and $clientRoutes (not .Values.policy.enabled))) }}
```

- [ ] **Step 6: Run the assertion to verify only the client remains**

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -E "^kind:" | sort | uniq -c`
Expected: a `DaemonSet` (the client), `ServiceAccount`/`Role`/`RoleBinding` (client RBAC), and a `Secret` (authkey, from Task 3) — and crucially **no** server `Deployment`, server `Service`, headscale `ConfigMap`, `Ingress`, `PersistentVolumeClaim`, or UI kinds.

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -E "name: headscale$" | wc -l`
Expected: `0` (no resource named exactly `headscale`, i.e. no server Deployment/Service/ConfigMap).

- [ ] **Step 7: Verify default (server) still renders fully**

Run: `helm template headscale headscale/ 2>&1 | grep -E "^kind:" | sort | uniq -c`
Expected: includes `Deployment`, `Service`, `ConfigMap`, `ServiceAccount` (server unchanged).

- [ ] **Step 8: Commit**

```bash
git add headscale/templates/
git commit -m "feat: gate server-side resources behind server.enabled"
```

---

## Task 3: Client external-mode wiring

**Files:**
- Create: `headscale/templates/client-authkey-secret.yaml`
- Modify: `headscale/templates/client-deployment.yaml` (full rewrite)

- [ ] **Step 1: Write the failing render assertions**

Run (login-server): `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "login-server=https://hs.example.com"`
Expected now: `0` (client still derives the in-cluster URL).

Run (no init container): `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "ensure-authkey"`
Expected now: `1` (init container still present) — we want `0` after implementation.

Run (authkey secret created from inline key): `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "tskey-auth-EXAMPLE"`
Expected now: `0`.

- [ ] **Step 2: Create `headscale/templates/client-authkey-secret.yaml`**

```
{{- if and .Values.client.enabled (not .Values.server.enabled) .Values.client.authKey }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "headscale.fullname" . }}-client-authkey
  labels:
    {{- include "headscale.labels" . | nindent 4 }}
type: Opaque
stringData:
  authkey: {{ .Values.client.authKey | quote }}
{{- end }}
```

- [ ] **Step 3: Replace `headscale/templates/client-deployment.yaml` with the external-aware version**

Overwrite the whole file with:

```
{{- if .Values.client.enabled }}
{{- $fullname := include "headscale.fullname" . }}
{{- $hasRoutes := gt (len .Values.client.advertiseRoutes) 0 }}
{{- $isDaemonSet := .Values.client.daemonset }}
{{- $tlsSecret := .Values.tls.secretName | default "" }}
{{- $external := not .Values.server.enabled }}
{{- $modeA := and (not $external) .Values.ingress.enabled }}
{{- $modeB := and (not $external) (not .Values.ingress.enabled) (ne $tlsSecret "") }}
{{- $useHttps := or $modeA $modeB }}
{{- $externalCa := and $external (ne (.Values.client.caSecretName | default "") "") }}
{{- /* Resolve the preauth-key Secret name/key for external mode */ -}}
{{- $authSecretName := printf "%s-client-authkey" $fullname }}
{{- $authSecretKey := "authkey" }}
{{- if and $external (not .Values.client.authKey) }}
{{- $authSecretName = .Values.client.authKeySecret.name }}
{{- $authSecretKey = (.Values.client.authKeySecret.key | default "authkey") }}
{{- end }}
apiVersion: apps/v1
kind: {{ if $isDaemonSet }}DaemonSet{{ else }}Deployment{{ end }}
metadata:
  name: {{ $fullname }}-client
  labels:
    {{- include "headscale.labels" . | nindent 4 }}
    app.kubernetes.io/component: client
spec:
  {{- if not $isDaemonSet }}
  replicas: 1
  {{- end }}
  selector:
    matchLabels:
      {{- include "headscale.selectorLabels" . | nindent 6 }}
      app.kubernetes.io/component: client
  template:
    metadata:
      labels:
        {{- include "headscale.labels" . | nindent 8 }}
        app.kubernetes.io/component: client
    spec:
      serviceAccountName: {{ $fullname }}-client
      {{- if $isDaemonSet }}
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      tolerations:
      - effect: NoSchedule
        operator: Exists
      {{- end }}
      volumes:
      - name: dev-net-tun
        hostPath:
          path: /dev/net/tun
          type: CharDevice
      - name: client-auth-init
        {{- if $external }}
        secret:
          secretName: {{ $authSecretName }}
          items:
          - key: {{ $authSecretKey }}
            path: authkey
        {{- else }}
        emptyDir: {}
        {{- end }}
      {{- if not $external }}
      - name: job-script
        configMap:
          name: {{ $fullname }}-client-job-script
          defaultMode: 0755
      {{- end }}
      {{- if $modeA }}
      - name: tofu-certs
        emptyDir: {}
      {{- end }}
      {{- if $modeB }}
      - name: headscale-ca
        secret:
          secretName: {{ $tlsSecret }}
          items:
          - key: ca.crt
            path: ca.crt
          optional: true
      {{- end }}
      {{- if $externalCa }}
      - name: headscale-ca
        secret:
          secretName: {{ .Values.client.caSecretName }}
          items:
          - key: ca.crt
            path: ca.crt
      {{- end }}
      {{- if not $external }}
      initContainers:
      - name: ensure-authkey
        image: "{{ .Values.client.job.image.repository }}:{{ .Values.client.job.image.tag }}"
        imagePullPolicy: {{ .Values.client.job.image.pullPolicy }}
        env:
        - name: AUTH_FILE_PATH
          value: /etc/client-auth/authkey
        command: ["/scripts/ensure-client-key.sh"]
        volumeMounts:
        - name: job-script
          mountPath: /scripts
          readOnly: true
        - name: client-auth-init
          mountPath: /etc/client-auth
      {{- if $modeA }}
      - name: tofu-cert-fetch
        image: "{{ .Values.client.internalTls.image.repository }}:{{ .Values.client.internalTls.image.tag }}"
        imagePullPolicy: {{ .Values.client.internalTls.image.pullPolicy }}
        command:
        - /bin/sh
        - -c
        - |
          set -eu
          apk add --no-cache openssl >/dev/null 2>&1
          HS_HOST="{{ $fullname }}.{{ .Release.Namespace }}.svc.cluster.local"
          echo "[tofu] Waiting for TLS sidecar at ${HS_HOST}:443 ..."
          for i in $(seq 1 120); do
            if echo | openssl s_client -connect "${HS_HOST}:443" -servername "${HS_HOST}" 2>/dev/null | openssl x509 -noout 2>/dev/null; then
              echo "[tofu] TLS sidecar is ready"
              break
            fi
            echo "[tofu] TLS sidecar not ready yet ($i/120)"
            sleep 5
          done
          echo | openssl s_client -connect "${HS_HOST}:443" -servername "${HS_HOST}" 2>/dev/null | openssl x509 > /tofu-certs/sidecar.crt 2>/dev/null
          if [ -s /tofu-certs/sidecar.crt ]; then
            echo "[tofu] Sidecar TLS certificate saved"
          else
            echo "[tofu] ERROR: Could not fetch sidecar TLS certificate" >&2
            exit 1
          fi
        volumeMounts:
        - name: tofu-certs
          mountPath: /tofu-certs
      {{- end }}
      {{- end }}
      containers:
      - name: tailscale
        image: "{{ .Values.client.image.repository }}:{{ .Values.client.image.tag }}"
        imagePullPolicy: {{ .Values.client.image.pullPolicy }}
        {{- if $isDaemonSet }}
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        {{- end }}
        command:
        - /bin/sh
        - -c
        - |
          # Use POSIX-safe options; avoid bash-only flags
          set -eu
          AUTH_FILE="/etc/client-auth/authkey"
          echo "[client] Waiting for preauth key at $AUTH_FILE ..."
          # Try up to ~10 minutes for the Secret to appear via projected volume
          for i in $(seq 1 120); do
            if [ -s "$AUTH_FILE" ]; then
              break
            fi
            echo "[client] auth key not present yet ($i/120)"
            sleep 5
          done

          {{- if and $hasRoutes (not $isDaemonSet) }}
          # Enable IP forwarding for subnet routing
          # (DaemonSet mode uses hostNetwork so the host already handles forwarding)
          echo "[client] Enabling IP forwarding"
          sysctl -w net.ipv4.ip_forward=1
          sysctl -w net.ipv6.conf.all.forwarding=1
          {{- end }}

          {{- if $modeA }}
          # Mode A: Trust sidecar cert fetched by init container
          if [ -s /tofu-certs/sidecar.crt ]; then
            cat /etc/ssl/certs/ca-certificates.crt /tofu-certs/sidecar.crt > /tmp/ca-bundle.crt
            export SSL_CERT_FILE=/tmp/ca-bundle.crt
            echo "[client] Trusting sidecar TLS certificate (TOFU)"
          else
            echo "[client] WARNING: No sidecar certificate found at /tofu-certs/sidecar.crt"
          fi
          {{- end }}

          {{- if $modeB }}
          # Mode B: Trust CA from TLS secret
          if [ -f /etc/headscale-ca/ca.crt ]; then
            cat /etc/ssl/certs/ca-certificates.crt /etc/headscale-ca/ca.crt > /tmp/ca-bundle.crt
            export SSL_CERT_FILE=/tmp/ca-bundle.crt
            echo "[client] Trusting CA from TLS secret"
          else
            echo "[client] WARNING: No ca.crt found in TLS secret; using system CA bundle"
          fi
          {{- end }}

          {{- if $externalCa }}
          # External mode: Trust CA from client.caSecretName
          if [ -f /etc/headscale-ca/ca.crt ]; then
            cat /etc/ssl/certs/ca-certificates.crt /etc/headscale-ca/ca.crt > /tmp/ca-bundle.crt
            export SSL_CERT_FILE=/tmp/ca-bundle.crt
            echo "[client] Trusting CA from caSecretName"
          else
            echo "[client] WARNING: No ca.crt found in caSecretName secret; using system CA bundle"
          fi
          {{- end }}

          echo "[client] Starting tailscaled"
          {{- if $isDaemonSet }}
          tailscaled --state=kube:{{ $fullname }}-client-state-${NODE_NAME} --socket=/var/run/tailscale/tailscaled.sock &
          {{- else }}
          tailscaled --state=kube:{{ $fullname }}-client-state --socket=/var/run/tailscale/tailscaled.sock &
          {{- end }}

          # If key exists, perform login; otherwise keep running and allow later manual login
          if [ -s "$AUTH_FILE" ]; then
            AUTH_KEY=$(cat "$AUTH_FILE")
            echo "[client] Performing tailscale up"
            {{- if $isDaemonSet }}
            {{- if $external }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client-${NODE_NAME} --login-server={{ .Values.client.loginServer }} \
            {{- else if $useHttps }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client-${NODE_NAME} --login-server=https://{{ $fullname }}.{{ .Release.Namespace }}.svc.cluster.local:443 \
            {{- else }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client-${NODE_NAME} --login-server=http://{{ $fullname }}.{{ .Release.Namespace }}.svc.cluster.local:8080 \
            {{- end }}
            {{- else }}
            {{- if $external }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client --login-server={{ .Values.client.loginServer }} \
            {{- else if $useHttps }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client --login-server=https://{{ $fullname }}:443 \
            {{- else }}
            tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$AUTH_KEY" --hostname={{ .Chart.Name }}-client --login-server=http://{{ $fullname }}:8080 \
            {{- end }}
            {{- end }}
              {{- if and (ne (.Values.client.acceptDns | toString) "") (ne (.Values.client.acceptDns | toString) "unset") }}
              --accept-dns={{ .Values.client.acceptDns | toString }} \
              {{- end }}
              {{- if and (ne (.Values.client.acceptRoutes | toString) "") (ne (.Values.client.acceptRoutes | toString) "unset") }}
              --accept-routes={{ .Values.client.acceptRoutes | toString }} \
              {{- end }}
              {{- if $hasRoutes }}
              --advertise-routes={{ .Values.client.advertiseRoutes | join "," }} \
              {{- end }}
              {{- if .Values.client.exitNode }}
              --advertise-exit-node \
              {{- end }}
              || true
          else
            echo "[client] No preauth key found after timeout; skipping tailscale up for now."
          fi

          # Keep container alive
          wait $! || true
          tail -f /dev/null
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - 'tailscale --socket=/var/run/tailscale/tailscaled.sock status --json | grep -q "BackendState.*Running"'
          initialDelaySeconds: 15
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
        securityContext:
          {{- if and $hasRoutes (not $isDaemonSet) }}
          # Privileged mode required to set sysctl for IP forwarding
          # (DaemonSet mode uses hostNetwork and skips the sysctl init container)
          privileged: true
          {{- else }}
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
          {{- end }}
        volumeMounts:
        - name: dev-net-tun
          mountPath: /dev/net/tun
        - name: client-auth-init
          mountPath: /etc/client-auth
          readOnly: true
        {{- if $modeA }}
        - name: tofu-certs
          mountPath: /tofu-certs
          readOnly: true
        {{- end }}
        {{- if or $modeB $externalCa }}
        - name: headscale-ca
          mountPath: /etc/headscale-ca
          readOnly: true
        {{- end }}
{{- end }}
```

- [ ] **Step 4: Run the assertions to verify they pass**

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "login-server=https://hs.example.com"`
Expected: `1`

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "ensure-authkey"`
Expected: `0`

Run: `helm template headscale headscale/ -f /tmp/ext-valid.yaml 2>&1 | grep -c "tskey-auth-EXAMPLE"`
Expected: `1` (Secret created from inline key)

- [ ] **Step 5: Verify the authKeySecret reference path (no Secret created)**

Create `/tmp/ext-secretref.yaml`:

```yaml
server:
  enabled: false
client:
  enabled: true
  loginServer: https://hs.example.com
  authKeySecret:
    name: my-existing-authkey
    key: tskey
```

Run: `helm template headscale headscale/ -f /tmp/ext-secretref.yaml 2>&1 | grep -A6 "name: client-auth-init"`
Expected: the volume references `secretName: my-existing-authkey` with `key: tskey`.

Run: `helm template headscale headscale/ -f /tmp/ext-secretref.yaml -s templates/client-authkey-secret.yaml 2>&1 | grep -c "kind: Secret"`
Expected: `0` (chart does not create a Secret when referencing an existing one).

- [ ] **Step 6: Verify custom CA path**

Create `/tmp/ext-ca.yaml`:

```yaml
server:
  enabled: false
client:
  enabled: true
  loginServer: https://hs.internal.example
  authKey: tskey-auth-EXAMPLE
  caSecretName: remote-hs-ca
```

Run: `helm template headscale headscale/ -f /tmp/ext-ca.yaml 2>&1 | grep -c "secretName: remote-hs-ca"`
Expected: `1`

Run: `helm template headscale headscale/ -f /tmp/ext-ca.yaml 2>&1 | grep -c "Trusting CA from caSecretName"`
Expected: `1`

- [ ] **Step 7: Verify default (server) client is unchanged**

Create `/tmp/server-client.yaml`:

```yaml
client:
  enabled: true
```

Run: `helm template headscale headscale/ -f /tmp/server-client.yaml 2>&1 | grep -c "ensure-authkey"`
Expected: `1` (in-cluster init container still present)

Run: `helm template headscale headscale/ -f /tmp/server-client.yaml 2>&1 | grep -c "login-server=http://headscale:8080"`
Expected: `1` (in-cluster URL unchanged)

- [ ] **Step 8: Commit**

```bash
git add headscale/templates/client-deployment.yaml headscale/templates/client-authkey-secret.yaml
git commit -m "feat: wire tailscale client to external headscale in client-only mode"
```

---

## Task 4: Smoke test — `--with-external-client`

**Files:**
- Modify: `hack/kind-smoke.sh`

- [ ] **Step 1: Add the flag parsing**

In `hack/kind-smoke.sh`, add `WITH_EXTERNAL_CLIENT=0` next to the other `WITH_*` defaults (near line 17). Add a `--with-external-client` case to the `while`/`case` arg loop (mirroring `--with-client-daemonset`):

```bash
    --with-external-client)
      WITH_EXTERNAL_CLIENT=1
      shift
      ;;
```

Add the env-var normalization next to the others:

```bash
if [[ ${WITH_EXTERNAL_CLIENT:-0} -eq 1 ]]; then
  WITH_EXTERNAL_CLIENT=1
fi
```

Add a line to the `usage()` heredoc under Options:

```
  --with-external-client   Deploy a server release, then a separate client-only release that joins it
```

- [ ] **Step 2: Add the external-client test block**

Insert this block in `hack/kind-smoke.sh` immediately BEFORE the final `echo "[success] Headscale chart smoke test completed"` line. It is self-contained (own namespaces, own cleanup) and only runs when the flag is set:

```bash
if [[ $WITH_EXTERNAL_CLIENT -eq 1 ]]; then
  echo "[external] Testing client-only mode against a separate server release"
  SRV_NS=hs-server
  CLI_NS=hs-client

  # Release A: server only (no client)
  cat <<'EOF' >"$TMP_VALUES.srv"
server:
  enabled: true
client:
  enabled: false
EOF
  echo "[external] Installing server release in namespace $SRV_NS"
  helm upgrade --install hs-ext-server "$ROOT_DIR/headscale" \
    --namespace "$SRV_NS" --create-namespace --wait --timeout 5m \
    -f "$TMP_VALUES.srv"
  kubectl rollout status deployment/hs-ext-server -n "$SRV_NS" --timeout=2m

  # Mint a real preauth key on the server (mirrors a remote admin handing one over)
  echo "[external] Creating user + preauth key on the server"
  SRV_POD=$(kubectl get pods -n "$SRV_NS" -l app.kubernetes.io/component=server -o jsonpath='{.items[0].metadata.name}')
  kubectl exec -n "$SRV_NS" "$SRV_POD" -c headscale -- headscale users create ext-test >/dev/null 2>&1 || true
  EXT_KEY=$(kubectl exec -n "$SRV_NS" "$SRV_POD" -c headscale -- \
    headscale preauthkeys create -u 1 --reusable --expiration 24h -o json | jq -r '.key')
  if [[ -z "$EXT_KEY" || "$EXT_KEY" == "null" ]]; then
    echo "[ERROR] Failed to mint preauth key on server" >&2
    exit 1
  fi

  # Hand the key to the client namespace as a Secret (the admin-provides-key flow)
  kubectl create namespace "$CLI_NS" 2>/dev/null || true
  kubectl create secret generic remote-authkey -n "$CLI_NS" \
    --from-literal=authkey="$EXT_KEY" --dry-run=client -o yaml | kubectl apply -f -

  # Release B: client only, joining release A via cross-namespace Service DNS
  cat <<EOF >"$TMP_VALUES.cli"
server:
  enabled: false
client:
  enabled: true
  daemonset: true
  loginServer: http://hs-ext-server.${SRV_NS}.svc.cluster.local:8080
  authKeySecret:
    name: remote-authkey
    key: authkey
EOF
  echo "[external] Installing client-only release in namespace $CLI_NS"
  helm upgrade --install hs-ext-client "$ROOT_DIR/headscale" \
    --namespace "$CLI_NS" --create-namespace --wait --timeout 5m \
    -f "$TMP_VALUES.cli"

  echo "[external:verify] Ensuring NO server resources exist in client namespace"
  if kubectl get deployment hs-ext-client -n "$CLI_NS" >/dev/null 2>&1; then
    echo "[ERROR] Unexpected server Deployment 'hs-ext-client' in client-only namespace" >&2
    exit 1
  fi
  if kubectl get configmap hs-ext-client -n "$CLI_NS" >/dev/null 2>&1; then
    echo "[ERROR] Unexpected server ConfigMap 'hs-ext-client' in client-only namespace" >&2
    exit 1
  fi

  echo "[external:verify] Ensuring client DaemonSet is present and ready"
  kubectl rollout status daemonset/hs-ext-client-client -n "$CLI_NS" --timeout=3m

  echo "[external:verify] Waiting for client state secret (proves control-plane connection to external server)"
  CONNECTED=0
  for _ in $(seq 1 40); do
    if kubectl get secrets -n "$CLI_NS" -o name | grep -q 'hs-ext-client-client-state'; then
      CONNECTED=1
      break
    fi
    sleep 5
  done
  if [[ $CONNECTED -eq 1 ]]; then
    echo "[external:verify] Client state secret found — external join successful!"
  else
    echo "[ERROR] Client did not establish state with external server" >&2
    CLI_POD=$(kubectl get pods -n "$CLI_NS" -l app.kubernetes.io/component=client -o jsonpath='{.items[0].metadata.name}')
    kubectl logs "$CLI_POD" -n "$CLI_NS" --tail=30 2>/dev/null || true
    exit 1
  fi

  echo "[external:verify] Confirming the server sees the joined node"
  if kubectl exec -n "$SRV_NS" "$SRV_POD" -c headscale -- headscale nodes list -o json | jq -e 'length >= 1' >/dev/null; then
    echo "[external:verify] Server reports >=1 registered node"
  else
    echo "[WARN] Server node list empty (node may still be registering)"
  fi

  echo "[external] Cleaning up external-mode releases"
  helm uninstall hs-ext-client -n "$CLI_NS" --wait 2>/dev/null || true
  helm uninstall hs-ext-server -n "$SRV_NS" --wait 2>/dev/null || true
  rm -f "$TMP_VALUES.srv" "$TMP_VALUES.cli"
fi
```

- [ ] **Step 3: Run the smoke test (requires kind + kubectl + helm + jq)**

Run: `WITH_EXTERNAL_CLIENT=1 hack/kind-smoke.sh --with-external-client`
Expected: ends with `[external:verify] Client state secret found — external join successful!` and `[success] Headscale chart smoke test completed`.

If kind is unavailable in the execution environment, note this explicitly in the task output (do not silently skip) and rely on the render assertions from Tasks 1–3 plus CI. State clearly: "kind smoke test not run here — needs a kind-capable environment."

- [ ] **Step 4: Commit**

```bash
git add hack/kind-smoke.sh
git commit -m "test: add --with-external-client smoke test for client-only mode"
```

---

## Task 5: CI render check + docs

**Files:**
- Modify: `.github/workflows/lint.yaml`
- Modify: `headscale/README.md` (regenerated)

- [ ] **Step 1: Add an external-mode template render to CI**

In `.github/workflows/lint.yaml`, after the existing `Helm template (default values)` step, add:

```yaml
      - name: Helm template (client-only / external mode)
        run: |
          helm template headscale headscale/ \
            --set server.enabled=false \
            --set client.enabled=true \
            --set client.loginServer=https://hs.example.com \
            --set client.authKey=tskey-auth-EXAMPLE
```

- [ ] **Step 2: Verify the CI command renders locally**

Run:
```bash
helm template headscale headscale/ \
  --set server.enabled=false \
  --set client.enabled=true \
  --set client.loginServer=https://hs.example.com \
  --set client.authKey=tskey-auth-EXAMPLE >/dev/null 2>&1 && echo OK
```
Expected: `OK`

- [ ] **Step 3: Add a usage note to `headscale/README.md`**

Add a section (above the auto-generated values table, or in an existing usage area) titled `## Client-only mode (join an external headscale)` with:

````markdown
## Client-only mode (join an external headscale)

Set `server.enabled=false` to deploy *only* the Tailscale client and join an
external headscale. ACLs and subnet-route approval live on the remote headscale
and are managed by its administrator. The Tailscale Kubernetes operator does not
work with headscale; this mode is the supported way to join external clusters.

```yaml
server:
  enabled: false
client:
  enabled: true
  daemonset: true
  loginServer: https://headscale.example.com
  # Provide a preauth key minted on the remote headscale, either inline:
  authKey: tskey-auth-xxxxxxxxxxxx
  # ...or by referencing an existing Secret:
  # authKeySecret:
  #   name: my-headscale-authkey
  #   key: authkey
  # For a self-signed / private-CA remote, mount its CA (empty = system bundle):
  # caSecretName: remote-headscale-ca
```
````

- [ ] **Step 4: Regenerate the values docs**

Run: `./generate_helm_docs.sh`
Expected: `headscale/README.md` values table now includes `server.enabled` and the new `client.*` keys.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/lint.yaml headscale/README.md
git commit -m "ci+docs: external-mode render check and client-only usage docs"
```

---

## Task 6: Final verification and PR

- [ ] **Step 1: Lint and render matrix**

Run each and confirm success:
```bash
helm lint headscale/
helm template headscale headscale/ >/dev/null && echo "default OK"
helm template headscale headscale/ -f /tmp/ext-valid.yaml >/dev/null && echo "external OK"
helm template headscale headscale/ -f /tmp/ext-secretref.yaml >/dev/null && echo "secretref OK"
```
Expected: `helm lint` passes; all three `... OK` lines print.

- [ ] **Step 2: Confirm validation guards still fail as designed**

```bash
helm template headscale headscale/ -f /tmp/ext-bad-loginserver.yaml 2>&1 | grep -q "only valid when server.enabled=false" && echo "guard1 OK"
helm template headscale headscale/ -f /tmp/ext-missing-key.yaml 2>&1 | grep -q "a preauth key is required" && echo "guard2 OK"
```
Expected: `guard1 OK` and `guard2 OK`.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feature/client-only-external-server
gh pr create --base main --title "feat: client-only mode (join external headscale)" --body "$(cat <<'EOF'
## Summary
- Adds `server.enabled` (default true). When false, the chart deploys only the Tailscale client and joins an external headscale.
- Client gets `--login-server` from `client.loginServer`, preauth key from `client.authKey` or `client.authKeySecret`, optional CA via `client.caSecretName`.
- All server-side resources gated behind `server.enabled`. Render-time validation enforces mutual exclusivity of the two modes.
- Smoke test: new `--with-external-client` (server release + separate client-only release joining it). CI gains an external-mode `helm template` check.

Closes the "client-only / external headscale" use case (Tailscale operator is incompatible with headscale).

## Test plan
- `helm lint` + default/external `helm template` (CI).
- `hack/kind-smoke.sh --with-external-client` end-to-end.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review notes

- **Spec coverage:** `server.enabled` gating (Task 2) ✓; client login/auth/CA wiring (Task 3) ✓; both auth sources, configurable (Task 1 values + Task 3) ✓; optional CA, empty→system bundle (Task 3) ✓; validation guards / mutual exclusivity (Task 1) ✓; skip policy generation (Task 2, policy-configmap gated) ✓; smoke test single-cluster two-release (Task 4) ✓; CI render check (Task 5) ✓; docs note that operator is incompatible + remote admin owns ACLs (Task 5) ✓.
- **Type/name consistency:** Secret name `<fullname>-client-authkey`, volume `client-auth-init` mounted at `/etc/client-auth`, CA volume `headscale-ca` at `/etc/headscale-ca`, template vars `$external`/`$externalCa`/`$authSecretName`/`$authSecretKey` used consistently across `client-deployment.yaml` and `client-authkey-secret.yaml`.
- **No placeholders:** every code/template/bash block is complete and copy-pasteable.
