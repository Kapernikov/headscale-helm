# Policy Hot-Reload Sidecar

Related: PR #7 (tekulvw/improvements) — policy hot-reload concept originated there.

## Problem

When ACL policy ConfigMaps are updated, the headscale server pod must be restarted to pick up changes. Users with Stakater Reloader or similar tools can handle this externally, but users without such tools have no built-in option.

## Design

Add an optional `kiwigrid/k8s-sidecar` as a native sidecar (restartable init container) that watches for labeled ConfigMaps and syncs them into the pod filesystem. Headscale detects file changes and reloads policy automatically.

### Values

```yaml
policy:
  hotReload:
    enabled: false
    image:
      repository: kiwigrid/k8s-sidecar
      tag: "1.30.3"
      pullPolicy: IfNotPresent
```

### Behavior when enabled

1. Sidecar watches ConfigMaps labeled `headscale-policy: "true"` via `METHOD: WATCH`
2. Policy ConfigMap gets the `headscale-policy: "true"` label
3. Policy volume switches from direct ConfigMap mount (subPath) to emptyDir populated by sidecar
4. Policy path becomes `/etc/headscale/policy/policy.json` (directory mount instead of file mount)
5. Role/RoleBinding added for main SA to `list/get/watch` ConfigMaps

### Behavior when disabled (default)

No changes from current behavior. Policy is mounted as a standard ConfigMap volume.

### Files touched

- `values.yaml` — new `policy.hotReload` section
- `values.schema.json` — schema for new fields
- `deployment.yaml` — conditional sidecar + volume switch
- `policy-configmap.yaml` — conditional label
- `serviceaccount.yaml` — conditional RBAC
- `configmap.yaml` — conditional policy path adjustment
