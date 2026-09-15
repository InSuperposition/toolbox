# SPIRE Server and Agent ship as one tofu-owned Helm release

SPIRE Server and Agent both ship via one `helm_release` of the upstream
`spire` umbrella chart, tofu-owned (same ADR-0016 test as OpenBao: a
long-lived process minting its own signing keys, with a one-time
bootstrap) — not split across tofu (Server) and Flux (Agent). The
umbrella chart structurally couples Server, Agent, and `spire-lib` as
one dependency graph; splitting the Agent into a hand-authored
Flux-reconciled path would mean re-implementing the chart's own
RBAC/ServiceAccount/DaemonSet shape for zero isolation benefit, since
the Agent holds no durable secret a reconcile loop could threaten.
`spire-crds` installs as a genuinely separate release first — it is not
a `Chart.yaml` dependency of `spire`.

## Consequences

SPIRE's own CA verifies OpenBao's TLS listener via a dedicated
`trust-manager` `Bundle` CR (`environments/local/trust-manager/spire-vault-ca.yaml`),
not the shared Kyverno/ci one (ADR 0022) — the vault upstreamAuthority
plugin hardcodes reading a key literally named `ca.crt` from its mounted
ConfigMap, a different key name than the shared Bundle's
`ca-certificates.crt`. This PR also explicitly disables
`spire-server.controllerManager` — the umbrella chart's own `values.yaml`
overrides the subchart's default (`false`) back to `true`, which would
otherwise silently ship a controller-manager, a
`ValidatingWebhookConfiguration`, and `ClusterSPIFFEID` CRs with no
review. Registration-entry reconciliation is deferred to whichever
future PR actually needs it.
