#!/usr/bin/env bats

# openbao-preflight.sh — the OpenBao-state gate attestation-sign.sh runs
# before it wastes the operator's time. It must name the ONE correct fix for
# each way signing is unavailable. The five unhealthy states are checked
# through a stub `bao` (helper.bash `fake_bao`) so each is deterministic;
# the real-server round-trip is covered by openbao-bootstrap.bats.
#
# CX #9: the sealed-state advice used to say "use the printed unseal key" —
# wrong since the static seal (ADR 0010/0011), which auto-unseals from a
# 0600 file and prints no key. And a never-initialised instance also reports
# sealed=true, so the initialised check must come first. Both are asserted
# here.

setup() {
	load helper
	FIX="$(mktemp -d)"
	SCRIPTS="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export VAULT_ADDR="http://127.0.0.1:8200"
}

teardown() {
	rm -rf "$FIX"
}

@test "unreachable: exit 3, names the daemon-start fix" {
	fake_bao unreachable
	run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"cannot reach OpenBao"* ]]
	[[ "$output" == *"mise run local:openbao:start"* ]]
}

@test "uninitialised: exit 3, fix is bootstrap — NOT unseal (checked before sealed)" {
	fake_bao uninitialised
	run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"never initialised"* ]]
	[[ "$output" == *"mise run local:openbao:bootstrap"* ]]
	[[ "$output" != *"unseal"* ]]
}

@test "sealed: exit 3, advice is the static-seal reality — no 'printed unseal key'" {
	fake_bao sealed
	run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"sealed"* ]]
	[[ "$output" == *"seal.key"* ]]
	[[ "$output" == *"mise run local:openbao:start"* ]]
	[[ "$output" != *"printed"* ]]
	[[ "$output" != *"out-of-band"* ]]
}

@test "no VAULT_TOKEN: exit 3, names where the token comes from" {
	fake_bao healthy
	unset VAULT_TOKEN
	run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"no VAULT_TOKEN"* ]]
	[[ "$output" == *"root.token"* ]]
}

@test "unauthorized: exit 3, names the token as the thing to fix" {
	fake_bao unauthorized
	VAULT_TOKEN="hvs.not-root" run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"cannot read transit/keys/approval-key"* ]]
}

@test "missing-key: exit 3, fix provisions the key from environments/local/" {
	fake_bao missing-key
	VAULT_TOKEN="hvs.root" run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 3 ]
	[[ "$output" == *"does not exist"* ]]
	[[ "$output" == *"mise run local:openbao:bootstrap"* ]]
}

@test "healthy: exit 0, no advice" {
	fake_bao healthy
	VAULT_TOKEN="hvs.root" run "$SCRIPTS/openbao-preflight.sh"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "a custom key name flows through to the read + the error text" {
	fake_bao missing-key
	VAULT_TOKEN="hvs.root" run "$SCRIPTS/openbao-preflight.sh" chains-provenance-key
	[ "$status" -eq 3 ]
	[[ "$output" == *"'chains-provenance-key' does not exist"* ]]
}
