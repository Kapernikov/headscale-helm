# Repository Guidelines

## Project Structure & Module Organization
- `headscale/`: Helm chart root.
  - `templates/`: Kubernetes manifests and helpers (e.g., `_helpers.tpl`, `deployment.yaml`, `ingress.yaml`, `ui-*`).
  - `values.yaml`: User‑facing configuration (kept minimal; avoid unused “fake” options).
  - `README.md`: Auto‑generated via helm‑docs; edit `README.md.gotmpl`.
- `generate_helm_docs.sh`: Regenerates chart docs using the `jnorwood/helm-docs` image.

## Build, Test, and Development Commands
- Lint chart: `helm lint headscale/`
- Render manifests: `helm template headscale/ -f my-values.yaml | less`
- Dry‑run install: `helm upgrade --install my-release headscale/ -n test --create-namespace -f my-values.yaml --dry-run --debug`
- Install locally: `helm upgrade --install my-release headscale/ -n test -f my-values.yaml`
- Regenerate docs: `bash ./generate_helm_docs.sh`

## Coding Style & Naming Conventions
- YAML: 2‑space indentation; stable key ordering (metadata, spec, etc.).
- Helm: Use helpers for names/labels (`include "headscale.fullname"`, `headscale.labels`).
- Values: Expose only options that are wired in templates; remove duplicates.
- Routing: UI is served on the same hostname under `/web` by default.
- Persistence: PVC carries `helm.sh/resource-policy: keep` — do not remove.

## Testing Guidelines
- Run `helm lint` and `helm template` on every change.
- Smoke test in a cluster (kind/minikube): install, then verify:
  - Ingress: main host routes `/`, UI routes `/web` on same host.
  - UI env: `HEADSCALE_URL` resolves to external host when ingress enabled.
  - PVC: `kubectl get pvc` shows annotation `helm.sh/resource-policy=keep`.

## Commit & Pull Request Guidelines
- Messages: Imperative, concise; scope if useful (e.g., `ui:`, `ingress:`).
- PRs: Describe motivation, changes, and user impact; link issues.
- When changing values or templates: update `README.md.gotmpl`, run docs, and bump chart version in `headscale/Chart.yaml`.
- Include validation output (e.g., `helm lint`), and screenshots/commands for UI/ingress behavior when relevant.

## Security & Configuration Tips
- Do not commit secrets; prefer external secrets/Secrets references.
- Ensure `config.server_url` matches the ingress host/scheme in production.
- For non‑nginx controllers, confirm WebSocket and timeout equivalents.
