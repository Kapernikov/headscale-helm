# headscale

A Helm chart for deploying Headscale, an open-source implementation of the Tailscale control server.

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.23.0](https://img.shields.io/badge/AppVersion-0.23.0-informational?style=flat-square)

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

## Headscale UI

This chart can optionally deploy the community Headscale UI from `gurucomputing/headscale-ui`.

- Enable by setting `ui.enabled` to `true`.
- A separate `Service` named `<release>-headscale-ui` is created on port `ui.service.port` (default 80).
- If `ingress.enabled` is also `true`, an additional `Ingress` is created for the UI using `ui.ingress.*` (host, path, pathType, annotations, tls). The UI Ingress uses the same `ingress.className` as the main service.

Example snippet:

```yaml
ui:
  enabled: true
  headscaleUrl: "http://my-release-headscale.default.svc.cluster.local:8080" # optional, defaults to internal service
  ingress:
    host: headscale-ui.example.com
    path: /
    pathType: ImplementationSpecific
    tls:
      - secretName: headscale-ui-tls
        hosts: [headscale-ui.example.com]
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
| config.client.enabled | bool | `true` |  |
| config.client.image.pullPolicy | string | `"IfNotPresent"` |  |
| config.client.image.repository | string | `"tailscale/tailscale"` |  |
| config.client.image.tag | string | `"latest"` |  |
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
| config.server_url | string | `""` | When empty and ingress.enabled=true, derived from ingress host; otherwise defaults to internal service URL. Must match external hostname.
| configMap.create | bool | `true` |  |
| fullnameOverride | string | `""` |  |
| image.pullPolicy | string | `"IfNotPresent"` |  |
| image.repository | string | `"headscale/headscale"` |  |
| image.tag | string | `"v0.26.1"` |  |
| imagePullSecrets | list | `[]` |  |
| ingress.annotations | object | `{"nginx.ingress.kubernetes.io/enable-websocket":"\"true\"","nginx.ingress.kubernetes.io/proxy-read-timeout":"\"3600\"","nginx.ingress.kubernetes.io/proxy-send-timeout":"\"3600\""}` |  |
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
| ui.enabled | bool | `false` |  |
| ui.env | object | `{}` |  |
| ui.extraEnv | list | `[]` |  |
| ui.headscaleUrl | string | `""` |  |
| ui.image.pullPolicy | string | `"IfNotPresent"` |  |
| ui.image.pullPolicy | string | `"IfNotPresent"` |  |
| ui.image.repository | string | `"ghcr.io/gurucomputing/headscale-ui"` |  |
| ui.image.repository | string | `"ghcr.io/gurucomputing/headscale-ui"` |  |
| ui.image.tag | string | `"latest"` |  |
| ui.image.tag | string | `"latest"` |  |
| ui.ingress.annotations | object | `{}` |  |
| ui.ingress.annotations | object | `{}` |  |
| ui.ingress.className | string | `"nginx"` |  |
| ui.ingress.host | string | `"ui.headscale.local"` |  |
| ui.ingress.hosts[0].host | string | `"headscale-ui.local"` |  |
| ui.ingress.hosts[0].paths[0].path | string | `"/"` |  |
| ui.ingress.hosts[0].paths[0].pathType | string | `"ImplementationSpecific"` |  |
| ui.ingress.path | string | `"/"` |  |
| ui.ingress.pathType | string | `"ImplementationSpecific"` |  |
| ui.ingress.tls | list | `[]` |  |
| ui.ingress.tls | list | `[]` |  |
| ui.replicaCount | int | `1` |  |
| ui.service.port | int | `80` |  |
| ui.service.port | int | `80` |  |
| ui.service.type | string | `"ClusterIP"` |  |
| ui.service.type | string | `"ClusterIP"` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
