# tests/lib/helm_repo.bash — a throwaway local CLASSIC (index.yaml + bare
# .tgz over plain HTTP) Helm repo, for any consumer's test suite whose
# script pulls from a non-OCI Helm repo (spire-verify.sh's
# spiffe/helm-charts-hardened). Distinct from tests/lib/registry.bash,
# which is OCI/zot-shaped only — a classic repo has no `oras resolve`
# digest lookup at all, which is the whole reason spire-verify.sh
# `helm pull`s and shasums the .tgz itself.

# helm_repo_pack <dir> <chart-name> <chart-version> -> packages a
# trivial, valid chart (one ConfigMap template) into $dir/repo/. The
# rendered SHAPE spire-verify.sh's `helm template` step asserts is out of
# scope for these fixtures — same split as openbao-verify.bats's
# push_local_fixture, which also stands in placeholder bytes rather than
# a real chart: the digest-pin path (helm pull + shasum + lock
# comparison) is what a local fixture can cover without a live network;
# the render-shape assertions stay covered by the live happy-path test
# only. Callable more than once to stage multiple charts before
# start_helm_repo serves them.
helm_repo_pack() {
	local dir="$1" name="$2" version="$3"
	local src="$dir/src-$name-$version"
	mkdir -p "$src/templates" "$dir/repo"
	cat >"$src/Chart.yaml" <<-EOF
		apiVersion: v2
		name: ${name}
		version: ${version}
		description: throwaway test fixture, not the real chart
	EOF
	cat >"$src/templates/cm.yaml" <<-'EOF'
		apiVersion: v1
		kind: ConfigMap
		metadata:
		  name: fixture
	EOF
	helm package "$src" -d "$dir/repo" >/dev/null
}

# start_helm_repo <dir> -> sets HELM_REPO (a full http://127.0.0.1:<port>/
# URL), serves $dir/repo (every chart staged via helm_repo_pack) as a
# classic Helm repo, writes $dir/helm-repo.pid. python3's stdlib
# http.server: no mise-pinned static file server exists for this one
# fixture (same class of accepted gap as start_registry_tls's htpasswd
# note) — python3 ships on every darwin/CI machine this repo targets.
# Call AFTER every helm_repo_pack for this run — `helm repo index` reads
# the directory once, at start time.
start_helm_repo() {
	local dir="$1" port
	port="$(free_port)"
	HELM_REPO="http://127.0.0.1:${port}/"
	helm repo index "$dir/repo" --url "$HELM_REPO" >/dev/null
	python3 -m http.server "$port" --bind 127.0.0.1 --directory "$dir/repo" \
		>"$dir/helm-repo.log" 2>&1 &
	local ppid=$!
	echo "$ppid" >"$dir/helm-repo.pid"
	disown "$ppid" 2>/dev/null || true
	local i=0
	while [ "$i" -lt 50 ]; do
		curl -sf "${HELM_REPO}index.yaml" >/dev/null 2>&1 && return 0
		sleep 0.1
		i=$((i + 1))
	done
	echo "helm repo http server did not come up on ${HELM_REPO}" >&2
	return 1
}

stop_helm_repo() {
	local dir="$1"
	[ -f "$dir/helm-repo.pid" ] && kill "$(cat "$dir/helm-repo.pid")" 2>/dev/null || true
}
