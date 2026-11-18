# initialize-repo: Agent Skill design

Date: 2026-11-17
Status: draft, awaiting approval

## Intent

An Agent Skill that sets a GitHub repository up for a professional development
workflow: standard project files, CI that skips heavy checks on changes that
can't affect how the program runs, repo settings kept as reviewable code, and
GitHub issue/project conventions that future agents in the repo will follow.

It is mainly for **brand-new repos** but must also be useful on **existing
repos**. It is built for the author's own use first, and will be **published**
for others, so nothing personal is hard-coded.

### Origin

The idea came from `sohampatwardhan/Amtrak-GTFS-RT`. A one-line `AGENTS.md`
change (#95) was blocked by seven required CI jobs (Rust build and test, image
builds, Compose checks) and had to be merged with admin bypass. The fix in #96
taught the lessons this skill is built on:

- Markdown can't change how a program runs, so CI should only do heavy work
  when implementation or logic changes.
- A workflow-level `on: paths:` filter, or a job-level `if:` on a **matrix**
  job, leaves required checks stuck on "pending" forever.
- Some markdown *is* read by checks (`.security/**/*.md` by an expiry check,
  `CHANGELOG.md` by release scripts). That markdown counts as logic.
- Unlisted paths must default to "run CI".
- The docs-only check belongs in a small script with its own test, and should
  be validated against the file lists of real past PRs.
- `AGENTS.md` must explain why the skip is built this way, or a later agent
  will "simplify" it back into a trigger filter.

## Goals

1. Create a new GitHub repo, or connect to an existing one.
2. Write the standard files: `README.md`, `AGENTS.md`, `CLAUDE.md` (imports
   AGENTS.md), `CHANGELOG.md`, `CONTRIBUTING.md`, `LICENSE`, plus `.gitignore`,
   `.editorconfig`, `SECURITY.md`, issue templates, a PR template,
   `dependabot.yml`, and a CI workflow.
3. CI that skips heavy jobs on non-logic changes while required checks still
   report success, with a tested scope script. See CI design.
4. Keep each repo's desired settings, ruleset, and labels as committed JSON
   under `.github/settings/`, with a script that audits them against live
   GitHub and applies approved differences.
5. Make agents use GitHub's issue tracking and project management features
   fully. The guidance ships **inside the skill** (no dependency on any user's
   personal rules), is followed during init, and is written into the generated
   `AGENTS.md`.
6. Install via a Claude Code plugin marketplace, `npx skills add`, or manual
   copy, and run in any agent tool that supports Agent Skills.

## Non-goals

- Dependency-audit and risk-acceptance workflows (e.g. expiry checks on
  accepted risks). Out of scope for this repo. Dependabot and SHA-pinned
  actions are in scope.
- Release automation (release-please, semantic-release, publish workflows).
  CHANGELOG is maintained by hand in Keep a Changelog format.
- Hosts other than GitHub.
- Deploy pipelines, environments, secrets management.
- Generating application code or framework scaffolding.

## Anti-goals (would be a failure even if it technically works)

- Overwriting an existing file, label, template, workflow, or setting without
  asking.
- Changing repo settings silently. Settings affect everyone on the repo.
- Reporting success for something GitHub refused (e.g. a ruleset on a private
  repo under a free personal plan).
- A PR that can never merge because a required check never reports.
- The skill merging its own PR.
- Re-proposing a setting the user deliberately declined, on every run.
- Anything personal (name, licence choice, merge style) baked into the
  published skill.
- Dependence on one agent tool's private features.

## Constraints

