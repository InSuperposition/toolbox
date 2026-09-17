#!/usr/bin/env bats

# Mutation tests for tests/check-tf-path-boundary.sh: the guard must FAIL
# when a file()/templatefile()/filebase64() call climbs into a sibling
# concern, not just pass on a clean tree. Each case runs the script inside
# a throwaway git repo (it resolves its scan root from
# `git rev-parse --show-toplevel`).

setup() {
	SCRIPT="$(cd "$BATS_TEST_DIRNAME" && pwd)/check-tf-path-boundary.sh"
	REPO="$(mktemp -d)"
	cd "$REPO"
	git init -q
	git config user.email t@t
	git config user.name t
	mkdir -p environments/local/openbao
}

teardown() {
	rm -rf "$REPO"
}

commit_tf() {
	printf '%s\n' "$1" >environments/local/openbao/main.tf
	git add -A
	git commit -qm x
}

@test "passes on a path.module-relative templatefile call" {
	commit_tf 'x = templatefile("${path.module}/templates/openbao.hcl.tftpl", {})'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
}

@test "fails on a file() call climbing into deploy/" {
	commit_tf 'x = file("${path.module}/../../../deploy/frontend/Dockerfile")'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"deploy/"* ]]
}

@test "fails on a templatefile() call climbing into attestation/" {
	commit_tf 'x = templatefile("../../../attestation/verdict-approved.cue", {})'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"attestation/"* ]]
}

@test "fails on a filebase64() call climbing into ci/" {
	commit_tf 'x = filebase64("../../ci/tasks/gate.yaml")'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"ci/"* ]]
}

@test "fails on a bare two-level climb even without a named concern" {
	commit_tf 'x = file("${path.module}/../../something.txt")'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
}
