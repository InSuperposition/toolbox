# Design: Repo Structure — Ownership Boundaries

## Abstract

`toolbox` has had no written file-placement rule. The symptoms: shell
scripts split across `scripts/` and `deploy/frontend/scripts/` with no
stated reason, `.bats` files under two conventions (one set not beside the
scripts it covers), the local-OpenBao concern spread over `modules/`,
`environments/local/`, and root `scripts/`, and a consumer-agnostic
sign/verify seam filed inside its first consumer (`deploy/frontend/`).

This design defines the rule every file obeys: **each top-level concern
has one owner and a declared list of the concerns it may depend on; a file
lives with the concern that owns it, not by how deep a directory nests.**
The allowed dependency edges are explicit and machine-checked in
`mise run check`.

## Goals

- One written rule — ownership plus allowed edges — that every future file
  obeys, checked by `mise run check`.
- Every `.bats` in a `tests/` directory beside the script it covers.
- A repo-level shared test lib; a per-concern runtime `lib/` only where
  real shared logic exists.
- The local-OpenBao concern coherent: the tofu unit in one place, its
  orchestration scripts in the environment that owns bringing it up.
- The attestation sign/verify seam in its own boundary, reusable by any
  consumer, never referencing a consumer.
- mise tasks namespaced `<environment>:<domain>:<verb>` / `<domain>:<verb>`.

## Constraints

- The rule is normative now; the tree is migrated to match it in phases
  (see Migration status below). A reader must not assume every path in
  this document already exists on disk.
- `mise run check` stays green after every phase.
- `git mv` and a logic change never land in the same commit — refactor,
  then change.
- `hk` stays the only git-hook gate; its config gains steps, is never
  bypassed.
- `deploy/frontend/Dockerfile` carve-out is unchanged
  ([ADR 0007](../adr/0007-distroless-dockerfile-not-buildpacks.md)).
- No external repo pins `modules/*` or `environments/*` today — the
  restructure is free to move directories; the module-extraction cost is
  paid later if a downstream consumer appears.

## The rule

1. Every top-level concern directory has **one owner** and a declared list
   of the concerns it **may depend on**.
2. A file is placed with the concern that **owns** it — not by "lowest
   containing directory". Containment breaks on the real cross-concern
   edges (a shared test lib, a verify seam consumed from two places).
3. Allowed dependency edges are explicit and machine-checked. A reference
   (path string, relative climb, `source`, exec) that crosses a boundary
   not on the allow-list fails `mise run check`.

"Concern" here is coarse — about five in this repo, not one per directory.
The owner is the directory itself; the allow-list is the set of other
concerns whose files it may name.

## The concerns and their allowed edges

```
                       tests/lib   (leaf — tests only; any concern may load it)
                           ▲
         ┌─────────────────┼──────────────────────┐
         │                 │                      │
   deploy/frontend ──────▶ attestation      environments/local
         │                                        │  owns openbao/  (source = ./openbao)
         │  frontend consumes the verify          │  owns its orchestration scripts
         │  seam — the one allowed edge           ▼
         └──────────────────────────────  environments/local/openbao   (tofu unit — leaf)

FORBIDDEN:
  attestation                     ─╳▶  deploy/*                a seam never names its consumers
  environments/local/openbao      ─╳▶  attestation, deploy/*, environments/local/scripts
  environments/local/scripts      ─╳▶  attestation, deploy/*   (calls the attestation:export-pubkey TASK,
                                                                never writes the pubkey file)
  tests/lib                       ─╳▶  any concern             scratch helpers take copy-paths as ARGS
  anything                        ─╳▶  modules/*               except a published-module `source` pin

Runtime-only edges (env vars / mise-task calls, not file paths — allowed, not "dependencies"):
  attestation/scripts/openbao-preflight.sh       ··▶  OpenBao daemon        via $VAULT_ADDR
  deploy/frontend/scripts/frontend-serve.sh      ··▶  attestation-verify    via $TOOLBOX_ATTESTATION_VERIFY
  environments/local/scripts/openbao-bootstrap.sh ··▶ `mise run attestation:export-pubkey`  (task call, not a file write)
```

| concern | owns | may depend on |
|---|---|---|
| `tests/` | repo-level shared test support (`lib/`, `setup_suite.bash`, the coverage guard) | nothing — leaf; concern-agnostic (helpers take paths as args) |
| `attestation/` | the sign + verify + preflight seam, `verdict-approved.cue`, `cosign-approval.pub` | `tests/lib` |
| `deploy/frontend/` | one consumer of an approved image: build, deploy, serve | `attestation` (the verify seam, via env), `tests/lib` |
| `environments/local/` | one deployment target: the tofu composition, the orchestration scripts that bring its units up | its own `openbao/` unit, `tests/lib`; calls `attestation:export-pubkey` as a task |
| `environments/local/openbao/` | the local-OpenBao **tofu unit** only | `tests/lib` (for its `.tftest.hcl`) — leaf |
| `modules/` | reusable, versioned, URL-consumed OpenTofu modules only | — (empty today; a README states the rule) |

