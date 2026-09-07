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

# --- openbao-preflight.sh fake `bao` --------------------------------------
# openbao-preflight.sh only branches on `bao status` / `bao read` output, so
# a stub `bao` on PATH tests every state deterministically without a real
# server (the real server round-trip is proved by openbao-bootstrap.bats).
# jq stays real — only `bao` is shadowed.
#
# fake_bao <state> — state in: unreachable uninitialised sealed unauthorized
#                    missing-key healthy
fake_bao() {
	local dir="$FIX/fakebin"
	mkdir -p "$dir"
	{
		printf '#!/usr/bin/env bash\nstate=%q\n' "$1"
		cat <<'EOF'
case "$1" in
status)
	case "$state" in
	unreachable)   exit 1 ;;
	uninitialised) echo '{"initialized":false,"sealed":true,"type":"static"}'; exit 2 ;;
	sealed)        echo '{"initialized":true,"sealed":true,"type":"static"}';  exit 2 ;;
	*)             echo '{"initialized":true,"sealed":false,"type":"static"}'; exit 0 ;;
	esac ;;
read)
	case "$state" in
	unauthorized) echo "Error reading transit/keys/approval-key: permission denied" >&2; exit 2 ;;
	missing-key)  echo "Error reading transit/keys/approval-key: no value found at transit/keys/approval-key" >&2; exit 2 ;;
	healthy)      echo '{"data":{"name":"approval-key"}}'; exit 0 ;;
	*)            echo "fake bao: unexpected 'read' in state $state" >&2; exit 1 ;;
	esac ;;
*) echo "fake bao: unknown subcommand $1" >&2; exit 1 ;;
esac
EOF
	} >"$dir/bao"
	chmod +x "$dir/bao"
	export PATH="$dir:$PATH"
}
