# SPIRE Phase 3 (OpenBao signing identity) targets `jwt` auth, not `cert`

Phase 0's spike (throwaway SPIRE Server + Agent, throwaway OpenBao
container) live-confirmed that OpenBao 2.6.2's `cert` auth backend
cannot authenticate a stock SPIFFE X.509-SVID at all: it unconditionally
builds the identity alias from the client certificate's Common Name
(`Alias.Name = clientCert.Subject.CommonName`), and SPIFFE X.509-SVIDs
carry no CN by spec — login fails with `"missing name in alias"` even
when `allowed_uri_sans` correctly matches the presented cert (verified
separately: a mismatched SVID is correctly rejected with `"no chain
matching all constraints"`, proving the URI SAN check itself works —
it's the alias-creation step afterward that's the hard blocker, and no
role parameter offers an alternate alias-name source). So the SPIFFE ID
is provably a real, working *access-gate* condition, but OpenBao's `cert`
backend cannot turn one into a completed login for a CN-less client cert
in this version. Phase 3 (`attestation-sign.sh`'s OpenBao signing auth,
retiring the root-token path) targets `jwt` auth + JWT-SVID instead —
the fallback TODOS.md's own per-boundary verdict table already named.

## Considered Options

- **`cert` auth + X.509-SVID** — rejected. Stronger in principle
  (proof-of-possession via mTLS vs. a bearer token), but structurally
  incompatible with CN-less SPIFFE certs in OpenBao 2.6.2's `cert`
  backend; no config workaround exists (confirmed via
  `bao path-help auth/cert/certs/<name>` — no alias-name-source
  override).
- **`jwt` auth + JWT-SVID** — accepted. Works today; the known
  proof-of-possession weakness (bearer token) is accepted for Phase 3's
  narrow, already-scoped use (one workload, one policy,
  `transit/sign/approval-key` only).

## Consequences

Phase 1/2 of the SPIRE rollout (zot mTLS, host-side agent) are
unaffected — neither depends on OpenBao's `cert` auth. If a future
OpenBao release adds an alias-name-source option (e.g. deriving identity
from a URI SAN or an x509 extension via `allowed_metadata_extensions`),
this decision should be revisited.
