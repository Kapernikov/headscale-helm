# Headscale Helm Chart

This repository contains a Helm chart for deploying Headscale, an open-source implementation of the Tailscale control server.

For detailed information about the Helm chart, including installation instructions and configuration options, please refer to the [Helm Chart README](./headscale/README.md).

**Install From OCI (GHCR)**
- Prereqs: Helm 3.10+ (recommended). Helm 3.8–3.9 work with the pull-then-install flow below.
- Registry: `ghcr.io/kapernikov/charts/headscale` (owner lowercased for GHCR).
- Auth: Public charts require no login. For private charts, run `helm registry login ghcr.io -u <github-user> -p <token-with-read:packages>`.

Install or upgrade (Helm 3.10+):
- `helm upgrade --install headscale oci://ghcr.io/kapernikov/charts/headscale --version <chart_version> --namespace headscale --create-namespace`

Install with Helm 3.8–3.9:
- `helm pull oci://ghcr.io/kapernikov/charts/headscale --version <chart_version>`
- `helm install headscale headscale-<chart_version>.tgz --namespace headscale --create-namespace`

Configure values:
- See `headscale/README.md` and `headscale/values.yaml` for configuration options, e.g. `-f my-values.yaml` during install/upgrade.
