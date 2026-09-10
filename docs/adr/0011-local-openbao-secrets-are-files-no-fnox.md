# The local OpenBao's secrets are 0600 files beside its data — no fnox, no keychain

Every secret the local dev OpenBao needs — the static-seal key, the root
token, the recovery key — is a `0600` file in `$STATE_DIR`
(`~/.local/state/toolbox/openbao/`), written by
`environments/local/scripts/openbao-bootstrap.sh` with an atomic
`mktemp`+`chmod`+`mv`. `VAULT_TOKEN` reaches every `mise run` task
and the interactive shell through one `mise.toml` line —
`VAULT_TOKEN = "{{ exec(command='cat "$OPENBAO_STATE_DIR/root.token" …') }}"` —
no shell hook. `fnox` is removed from the stack entirely (`mise.toml`
`[tools]`, `fnox.toml`, `fnox check`).

Why (supersedes the T3 "root token machine-held via fnox → OS keychain"
decision): `fnox` + keychain caused three concrete failures — `fnox remove`
and `fnox set` both silently rewrite the committed `fnox.toml`, and a
keychain item created by one binary and read by another triggers a blocking
GUI password prompt that fired inside `bats` and would fire on every dev's
first `mise run attestation:sign`. The static-seal key was *already* a `0600` file
(ADR 0010, forced by `--boot-start` needing it before the login keychain
unlocks); putting the root token in the keychain while the seal key sits on
disk is inconsistent — whoever can read `seal.key` + `data/` can decrypt
everything the token protects anyway. The machine is the trust boundary
(ADR 0010); FileVault covers at-rest.

The recovery key is kept as a file (not discarded): a file is zero
DX cost — never typed, never shown — and it is the only *non-destructive*
recovery when `root.token` is lost or corrupt but the instance is healthy
(`bao operator generate-root`).

`mise run local:openbao:snapshot` writes a *bundle* — the raft snapshot plus a
copy of `seal.key` and `root.token` — into `snapshots/`. A bare `.snap`
cannot be restored; the three files must travel together (copy the whole
`snapshots/` dir off-machine for real disaster recovery). Under ADR 0016 the
bundle is also the in-cluster instance's genesis path.

Status: accepted. Supersedes the T3 fnox/keychain call. The production
`secret-openbao` module (deferred) keeps its own out-of-band requirement.
Amended by [ADR 0016](0016-local-openbao-in-cluster-statefulset.md) — the
seal key is now also delivered as a Kubernetes Secret, sourced from the same
`0600` file; the `0600`-files-are-the-trust-model call is unchanged.
