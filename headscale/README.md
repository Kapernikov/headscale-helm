# headscale

A Helm chart for deploying Headscale, an open-source implementation of the Tailscale control server.

![Version: 0.1.2](https://img.shields.io/badge/Version-0.1.2-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.27.0](https://img.shields.io/badge/AppVersion-0.27.0-informational?style=flat-square)

## Client Container

This Helm chart includes an optional client container that runs a Tailscale client (`tailscaled`) alongside the Headscale server. This client automatically registers with the Headscale server using a pre-authenticated key, simplifying the initial setup for testing or demonstration purposes.

The client container is configured to:
- Start the `tailscaled` daemon in the background.
- Use `tailscale up` to connect to the Headscale server.

You can enable or disable the client container via the `client.enabled` value in `values.yaml`.

## Persistence

Headscale requires persistence to store its database and noise private key. This chart configures a PersistentVolumeClaim (PVC) to ensure that Headscale's data is not lost across pod restarts or redeployments.

By default, persistence is enabled with a 1Gi volume. You can configure the size through the `persistence` section in `values.yaml`. Data is stored at `/var/lib/headscale` inside the container and this mount path is fixed by the chart.

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

## Installing the Chart

To install the chart with the release name `my-release`:

```console
$ helm repo add foo-bar http://charts.foo-bar.com
$ helm install my-release foo-bar/headscale
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| autoscaling.enabled | bool | `false` |  |
| autoscaling.maxReplicas | int | `100` |  |
| autoscaling.minReplicas | int | `1` |  |
| autoscaling.targetCPUUtilizationPercentage | int | `80` |  |
| client.enabled | bool | `true` |  |
| client.image.pullPolicy | string | `"IfNotPresent"` |  |
| client.image.repository | string | `"tailscale/tailscale"` |  |
| client.image.tag | string | `"latest"` |  |
| client.job.image.pullPolicy | string | `"IfNotPresent"` |  |
| client.job.image.repository | string | `"alpine/k8s"` |  |
| client.job.image.tag | string | `"1.30.2"` |  |
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
| extraDnsRecords.configMap.create | bool | `true` |  |
| extraDnsRecords.configMap.key | string | `"extra-dns-records.json"` |  |
| extraDnsRecords.configMap.name | string | `""` |  |
| extraDnsRecords.enabled | bool | `false` |  |
| extraDnsRecords.path | string | `"/etc/headscale/extra-dns-records.json"` |  |
| extraDnsRecords.records | list | `[]` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"headscale/headscale"` |  |
| image.tag | string | `"v0.27.0"` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/client-body-buffer-size" | string | `"1m"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/enable-websocket" | string | `"true"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-body-size" | string | `"8000m"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-read-timeout" | string | `"3600"` |  |
| ingress.annotations."nginx.ingress.kubernetes.io/proxy-send-timeout" | string | `"3600"` |  |
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
| persistence.enabled | bool | `true` |  |
| persistence.size | string | `"1Gi"` |  |
| podAnnotations | object | `{}` |  |
| podLabels | object | `{}` |  |
| podSecurityContext | object | `{}` |  |
| readinessProbe.failureThreshold | int | `3` |  |
| readinessProbe.httpGet.path | string | `"/health"` |  |
| readinessProbe.httpGet.port | string | `"http"` |  |
| readinessProbe.initialDelaySeconds | int | `10` |  |
| readinessProbe.periodSeconds | int | `5` |  |
| readinessProbe.timeoutSeconds | int | `3` |  |
| replicaCount | int | `1` |  |
| resources | object | `{}` |  |
| securityContext | object | `{}` |  |
| service.port | int | `8080` |  |
| service.type | string | `"ClusterIP"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `true` |  |
| serviceAccount.name | string | `""` |  |
| ui.enabled | bool | `false` |  |
| ui.extraEnv | list | `[]` |  |
| ui.headscaleUrl | string | `""` |  |
| ui.image.pullPolicy | string | `"IfNotPresent"` |  |
| ui.image.repository | string | `"ghcr.io/gurucomputing/headscale-ui"` |  |
| ui.image.tag | string | `"latest"` |  |
| ui.ingress.annotations | object | `{}` |  |
| ui.ingress.host | string | `""` |  |
| ui.ingress.path | string | `"/web"` |  |
| ui.ingress.pathType | string | `"ImplementationSpecific"` |  |
| ui.ingress.tls | list | `[]` |  |
| ui.replicaCount | int | `1` |  |
| ui.service.port | int | `80` |  |
| ui.service.type | string | `"ClusterIP"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
