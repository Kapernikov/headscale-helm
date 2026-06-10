# headscale

A Helm chart for deploying Headscale, an open-source implementation of the Tailscale control server.

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.28.0](https://img.shields.io/badge/AppVersion-0.28.0-informational?style=flat-square)

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

**Risk analysis — steps to take before enabling DaemonSet mode:**

- **Verify no subnet overlap.** The tailscale CGNAT range (`100.64.0.0/10`) and any subnets advertised by other tailscale nodes must not overlap with your cluster's pod CIDR, service CIDR, or node network. Overlapping ranges will cause unpredictable routing and can make pods or services unreachable.
- **Have a recovery plan.** DaemonSet mode modifies the host network stack directly. If something goes wrong (misconfigured DNS, route conflicts, tailscale crash), nodes can become unreachable over the cluster network. Ensure you have **out-of-band access** to every node (IPMI, cloud serial console, physical console) before enabling this mode.
- **Set `client.acceptDns: false`** unless you have verified that all nodes use `systemd-resolved` for split-DNS support. Without this, tailscale will overwrite `/etc/resolv.conf` on the host, breaking cluster DNS and making nodes unresolvable. See the [accept-dns](#accept-dns-clientacceptdns) section below.
- **Cilium users: prevent XDP crash on `tailscale0`.** The DaemonSet creates a `tailscale0` TUN device on each node. Cilium discovers all host interfaces and tries to attach XDP (eBPF) programs to them, but TUN devices do not support XDP. This causes Cilium to crash with `attaching XDP program to interface tailscale0: failed` (level=fatal), taking down pod networking on the node. The simplest fix is to set `loadBalancer.acceleration: best-effort` in your Cilium Helm values — this makes Cilium skip XDP on devices that don't support it instead of crashing. Alternatively, use `devices` to whitelist only the interfaces Cilium should manage, or `bpf.exclude-devices` to blacklist `tailscale0`.

**Warning:** DaemonSet mode uses host networking and runs on every node, directly modifying the host network stack. This means:

- The tailscale interface is created on the **host**, not inside a pod network namespace.
- By default, tailscale's `--accept-dns` flag is **true**, which rewrites the host's `/etc/resolv.conf` to use tailscale's DNS. On nodes without split-DNS support (e.g. **Talos Linux** or any distribution not using `systemd-resolved`), **this will break cluster DNS and can make nodes unreachable**. Set `client.acceptDns: false` to prevent this.
- IP forwarding (`net.ipv4.ip_forward`) is already enabled on Kubernetes nodes, so the chart does not set it in DaemonSet mode.
- **Route advertisement in DaemonSet mode:** When `client.advertiseRoutes` is set together with `client.daemonset=true`, every node will advertise the same routes as a subnet router. Headscale will pick one node as the primary router and use the others as failover. This is usually not what you want — it adds redundant subnet routers without real load balancing. If you need subnet routing, consider using the default Deployment mode (single replica) instead.

### accept-dns (`client.acceptDns`)

By default, tailscale enables `--accept-dns`, meaning it will configure the node to use tailscale's DNS resolver (MagicDNS). When running in Deployment mode (the default) this only affects the pod's network namespace and is generally harmless.

**In DaemonSet mode, this modifies the host's DNS configuration.** If your nodes use `systemd-resolved`, tailscale integrates cleanly via split-DNS. If your nodes do **not** use `systemd-resolved` (e.g. Talos Linux, Alpine-based nodes, many minimal distributions), tailscale will overwrite `/etc/resolv.conf`, breaking all non-tailscale DNS resolution including cluster DNS.

**Recommendation:** When using DaemonSet mode, always set `client.acceptDns: false` unless you have verified that your nodes support split-DNS via `systemd-resolved`.

## Client-only mode (join an external headscale)

Set `server.enabled=false` to deploy *only* the Tailscale client and join an
external headscale (for example, a central headscale reached over the internet).
All server-side resources are skipped. ACLs and subnet-route approval live on the
remote headscale and are managed by its administrator. The Tailscale Kubernetes
operator does not work with headscale, so this mode is the supported way to join
external clusters.

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

A publicly-trusted remote certificate (e.g. Let's Encrypt) needs no extra
configuration — the client's system CA bundle already trusts it. Only set
`caSecretName` when the remote headscale uses a self-signed or private-CA
certificate.

## TLS for In-Cluster Client

Tailscale v1.78+ has a [known issue](https://github.com/tailscale/tailscale/issues/15008) where reconnects force HTTPS even when the login server was specified with HTTP. This breaks the in-cluster client that connects to headscale over the cluster network. The chart provides TLS support to work around this, with three modes depending on your setup.

### Mode A: With Ingress (sidecar TLS)

When `ingress.enabled=true` and `client.enabled=true`, the chart adds an nginx TLS sidecar to the headscale server pod. The sidecar auto-generates a self-signed certificate and listens on port 443, proxying to headscale on port 8080. The client uses TOFU (trust on first use) to trust the sidecar certificate.

External clients connect through the ingress as before. The sidecar only serves the in-cluster client.

```yaml
ingress:
  enabled: true
  hosts:
    - host: headscale.example.com
      paths:
        - path: /
          pathType: ImplementationSpecific
tls:
  secretName: headscale-tls  # optional: also configures ingress TLS
client:
  enabled: true
```

### Mode B: Without Ingress (native TLS)

When `ingress.enabled=false` and `tls.secretName` is set, headscale serves TLS natively using the certificate from the secret. The client trusts the CA by mounting `ca.crt` from the same secret (works with cert-manager private CAs and public CAs).

```yaml
ingress:
  enabled: false
tls:
  secretName: headscale-tls  # must contain tls.crt, tls.key, optionally ca.crt
client:
  enabled: true
```

With cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: headscale-tls
spec:
  secretName: headscale-tls
  issuerRef:
    name: my-ca-issuer
    kind: ClusterIssuer
  dnsNames:
    - headscale.default.svc.cluster.local
```

### Mode C: No TLS (legacy)

When `tls.secretName` is empty and no ingress is enabled, everything stays HTTP. This is the default and works for pinned older tailscale versions that don't have the reconnect bug.

### TLS Decision Logic

| `ingress.enabled` | `tls.secretName` | `client.enabled` | Result |
|---|---|---|---|
| true | set | true | Ingress uses secret for external TLS. Sidecar handles internal TLS. Client uses TOFU. |
| true | unset | true | Ingress HTTP-only. Sidecar handles internal TLS. Client uses TOFU. |
| false | set | true | Headscale serves TLS natively. Client trusts `ca.crt` from secret. |
| false | unset | true | Plain HTTP (legacy). |
| any | any | false | No client deployed. TLS config only affects external access. |

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

Pass `--with-client` if you also want to deploy the optional Tailscale sidecar and verify the init container flow:

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
| client.acceptDns | string | <code>"unset"</code> | Override accept-dns flag. In daemonset mode this rewrites the host /etc/resolv.conf. On nodes without split-DNS (e.g. Talos) this breaks cluster DNS. Set to false unless your nodes use systemd-resolved. |
| client.acceptRoutes | string | <code>"unset"</code> | Override accept-routes flag. When true, the client accepts subnet routes advertised by other nodes on the tailnet. Defaults to tailscale's built-in default (false) when left as "unset". |
| client.advertiseRoutes | list | <code>[]</code> | Routes to advertise to the Tailscale network. When configured, IP forwarding is enabled and the client acts as a subnet router. WARNING: Using 0.0.0.0/0 or ::/0 (exit node mode) will also expose all Kubernetes pods and services to clients using this exit node. |
| client.authKey | string | <code>""</code> | Inline preauth key for external mode. The chart creates a Secret from it. Mutually exclusive with authKeySecret. Only valid when server.enabled=false. |
| client.authKeySecret | object | <code>{"key":<wbr>"authkey",<wbr>"name":<wbr>""}</code> | Reference an existing Secret holding the preauth key (external mode). Mutually exclusive with authKey. Only valid when server.enabled=false. |
| client.caSecretName | string | <code>""</code> | Optional Secret containing a ca.crt to trust the external headscale's TLS certificate (self-signed / private CA). Empty = rely on the system CA bundle (covers Let's Encrypt and other public CAs). Only valid when server.enabled=false. |
| client.daemonset | bool | <code>false</code> | Run the client as a DaemonSet with hostNetwork, giving every node direct tailnet connectivity. Useful when nodes need to reach tailnet IPs directly (e.g. pulling images from a private registry on the tailnet). WARNING: DaemonSet mode uses hostNetwork and runs privileged on every node, modifying the host network stack. Combined with accept-dns (on by default), this can replace the node's DNS resolver and break cluster DNS on distributions without split-DNS support (e.g. Talos Linux). See client.acceptDns. |
| client.enabled | bool | <code>true</code> | Enable or disable the tailscale client container. |
| client.exitNode | bool | <code>false</code> | Enable exit node functionality. When set to true, the client will advertise itself as an exit node. This requires advertiseRoutes to include at least 0.0.0.0/0 and/or ::/0. |
| client.image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| client.image.repository | string | <code>"tailscale/<wbr>tailscale"</code> |  |
| client.image.tag | string | <code>"stable"</code> |  |
| client.internalTls | object | <code>{"image":<wbr>{"pullPolicy":<wbr>"IfNotPresent",<wbr>"repository":<wbr>"nginx",<wbr>"tag":<wbr>"alpine"}}</code> | TLS sidecar settings for internal client connectivity. Auto-enabled when both client and ingress are active. |
| client.job.cronjob.enabled | bool | <code>false</code> |  |
| client.job.cronjob.schedule | string | <code>"0 3 1 * *"</code> |  |
| client.job.image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| client.job.image.repository | string | <code>"alpine/<wbr>k8s"</code> |  |
| client.job.image.tag | string | <code>"1.30.2"</code> |  |
| client.loginServer | string | <code>""</code> | URL of an EXTERNAL headscale to join (client-only mode). Required when server.enabled=false; FORBIDDEN when server.enabled=true. Include the scheme, e.g. https://headscale.example.com |
| client.podDisruptionBudget | object | <code>{"enabled":<wbr>true,<wbr>"maxUnavailable":<wbr>1}</code> | Pod disruption budget settings for the optional client deployment. |
| client.preauthKeyExpiration | string | <code>"87600h"</code> | Expiration for the client preauthkey. Headscale defaults to 1h when omitted, which causes the in-cluster client to lose connectivity once the key expires. Set to a long duration to keep the client connected across restarts. The key management job is idempotent and only creates a new key when no valid one exists. |
| config.database.sqlite.path | string | <code>"/<wbr>var/<wbr>lib/<wbr>headscale/<wbr>db.sqlite"</code> |  |
| config.database.type | string | <code>"sqlite"</code> |  |
| config.derp.urls[0] | string | <code>"https:<wbr>/<wbr>/<wbr>controlplane.tailscale.com/<wbr>derpmap/<wbr>default"</code> |  |
| config.dns.base_domain | string | <code>"headscale.local"</code> |  |
| config.dns.magic_dns | bool | <code>true</code> |  |
| config.dns.nameservers.global[0] | string | <code>"1.1.1.1"</code> |  |
| config.dns.nameservers.global[1] | string | <code>"8.8.8.8"</code> |  |
| config.dns.override_local_dns | bool | <code>true</code> |  |
| config.listen_addr | string | <code>"0.0.0.0:<wbr>8080"</code> |  |
| config.noise.private_key_path | string | <code>"/<wbr>var/<wbr>lib/<wbr>headscale/<wbr>noise_private.key"</code> |  |
| config.prefixes.v4 | string | <code>"100.64.0.0/<wbr>10"</code> |  |
| config.prefixes.v6 | string | <code>"fd7a:<wbr>115c:<wbr>a1e0:<wbr>:<wbr>/<wbr>48"</code> |  |
| config.server_url | string | <code>""</code> |  |
| configMap.create | bool | <code>true</code> |  |
| derpMap.configMap.create | bool | <code>true</code> |  |
| derpMap.configMap.key | string | <code>"derp-map.yaml"</code> |  |
| derpMap.configMap.name | string | <code>""</code> |  |
| derpMap.content | object | <code>{}</code> |  |
| derpMap.enabled | bool | <code>false</code> |  |
| derpMap.path | string | <code>"/<wbr>etc/<wbr>headscale/<wbr>derp-map.yaml"</code> |  |
| extraDnsRecords.configMap.create | bool | <code>true</code> |  |
| extraDnsRecords.configMap.key | string | <code>"extra-dns-records.json"</code> |  |
| extraDnsRecords.configMap.name | string | <code>""</code> |  |
| extraDnsRecords.enabled | bool | <code>false</code> |  |
| extraDnsRecords.path | string | <code>"/<wbr>etc/<wbr>headscale/<wbr>extra-dns-records.json"</code> |  |
| extraDnsRecords.records | list | <code>[]</code> |  |
| extraVolumeMounts | list | <code>[]</code> |  |
| extraVolumes | list | <code>[]</code> |  |
| forbiddenNodeNames.enabled | bool | <code>false</code> |  |
| forbiddenNodeNames.job.image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| forbiddenNodeNames.job.image.repository | string | <code>"alpine/<wbr>k8s"</code> |  |
| forbiddenNodeNames.job.image.tag | string | <code>"1.30.2"</code> |  |
| forbiddenNodeNames.names[0] | string | <code>"localhost"</code> |  |
| forbiddenNodeNames.schedule | string | <code>"*/<wbr>15 * * * *"</code> |  |
| fullnameOverride | string | <code>""</code> |  |
| image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| image.repository | string | <code>"headscale/<wbr>headscale"</code> |  |
| image.tag | string | <code>"v0.28.0"</code> |  |
| imagePullSecrets | list | <code>[]</code> |  |
| ingress.annotations | object | <code>{}</code> |  |
| ingress.className | string | <code>"nginx"</code> |  |
| ingress.enabled | bool | <code>false</code> |  |
| ingress.hosts[0].host | string | <code>"headscale.local"</code> |  |
| ingress.hosts[0].paths[0].path | string | <code>"/<wbr>"</code> |  |
| ingress.hosts[0].paths[0].pathType | string | <code>"ImplementationSpecific"</code> |  |
| ingress.tls | list | <code>[]</code> |  |
| livenessProbe.failureThreshold | int | <code>3</code> |  |
| livenessProbe.httpGet.path | string | <code>"/<wbr>health"</code> |  |
| livenessProbe.httpGet.port | string | <code>"http"</code> |  |
| livenessProbe.initialDelaySeconds | int | <code>10</code> |  |
| livenessProbe.periodSeconds | int | <code>5</code> |  |
| livenessProbe.timeoutSeconds | int | <code>3</code> |  |
| nameOverride | string | <code>""</code> |  |
| persistence.accessModes[0] | string | <code>"ReadWriteOnce"</code> |  |
| persistence.enabled | bool | <code>true</code> |  |
| persistence.existingClaim | string | <code>""</code> |  |
| persistence.size | string | <code>"1Gi"</code> |  |
| persistence.storageClassName | string | <code>""</code> |  |
| podAnnotations | object | <code>{}</code> |  |
| podDisruptionBudget.enabled | bool | <code>true</code> |  |
| podDisruptionBudget.maxUnavailable | int | <code>1</code> |  |
| podLabels | object | <code>{}</code> |  |
| podSecurityContext.fsGroup | int | <code>1000</code> |  |
| policy.configMap.create | bool | <code>true</code> |  |
| policy.configMap.key | string | <code>"policy.json"</code> |  |
| policy.configMap.name | string | <code>""</code> |  |
| policy.content | object | <code>{}</code> |  |
| policy.enabled | bool | <code>false</code> |  |
| policy.hotReload.enabled | bool | <code>false</code> |  |
| policy.hotReload.image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| policy.hotReload.image.repository | string | <code>"kiwigrid/<wbr>k8s-sidecar"</code> |  |
| policy.hotReload.image.tag | string | <code>"1.30.3"</code> |  |
| policy.path | string | <code>"/<wbr>etc/<wbr>headscale/<wbr>policy.json"</code> |  |
| readinessProbe.failureThreshold | int | <code>3</code> |  |
| readinessProbe.httpGet.path | string | <code>"/<wbr>health"</code> |  |
| readinessProbe.httpGet.port | string | <code>"http"</code> |  |
| readinessProbe.initialDelaySeconds | int | <code>10</code> |  |
| readinessProbe.periodSeconds | int | <code>5</code> |  |
| readinessProbe.timeoutSeconds | int | <code>3</code> |  |
| resources | object | <code>{}</code> |  |
| runtime.socketDir | string | <code>"/<wbr>var/<wbr>run/<wbr>headscale"</code> |  |
| securityContext.allowPrivilegeEscalation | bool | <code>false</code> |  |
| securityContext.capabilities.drop[0] | string | <code>"ALL"</code> |  |
| securityContext.readOnlyRootFilesystem | bool | <code>false</code> |  |
| securityContext.runAsGroup | int | <code>1000</code> |  |
| securityContext.runAsNonRoot | bool | <code>true</code> |  |
| securityContext.runAsUser | int | <code>1000</code> |  |
| server.enabled | bool | <code>true</code> |  |
| service.port | int | <code>8080</code> |  |
| service.type | string | <code>"ClusterIP"</code> |  |
| serviceAccount.annotations | object | <code>{}</code> |  |
| serviceAccount.create | bool | <code>true</code> |  |
| serviceAccount.name | string | <code>""</code> |  |
| tls.secretName | string | <code>""</code> | Name of a Kubernetes TLS Secret (must contain tls.crt, tls.key, optionally ca.crt). |
| ui.configMap.create | bool | <code>true</code> |  |
| ui.configMap.data | object | <code>{}</code> |  |
| ui.configMap.enabled | bool | <code>false</code> |  |
| ui.configMap.key | string | <code>"config.yaml"</code> |  |
| ui.configMap.name | string | <code>""</code> |  |
| ui.configMap.path | string | <code>"/<wbr>app/<wbr>config.yaml"</code> |  |
| ui.containerPort | int | <code>8080</code> |  |
| ui.enabled | bool | <code>false</code> |  |
| ui.extraEnv | list | <code>[]</code> |  |
| ui.headscaleUrl | string | <code>""</code> |  |
| ui.headscaleUrlEnvName | string | <code>"HEADSCALE_URL"</code> |  |
| ui.image.pullPolicy | string | <code>"IfNotPresent"</code> |  |
| ui.image.repository | string | <code>"ghcr.io/<wbr>gurucomputing/<wbr>headscale-ui"</code> |  |
| ui.image.tag | string | <code>"latest"</code> |  |
| ui.ingress.annotations | object | <code>{}</code> |  |
| ui.ingress.host | string | <code>""</code> |  |
| ui.ingress.path | string | <code>"/<wbr>web"</code> |  |
| ui.ingress.pathType | string | <code>"ImplementationSpecific"</code> |  |
| ui.ingress.tls | list | <code>[]</code> |  |
| ui.persistence.accessModes[0] | string | <code>"ReadWriteOnce"</code> |  |
| ui.persistence.enabled | bool | <code>false</code> |  |
| ui.persistence.existingClaim | string | <code>""</code> |  |
| ui.persistence.mountPath | string | <code>"/<wbr>var/<wbr>lib/<wbr>headscale-ui"</code> |  |
| ui.persistence.size | string | <code>"1Gi"</code> |  |
| ui.persistence.storageClassName | string | <code>""</code> |  |
| ui.podDisruptionBudget.enabled | bool | <code>true</code> |  |
| ui.podDisruptionBudget.maxUnavailable | int | <code>1</code> |  |
| ui.service.port | int | <code>8080</code> |  |
| ui.service.type | string | <code>"ClusterIP"</code> |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
