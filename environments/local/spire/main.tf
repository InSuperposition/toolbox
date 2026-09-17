# SPIRE Server + Agent in-cluster — the first stage of this repo's
# workload-identity rollout, shipped as one tofu-owned Helm release rather
# than splitting Server (tofu) from Agent (Flux).
#
# `spire-crds` installs first — CRDs the spire-server chart's own
# controller-manager subcomponent needs (enabled below, for declarative
# ClusterSPIFFEID registration) and a hard prerequisite of the umbrella
# chart regardless.
# `spire` (the umbrella chart) then installs spire-server + spire-agent
# as ONE release — splitting the Agent into a Flux-reconciled path would
# mean re-implementing the chart's own RBAC/ServiceAccount/DaemonSet shape
# for zero isolation benefit, since the Agent holds no durable secret a
# reconcile loop could threaten.
#
# NOT applied by `mise run check` — the bootstrap bridge
# (../scripts/spire-bootstrap.sh) is the only thing that applies it
# against a real cluster. `tofu test` here is mock_provider only
# (tests/*.tftest.hcl); the offline structural check is spire-verify.sh.

locals {
  # One YAML values doc, built structurally (yamlencode) — no heredoc
  # YAML, same convention as the openbao unit.
  helm_values = yamlencode({
    global = {
      spire = {
        trustDomain = var.trust_domain
      }
    }

    "spire-server" = {
      enabled = true

      # Chart defaults (kind=statefulset, persistence.type=pvc,
      # dataStore.sql.databaseType=sqlite3, keyManager.disk.enabled=true,
      # nodeAttestor.k8sPSAT.enabled=true) already match this repo's
      # dev-scale shape — only override what the OpenBao integration and
      # the security-relevant ServiceAccount name actually need.

      # EXPLICIT — the chart's own fullname-derived default for release
      # name "spire" computes to "spire-spire-server", not "spire-server".
      # The OpenBao k8s-auth role for spire-server already binds the
      # literal name "spire-server"
      # in namespace "spire"; this must match exactly.
      serviceAccount = {
        name = "spire-server"
      }

      persistence = {
        size = var.data_storage_size
      }

      upstreamAuthority = {
        vault = {
          enabled       = true
          vaultAddr     = var.openbao_endpoint
          pkiMountPoint = "pki" # matches environments/local/openbao's vault_mount.pki.path

          # The plugin mounts this ConfigMap whole and hardcodes reading
          # a key literally named "ca.crt" from it
          # (server-resource.yaml + configmap.yaml, confirmed live) — the
          # dedicated trust-manager Bundle publishes exactly that key.
          caCert = {
            type = "Configmap"
            name = var.spire_ca_configmap_name
          }

          k8sAuth = {
            enabled           = true
            k8sAuthMountPoint = "kubernetes"   # matches openbao's vault_auth_backend.kubernetes.path
            k8sAuthRoleName   = "spire_server" # matches openbao's vault_kubernetes_auth_backend_role.spire_server

            # Set explicitly: the chart's own default ("vault") does NOT
            # match the OpenBao k8s-auth role's own audience, which sets
            # `audience = var.openbao_endpoint` (the same convention
            # flux_sops/chains_provenance already use). A mismatch here
            # is a 403 "invalid audience (aud) claim" at spire-server
            # startup, not a silent misconfiguration.
            token = {
              audience = var.openbao_endpoint
            }
          }
        }
      }

      # Publishes spire-server's
      # own trust bundle cross-namespace into ns "zot" — zot's mTLS
      # listener verifies client SVIDs against this. RBAC (Role/
      # RoleBinding) follows the SAME namespace value automatically
      # (spire-server.bundle-namespace-bundlepublisher helper, confirmed
      # no divergence risk during this rollout's own research). format=pem (not the
      # chart default "spiffe") so the published key is bundle.crt,
      # plain PEM.
      bundlePublisher = {
        k8sConfigMap = {
          enabled   = true
          format    = "pem"
          namespace = "zot"
        }
      }

      # Flipped back to true (an earlier pass disabled this as negative
      # space — "no consumer yet"). The `ci` namespace's default ServiceAccount
      # (what buildkit-build/scan-attach actually run as) is now a real
      # consumer needing a registration entry. Rather than hand-roll an
      # imperative `spire-server entry create` script, this repo's
      # declarative-first mandate points at the chart's OWN default
      # ClusterSPIFFEID (spiffeIDTemplate
      # "spiffe://{{.TrustDomain}}/ns/{{.PodMeta.Namespace}}/sa/{{.PodSpec.ServiceAccountName}}",
      # namespaceSelector NotIn [spire, spire-server, spire-system]) —
      # it already covers ns `ci` with zero extra CRs. Accepting the
      # coupled webhook + install/upgrade/delete-hook Jobs as one chart
      # feature, not selectively disabled.
      controllerManager = {
        enabled = true
      }
    }

    "spire-agent" = {
      enabled = true

      # Set explicitly: the agent's own bootstrap trust file format
      # (default "spiffe") is an INDEPENDENT setting from
      # spire-server.bundlePublisher.k8sConfigMap.format above, but both
      # read the SAME ConfigMap (bundleConfigMap: spire-bundle on both
      # sides, by chart default) — a mismatch here means the agent looks
      # for a key ("bundle.spiffe") the server never writes ("bundle.crt",
      # format=pem), and the agent hangs retrying "could not parse trust
      # bundle: ... no such file or directory" forever.
      trustBundleFormat = "pem"
    }

    # Negative space — everything else this umbrella chart can enable,
    # off: no CSI driver, no OIDC discovery, no UI, no SPIKE, no
    # nested/upstream federation. (controller-manager is ON — see
    # spire-server.controllerManager above.)
    "spiffe-csi-driver"              = { enabled = false }
    "spiffe-oidc-discovery-provider" = { enabled = false }
    "tornjak-frontend"               = { enabled = false }
    "spike-keeper"                   = { enabled = false }
    "spike-nexus"                    = { enabled = false }
    "spike-pilot"                    = { enabled = false }
    "spire-identity-exchange"        = { enabled = false }
    upstream                         = { enabled = false }
  })
}

resource "helm_release" "spire_crds" {
  name      = "spire-crds"
  namespace = var.namespace
  # The bootstrap bridge creates the namespace (kubectl, idempotent)
  # BEFORE this applies — tofu never owns a namespace another actor
  # manages, same invariant as the openbao unit.
  create_namespace = false

  repository = var.chart_repository
  chart      = "spire-crds"
  version    = var.spire_crds_chart_version

  atomic          = false
  cleanup_on_fail = true
  # CRDs are cheap/fast to install — safe to wait for, unlike the
  # openbao unit's raft-readiness deadlock.
  wait    = true
  timeout = 120
}

resource "helm_release" "spire" {
  name             = var.release_name
  namespace        = var.namespace
  create_namespace = false

  repository = var.chart_repository
  chart      = "spire"
  version    = var.spire_chart_version

  atomic          = false
  cleanup_on_fail = true
  # spire-server's readiness depends on a runtime round-trip to OpenBao
  # (the vault upstreamAuthority plugin's sign-intermediate call) that
  # cannot succeed before OpenBao's spire_server role exists and this
  # release's ServiceAccount is live — `wait`+`atomic` would deadlock for
  # `timeout` then roll back, same reasoning as openbao's Phase A.
  wait    = false
  timeout = 600

  values = [local.helm_values]

  depends_on = [helm_release.spire_crds]
}
