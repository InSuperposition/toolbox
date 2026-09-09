# Mocks the helm / kubernetes / vault providers entirely (no cluster) to
# assert the Phase-A helm_release's shape — the values that decide whether
# the single replica schedules and whether the listener is TLS. The deep
# structural check (against the real rendered chart) is
# openbao-cluster-verify.sh; this is the fast offline guard that a future
# edit does not quietly flip tlsDisable back on, re-enable the PDB, or let
# tofu start owning the namespace.

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "vault" {}

run "release_pins_the_locked_chart_version" {
  command = plan

  assert {
    condition     = helm_release.openbao.version == "0.29.4"
    error_message = "helm_release.version must equal openbao-cluster.lock's chart_version (the digest-equality gate keys off this tag)"
  }

  assert {
    condition     = helm_release.openbao.repository == "oci://ghcr.io/openbao/charts"
    error_message = "chart must come from the pinned OCI repository"
  }
}

run "tofu_never_owns_the_namespace" {
  command = plan

  assert {
    condition     = helm_release.openbao.create_namespace == false
    error_message = "create_namespace must be false — the bootstrap bridge (4b) creates ns openbao before this applies; tofu owning a namespace another actor manages is the dependency inversion plan § B1/B5 rejects"
  }
}

run "listener_is_tls_and_single_replica" {
  command = plan

  # values[0] is the yamlencode'd doc from local.helm_values.
  assert {
    condition     = yamldecode(helm_release.openbao.values[0]).global.tlsDisable == false
    error_message = "global.tlsDisable must be false — a ClusterIP listener is not loopback (plan § B4); a regression here serves the k8s-auth tokens in plaintext"
  }

  assert {
    condition     = yamldecode(helm_release.openbao.values[0]).server.ha.replicas == 1
    error_message = "exactly one raft voter — the whole cluster is one schedulable node (plan § Topology)"
  }

  assert {
    condition     = yamldecode(helm_release.openbao.values[0]).server.affinity == ""
    error_message = "server.affinity must be cleared — the chart renders podAntiAffinity whenever ha.enabled, and the one replica must schedule on OrbStack's single node (confirm #1)"
  }

  assert {
    condition     = yamldecode(helm_release.openbao.values[0]).server.ha.disruptionBudget.enabled == false
    error_message = "the PDB must stay disabled — one voter, a PDB blocks its own drain (confirm #1)"
  }
}

run "both_secrets_are_referenced_not_created" {
  command = plan

  assert {
    condition = length([
      for v in yamldecode(helm_release.openbao.values[0]).server.volumes : v
      if contains(keys(v.secret), "secretName")
    ]) == 2
    error_message = "server.volumes must mount exactly the seal + TLS Secrets by name (neither is created by this unit)"
  }

  assert {
    condition     = strcontains(yamldecode(helm_release.openbao.values[0]).server.ha.raft.config, "seal \"static\"")
    error_message = "the raft config must carry a seal \"static\" stanza so the pod auto-unseals from the mounted key with no operator step"
  }

  assert {
    condition = alltrue([
      strcontains(yamldecode(helm_release.openbao.values[0]).server.ha.raft.config, "/openbao/tls/tls.crt"),
      strcontains(yamldecode(helm_release.openbao.values[0]).server.ha.raft.config, "/openbao/tls/tls.key"),
    ])
    error_message = "the listener must read its cert + key from the cert-manager TLS mount"
  }
}

run "image_is_digest_pinned" {
  command = plan

  assert {
    condition     = strcontains(yamldecode(helm_release.openbao.values[0]).server.image.tag, "@sha256:")
    error_message = "server.image.tag must carry an @sha256: digest — kubelet pins the digest, the tag is cosmetic"
  }
}
