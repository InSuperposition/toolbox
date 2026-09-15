# Mocks helm / kubernetes (no cluster, no vault provider in this unit) to
# assert the resource graph: the security-relevant ServiceAccount name is
# explicit (not chart-derived), the vault upstreamAuthority plugin is
# wired to the exact OpenBao mount/role PR 1 created, every non-server/
# agent subchart stays off, and this PR does not jump ahead to PR 3's
# cross-namespace bundle wiring. (helm_release.spire_crds existing and
# main.tf's depends_on wiring it before helm_release.spire is not
# introspectable via a tftest assert — same test-coverage boundary as
# the openbao unit, which also never asserts a depends_on meta-argument
# directly.)

mock_provider "helm" {}
mock_provider "kubernetes" {}

run "server_and_agent_enabled_everything_else_off" {
  command = plan

  assert {
    condition     = strcontains(helm_release.spire.values[0], "\"spire-server\":\n  \"bundlePublisher\":")
    error_message = "spire-server must be present and configured"
  }
  assert {
    condition     = strcontains(helm_release.spire.values[0], "\"spire-agent\":\n  \"enabled\": true")
    error_message = "spire-agent must be enabled"
  }
  assert {
    condition = alltrue([
      strcontains(helm_release.spire.values[0], "\"spiffe-csi-driver\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"spiffe-oidc-discovery-provider\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"tornjak-frontend\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"spike-keeper\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"spike-nexus\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"spike-pilot\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"spire-identity-exchange\":\n  \"enabled\": false"),
      strcontains(helm_release.spire.values[0], "\"upstream\":\n  \"enabled\": false"),
    ])
    error_message = "every non-server/agent subchart must stay off — negative space, nothing this repo doesn't use"
  }
}

run "service_account_name_is_explicit" {
  command = plan

  assert {
    # The chart's own fullname-derived default for release name "spire"
    # computes to "spire-spire-server", NOT "spire-server" — OpenBao's
    # k8s-auth role already binds the literal name "spire-server", so
    # this override is a real regression guard, not decoration.
    condition     = strcontains(helm_release.spire.values[0], "\"serviceAccount\":\n    \"name\": \"spire-server\"")
    error_message = "spire-server.serviceAccount.name must be explicitly set to 'spire-server' — the chart's fullname default would not match OpenBao's k8s-auth role binding"
  }
}

run "vault_upstream_authority_wired_to_openbao_pr1_role" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(helm_release.spire.values[0], "\"pkiMountPoint\": \"pki\""),
      strcontains(helm_release.spire.values[0], "\"k8sAuthMountPoint\": \"kubernetes\""),
      strcontains(helm_release.spire.values[0], "\"k8sAuthRoleName\": \"spire_server\""),
    ])
    error_message = "the vault upstreamAuthority plugin must target the exact mount/role PR 1 created in the openbao unit: pki mount, kubernetes auth backend, spire_server role"
  }
  assert {
    # Live-verified regression guard (2026-09-15): the chart's own
    # default token audience ("vault") does NOT match PR 1's OpenBao
    # role, which sets `audience = var.openbao_endpoint` — a mismatch
    # here is a 403 "invalid audience (aud) claim" at spire-server
    # startup.
    condition     = strcontains(helm_release.spire.values[0], "\"audience\": \"https://openbao.openbao.svc.cluster.local:8200\"")
    error_message = "k8sAuth.token.audience must match OpenBao's spire_server role audience exactly (var.openbao_endpoint) — the chart's own default ('vault') causes a live 403 at spire-server startup"
  }
  assert {
    condition = alltrue([
      !strcontains(helm_release.spire.values[0], "\"cert_auth\""),
      !strcontains(helm_release.spire.values[0], "\"token_auth\""),
      !strcontains(helm_release.spire.values[0], "\"approle_auth\""),
    ])
    error_message = "must authenticate to OpenBao via k8s-auth only — no static credential (token/approle/cert) in state"
  }
}

run "ca_cert_targets_the_dedicated_trust_manager_bundle" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(helm_release.spire.values[0], "\"name\": \"spire-vault-ca\""),
      strcontains(helm_release.spire.values[0], "\"type\": \"Configmap\""),
    ])
    error_message = "caCert must reference the dedicated trust-manager Bundle's ConfigMap (spire-vault-ca), keyed ca.crt — the vault plugin hardcodes reading that exact key from a mounted ConfigMap/Secret"
  }
}

run "bundle_publisher_targets_zot_this_pr" {
  command = plan

  assert {
    condition     = strcontains(helm_release.spire.values[0], "\"format\": \"pem\"")
    error_message = "bundlePublisher.k8sConfigMap.format must be pem — zot needs bundle.crt, plain PEM"
  }
  assert {
    # Live-verified regression guard (2026-09-15): the agent's OWN
    # bootstrap trust format is independent from the server's publish
    # format above, but both read the same ConfigMap — a mismatch hangs
    # the agent forever on "could not parse trust bundle ... no such
    # file or directory".
    condition     = strcontains(helm_release.spire.values[0], "\"trustBundleFormat\": \"pem\"")
    error_message = "spire-agent.trustBundleFormat must match spire-server.bundlePublisher.k8sConfigMap.format (pem) — they read the same ConfigMap key"
  }
  assert {
    # PR 3: repointed cross-namespace into ns "zot" — zot's mTLS
    # listener verifies client SVIDs against this bundle.
    condition     = strcontains(helm_release.spire.values[0], "\"namespace\": \"zot\"")
    error_message = "bundlePublisher.k8sConfigMap.namespace must be zot — this is what zot's mTLS listener verifies client SVIDs against"
  }
}

run "controller_manager_is_on_for_declarative_registration" {
  command = plan

  assert {
    # PR 3 reverses PR 2's explicit negative-space choice: a real
    # consumer (ci namespace's default ServiceAccount) now exists, and
    # the chart's own default ClusterSPIFFEID already covers it —
    # declarative registration over a hand-rolled entry-create script.
    condition     = strcontains(helm_release.spire.values[0], "\"controllerManager\":\n    \"enabled\": true")
    error_message = "spire-server.controllerManager.enabled must be true — PR 3 needs its default ClusterSPIFFEID for declarative registration of the ci-namespace consumer"
  }
}
