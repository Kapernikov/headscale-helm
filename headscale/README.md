# headscale

A Helm chart for deploying Headscale, an open-source implementation of the Tailscale control server.

![Version: 0.1.6](https://img.shields.io/badge/Version-0.1.6-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.28.0](https://img.shields.io/badge/AppVersion-0.28.0-informational?style=flat-square)

## Client Container

This Helm chart includes an optional client container that runs a Tailscale client (`tailscaled`) alongside the Headscale server. This client automatically registers with the Headscale server using a pre-authenticated key, simplifying the initial setup for testing or demonstration purposes.

The client container is configured to:
- Start the `tailscaled` daemon in the background.
- Use `tailscale up` to connect to the Headscale server.
- Optionally advertise routes to act as a subnet router.
- Optionally advertise itself as an exit node.

You can enable or disable the client container via the `client.enabled` value in `values.yaml`. Configure subnet routing with `client.advertiseRoutes` and exit node functionality with `client.exitNode`.

**Warning:** Using the client as an exit node (or advertising `0.0.0.0/0` and `::/0` routes) exposes all Kubernetes pods and services to nodes using this exit node. This is usually not recommended. Only enable this if you understand the security implications.

### DaemonSet Mode

Setting `client.daemonset=true` deploys the client as a DaemonSet with `hostNetwork: true`, giving every node direct tailnet connectivity. This is useful when nodes need to reach tailnet IPs directly (e.g. pulling images from a private registry on the tailnet).

**Warning:** DaemonSet mode uses host networking and runs on every node, directly modifying the host network stack. This means:

- The tailscale interface is created on the **host**, not inside a pod network namespace.
- By default, tailscale's `--accept-dns` flag is **true**, which rewrites the host's `/etc/resolv.conf` to use tailscale's DNS. On nodes without split-DNS support (e.g. **Talos Linux** or any distribution not using `systemd-resolved`), **this will break cluster DNS and can make nodes unreachable**. Set `client.acceptDns: false` to prevent this.
- IP forwarding (`net.ipv4.ip_forward`) is already enabled on Kubernetes nodes, so the chart does not set it in DaemonSet mode.

### accept-dns (`client.acceptDns`)

By default, tailscale enables `--accept-dns`, meaning it will configure the node to use tailscale's DNS resolver (MagicDNS). When running in Deployment mode (the default) this only affects the pod's network namespace and is generally harmless.

**In DaemonSet mode, this modifies the host's DNS configuration.** If your nodes use `systemd-resolved`, tailscale integrates cleanly via split-DNS. If your nodes do **not** use `systemd-resolved` (e.g. Talos Linux, Alpine-based nodes, many minimal distributions), tailscale will overwrite `/etc/resolv.conf`, breaking all non-tailscale DNS resolution including cluster DNS.

**Recommendation:** When using DaemonSet mode, always set `client.acceptDns: false` unless you have verified that your nodes support split-DNS via `systemd-resolved`.

## Persistence

Headscale requires persistence to store its database and noise private key. This chart configures a PersistentVolumeClaim (PVC) to ensure that Headscale's data is not lost across pod restarts or redeployments.

By default, persistence is enabled with a 1Gi volume. You can configure the size, access modes, and storage class through the `persistence` section in `values.yaml`. Set `persistence.existingClaim` to reuse a pre-created PVC. Data is stored at `/var/lib/headscale` inside the container and this mount path is fixed by the chart.

## Ingress

The chart provides an option to expose the Headscale service via an Ingress resource. This allows you to access your Headscale instance from outside the Kubernetes cluster using a domain name.

You can enable Ingress by setting `ingress.enabled` to `true` in `values.yaml`. You can also configure the Ingress class, hosts, TLS settings, and annotations to customize its behavior for your environment.

Important: the Headscale `server_url` must match the external hostname clients use (typically your Ingress host). This chart auto-populates `config.server_url` from the first `ingress.hosts[].host` when `ingress.enabled` is true and `config.server_url` is empty. If you set `config.server_url` explicitly, ensure it matches your Ingress hostname and scheme (https when TLS is enabled), otherwise clients may fail to connect with noise/decrypt errors.

WebSockets must be supported by your ingress for Headscale to work correctly. For ingress-nginx, the chart defaults include annotations enabling WebSockets and long-lived timeouts:

```yaml
ingress:
  annotations:
    nginx.ingress.kubernetes.io/enable-websocket: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
```
If you use another ingress controller, configure equivalent settings to allow WebSocket upgrades and long read/send timeouts.

## Extra DNS Records

Headscale can serve additional MagicDNS entries by pointing `dns.extra_records_path` at a JSON file. The chart wires this up through `extraDnsRecords`, letting you either supply records inline or reference an existing ConfigMap.

- Set `extraDnsRecords.enabled=true` to mount a JSON file and set `dns.extra_records_path`.
- When `extraDnsRecords.configMap.create=true` (default), the chart renders the list under `extraDnsRecords.records` into a ConfigMap.
- To reuse an existing ConfigMap, set `extraDnsRecords.configMap.create=false` and provide the `name`/`key` that contain your JSON payload.

Inline example:

```yaml
extraDnsRecords:
  enabled: true
  path: /etc/headscale/extra-dns-records.json
  records:
    - name: grafana.internal.example.com
      type: A
      value: 100.64.0.10
    - name: prometheus.internal.example.com
      type: A
      value: 100.64.0.10
```

Referencing an existing ConfigMap:

```yaml
extraDnsRecords:
  enabled: true
  configMap:
    create: false
    name: shared-dns-records
    key: records.json
  path: /etc/headscale/extra-dns-records.json
```

## Headscale UI

This chart can optionally deploy the community Headscale UI (`gurucomputing/headscale-ui`).

- Enable by setting `ui.enabled` to `true`.
- A separate `Service` named `<release>-headscale-ui` is created on port `ui.service.port` (default 80).
- When `ingress.enabled=true`, the UI is exposed on the same hostname as Headscale under a subpath (default `/web`). The UI has its own `Ingress` resource that targets the same host as the main ingress, with its path set from `ui.ingress.path`.
- `HEADSCALE_URL` defaults to the external scheme+host from the main Ingress when Ingress is enabled; otherwise it falls back to the internal cluster service. You can override via `ui.headscaleUrl`.
- Optional UI persistence creates a PVC and mounts it at `ui.persistence.mountPath`. Set `ui.persistence.existingClaim` to reuse a pre-created PVC.

Example snippet:

```yaml
ingress:
  enabled: true
  hosts:
    - host: headscale.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific

ui:
  enabled: true
  # Optional override; by default uses https://headscale.example.com when TLS is enabled
  # headscaleUrl: "https://headscale.example.com"
  ingress:
  path: /web
  pathType: ImplementationSpecific
  persistence:
    enabled: true
    mountPath: /var/lib/headscale-ui
    size: 5Gi
```

## Local Testing with kind

For a quick local smoke test you can use [kind](https://kind.sigs.k8s.io). The repository provides `hack/kind-smoke.sh`, which spins up a temporary kind cluster, installs the chart (with sample extra DNS records), verifies readiness, and tears everything down by default.

```console
$ hack/kind-smoke.sh
```

Use `hack/kind-smoke.sh --keep` to retain the cluster for further inspection.

Pass `--with-client` if you also want to deploy the optional Tailscale sidecar and verify the hook/job flow:

```console
$ hack/kind-smoke.sh --with-client
```

## Disruption Budgets

Every workload deployed by the chart (server, UI, and optional client) now includes a PodDisruptionBudget to describe how voluntary disruptions should be handled. By default each budget sets `maxUnavailable: 1`, which lets Kubernetes evict the single replica when needed (e.g., for node drains) without blocking cluster operations. You can toggle or adjust these budgets through `podDisruptionBudget`, `ui.podDisruptionBudget`, and `client.podDisruptionBudget` in `values.yaml`. Set `enabled: false` to skip creating a budget or provide your own `minAvailable`/`maxUnavailable` values to better match your topology.

## Installing the Chart

To install the chart with the release name `my-release`:

```console
$ helm repo add foo-bar http://charts.foo-bar.com
$ helm install my-release foo-bar/headscale
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| client.acceptDns | string | `"unset"` | Override accept-dns flag. In daemonset mode this rewrites the host /etc/resolv.conf. On nodes without split-DNS (e.g. Talos) this breaks cluster DNS. Set to false unless your nodes use systemd-resolved. |
| client.advertiseRoutes | list | `[]` | Routes to advertise to the Tailscale network. When configured, IP forwarding is enabled and the client acts as a subnet router. WARNING: Using 0.0.0.0/0 or ::/0 (exit node mode) will also expose all Kubernetes pods and services to clients using this exit node. |
| client.daemonset | bool | `false` | Run the client as a DaemonSet with hostNetwork, giving every node direct tailnet connectivity. Useful when nodes need to reach tailnet IPs directly (e.g. pulling images from a private registry on the tailnet). WARNING: DaemonSet mode uses hostNetwork and runs privileged on every node, modifying the host network stack. Combined with accept-dns (on by default), this can replace the node's DNS resolver and break cluster DNS on distributions without split-DNS support (e.g. Talos Linux). See client.acceptDns. |
| client.enabled | bool | `true` | Enable or disable the tailscale client container. |
| client.exitNode | bool | `false` | Enable exit node functionality. When set to true, the client will advertise itself as an exit node. This requires advertiseRoutes to include at least 0.0.0.0/0 and/or ::/0. |
| client.image.pullPolicy | string | `"IfNotPresent"` |  |
| client.image.repository | string | `"tailscale/tailscale"` |  |
| client.image.tag | string | `"stable"` |  |
| client.job.cronjob.enabled | bool | `false` |  |
| client.job.cronjob.schedule | string | `"0 3 1 * *"` |  |
| client.job.image.pullPolicy | string | `"IfNotPresent"` |  |
| client.job.image.repository | string | `"alpine/k8s"` |  |
| client.job.image.tag | string | `"1.30.2"` |  |
| client.podDisruptionBudget | object | `{"enabled":true,"maxUnavailable":1}` | Pod disruption budget settings for the optional client deployment. |
| client.preauthKeyExpiration | string | `"87600h"` | Expiration for the client preauthkey. Headscale defaults to 1h when omitted, which causes the in-cluster client to lose connectivity once the key expires. Set to a long duration to keep the client connected across restarts. The key management job is idempotent and only creates a new key when no valid one exists. |
| config.database.sqlite.path | string | `"/var/lib/headscale/db.sqlite"` |  |
| config.database.type | string | `"sqlite"` |  |
| config.derp.urls[0] | string | `"https://controlplane.tailscale.com/derpmap/default"` |  |
| config.dns.base_domain | string | `"headscale.local"` |  |
| config.dns.magic_dns | bool | `true` |  |
| config.dns.nameservers.global[0] | string | `"1.1.1.1"` |  |
| config.dns.nameservers.global[1] | string | `"8.8.8.8"` |  |
| config.dns.override_local_dns | bool | `true` |  |
| config.listen_addr | string | `"0.0.0.0:8080"` |  |
| config.noise.private_key_path | string | `"/var/lib/headscale/noise_private.key"` |  |
| config.prefixes.v4 | string | `"100.64.0.0/10"` |  |
| config.prefixes.v6 | string | `"fd7a:115c:a1e0::/48"` |  |
| config.server_url | string | `""` |  |
| configMap.create | bool | `true` |  |
| derpMap.configMap.create | bool | `true` |  |
| derpMap.configMap.key | string | `"derp-map.yaml"` |  |
| derpMap.configMap.name | string | `""` |  |
| derpMap.content | object | `{}` |  |
| derpMap.enabled | bool | `false` |  |
| derpMap.path | string | `"/etc/headscale/derp-map.yaml"` |  |
| extraDnsRecords.configMap.create | bool | `true` |  |
| extraDnsRecords.configMap.key | string | `"extra-dns-records.json"` |  |
| extraDnsRecords.configMap.name | string | `""` |  |
| extraDnsRecords.enabled | bool | `false` |  |
| extraDnsRecords.path | string | `"/etc/headscale/extra-dns-records.json"` |  |
| extraDnsRecords.records | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"headscale/headscale"` |  |
| image.tag | string | `"v0.28.0"` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{}` |  |
| ingress.className | string | `"nginx"` |  |
| ingress.enabled | bool | `false` |  |
| ingress.hosts[0].host | string | `"headscale.local"` |  |
| ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ingress.tls | list | `[]` |  |
| livenessProbe.failureThreshold | int | `3` |  |
| livenessProbe.httpGet.path | string | `"/health"` |  |
| livenessProbe.httpGet.port | string | `"http"` |  |
| livenessProbe.initialDelaySeconds | int | `10` |  |
| livenessProbe.periodSeconds | int | `5` |  |
| livenessProbe.timeoutSeconds | int | `3` |  |
| nameOverride | string | `""` |  |
| persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| persistence.enabled | bool | `true` |  |
| persistence.existingClaim | string | `""` |  |
| persistence.size | string | `"1Gi"` |  |
| persistence.storageClassName | string | `""` |  |
| podAnnotations | object | `{}` |  |
| podDisruptionBudget.enabled | bool | `true` |  |
| podDisruptionBudget.maxUnavailable | int | `1` |  |
| podLabels | object | `{}` |  |
| podSecurityContext.fsGroup | int | `1000` |  |
| policy.configMap.create | bool | `true` |  |
| policy.configMap.key | string | `"policy.json"` |  |
| policy.configMap.name | string | `""` |  |
| policy.content | object | `{}` |  |
| policy.enabled | bool | `false` |  |
| policy.path | string | `"/etc/headscale/policy.json"` |  |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.httpGet.path | string | `"/health"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| readinessProbe.initialDelaySeconds | int | `10` |  |
| readinessProbe.periodSeconds | int | `5` |  |
| readinessProbe.timeoutSeconds | int | `3` |  |
| resources | object | `{}` |  |
| runtime.socketDir | string | `"/var/run/headscale"` |  |
| securityContext.allowPrivilegeEscalation | bool | `false` |  |
| securityContext.capabilities.drop[0] | string | `"ALL"` |  |
| securityContext.readOnlyRootFilesystem | bool | `false` |  |
| securityContext.runAsGroup | int | `1000` |  |
| securityContext.runAsNonRoot | bool | `true` |  |
| securityContext.runAsUser | int | `1000` |  |
| service.port | int | `8080` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| ui.configMap.create | bool | `true` |  |
| ui.configMap.data | object | `{}` |  |
| ui.configMap.enabled | bool | `false` |  |
| ui.configMap.key | string | `"config.yaml"` |  |
| ui.configMap.name | string | `""` |  |
| ui.configMap.path | string | `"/app/config.yaml"` |  |
| ui.containerPort | int | `8080` |  |
| ui.enabled | bool | `false` |  |
| ui.extraEnv | list | `[]` |  |
| ui.headscaleUrl | string | `""` |  |
| ui.headscaleUrlEnvName | string | `"HEADSCALE_URL"` |  |
| ui.image.pullPolicy | string | `"IfNotPresent"` |  |
| ui.image.repository | string | `"ghcr.io/gurucomputing/headscale-ui"` |  |
| ui.image.tag | string | `"latest"` |  |
| ui.ingress.annotations | object | `{}` |  |
| ui.ingress.host | string | `""` |  |
| ui.ingress.path | string | `"/web"` |  |
| ui.ingress.pathType | string | `"ImplementationSpecific"` |  |
| ui.ingress.tls | list | `[]` |  |
| ui.persistence.accessModes[0] | string | `"ReadWriteOnce"` |  |
| ui.persistence.enabled | bool | `false` |  |
| ui.persistence.existingClaim | string | `""` |  |
| ui.persistence.mountPath | string | `"/var/lib/headscale-ui"` |  |
| ui.persistence.size | string | `"1Gi"` |  |
| ui.persistence.storageClassName | string | `""` |  |
| ui.podDisruptionBudget.enabled | bool | `true` |  |
| ui.podDisruptionBudget.maxUnavailable | int | `1` |  |
| ui.service.port | int | `8080` |  |
| ui.service.type | string | `"ClusterIP"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
