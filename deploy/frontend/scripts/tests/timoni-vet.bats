#!/usr/bin/env bats

# The cv_frontend Timoni module (ADR 0019). `timoni mod vet` is the schema
# gate for the timoni path — it type-checks the module + its rendered
# Deployment/Service/ServiceAccount against the vendored k8s CUE schemas.
# There is no wrapper script (declarative-first): the `timoni` hk step runs
# `timoni mod vet` inline. This suite proves the two directions the hk step
# alone cannot: that a valid module passes, AND that the load-bearing
# `image.digest` constraint actually rejects a non-digest reference (a green
# vet on the negative fixture would mean the constraint was weakened).

setup() {
	_d="$BATS_TEST_DIRNAME"
	while [ "$_d" != "/" ] && [ ! -e "$_d/mise.toml" ]; do _d="$(dirname "$_d")"; done
	ROOT="$_d"
	MOD="$ROOT/deploy/frontend/timoni"
}

@test "timoni mod vet: the module passes with default values" {
	run timoni mod vet "$MOD" --name cv-frontend
	[ "$status" -eq 0 ]
}

@test "timoni mod vet: a tag-only / malformed image.digest is rejected" {
	run timoni mod vet "$MOD" --name cv-frontend \
		--values "$MOD/tests/invalid-image-digest.cue"
	[ "$status" -ne 0 ]
	[[ "$output" == *'image.digest'* ]]
}
