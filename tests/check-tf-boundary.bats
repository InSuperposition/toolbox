#!/usr/bin/env bats

# Mutation tests for tests/check-tf-boundary.sh (ADR 0018): the guard must
# FAIL when a `kubernetes_*` / `kubernetes_manifest` resource is present, not
# just pass on a clean tree. Each case runs the script inside a throwaway git
# repo (it resolves its scan root from `git rev-parse --show-toplevel`).

setup() {
	SCRIPT="$(cd "$BATS_TEST_DIRNAME" && pwd)/check-tf-boundary.sh"
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

@test "passes on a tree with no kubernetes_ resource" {
	commit_tf 'resource "helm_release" "ok" {}'
	run "$SCRIPT"
	[ "$status" -eq 0 ]
}

@test "fails on resource \"kubernetes_namespace\"" {
	commit_tf 'resource "kubernetes_namespace" "bad" {}'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"ADR 0018 violation"* ]]
	[[ "$output" == *"kubernetes_namespace"* ]]
}

@test "fails on resource \"kubernetes_manifest\"" {
	commit_tf 'resource "kubernetes_manifest" "m" {}'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"kubernetes_manifest"* ]]
}

@test "an indented resource block is still caught" {
	commit_tf '  resource "kubernetes_config_map" "c" {}'
	run "$SCRIPT"
	[ "$status" -eq 1 ]
}
