# Tailscale Peer Relay TODO

## Current status
- Tailscale peer relays are in public beta and require clients running `tailscale` 1.86 or newer, configured with `tailscale set --relay-server-port <udp-port>`.
- Headscale **does not** expose peer relay capability yet; upstream tracking is in `juanfont/headscale#2841`, which depends on grant/capability work (`juanfont/headscale#2180`).
- Because grants support is missing, enabling peer relay from the Helm chart is currently infeasible; the optional client sidecar can only perform `tailscale up`.

## References
- Announcement blog: https://tailscale.com/blog/peer-relays-beta
- Documentation: https://tailscale.com/kb/1591/peer-relays
- Headscale tracking issue: https://github.com/juanfont/headscale/issues/2841
- Headscale grants prerequisite: https://github.com/juanfont/headscale/issues/2180

## Implementation plan (once upstream support lands)
- **Track release:** Wait for a headscale release that implements grants and recognizes the `tailscale.com/cap/relay` capability. Update `headscale/values.yaml` to point `image.tag` at that version and bump the chart `version`.
- **Client image:** Ensure the optional Tailscale client sidecar uses `tailscale/tailscale` ≥ 1.86. Default the tag accordingly and document minimum versions.
- **Helm values:** Introduce values to toggle relay mode on the client (e.g., `client.peerRelay.enabled`, `client.peerRelay.port`, `client.peerRelay.tags`). Wire these into the client deployment script to invoke `tailscale set --relay-server-port` and optionally add tags.
- **Networking:** Decide whether to expose the relay UDP port via a Kubernetes `Service` (likely `NodePort` or `LoadBalancer`) or rely on host networking. Document firewall expectations in `README.md.gotmpl`.
- **Access control:** Surface guidance for configuring headscale ACLs/grants once supported, especially how to express the `tailscale.com/cap/relay` capability for relay nodes and consumers.
- **Docs & testing:** Update chart docs (`README.md.gotmpl` + `generate_helm_docs.sh`) and validate via `helm lint` plus an integration smoke test confirming relay functionality in a restrictive-NAT scenario.

## Open questions
- How will headscale surface grants configuration (file schema, CLI, or API) once implemented?
- What is the recommended exposure pattern for the relay UDP port inside Kubernetes (hostPort vs. Service)?
- Do we also need to support multiple peer relay replicas and coordination between them in the chart?
