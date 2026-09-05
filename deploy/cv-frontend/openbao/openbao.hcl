# OpenBao server config for the local, pitchfork-supervised dev process
# (see ../pitchfork.toml). File-backed storage, NOT `-dev` mode — `-dev`
# is ephemeral/insecure and unsuitable even at this scale. See
# docs/designs/digest-as-source-of-truth.md, "Signing key custody", and
# CLAUDE.md § Tool Boundaries (pitchfork row: dev-only, directory-scoped
# daemon supervision — this is exactly that, not the deferred production
# `secret-openbao` module).
#
# Loopback-only, TLS disabled: this process never listens on anything but
# 127.0.0.1 and is a dev daemon, not production infra. If this ever needs
# to be reachable from another host, that is a different, non-dev design
# (real TLS certs, real network exposure review) — not a flag flip here.
#
# `disable_mlock` is intentionally absent: OpenBao >=2.0 removed mlock
# support entirely (the option is an obsolete no-op as of openbao/openbao
# GH-363), so carrying it over from Vault-config muscle memory would be
# dead config, not a real setting.

storage "file" {
  path = "openbao/data"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

api_addr = "http://127.0.0.1:8200"
