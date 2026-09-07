# modules/

Reusable, **versioned, URL-consumed** OpenTofu modules only — a module
here is pinned by `source = "github.com/…//modules/<name>?ref=<sha>"` from
a downstream repo (see `docs/designs/repo-structure.md` § The concerns and
their allowed edges).

Empty today. The deferred production `secret-openbao` module is the first
candidate (`TODOS.md`; ADR 0012 explains why the *local* OpenBao unit
lives under `environments/local/openbao/` instead).

A tofu unit with exactly one in-repo consumer and no version pin is **not**
a module — it belongs with the environment that owns it.
