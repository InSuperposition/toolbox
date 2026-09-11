// The cv_frontend consumer's PipelineRun — rendered, not applied by hand.
//
//   cue export deploy/frontend/pipelinerun.cue -e pipelineRun \
//     -t rev=<cv_frontend-sha> -t defsRev=<toolbox-sha> --out yaml
//
// `frontend-build.sh` runs that, pipes it to `kubectl create -f -`, and
// watches the run. Plain CUE, one self-contained file, no cue.mod, no
// cross-concern import — the exact shape of attestation/verdict-approved.cue
// (T7b3 plan D1/D2: Timoni's module+bundle+~1.3MB vendored cue.mod only
// earns its footprint for a reconciled Instance; a PipelineRun is
// fire-and-forget and stays operator-triggered through Phase 3).
//
// CUE is the schema here (this repo's "schemas required for core
// functionality"): _rev / _defsRev carry a hex-SHA regex and are @tag
// injection points, so a missing OR malformed -t value fails `cue export`
// closed (exit 1, non-concrete / constraint violation) before anything
// reaches the cluster.
//
// ci/ never names a consumer (ADR 0014); this file is where cv_frontend's
// repo URLs and image ref live, binding the params-only
// `build-scan-approve` Pipeline by name.

package pipelinerun

// The per-run inputs. `cue export -t rev=… -t defsRev=…` fills these; with
// no tag the value stays the bare regex (non-concrete) and export fails.
_rev:     =~"^[0-9a-f]{7,40}$" @tag(rev)
_defsRev: =~"^[0-9a-f]{7,40}$" @tag(defsRev)

// cv_frontend's registry facts — the ONE place these hostnames live.
// The pipeline pushes/scans over the in-cluster service DNS; every
// host-side tool (`oras resolve`, `attestation:sign`, `frontend:deploy`,
// `frontend:publish`) addresses the SAME name (T7c R1b-ii-c — zot's NodePort
// is gone; OrbStack routes the Mac host into the cluster network directly,
// same as `openbao-tls`, so `.host` and `.inCluster` are now identical —
// kept as two fields, not collapsed to one, so every existing
// `-e image.host` / `-e image.manifests.host` call site keeps working
// unchanged). `cue export -e image.host` hands the operator that name;
// `-e image.manifests.inCluster` the form the Flux `OCIRepository frontend`
// pulls (Plan B M3, ADR 0019).
#image: {
	inCluster: "zot.zot.svc.cluster.local:5000/cv-frontend"
	host:      "zot.zot.svc.cluster.local:5000/cv-frontend"
	// The rendered-manifest OCI artifact (D_man) — `frontend:publish`
	// `flux push`es it to `.host`, the Flux `OCIRepository` pulls `.inCluster`.
	manifests: {
		inCluster: "zot.zot.svc.cluster.local:5000/cv-frontend-manifests"
		host:      "zot.zot.svc.cluster.local:5000/cv-frontend-manifests"
	}
}
image: #image

#PipelineRun: {
	apiVersion: "tekton.dev/v1"
	kind:       "PipelineRun"
	metadata: {
		generateName: "cv-frontend-"
		// Never rely on the ambient kubeconfig namespace (the default-vs-ci
		// bug that bit twice in T7b1-followup / T7b2 verification).
		namespace: "ci"
	}
	spec: {
		// Tekton self-terminates a stuck run server-side; the client poll in
		// frontend-build.sh bounds ~16m so it always observes a real
		// terminal condition rather than orphaning pods.
		timeouts: pipeline: "15m"
		pipelineRef: name:  "build-scan-approve"
		params: [
			{name: "IMAGE", value: #image.inCluster},
			{name: "APP_REPO_URL", value: "https://github.com/InSuperposition/cv_frontend.git"},
			{name: "APP_REVISION", value: _rev},
			{name: "DEFS_REPO_URL", value: "https://github.com/InSuperposition/toolbox.git"},
			{name: "DEFS_REVISION", value: _defsRev},
			{name: "DOCKERFILE_DIR", value: "deploy/frontend"},
		]
		workspaces: [
			{
				name: "shared"
				volumeClaimTemplate: spec: {
					accessModes: ["ReadWriteOnce"]
					resources: requests: storage: "2Gi"
				}
			},
			{
				name: "buildkitd-config"
				configMap: name: "buildkitd-mirror"
			},
			{
				// T7c R1b-ii-c: zot is HTTPS-only — the trust-manager
				// toolbox-ca-bundle ConfigMap (already in ns `ci`, R1b-ii-a)
				// gives `build`/`scan-attach` the dev CA.
				name: "ca-bundle"
				configMap: name: "toolbox-ca-bundle"
			},
		]
	}
}

pipelineRun: #PipelineRun