## Naming

- **Script files:** `<domain>-<verb>.sh`, where `<domain>` is the **tool**
  (`openbao-bootstrap.sh`, `attestation-sign.sh`), never the directory
  name. This decouples file names from directory renames. The `.sh` stem
  matches `^[a-z]+(-[a-z]+)+$`.
- **Directories:** kebab-case.
- **Tests:** `<concern>/scripts/tests/*.bats`, beside the scripts. The tofu
  unit keeps `<unit>/tests/*.tftest.hcl`.
- **Runtime shared shell:** `<concern>/scripts/lib/<domain>.sh` —
  self-contained, no repo-level runtime lib. The `SCRIPT_DIR` / `REPO_ROOT`
  idiom stays inline (standard bash, not domain logic).
- **Test support** lives under a `tests/` path; a production script never
  sources from a `tests/` path.

## mise task map

`<environment>:<domain>:<verb>` for environment-scoped work,
`<domain>:<verb>` otherwise. `check` / `fix` stay top-level. A task body
is a single inline command unless it has a loop, a conditional, error
classification, or a multi-step sequence with an invariant — only then
does it get a script.

```
BEFORE                    AFTER                          form
openbao-bootstrap         local:openbao:bootstrap        → environments/local/scripts/openbao-bootstrap.sh
openbao-up                local:openbao:start            inline: pitchfork start global/openbao
(new)                     local:openbao:stop             inline: pitchfork stop global/openbao
openbao-reset             local:openbao:reset            → environments/local/scripts/openbao-reset.sh
openbao-snapshot          local:openbao:snapshot         → environments/local/scripts/openbao-snapshot.sh
openbao-snapshot-restore  local:openbao:snapshot-restore inline: bao operator raft snapshot restore
export-approval-pubkey    attestation:export-pubkey      inline: cosign public-key --key openbao://approval-key --outfile attestation/cosign-approval.pub
approve                   attestation:sign               → attestation/scripts/attestation-sign.sh
verify-approval           attestation:verify             → attestation/scripts/attestation-verify.sh
consume                   frontend:deploy                → deploy/frontend/scripts/frontend-deploy.sh
check / fix               check / fix                    unchanged
(future)                  local:bootstrap               aggregate → local:openbao:bootstrap + …
```

## Target tree

```
toolbox/
├── CLAUDE.md  README.md  TODOS.md
├── mise.toml  hk.pkl  pitchfork.toml
├── .ls-lint.yml                                      structure + naming (Phase 1a)
├── sgconfig.yml  rules/boundary-*.yml                dependency edges, ast-grep (Phase 1a)
│
├── tests/                                            repo-level shared test support (leaf)
│   ├── setup_suite.bash                              bats-native — exposes load_lib
│   ├── check-coverage.sh                             parses `hk check --format jsonl`, diffs scheduled
│   │                                                 steps + case counts vs manifest.txt
│   ├── manifest.txt                                  committed: every suite + its expected case count
│   └── lib/
│       ├── scratch.bash        scratch dir; caller passes which concern paths to copy
│       ├── assert.bash         assert_success / assert_exit / assert_file_mode …
│       ├── ports.bash          allocate a free host port; host ≠ container mapping
│       └── registry.bash       spin a local zot / fake registry
│
├── attestation/                                      consumer-agnostic sign + verify seam
│   ├── verdict-approved.cue
│   ├── cosign-approval.pub                           written by `mise run attestation:export-pubkey` only
│   ├── README.md
│   └── scripts/
│       ├── attestation-sign.sh                       (was deploy/frontend/scripts/approve.sh)
│       ├── attestation-verify.sh                     (was …/verify-approval.sh)
│       ├── openbao-preflight.sh                      (moved — signing precondition)
│       ├── lib/attestation.sh
│       └── tests/
│           ├── attestation-sign.bats
│           ├── attestation-verify.bats
│           ├── openbao-preflight.bats
│           └── fixtures/
│
├── deploy/
│   └── frontend/                                     one consumer of an approved image
│       ├── Dockerfile  Dockerfile.dockerignore  README.md
│       └── scripts/
│           ├── frontend-deploy.sh                    (was consume.sh)
│           ├── frontend-serve.sh                     (was run.sh — pitchfork entrypoint)
│           ├── lib/frontend.sh
│           └── tests/
│               ├── frontend-deploy.bats
│               ├── frontend-serve.bats               (one case uses the DEFAULT verify path)
│               └── fixtures/
│
├── environments/
│   └── local/                                        one deployment target
│       ├── main.tf  provider.tf  outputs.tf  variables.tf  versions.tf  README.md
│       │            module "secret_openbao_local" { source = "./openbao" }   ← label kept
│       ├── scripts/                                  the environment owns bringing its units up
│       │   ├── openbao-bootstrap.sh
│       │   ├── openbao-reset.sh
│       │   ├── openbao-snapshot.sh                   (extracted from the mise task)
│       │   ├── lib/openbao.sh                        state-dir resolution, daemon wait-loop, atomic 0600 write
│       │   └── tests/
│       │       ├── openbao-bootstrap.bats
│       │       ├── openbao-reset.bats
│       │       ├── openbao-snapshot.bats
│       │       ├── mise-env.bats
│       │       └── fixtures/
│       └── openbao/                                  the tofu unit only (leaf)
│           ├── main.tf  variables.tf  outputs.tf  versions.tf  README.md
│           ├── templates/openbao.hcl.tftpl
│           └── tests/
│               ├── config_render.tftest.hcl
│               ├── keys.tftest.hcl
│               └── policies.tftest.hcl
│
├── modules/
│   └── README.md                                     "reusable, versioned, URL-consumed OT modules only"
│
└── docs/
    ├── designs/
    │   ├── repo-structure.md                         this file
    │   └── digest-as-source-of-truth.md
    └── adr/
        ├── 0012-local-openbao-is-environment-nested.md
        ├── 0013-attestation-seam-is-consumer-agnostic.md
        └── … existing
```

