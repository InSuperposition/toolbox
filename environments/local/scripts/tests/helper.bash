# environments/local/scripts test helpers — the shared per-run isolation
# lib (free_port) and the concern-agnostic scratch-copy helper.

_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# shellcheck source=/dev/null
. "$_d/tests/lib/ports.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/scratch.bash"
unset _d

# fake_mise_export <outdir> — a stub `mise` on PATH. openbao-bootstrap.sh
# calls `mise run attestation:export-pubkey` (a task in the attestation/
# concern — it must not write the pubkey file across the boundary itself,
# ADR 0013 / CX #3). Under bats there is no repo mise.toml above the scratch
# to resolve that task, so this stub records the call and runs the same one
# `cosign public-key` line against the scratch OpenBao, writing into
# <outdir>. Any other `mise` invocation is an error — the bootstrap should
# call nothing else.
fake_mise_export() {
	local out="$1" dir="$SCRATCH/fakebin"
	mkdir -p "$dir" "$out"
	cat >"$dir/mise" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "run attestation:export-pubkey" ]; then
	echo called >>"$SCRATCH/.mise-export-calls"
	exec cosign public-key --key openbao://approval-key --outfile "$out/cosign-approval.pub"
fi
echo "fake mise: unexpected invocation: \$*" >&2
exit 1
EOF
	chmod +x "$dir/mise"
	export PATH="$dir:$PATH"
}
