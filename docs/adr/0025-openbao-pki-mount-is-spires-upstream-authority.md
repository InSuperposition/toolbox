# OpenBao's PKI mount is SPIRE's upstream authority

SPIRE Phase 1 (TODOS.md's phased workload-identity rollout) needs an
upstream CA to issue SPIRE's intermediate cert. That mount lives in the
existing `environments/local/openbao/` tofu unit — not a new mount owned
by the future `environments/local/spire/` unit — because OpenBao is
already this repo's one root of trust / PKI substrate of record; a
second independent mount elsewhere would mean two CAs alongside
`toolbox-dev-ca`, the exact thing this decision avoids. SPIRE's server
reaches the mount at **runtime** via its own vault upstreamAuthority
plugin (k8s-auth login → `pki/root/sign-intermediate`), never via
tofu-to-tofu state sharing — the two units' only coupling is a
plain-string role name (`spire_server`) and the already-public OpenBao
endpoint URL, neither a secret nor a state read.

## Consequences

The mount has no key-preservation constraint the way `transit`/
`approval-key` do (ADR 0016) — nothing else creates or seeds it, so a
future re-init has zero blast radius outside this repo until a real
SPIRE consumer exists. This PR creates the OpenBao-side half of the
contract only (mount, root cert, a policy scoped to exactly
`pki/root/sign-intermediate`, a k8s-auth role bound to a ServiceAccount
name/namespace that doesn't exist yet); the `environments/local/spire/`
unit and its actual consumer land in a later PR.