## Enforcement

Two `hk` fast-layer steps, both covered by `mise run check`:

| tool | job | how |
|---|---|---|
| `ls-lint` (`aqua:loeffel-io/ls-lint`; the `hk` `ls_lint` builtin drives the binary) | structure + naming | `.ls-lint.yml`: kebab-case directories; the `.sh` **stem** matches `^[a-z]+(-[a-z]+)+$`; each `scripts/` has a `tests/`; allowed extensions per directory |
| `ast-grep` (`aqua:ast-grep/ast-grep`) | forbidden-edge **lint** | `sgconfig.yml` + `rules/boundary-*.yml`: per concern, per language — error on a **literal** `deploy/` / `attestation/` path string, a `../<concern>` relative climb, or `source`/exec of a literal path crossing a boundary |

### Honest scope

`ls-lint` + `ast-grep` are a **strong lint, not dependency-graph
analysis.** They catch literal path strings, relative climbs, and
`source`/exec of a literal. They do **not** catch: a path assembled from
variables, `source "$x"` resolution, or cross-language task references
(the `ast-grep` rules are per-language; TOML/Pkl task refs are not
covered). The lint is paired with a review checklist for the rest.

A real resolved-dependency-graph check — a generated manifest validated by
`conftest`/OPA (Rego), `tofu graph` for the HCL layer, or CUE/Timoni
schemas expressing the allowed-edge set — is a separate future planning
session, tracked in [`TODOS.md`](../../TODOS.md).

## Migration status

The rule is in force now. The tree is moved to match it in phased,
typed PRs, each green on its own — full phase list and per-phase
verification in [`TODOS.md`](../../TODOS.md) (tasks T1–T6). Until a phase
lands, the affected files stay at their pre-restructure paths:

| phase | moves | status |
|---|---|---|
| 0 | this doc + CLAUDE.md rule + 2 ADRs — no code | ← you are here |
| 1a | pin `ls-lint` + `ast-grep`; `.ls-lint.yml` + `rules/` for the **current** tree | pending |
| 1b–1d | `tests/lib/`, co-locate `deploy/frontend/tests/`, coverage guard, parallel-safe isolation | pending |
| 2 | local-OpenBao → `environments/local/{openbao,scripts}/`; root `scripts/` emptied; `modules/` → README only | pending |
| 3 | mise task namespacing | pending |
| 4 | `attestation/` split out of `deploy/frontend/` (one PR) | pending |
| 5 | docs-accuracy sweep — every `.md` re-verified against the moved code | pending |

## Negative space (deliberately not here)

- **No `environments/production/`** — created when real infra lands; the
  `environments/` seam already exists for it.
- **No repo-level runtime shell lib** — shared runtime logic lives in the
  one concern lib that uses it.
- **No compatibility shims** during the migration — a phase either lands
  whole or does not land.
- **No `modules/*` content** — `modules/` stays empty with a README until a
  genuinely reusable, versioned, URL-consumed module exists (the deferred
  production `secret-openbao` is the first candidate).
