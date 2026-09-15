# SPIRE Server + Agent in-cluster (SPIRE Phase 1, TODOS.md; docs/adr/0026).
#
# `spire-crds` installs first (CRDs the spire-server chart's own
# controller-manager subcomponent would need — not enabled in this PR,
# but the CRDs are a hard prerequisite of the umbrella chart regardless).
# `spire` (the umbrella chart) then installs spire-server + spire-agent
# as ONE release — see docs/adr/0026 for why they are not split across
# tofu/Flux.
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
      # PR 1's OpenBao role already binds the literal name "spire-server"
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

            # EXPLICIT — live-verified 2026-09-15: the chart's own default
            # ("vault") does NOT match PR 1's OpenBao role, which sets
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

      # Publishes spire-server's own trust bundle to a ConfigMap in ITS
      # OWN namespace (namespace left unset here) — repointing this
      # cross-namespace to zot's is PR 3's job, once zot exists as a
      # consumer to test against. format=pem (not the chart default
      # "spiffe") so the published key is bundle.crt, plain PEM.
      bundlePublisher = {
        k8sConfigMap = {
          enabled = true
          format  = "pem"
        }
      }

      # EXPLICIT false — live-rendering surfaced that the UMBRELLA
      # chart's own values.yaml overrides this subchart's default
      # (false) back to true, which would silently ship a
      # controller-manager, a ValidatingWebhookConfiguration, 3
      # ClusterSPIFFEID CRs, and install/upgrade/delete-hook Jobs. No
      # ClusterSPIFFEID reconciliation in this PR (negative space) —
      # registration entries are the future consumer PR's concern.
      controllerManager = {
        enabled = false
      }
    }

    "spire-agent" = {
      enabled = true

      # EXPLICIT — live-verified 2026-09-15: the agent's own bootstrap
      # trust file format (default "spiffe") is an INDEPENDENT setting
      # from spire-server.bundlePublisher.k8sConfigMap.format above, but
      # both read the SAME ConfigMap (bundleConfigMap: spire-bundle on
      # both sides, by chart default) — a mismatch here means the agent
      # looks for a key ("bundle.spiffe") the server never writes
      # ("bundle.crt", format=pem), and the agent hangs retrying
      # "could not parse trust bundle: ... no such file or directory"
      # forever.
      trustBundleFormat = "pem"
    }

    # Negative space — everything else this umbrella chart can enable,
    # off. No controller-manager (no ClusterSPIFFEID reconciliation in
    # this PR), no CSI driver, no OIDC discovery, no UI, no SPIKE, no
    # nested/upstream federation.
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
