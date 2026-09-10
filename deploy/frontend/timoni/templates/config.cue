package templates

import (
	corev1 "k8s.io/api/core/v1"
	timoniv1 "timoni.sh/core/v1alpha1"
)

// #Config is the schema and defaults for the cv_frontend instance values.
//
// The digest constraint on `image.digest` is the load-bearing rule: it
// mirrors `attestation/scripts/lib/attestation.sh`'s `attestation_is_digest_ref`
// so a tag-only or malformed image reference fails `timoni mod vet` before
// anything is rendered — the same "a tag is mutable, which is the whole
// point of this pipeline" contract `frontend-deploy.sh` / `frontend-serve.sh`
// enforce for the pitchfork path (ADR 0009). Proven by the negative fixture
// in `../tests/`.
#Config: {
	// Set at apply-time from the cluster API (timoni.cue).
	kubeVersion!: string
	clusterVersion: timoniv1.#SemVer & {#Version: kubeVersion, #Minimum: "1.30.0"}
	moduleVersion!: string

	// Kubernetes metadata common to every rendered object. `name` and
	// `namespace` come from the instance name/namespace at apply-time.
	metadata: timoniv1.#Metadata & {#Version: moduleVersion}
	metadata: labels: timoniv1.#Labels & {
		"app.kubernetes.io/part-of": "toolbox-frontend"
	}
	metadata: annotations?: timoniv1.#Annotations

	// Label selector for the Deployment + Service.
	selector: timoniv1.#Selector & {#Name: metadata.name}

	// The container image. `digest` MUST be a full sha256 digest — a
	// tag-only reference is rejected here, not at reconcile time.
	image!: timoniv1.#Image & {
		digest: =~"^sha256:[0-9a-f]{64}$"
	}

	// Container resource requests/limits. Defaults sized for the small
	// Remix/Node server; a values override tunes them per environment.
	resources: timoniv1.#ResourceRequirements & {
		requests: {
			cpu:    *"25m" | timoniv1.#CPUQuantity
			memory: *"64Mi" | timoniv1.#MemoryQuantity
		}
		limits: {
			cpu?:   timoniv1.#CPUQuantity
			memory: *"192Mi" | timoniv1.#MemoryQuantity
		}
	}

	replicas: *1 | int & >0

	// Container security context — the image is distroless nonroot, so the
	// pod runs with no added capabilities and a read-only root filesystem.
	securityContext: corev1.#SecurityContext & {
		allowPrivilegeEscalation: *false | true
		privileged:               *false | true
		readOnlyRootFilesystem:   *true | false
		runAsNonRoot:             *true | false
		capabilities: drop: *["ALL"] | [...string]
		seccompProfile: type: *"RuntimeDefault" | "Localhost" | "Unconfined"
	}

	// The cv_frontend server listens on 44100 (its own contract — see
	// deploy/frontend/scripts/frontend-serve.sh). The Service exposes the
	// same port.
	port: *44100 | int & >0 & <=65535

	service: {
		annotations?: timoniv1.#Annotations
		port:         *44100 | int & >0 & <=65535
	}

	podAnnotations?: {[string]: string}
	podSecurityContext?: corev1.#PodSecurityContext
	imagePullSecrets?: [...timoniv1.#ObjectReference]
	tolerations?: [...corev1.#Toleration]
	topologySpreadConstraints?: [...corev1.#TopologySpreadConstraint]

	nodeSelector: *{"kubernetes.io/os": "linux"} | {[string]: string}

	affinity: timoniv1.#AffinityValues & {
		podAntiAffinity: timoniv1.#AffinityPreset | corev1.#PodAntiAffinity
		nodeAffinity?:   corev1.#NodeAffinity
		podAffinity?:    corev1.#PodAffinity
	}
}

// #Instance renders the config into the Kubernetes objects.
//
// ServiceAccount + Service + Deployment only. No ConfigMap (the app carries
// its own config), no test Job (the k8s path is delivery-only — the app has
// a known Remix v3 boot crash, `deploy/frontend/README.md`; workload health
// is asserted by chainsaw at the "container started" level, not "Available").
#Instance: {
	config: #Config

	objects: {
		sa: #ServiceAccount & {#config: config}
		svc: #Service & {#config: config}
		deploy: #Deployment & {#config: config}
	}
}
