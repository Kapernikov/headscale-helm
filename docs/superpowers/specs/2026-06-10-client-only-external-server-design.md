# Client-only mode: join an external headscale

**Date:** 2026-06-10
**Status:** Approved design, pending implementation
**Branch:** `feature/client-only-external-server`

## Problem

The chart bundles a Tailscale client (Deployment or DaemonSet) that today is hard-wired
to the headscale **server** deployed by the same release. We want to deploy *only* the
client — no server — so a cluster can join an **external** headscale (e.g. a central
headscale reached over the public internet via Let's Encrypt TLS).

The Tailscale Kubernetes **operator** is not an option: it authenticates via OAuth against
`api.tailscale.com` and drives Tailscale's admin REST API, which headscale does not
implement. Extending this chart is the correct path.

## Current coupling to remove

1. **Key generation** — `client-job-script-configmap.yaml` (`ensure-client-key.sh`)
   `kubectl exec`s into the server pod to run `headscale preauthkeys create`. No local
   server → no pod to exec into.
2. **Login server URL** — `client-deployment.yaml` derives `--login-server` from the
   in-cluster Service DNS name.
3. **Policy generation** — `client.advertiseRoutes` triggers a server-side policy
   ConfigMap (autoApprovers, `tag:in-cluster-client`). In external mode the remote
   headscale owns ACLs and route approval.

## Design

### The toggle: `server.enabled` (default `true`)

Backward-compatible. When `false`, gate OFF every server-side resource:

- `deployment.yaml`, `service.yaml`, `configmap.yaml`, `ingress.yaml`, `pvc.yaml`
- server `serviceaccount.yaml`, server `poddisruptionbudget.yaml`
- `policy-configmap.yaml`, `derp-map-configmap.yaml`, `extra-dns-configmap.yaml`, `tls-sidecar-configmap.yaml`
- all `ui-*` resources
- `forbidden-node-names-*` (server-side maintenance)
- preauth-key **generation** Job + CronJob + their `client-secret-job-rbac` exec permissions

With `server.enabled=false` + `client.enabled=true`, only the client workload + its
state-secret RBAC + the authkey Secret remain.

### Client values (new)

```yaml
client:
  enabled: true
  loginServer: ""        # external headscale URL, e.g. https://hs.example.com
                         # REQUIRED when server.enabled=false; FORBIDDEN when true
  authKey: ""            # inline preauth key (chart creates the Secret)
  authKeySecret:         # OR reference an existing Secret
    name: ""
    key: authkey
  caSecretName: ""       # optional Secret with ca.crt for private-CA remote
                         # empty -> system CA bundle (covers Let's Encrypt)
```

### Client wiring in external mode

- **Login server:** when `server.enabled=false`, `--login-server` = `client.loginServer`
  verbatim. The existing in-cluster Mode A/B derivation is untouched when server is enabled.
- **Auth key:** replaces the `ensure-authkey` init container. If `client.authKey` is set,
  the chart creates a Secret from it; otherwise `client.authKeySecret.{name,key}` is used.
  The Secret is mounted directly as the authkey file. `ensure-client-key.sh`, the key-gen
  Job/CronJob, and the server-exec RBAC are all skipped.
- **TLS trust:** reuse the existing Mode B pattern — if `caSecretName` is set, mount its
  `ca.crt` and append to the system bundle; otherwise system bundle only. No sidecar, no
  TOFU, no cert-fetch init container in external mode.
- **Route/ACL flags:** `advertiseRoutes`, `exitNode`, `acceptRoutes`, `acceptDns` still
  pass through to `tailscale up` (subnet router still works). The policy ConfigMap is NOT
  generated — route auto-approval and ACLs are configured on the remote headscale by its
  admin. Documented in values + README.

### Why the client needs TLS trust at all

The Tailscale data plane (WireGuard, DERP) does not use the HTTPS endpoint, but the
**control plane** does: node registration, key exchange, and the coordination long-poll
all run over HTTPS to `--login-server`. The client must validate that cert. Let's Encrypt /
public CAs are covered by the container's system bundle (zero config); `caSecretName` is
only for self-signed / private-CA remotes.

### Validation guards (hard `fail` at render time, in `_helpers.tpl`)

When `server.enabled=true`, the following are **forbidden** (set → error):
- `client.loginServer`
- `client.authKey` / `client.authKeySecret.name`
- `client.caSecretName`

When `server.enabled=false`:
- `client.enabled=false` too → fail ("nothing to deploy")
- `client.loginServer` empty → fail ("loginServer required in external mode")
- both `client.authKey` and `client.authKeySecret.name` empty → fail ("preauth key required")
- both set → fail ("set one, not both")

Each external-mode value is legal in exactly one mode.

## Testing

### Smoke test: new `--with-external-client` flag in `hack/kind-smoke.sh`

Single kind cluster, two releases in two namespaces (no second cluster — kind clusters are
on separate Docker networks; cross-namespace Service DNS resolves directly and exercises
the exact new code path):

1. Release **A** in `hs-server`: `server.enabled=true`, `client.enabled=false`.
2. Generate a real preauth key by `kubectl exec` into A's server pod
   (`headscale preauthkeys create`); store it in a Secret in `hs-client`. Mirrors a real
   remote admin handing over a key.
3. Release **B** in `hs-client`: `server.enabled=false`, `client.enabled=true`,
   `loginServer=http://headscale.hs-server.svc.cluster.local:8080`, `authKeySecret` → the
   Secret from step 2.
4. **Assert render:** release B has no server Deployment/Service/ConfigMap/UI.
5. **Assert live:** B's client pod comes up, `tailscale up` against A succeeds, B's
   `*-client-state` Secret appears (proves a real control-plane connection).

### CI

`.github/workflows/lint.yaml` continues to run `helm lint` + `helm template` only. The kind
smoke test stays local/manual, matching current behavior. Add a `helm template` invocation
with `server.enabled=false` values to CI so the new render path is linted on every PR.

## Out of scope

- True multi-cluster e2e (separate kind clusters with routable networking).
- Any change to in-cluster (`server.enabled=true`) behavior.
- OIDC config (already supported via `config.oidc`; tracked separately).
