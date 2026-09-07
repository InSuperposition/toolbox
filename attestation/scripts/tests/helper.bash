# attestation/scripts test helpers. The concern-agnostic half — throwaway
# zot registry, cosign key, fake image artifacts, scratch-dir copy — lives
# in tests/lib/ and is loaded below (per-dir loader, no BATS_LIB_PATH / mise
# env). What stays here is the attestation-sign.sh call wrapper.

_d="$BATS_TEST_DIRNAME"
while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
# ports.bash first — registry.bash uses free_port.
# shellcheck source=/dev/null
. "$_d/tests/lib/ports.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/scratch.bash"
# shellcheck source=/dev/null
. "$_d/tests/lib/registry.bash"
unset _d

# run_sign <image-ref> <approve|reject> <reason> — runs attestation-sign.sh
# with the local test key and the decision fed on stdin. Echoes its stdout.
run_sign() {
	printf '%s\n%s\n' "$2" "$3" >"$FIX/answers"
	TOOLBOX_APPROVE_KEY="$FIX/cosign.key" \
		COSIGN_PASSWORD="" \
		TOOLBOX_APPROVED_BY="bats" \
		"$SCRIPTS/attestation-sign.sh" "$1" <"$FIX/answers"
}

# attestation_digest <sign output> — the sha256:... it told the operator to record
attestation_digest() {
	printf '%s' "$1" | sed -n 's/^attestation digest: //p'
}