- Runtime tools: `git`, the `gh` CLI, and `jq`. Scripts are `bash` (3.2
  compatible, for macOS's default shell). `jq` is needed because the scripts
  read the committed `.github/settings/*.json` files, and `gh --jq` only
  filters API responses. `jq` ships with macOS 15+ and GitHub's runners.
  No Python or Node required. (Changed during planning; the approved draft
  said no `jq`.)
- Must run on macOS, Linux, and Windows via Git Bash.
- `gh` must be installed and authenticated. The skill checks first and stops
  with a clear message if not.
- GitHub plan limits:
  - Rulesets are unavailable on **private repos owned by a free personal
    account**.
  - **Issue types** (Task/Bug/Feature) aren't available on every repo. They
    started as organization-only, but this personal repo has them. Detect
    per repo via GraphQL (`repository.issueTypes`); never infer from owner
    type.
  - Security alert links need Dependabot alerts / code scanning enabled.
- Follows the Agent Skills format (`SKILL.md` with `name` and `description`
  frontmatter). The builder verifies current field rules, the Claude Code
  plugin/marketplace manifest format, and what `npx skills add` expects, against
  current docs.
- `SKILL.md` refers to its own `scripts/`, `config/`, `templates/` by paths
  relative to the skill directory, and tells the agent to resolve them from
  there, since each tool runs skills from a different working directory.

## Approaches considered

| Approach | Summary | Trade-off |
| --- | --- | --- |
| A. Instructions only | Agent does everything via `gh`/`git` from written guidance. | Simplest and adaptive, but settings changes are improvised per run: inconsistent and untestable where it matters most. |
| B. Script-driven | One script does everything; SKILL.md says "run it". | Deterministic and testable, but no judgment: poor at merging into existing files, detecting stacks, or writing real descriptions. Existing repos are a stated use case. |
| **C. Hybrid (chosen)** | Agent does the judgment work; small scripts do the mechanical, risky GitHub changes from declarative JSON. | More moving parts than A, but predictable and testable for settings, flexible for content. |

Ruled out: GitHub template repos / cookiecutter. They only stamp files into a
new repo and can't audit settings or help an existing repo.

**Chosen: C**, by the user.

## Design

### Repo layout (this repo)

```text
.claude-plugin/
  marketplace.json                 # Claude Code marketplace listing
  plugin.json                      # plugin manifest (exact location per docs)
skills/initialize-repo/
  SKILL.md                         # workflow the agent follows
  references/
    github-workflow.md             # issue/project conventions
    settings-baseline.md           # what each setting does and why
    ci-design.md                   # how and why the skip works
  config/                          # defaults used to seed .github/settings/
    repo.json, ruleset-default-branch.json, labels.json
  scripts/
    preflight.sh                   # git/gh present, gh authed, scopes
  templates/
    README.md, AGENTS.md, CLAUDE.md, CHANGELOG.md, CONTRIBUTING.md,
    SECURITY.md, .editorconfig
    .github/
      ISSUE_TEMPLATE/{bug.yml, feature.yml, task.yml, config.yml}
      pull_request_template.md
      dependabot.yml
      workflows/ci.yml             # base: scope job + ci-ok gate
    ci/                            # per-stack job snippets
      python.yml, node.yml, go.yml, rust.yml, placeholder.yml
    scripts/                       # copied into the generated repo
      repo-settings.sh             # audit | apply, reads .github/settings/
      ci-scope.sh                  # classifies changed files
      ci-scope.test.sh             # tests for ci-scope.sh
docs/                              # this design and later docs
```

`LICENSE` and `.gitignore` are not templated. They come from GitHub's APIs
(`gh api /licenses/<key>`, `gh api /gitignore/templates/<Lang>`) so the text
is canonical. The agent fills in year and copyright holder.

### What the generated repo gets

```text
.github/
  settings/
    repo.json                      # merge options, features, security
    ruleset-default-branch.json    # the default-branch ruleset
    labels.json
  ISSUE_TEMPLATE/…, pull_request_template.md, dependabot.yml
  workflows/ci.yml
scripts/
  repo-settings.sh, ci-scope.sh, ci-scope.test.sh
README.md, AGENTS.md, CLAUDE.md, CHANGELOG.md, CONTRIBUTING.md,
SECURITY.md, LICENSE, .gitignore, .editorconfig
```

The skill uses the repo's own copy of `repo-settings.sh` for the settings
work. That way the repo can be audited later without the skill installed, and
there's one script, not two.

### Workflow (what SKILL.md tells the agent to do)

1. **Preflight.** Run `preflight.sh`. Read the optional preferences file. Work
   out the situation:
   - **new**: no GitHub remote or no commits
   - **existing, first run**: no `.github/settings/`
   - **existing, second run**: setup PR merged, ruleset changes still pending
   - **re-audit**: already set up; just check drift
2. **Gather.** Ask only what preferences and the repo don't answer: name and
   one-line description; owner and visibility (new only); licence (always
   asked unless in preferences); stack (new only. For existing repos, detect
   from `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, … and
   confirm); merge style and required approvals, if not in preferences.
3. **Create or connect.** New: `gh repo create` with name, owner, visibility,
   description, topics. Existing: confirm the remote.
4. **Write files.** Fill templates. Placeholders use `{{LIKE_THIS}}`, and a
   final check confirms none remain. Seed `.github/settings/*.json` from the
   skill's `config/` defaults plus the user's answers. Existing files are never
   overwritten: the agent shows what it would add or change and asks.
5. **CI in existing repos.** Adapt the existing workflows in place with
   per-step gating (see CI design), through the setup PR. Don't add a parallel
   `ci-ok` gate or change required check names. Before turning the skip on,
   **backtest** `ci-scope.sh` against the changed files of the last ~10 merged
   PRs (`gh pr list --state merged --json files`) and show which would have
   skipped.
6. **Commit.**
   - New repo: initial commit straight to the default branch and push,
     *before* the ruleset is applied.
   - Existing repo: commit on `chore/initialize-repo` and open a PR. The
     skill never merges it.
7. **Settings.** Run `repo-settings.sh audit`. Show current vs. desired.
   Apply only approved items. Report plan-limit refusals plainly.
   - Existing repo where the ruleset would require a check that isn't on the
     default branch yet: **stop here.** Tell the user to merge the setup PR and
     run the skill again. Step 1 detects the second run.
   - Classic branch protection: report it and offer to migrate to a ruleset.
     Never stack a second ruleset or change protection without approval.
8. **Summary.** List every file written, setting changed, item skipped or
   declined and why, and follow-ups (e.g. "replace the placeholder CI job once
   code exists").
9. **Offer a proof PR.** Offer to open a one-line docs PR that shows the skip
   working for real. Never opened without a yes.

### Preferences file

Optional, at `~/.config/initialize-repo/defaults.yaml`. The **agent** reads it;
scripts never do. Keys: `author_name`, `copyright_holder`, `license`,
`default_owner`, `default_visibility`, `merge_style`, `required_approvals`,
`commit_convention`, `assign_self`. Missing keys are asked for. The published
skill ships an example and nothing personal.

### Settings as code (`.github/settings/`)

- `repo.json`, `ruleset-default-branch.json`, `labels.json` hold the repo's
  **desired** state, seeded from defaults plus the user's choices.
- Each file can carry a `declined` list of baseline items the user chose not to
  adopt, with a reason. `audit` doesn't flag those, and the skill doesn't
  propose them again.
- `repo-settings.sh audit` prints a readable diff and exits non-zero when live
  differs from desired. `apply` takes an explicit list of items (or `--all`)
  and supports `--dry-run`. HTTP 403/422 from plan limits are caught and
  reported as "not available on this plan".
- Settings changes go through PRs like code, so they're reviewable.
- Drift checking runs on demand (by a person or an agent). A scheduled drift
  workflow isn't in v1: the default `GITHUB_TOKEN` may not be able to read
  rulesets or security settings.

### Settings baseline (skill defaults)

- **Merging:** merge style from preferences (default squash only), delete head
  branches on merge, allow auto-merge.
- **Default-branch ruleset:** require a PR; require the `ci-ok` check (new
  repos) or keep existing required checks (existing repos); block force-pushes
  and deletion; required approvals 0 by default (solo developers can't approve
  their own PRs). **Bypass: repository admin role, pull requests only.** Admins
  can merge a PR without waiting for checks, but nobody pushes straight to the
  default branch.
- **Security:** Dependabot alerts and security updates, secret scanning, push
  protection (where the plan allows).
- **Features:** Issues on. Wiki off unless already in use. Projects tab left as
  is.

### CI design

Never uses `on: paths:` / `paths-ignore` on the trigger.

**`ci-scope.sh`** takes a list of changed files and prints `logic` or
`non-logic`. A file is non-logic only if it matches the non-logic patterns
**and** isn't in the "read by checks" exceptions. Unlisted paths are logic.
Patterns are defined once, at the top of the script:

- default non-logic: `**/*.md`, `**/*.txt`, `docs/**`, `LICENSE*`,
  `.gitignore`, `.github/ISSUE_TEMPLATE/**`, `.github/pull_request_template.md`
- default exceptions (always logic): `CHANGELOG.md` if release tooling reads
  it. The agent adds others it finds (e.g. markdown parsed by a check).
- Workflow files and anything under `scripts/` are always logic.

`ci-scope.test.sh` covers the patterns and exceptions.

**Job categories in `ci.yml`:**

- **scope**: runs `ci-scope.sh` against the PR's changed files (plain `git
  diff --name-only` against the base; no third-party action). On `push` to the
  default branch, always `logic`.
- **always-on checks**: cheap jobs that run on every PR, including any check
  that reads markdown, and `ci-scope.test.sh`.
- **heavy jobs** (lint, test, builds): gated on the scope result.

**Two gating modes:**

- **New repos — job-level gate + `ci-ok`.** Heavy jobs use
  `if: needs.scope.outputs.logic == 'true'`. A final `ci-ok` job
  (`needs:` everything, `if: always()`) fails if any job failed or was
  cancelled, and treats skipped as success. `ci-ok` is the **only** required
  check, so skipped jobs and matrix expansion never matter.
- **Existing repos with named required checks — step-level gate.** Every job
  still runs and reports. Each heavy step gets `if: needs.scope.outputs.logic
  == 'true'`, so the job finishes green quickly on non-logic PRs. Required
  check names, including matrix ones, stay the same, and the ruleset doesn't
  change. This is the Amtrak #96 approach.

Stack jobs come from `templates/ci/`. If the stack is unknown,
`placeholder.yml` is used: a job that passes and says it must be replaced.
Third-party actions are pinned by commit SHA, and Dependabot keeps them
updated.

**AGENTS.md** gets a section on why the skip is built this way (no trigger
filters; why `ci-ok` or step-level gating), so nobody simplifies it back.

### GitHub workflow guidance (`references/github-workflow.md`)

Adapted from the author's issue rules, written for any repo and any agent:

- Fill every issue field that genuinely fits: assignees, existing labels, type,
  project/milestone only when it clearly belongs, relationships (parent/sub,
  blocked-by/blocking, relates-to as the default when unsure), linked PRs via
  closing keywords (`Closes #N`), security alerts when relevant.
- Read other open issues before linking. Never invent a relationship.
- Reuse existing labels. Don't create new ones unasked.
- State which fields were set or left empty, and why.
- Don't change repo settings to fill a field. Ask first.
- Use `gh` and `gh api graphql` for types and relationships the CLI flags
  don't cover.
- **Fallback:** on repos without issue types, use the
  `bug` / `enhancement` / `task` labels.

The same content goes into the generated `AGENTS.md`.

### Labels

Reuse GitHub's default labels. Add only `task` (for the issue-type
fallback). Dependabot creates `dependencies` itself.

### This repo (dogfooding)

This repo uses the skill's own output: README (with install steps for all
three channels), AGENTS.md, CI, `.github/settings/`, labels, and the ruleset.
Its non-logic patterns **exclude** `skills/**`, since SKILL.md, references,
and templates are the product.

Its CI runs:

- `shellcheck` on all scripts
- `actionlint` on `templates/.github/workflows/ci.yml` combined with each
  `templates/ci/*.yml` snippet
- `ci-scope.test.sh`
- a smoke test that renders the templates into a temp dir, checks no `{{…}}`
  placeholders remain, and validates the YAML/JSON
- `repo-settings.sh --dry-run` against a stubbed `gh` (via a `GH` environment
  variable pointing to a fake)
- validation of the plugin and marketplace manifests

## Calls made without the user (adjustable)

- Existing repos: adapt existing CI in place with step-level gating; never add
  a parallel gate or stack a second ruleset.
- Existing repos: two runs when new required checks are needed; the skill never
  merges its own PR.
- Per-repo choices live in `.github/settings/`, with a `declined` list.
- One `repo-settings.sh`, shipped into the generated repo and used by the
  skill.
- No scheduled drift workflow in v1.
- Backtest against the last ~10 merged PRs.
- Proof PR offered at the end, never automatic.
- Starter stacks: Python, Node/TypeScript, Go, Rust, plus placeholder.
- CONTRIBUTING defaults to Conventional Commits, overridable via preferences.
- Required approvals default to 0.

## Left to the builder

- Wording and sections of each template.
- How stack snippets are merged into `ci.yml`. (Planning decided: a small
  `scripts/render.sh` in the skill fills `{{PLACEHOLDERS}}` and inserts
  snippets, so the agent doesn't improvise it.)
- How the `gh` stub for tests works.
- Exact JSON shapes in `.github/settings/`.

## Decided after approval

- Licence for this skill repo: MIT.
- This repo is public: `sohampatwardhan/initialize-repo-skill`.
