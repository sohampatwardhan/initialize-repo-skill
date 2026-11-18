# initialize-repo Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish the `initialize-repo` Agent Skill, which sets a GitHub repo up with standard files, logic-scoped CI, settings-as-code, and GitHub issue conventions.

**Architecture:** Hybrid (approach C). `SKILL.md` drives the agent through judgment work: questions, stack detection, writing content, merging into existing files. Small bash scripts do the mechanical, risky work deterministically: classifying changed files, rendering templates, auditing and applying repo settings from committed JSON. Scripts that a generated repo keeps (`ci-scope.sh`, `repo-settings.sh`) live under `templates/scripts/` and are copied into it.

**Tech Stack:** bash 3.2+, `git`, `gh` CLI, `jq`, GitHub Actions. Dev/CI only: `shellcheck`, `actionlint`, `yq` (mikefarah), `markdownlint-cli2`.

**Spec:** `docs/superpowers/specs/2026-11-17-initialize-repo-skill-design.md`

## Global Constraints

- Scripts must run on bash 3.2 (macOS default): no associative arrays, no `mapfile`/`readarray`, no `${var,,}`, no `declare -n`. No GNU-only flags (`sed -i`, `grep -P`, `readlink -f`, `date -d`).
- Runtime dependencies: `git`, `gh`, `jq` only. No Python or Node at runtime.
- Every script calls `gh` as `"${GH:-gh}"` so tests can substitute a fake. Scripts pipe raw `gh api` output to `jq`; they do not use `gh --jq` (the fake doesn't emulate it).
- Templates use `{{UPPER_SNAKE}}` placeholders. GitHub Actions `${{ … }}` expressions are not placeholders and must survive rendering untouched.
- Every third-party action in any workflow (template or this repo) is pinned to a 40-character commit SHA with a `# vX.Y.Z` comment.
- Never use `on: paths:` / `paths-ignore:` on a workflow trigger.
- Required check name for new repos: `ci-ok`. Stack jobs in every snippet have the ids `lint` and `test`.
- Ruleset name: `default-branch`. Target `~DEFAULT_BRANCH`. Bypass: `RepositoryRole` admin (`actor_id` 5), `bypass_mode: pull_request`. Required approvals default `0`.
- Labels: GitHub defaults plus `task` only.
- Nothing personal in shipped files: no author name, licence choice, or owner baked in.
- Commits use Conventional Commits and end with the attribution trailer the session specifies.
- Work happens on branch `feat/v1`. Each task is one or more commits whose final commit message includes `Closes #<task issue>`. One PR to `main` lists every `Closes #N`. A human merges it.

## Review Focus

1. **Paths with spaces, or renamed/deleted files in a diff.** The scope result must still be right. Pinned by `test_path_with_spaces` and `test_deleted_doc_only` in Task 2.
2. **`${{ github.* }}` expressions in templates.** render.sh must leave them alone and must not mistake them for leftover placeholders. Pinned by `test_actions_expressions_untouched` in Task 3.
3. **Running `apply` twice.** It must update the existing ruleset and labels, never create duplicates. Pinned by `test_apply_ruleset_updates_existing` (Task 7) and `test_labels_apply_idempotent` (Task 6).
4. **`gh` missing, logged out, or without the `workflow` scope.** Preflight must stop with a message naming the fix, not fail halfway through a push. Pinned by `test_missing_workflow_scope` in Task 8.
5. **A default branch not named `main`.** Rendered CI and docs must use the real branch name. Pinned by `test_render_trunk_branch` in Task 4.

---

## File Map

```text
.github/workflows/ci.yml                       # this repo's CI (T1, extended T12)
tests/lib/assert.sh                            # assert helpers (T1)
tests/run-all.sh                               # runs every *.test.sh (T1)
tests/fake-gh/gh                               # gh stub (T5)
tests/fixtures/…                               # fixture API responses (T5–T8)
tests/{render,ci-template,repo-settings,labels,ruleset,preflight,smoke,skill,dogfood-sync}.test.sh
skills/initialize-repo/
  SKILL.md                                     # T10
  references/{github-workflow,settings-baseline,ci-design}.md   # T9, T10
  references/examples/step-gated.yml           # T10
  examples/defaults.yaml                       # T11
  config/{repo,ruleset-default-branch,labels}.json              # T5–T7
  scripts/preflight.sh                         # T8
  scripts/render.sh                            # T3
  templates/scripts/ci-scope.sh, ci-scope.test.sh               # T2
  templates/scripts/repo-settings.sh           # T5–T7
  templates/.github/workflows/ci.yml           # T4
  templates/ci/{python,node,go,rust,placeholder}.yml            # T4
  templates/{README,AGENTS,CLAUDE,CHANGELOG,CONTRIBUTING,SECURITY}.md, .editorconfig   # T9
  templates/.github/ISSUE_TEMPLATE/{bug,feature,task,config}.yml                       # T9
  templates/.github/{pull_request_template.md,dependabot.yml}                          # T9
.claude-plugin/{marketplace,plugin}.json       # T11
README.md, AGENTS.md, CLAUDE.md, … (dogfood)   # T12
```

---

### Task 1: Test harness and this repo's CI

**Files:**
- Create: `tests/lib/assert.sh`, `tests/run-all.sh`, `tests/harness.test.sh`, `.github/workflows/ci.yml`, `.gitignore`

**Interfaces:**
- Produces:
  - `assert_eq <expected> <actual> <msg>`
  - `assert_contains <haystack> <needle> <msg>`
  - `assert_not_contains <haystack> <needle> <msg>`
  - `assert_exit <code> <cmd...>`
  - `finish`, which prints a pass/fail count and exits 1 if anything failed.
  - Test files are `*.test.sh` and source `tests/lib/assert.sh`.
  - `tests/run-all.sh` runs every `tests/*.test.sh` plus `skills/initialize-repo/templates/scripts/*.test.sh`, and exits non-zero if any fail.

- [ ] **Step 1: Write `tests/harness.test.sh`**: assert `assert_eq a a` passes; a deliberately failing `assert_eq a b`, run in a subshell, makes `finish` exit 1.
- [ ] **Step 2: Run** `bash tests/harness.test.sh`. Expected: fails (assert.sh missing).
- [ ] **Step 3: Implement** `tests/lib/assert.sh` and `tests/run-all.sh`.
- [ ] **Step 4: Run** `bash tests/run-all.sh`. Expected: `harness.test.sh` passes, exit 0.
- [ ] **Step 5: Write `.github/workflows/ci.yml`** for this repo, triggered on `pull_request` and on `push` to `main`. Three jobs:
  - `shellcheck`: `shellcheck` on all `*.sh` files and `tests/fake-gh/gh`
  - `actionlint`: on `.github/workflows/*.yml`
  - `tests`: installs `jq`, runs `bash tests/run-all.sh`

  Pin `actions/checkout` by SHA (resolve with `gh api repos/actions/checkout/git/ref/tags/<latest v-tag> --jq .object.sha`).
- [ ] **Step 6: Run** `actionlint .github/workflows/ci.yml && shellcheck tests/*.sh tests/lib/*.sh`. Expected: no output.
- [ ] **Step 7: Commit**: `ci: add test harness and repository CI` + `Closes #<T1>`.

---

### Task 2: `ci-scope.sh` classifier

**Files:**
- Create: `skills/initialize-repo/templates/scripts/ci-scope.sh`, `skills/initialize-repo/templates/scripts/ci-scope.test.sh`

**Interfaces:**
- Produces: `ci-scope.sh` reads newline-separated paths on stdin and prints exactly `logic` or `non-logic`. It always exits 0 on valid input.
  - Empty input → `logic`.
  - Patterns live between the marker lines `# BEGIN SCOPE PATTERNS` and `# END SCOPE PATTERNS`, as two bash arrays: `NON_LOGIC` and `ALWAYS_LOGIC`.
  - Matching uses `[[ $path == $pattern ]]`, where `*` also matches `/`.
  - `ALWAYS_LOGIC` is checked first. A path matching neither array is logic.
- Defaults:
  - `NON_LOGIC=('*.md' '*.txt' 'docs/*' 'LICENSE*' '.gitignore' '*/.gitignore' '.github/ISSUE_TEMPLATE/*' '.github/pull_request_template.md')`
  - `ALWAYS_LOGIC=('.github/workflows/*' 'scripts/*')`
  - Plus a commented-out example: `# 'CHANGELOG.md'  # uncomment if release tooling reads it`.

- [ ] **Step 1: Write `ci-scope.test.sh`.** It sources `assert.sh` from `${ASSERT_LIB:-$(dirname "$0")/../../../../tests/lib/assert.sh}` if present, else defines minimal inline asserts, because the test ships into generated repos without `tests/lib`. Cases, each as `printf '%s\n' … | ci-scope.sh`:

```bash
test_readme_only            # README.md                         -> non-logic
test_nested_docs            # docs/a/b.md, guide.txt            -> non-logic
test_source_file            # src/main.rs                       -> logic
test_mixed                  # README.md, src/main.rs            -> logic
test_unlisted_path          # Makefile                          -> logic
test_always_logic_wins      # scripts/notes.md                  -> logic
test_workflow_is_logic      # .github/workflows/ci.yml          -> logic
test_empty_input            # (nothing)                         -> logic
test_path_with_spaces       # "docs/my notes.md"                -> non-logic
test_deleted_doc_only       # old-guide.md (deleted path)       -> non-logic
test_issue_template         # .github/ISSUE_TEMPLATE/bug.yml    -> non-logic
```

- [ ] **Step 2: Run** `bash skills/initialize-repo/templates/scripts/ci-scope.test.sh`. Expected: fails (script missing).
- [ ] **Step 3: Implement `ci-scope.sh`** with `while IFS= read -r path` and an early exit on the first logic path.
- [ ] **Step 4: Run** the test, then `shellcheck` on both files. Expected: all pass, no warnings.
- [ ] **Step 5: Commit**: `feat: add ci-scope classifier` + `Closes #<T2>`.

---

### Task 3: `render.sh` template renderer

**Files:**
- Create: `skills/initialize-repo/scripts/render.sh`, `tests/render.test.sh`

**Interfaces:**
- Produces: `render.sh <template> <output> [KEY=VALUE ...] [--insert MARKER=FILE ...]`
  - Replaces every `{{KEY}}` with `VALUE`. Values may contain `/`, `&`, and spaces.
  - `--insert MARKER=FILE` replaces a line whose trimmed content is `# {{MARKER}}` with the contents of FILE, indented to match the marker line.
  - Creates the parent directories of `<output>`.
  - Exit 1, with `render.sh: unfilled placeholders: KEY1 KEY2` on stderr, if any `{{[A-Z0-9_]+}}` not preceded by `$` remains. The output file is still written so the agent can inspect it.
  - Exit 2 on bad usage.

- [ ] **Step 1: Write `tests/render.test.sh`:**

```bash
test_substitutes_values               # "Hi {{NAME}}" NAME="A & B/C" -> "Hi A & B/C"
test_actions_expressions_untouched    # "${{ github.ref }} {{X}}" X=1 -> "${{ github.ref }} 1", exit 0
test_unfilled_placeholder_fails       # "{{MISSING}}" -> exit 1, stderr contains "MISSING"
test_insert_indents                   # "  # {{JOBS}}" + file "a:\n  b" -> "  a:\n    b"
test_creates_parent_dirs              # output deep/nested/x -> exists
```

- [ ] **Step 2: Run** `bash tests/render.test.sh`. Expected: fails.
- [ ] **Step 3: Implement.** Do the substitution in a bash `while read` loop with `${line//\{\{$key\}\}/$value}`, not `sed`, so special characters in values are safe.
- [ ] **Step 4: Run** the test and `shellcheck`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add template renderer` + `Closes #<T3>`.

---

### Task 4: CI workflow template and stack snippets

**Files:**
- Create: `skills/initialize-repo/templates/.github/workflows/ci.yml`, `skills/initialize-repo/templates/ci/{python,node,go,rust,placeholder}.yml`, `tests/ci-template.test.sh`

**Interfaces:**
- Consumes: `render.sh` (T3), `ci-scope.sh` (T2).
- Produces: a base `ci.yml` with these placeholders:
  - `{{DEFAULT_BRANCH}}`
  - the marker line `# {{STACK_JOBS}}`, at job indentation

  and these jobs:
  - **`scope`**:
    - Checks out with `fetch-depth: 2`.
    - On `pull_request`: `git diff --name-only HEAD^1 HEAD | bash scripts/ci-scope.sh`.
    - On `push` / `workflow_dispatch`: always `logic`.
    - Output: `logic` (`'true'`/`'false'`).
  - **`checks`**: always runs `bash scripts/ci-scope.test.sh`.
  - **`ci-ok`**:
    - `needs: [scope, checks, lint, test]`, `if: always()`.
    - Fails when `contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')`.

  Each snippet defines exactly two jobs, `lint` and `test`, each with `needs: scope` and `if: needs.scope.outputs.logic == 'true'`:
  - python: `astral-sh/setup-uv`; `uvx ruff check .`; `uv run pytest`
  - node: `actions/setup-node`; `npm ci`; `npm run lint --if-present`; `npm test`
  - go: `actions/setup-go`; `go vet ./...`; `go test ./...`
  - rust: `cargo clippy --all-targets -- -D warnings`; `cargo test`
  - placeholder: both jobs `echo "::warning::Replace this placeholder job with real lint/test steps"` and pass

- [ ] **Step 1: Write `tests/ci-template.test.sh`.** For each of the five snippets, render to a temp dir with `DEFAULT_BRANCH=main`, then:

```bash
test_render_<stack>        # render exit 0; actionlint on output exit 0
test_no_trigger_paths      # output has no "paths:" / "paths-ignore:" under "on:"
test_ci_ok_needs_all       # yq '.jobs."ci-ok".needs' == [scope, checks, lint, test]
test_actions_pinned        # every "uses:" value matches @[0-9a-f]{40}
test_render_trunk_branch   # DEFAULT_BRANCH=trunk -> yq '.on.push.branches[0]' == trunk
```

  Skip the actionlint cases, with a visible `SKIP`, if `actionlint` isn't installed locally. CI installs it.
- [ ] **Step 2: Run** `bash tests/ci-template.test.sh`. Expected: fails.
- [ ] **Step 3: Write the base `ci.yml` and the five snippets.** Resolve each action's SHA via `gh api repos/<owner>/<action>/git/ref/tags/<tag> --jq .object.sha`. If that returns a tag object, follow it with `gh api repos/<o>/<a>/git/tags/<sha> --jq .object.sha`.
- [ ] **Step 4: Run** the test. Expected: pass.
- [ ] **Step 5: Add `actionlint` and `yq` installation** to the `tests` job in this repo's `.github/workflows/ci.yml`, pinned by SHA or by a checksum-verified release download. Run `actionlint` on it.
- [ ] **Step 6: Commit**: `feat: add CI workflow template with logic-scoped jobs` + `Closes #<T4>`.

---

### Task 5: `repo-settings.sh` core and repo settings

**Files:**
- Create: `skills/initialize-repo/templates/scripts/repo-settings.sh`, `skills/initialize-repo/config/repo.json`, `tests/fake-gh/gh`, `tests/fixtures/repo-basic/…`, `tests/repo-settings.test.sh`

**Interfaces:**
- Produces: `repo-settings.sh <audit|apply> [--repo OWNER/NAME] [--dir DIR] [--dry-run] [--all | ITEM ...]`
  - Defaults: `--dir .github/settings`; `--repo` comes from `gh repo view --json nameWithOwner`.
  - **Item ids:** `repo.<key>` and `security.<key>`. Later tasks add `labels.<name>` and `ruleset.default-branch`.
  - **audit** prints one line per difference: `DIFF<TAB><item><TAB>live=<v><TAB>desired=<v>`.
    - Prints `NOTE<TAB>…` lines for information only.
    - Exit codes: 0 no differences, 1 differences, 2 error.
  - **apply** applies the named items, or every differing item with `--all`.
    - `--dry-run` prints `WOULD<TAB><METHOD> <endpoint>` instead of calling.
    - Prints `APPLIED<TAB><item>`, `UNAVAILABLE<TAB><item><TAB><reason>`, or `FAILED<TAB><item><TAB><reason>`.
    - Exit codes: 0 all applied, 1 any failed, 3 some unavailable and none failed.
  - **Plan limits:** a `gh` stderr containing `(HTTP 403)` or `(HTTP 422)` is reported as `UNAVAILABLE` with the API's message.
  - **`repo.json` shape:**
    - `{"repo": {allow_squash_merge, allow_merge_commit, allow_rebase_merge, delete_branch_on_merge, allow_auto_merge, has_issues, has_wiki}, "security": {vulnerability_alerts, automated_security_fixes, secret_scanning, secret_scanning_push_protection}, "declined": [{"item": "<id>", "reason": "…"}]}`
    - Booleans, except security values, which are `"enabled"`/`"disabled"`.
    - Declined items are never reported or applied.
  - **Endpoints:**
    - `repo.*`: `PATCH repos/{r}`
    - `security.vulnerability_alerts`: `PUT`/`DELETE repos/{r}/vulnerability-alerts`
    - `security.automated_security_fixes`: `PUT`/`DELETE repos/{r}/automated-security-fixes`
    - `secret_scanning*`: `PATCH repos/{r}` with `security_and_analysis`
- **Fake gh (`tests/fake-gh/gh`):**
  - Handles `api [-X METHOD] <endpoint> [--input FILE] [-f/-F …]` and `repo view`.
  - **GET:** prints `$FAKE_GH_DIR/<endpoint with / → __>.json`. If a sibling `.err` file exists, prints its contents to stderr and exits 1. A missing fixture prints `gh: Not Found (HTTP 404)` and exits 1.
  - **Writes:** appends `METHOD endpoint` plus the body to `$FAKE_GH_DIR/calls.log` and prints `{}`.

- [ ] **Step 1: Write `tests/repo-settings.test.sh`.** Use fixtures where live has `allow_auto_merge=false` and `delete_branch_on_merge=false`:

```bash
test_audit_reports_diffs        # exit 1; output has "DIFF\trepo.allow_auto_merge\tlive=false\tdesired=true"
test_audit_clean                # fixture matching desired -> exit 0, no DIFF lines
test_declined_not_reported      # declined repo.allow_auto_merge -> no DIFF line for it
test_apply_named_item           # apply repo.allow_auto_merge -> calls.log has "PATCH repos/o/r", APPLIED line
test_apply_dry_run              # --dry-run --all -> WOULD lines, calls.log empty
test_secret_scanning_unavailable  # PATCH .err "(HTTP 422)" -> UNAVAILABLE line, exit 3
test_missing_settings_dir       # --dir nope -> exit 2, stderr names the dir
```

- [ ] **Step 2: Run** `bash tests/repo-settings.test.sh`. Expected: fails.
- [ ] **Step 3: Implement the fake `gh`, `repo-settings.sh` (repo and security areas), and the default `config/repo.json`.** Defaults:
  - squash only: `allow_squash_merge: true`, `allow_merge_commit: false`, `allow_rebase_merge: false`
  - `delete_branch_on_merge: true`, `allow_auto_merge: true`, `has_issues: true`, `has_wiki: false`
  - all four security values `"enabled"`
  - `declined: []`

  Structure the script as one function per area (`audit_repo`, `apply_repo`, …) and a dispatcher, so Tasks 6–7 add areas without touching existing ones.
- [ ] **Step 4: Run** the test and `shellcheck`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add repo-settings audit and apply for repo settings` + `Closes #<T5>`.

---

### Task 6: Labels area

**Files:**
- Modify: `skills/initialize-repo/templates/scripts/repo-settings.sh`
- Create: `skills/initialize-repo/config/labels.json`, `tests/labels.test.sh`, fixtures

**Interfaces:**
- Consumes: the dispatcher, the fake `gh`, and the output and exit conventions from T5.
- Produces:
  - **`labels.json` shape:** `{"labels": [{"name", "color", "description"}], "declined": [...]}`.
  - **Item ids:** `labels.<name>`, with spaces kept.
  - **audit:** reports missing labels or a color/description mismatch. It never reports live labels that aren't in the file (extras are left alone).
  - **apply:** a missing label → `POST repos/{r}/labels`; a mismatch → `PATCH repos/{r}/labels/<url-encoded name>`. Labels are never deleted.

- [ ] **Step 1: Write `tests/labels.test.sh`:**

```bash
test_missing_task_label         # live lacks "task" -> "DIFF\tlabels.task\tlive=missing\tdesired=present"
test_extra_live_label_ignored   # live has "wontfix" not in file -> no line for it
test_labels_apply_idempotent    # apply --all twice against a live fixture that already has "task" -> no POST in calls.log
test_label_with_space           # "good first issue" color diff -> PATCH .../labels/good%20first%20issue
```

- [ ] **Step 2: Run** it. Expected: fails.
- [ ] **Step 3: Implement** the labels area. `config/labels.json` lists GitHub's nine default labels with their default colors, plus `{"name":"task","color":"1D76DB","description":"A specific piece of work"}`.
- [ ] **Step 4: Run** `bash tests/run-all.sh` and `shellcheck`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add labels area to repo-settings` + `Closes #<T6>`.

---

### Task 7: Ruleset area, check guard, and existing-protection notes

**Files:**
- Modify: `skills/initialize-repo/templates/scripts/repo-settings.sh`
- Create: `skills/initialize-repo/config/ruleset-default-branch.json`, `tests/ruleset.test.sh`, fixtures

**Interfaces:**
- Consumes: T5 conventions.
- Produces:
  - **`ruleset-default-branch.json`:** a ruleset request body, named `default-branch`, with an optional top-level `"declined"`, which is stripped before sending.
  - **Item id:** `ruleset.default-branch`.
  - **audit:**
    - Finds the live ruleset by name via `GET repos/{r}/rulesets` and then `GET repos/{r}/rulesets/<id>`.
    - Normalizes both sides to `{enforcement, conditions, bypass_actors, rules (sorted by type)}` with `jq -S`.
    - Prints `DIFF<TAB>ruleset.default-branch<TAB>live=<missing|differs><TAB>desired=present`, followed by a unified diff of the normalized JSON with each line prefixed `  `.
    - Prints `NOTE<TAB>other ruleset targets default branch: <name>` for other rulesets whose include list has `~DEFAULT_BRANCH`.
    - Prints `NOTE<TAB>classic branch protection is enabled on <branch>` when `GET repos/{r}/branches/<default>/protection` succeeds.
  - **apply:**
    - **Guard first.** For every context in the `required_status_checks` rule, the context must appear in `GET repos/{r}/commits/<default>/check-runs` (any status) or in the check runs of the most recently merged PR's head SHA. If any context is unseen, print `BLOCKED<TAB>ruleset.default-branch<TAB>required check <ctx> has not run on <branch> yet; merge the setup PR and re-run`, and exit 4.
    - `--allow-unseen-checks` skips the guard.
    - With no live ruleset → `POST repos/{r}/rulesets`; otherwise → `PUT repos/{r}/rulesets/<id>`. Both use `--input`.
    - 403/422 → `UNAVAILABLE`, as in T5.
- **Default body:**
  - `target: branch`, `enforcement: active`, `conditions.ref_name.include: ["~DEFAULT_BRANCH"]`
  - rules:
    - `pull_request` with `required_approving_review_count: 0`
    - `required_status_checks` with `[{"context":"ci-ok"}]` and `strict_required_status_checks_policy: false`
    - `non_fast_forward`
    - `deletion`
  - `bypass_actors: [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]`
  - Before committing, verify field names against GitHub's current REST docs for repository rulesets (use Context7 or the docs).

- [ ] **Step 1: Write `tests/ruleset.test.sh`:**

```bash
test_ruleset_missing                   # no live ruleset -> DIFF live=missing, exit 1
test_ruleset_differs_shows_diff        # live has 1 approval -> DIFF live=differs + diff lines containing required_approving_review_count
test_apply_ruleset_creates             # check-runs fixture has ci-ok -> POST repos/o/r/rulesets
test_apply_ruleset_updates_existing    # live ruleset id 42 exists -> PUT repos/o/r/rulesets/42, no POST
test_guard_blocks_unseen_check         # check-runs lacks ci-ok -> BLOCKED line, exit 4, calls.log empty
test_guard_override                    # --allow-unseen-checks -> POST happens
test_private_free_plan_unavailable     # POST .err "Upgrade to GitHub Pro … (HTTP 403)" -> UNAVAILABLE, exit 3
test_classic_protection_note           # protection fixture present -> NOTE line
```

- [ ] **Step 2: Run** it. Expected: fails.
- [ ] **Step 3: Implement** the area and the default config.
- [ ] **Step 4: Run** `bash tests/run-all.sh` and `shellcheck`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add ruleset area with required-check guard` + `Closes #<T7>`.

---

### Task 8: `preflight.sh`

**Files:**
- Create: `skills/initialize-repo/scripts/preflight.sh`, `tests/preflight.test.sh`

**Interfaces:**
- Produces: `preflight.sh [DIR]` (default `.`) prints `key=value` lines and exits 0 when the skill can proceed, or 1 with `error=<message>` lines that name the fix.
  - **Keys:**
    - `git`, `gh`, `jq`: each `ok` or `missing`
    - `auth`: `ok` or `none`
    - `scopes`: comma-separated
    - `repo`: `OWNER/NAME` or `none`
    - `default_branch`
    - `situation`: `new` | `existing-first` | `configured`
    - `owner_type`: `User` | `Organization` | `unknown`
    - `issue_types`: `yes` | `no`
  - **Situation:**
    - `new`: no GitHub `origin` remote, or no commits
    - `existing-first`: a remote exists and `DIR/.github/settings/` doesn't
    - `configured`: otherwise. The agent then runs `repo-settings.sh audit`, which covers both "second run" and "re-audit".
  - **Required scopes:** `repo` and `workflow`. `workflow` is needed to push workflow files.
  - **Issue types:** checked via `gh api graphql` on `repository.issueTypes` (org repos only). `no` for user-owned repos.

- [ ] **Step 1: Write `tests/preflight.test.sh`** using temp git repos and the fake `gh`, with the `auth status` and `api user` fixtures extended:

```bash
test_new_empty_dir                # git init, no remote -> situation=new
test_existing_first               # remote github.com/o/r + 1 commit, no .github/settings -> situation=existing-first
test_configured                   # + .github/settings/repo.json -> situation=configured
test_missing_workflow_scope       # scopes lack workflow -> exit 1, error= mentions "gh auth refresh -s workflow"
test_gh_logged_out                # auth status fails -> auth=none, exit 1, error= mentions "gh auth login"
test_user_repo_no_issue_types     # owner_type=User -> issue_types=no
```

- [ ] **Step 2: Run** it. Expected: fails.
- [ ] **Step 3: Implement.** Detect `jq` and `git` with `command -v`. Parse scopes from `gh auth status` output.
- [ ] **Step 4: Run** `bash tests/run-all.sh` and `shellcheck`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add preflight checks and situation detection` + `Closes #<T8>`.

---

### Task 9: Content templates and GitHub workflow guidance

**Files:**
- Create:
  - `skills/initialize-repo/templates/{README,AGENTS,CLAUDE,CHANGELOG,CONTRIBUTING,SECURITY}.md` and `templates/.editorconfig`
  - `templates/.github/ISSUE_TEMPLATE/{bug,feature,task,config}.yml`, `templates/.github/pull_request_template.md`, `templates/.github/dependabot.yml`
  - `skills/initialize-repo/references/github-workflow.md`
  - `tests/smoke.test.sh`

**Interfaces:**
- Consumes: `render.sh` (T3).
- Produces: templates using only these placeholders: `PROJECT_NAME`, `DESCRIPTION`, `OWNER`, `REPO`, `DEFAULT_BRANCH`, `YEAR`, `COPYRIGHT_HOLDER`, `LICENSE_NAME`, `SECURITY_CONTACT`, `COMMIT_CONVENTION`, `STACK_COMMANDS`.
  - **`AGENTS.md`** contains these sections, verbatim headings:
    - `## GitHub workflow`: the full content of `references/github-workflow.md`, including the issue-type → label fallback
    - `## CI scope`: why there are no trigger path filters, what `ci-ok` / step-level gating are, how to edit `scripts/ci-scope.sh` patterns, and "do not replace this with `on: paths:`"
    - `## Repository settings`: `.github/settings/` is the source of truth; run `scripts/repo-settings.sh audit`
  - **`CLAUDE.md`** is exactly `@AGENTS.md` plus a newline.
  - **`CHANGELOG.md`** follows Keep a Changelog 1.1.0, with an empty `## [Unreleased]`.
  - **Issue forms:** `bug.yml`, `feature.yml`, and `task.yml` set `type:` (Bug/Feature/Task) *and* `labels:` (`bug`/`enhancement`/`task`), so both personal and org repos work. Verify the issue-form `type` key against GitHub docs.
  - **PR template:** includes a `Closes #` line and a checklist line for `CHANGELOG.md`.
  - **`dependabot.yml`:** has a `github-actions` ecosystem entry, plus a commented `# {{STACK_ECOSYSTEM}}` block for the agent to fill in.

- [ ] **Step 1: Write `tests/smoke.test.sh`.** Render every file under `templates/` except `ci/` and `scripts/` into a temp dir, with fixture values for all placeholders (use `DEFAULT_BRANCH=trunk` once). Then:

```bash
test_all_render_clean          # every render.sh call exits 0
test_yaml_valid                # yq e '.' succeeds on every rendered *.yml
test_claude_md_imports_agents  # rendered CLAUDE.md == "@AGENTS.md"
test_agents_sections           # AGENTS.md contains "## GitHub workflow", "## CI scope", "## Repository settings"
test_agents_has_type_fallback  # AGENTS.md contains "bug" "enhancement" "task" fallback sentence
test_no_personal_data          # grep -ri "soham\|patwardhan" templates/ references/ config/ -> no match
test_markdown_lint             # markdownlint-cli2 on rendered *.md exits 0 (SKIP if not installed)
```

- [ ] **Step 2: Run** it. Expected: fails.
- [ ] **Step 3: Write `references/github-workflow.md`** from the spec's "GitHub workflow guidance" section, phrased for any agent and any repo. Then write the templates.
- [ ] **Step 4: Run** `bash tests/run-all.sh`. Expected: pass. Add `markdownlint-cli2` to this repo's CI `tests` job.
- [ ] **Step 5: Commit**: `feat: add content and GitHub templates` + `Closes #<T9>`.

---

### Task 10: `SKILL.md` and remaining references

**Files:**
- Create: `skills/initialize-repo/SKILL.md`, `skills/initialize-repo/references/settings-baseline.md`, `skills/initialize-repo/references/ci-design.md`, `skills/initialize-repo/references/examples/step-gated.yml`, `tests/skill.test.sh`

**Interfaces:**
- Consumes: every script and template, with the interfaces from T2–T9.
- Produces:
  - **`SKILL.md` frontmatter:**
    - `name: initialize-repo`
    - a `description` of 1024 characters or fewer, starting "Use when", covering new-repo setup, existing-repo audits, CI scoping, and settings
  - **`SKILL.md` body:**
    - Follows the spec's nine workflow steps in order.
    - Every script path is written relative to the skill directory (`scripts/…`, `templates/…`), with one instruction near the top: "Resolve these paths from the directory containing this SKILL.md."
    - Step 7 says how to read `BLOCKED` (exit 4) and stop.
    - Step 5 gives the backtest command: `gh pr list --state merged --limit 10 --json number,files`, then `jq` per PR into `ci-scope.sh`.
  - **`ci-design.md`:** both gating modes with the reasoning from the spec's Origin section, plus a link to `examples/step-gated.yml`, a worked step-level example with a matrix job.
  - **`settings-baseline.md`:** what each `config/*.json` setting does and why, including the bypass choice and the free-private-plan limit.

- [ ] **Step 1: Write `tests/skill.test.sh`:**

```bash
test_frontmatter_name          # name == initialize-repo == parent dir name
test_description_length        # description non-empty, <= 1024 chars, starts "Use when"
test_referenced_paths_exist    # every `scripts/…`, `templates/…`, `references/…`, `config/…` path in SKILL.md exists under the skill dir
test_step_gated_example_lints  # actionlint references/examples/step-gated.yml exits 0 (SKIP if absent)
test_steps_in_order            # SKILL.md headings contain Preflight, Gather, Create or connect, Write files, CI in existing repos, Commit, Settings, Summary, Proof PR in that order
```

- [ ] **Step 2: Run** it. Expected: fails.
- [ ] **Step 3: Write the three docs and the example.** Use the superpowers:writing-skills skill for `SKILL.md` structure and description wording.
- [ ] **Step 4: Run** `bash tests/run-all.sh`. Expected: pass.
- [ ] **Step 5: Commit**: `feat: add SKILL.md and design references` + `Closes #<T10>`.

---

### Task 11: Packaging for the three install channels

**Files:**
- Create: `.claude-plugin/marketplace.json`, `.claude-plugin/plugin.json` (or wherever current docs put it), `skills/initialize-repo/examples/defaults.yaml`
- Modify: `tests/skill.test.sh` (add manifest checks)

**Interfaces:**
- Consumes: the skill folder (T10).
- Produces:
  - A Claude Code marketplace entry that installs the plugin containing `skills/initialize-repo`.
  - A layout that `npx skills add sohampatwardhan/initialize-repo-skill` discovers.
  - `examples/defaults.yaml`, listing every preferences key from the spec with a comment each and placeholder values only.

- [ ] **Step 1: Look up current docs via Context7** for the Claude Code plugin marketplace manifest format and for the `skills` CLI's discovery rules. Record the doc URLs in a comment in the PR description.
- [ ] **Step 2: Add tests:**

```bash
test_manifests_valid_json      # jq e . on both manifests
test_manifest_points_at_skill  # the plugin's skill path resolves to skills/initialize-repo/SKILL.md
test_defaults_example_keys     # defaults.yaml contains all 9 keys from the spec
```

  Add `claude plugin validate .` as a CI step only if the docs confirm such a command exists.
- [ ] **Step 3: Run** them. Expected: fail. **Step 4: Write the manifests and the example.** **Step 5: Run** `bash tests/run-all.sh`. Expected: pass.
- [ ] **Step 6: Local install check:** add this repo as a local marketplace in Claude Code and confirm `initialize-repo` appears in the skill list. Run `npx skills add . --list` (or the docs' equivalent) and confirm it is discovered.
- [ ] **Step 7: Commit**: `feat: package skill for plugin marketplace and skills CLI` + `Closes #<T11>`.

---

### Task 12: Dogfood: initialize this repo with the skill

**Files:**
- Create via the skill:
  - `README.md` (with install steps for all three channels), `AGENTS.md`, `CLAUDE.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`, `.editorconfig`
  - `.github/ISSUE_TEMPLATE/*`, `.github/pull_request_template.md`, `.github/dependabot.yml`
  - `.github/settings/*.json`
  - `scripts/ci-scope.sh`, `scripts/ci-scope.test.sh`, `scripts/repo-settings.sh`
  - `tests/dogfood-sync.test.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the whole skill.
- Produces:
  - **This repo's `scripts/ci-scope.sh`:** `ALWAYS_LOGIC` also includes `'skills/*'` and `'tests/*'`.
  - **This repo's `ci.yml`:**
    - Gains the `scope` job.
    - The `shellcheck`, `actionlint`, and `tests` jobs are gated on `logic`.
    - A `ci-ok` job is added, and becomes the required check.

- This repo's licence is **MIT** (decided by the user). Copyright holder comes from the user's preferences or is asked for.

- [ ] **Step 1: Write `tests/dogfood-sync.test.sh`:**

```bash
test_repo_settings_in_sync     # scripts/repo-settings.sh identical to templates/scripts/repo-settings.sh
test_ci_scope_in_sync          # ci-scope.sh identical to template outside BEGIN/END SCOPE PATTERNS block
test_ci_scope_test_in_sync     # scripts/ci-scope.test.sh identical to template
```

- [ ] **Step 2: Run the skill on this repo** by following `SKILL.md` as written: preflight, then `situation=configured` or `existing-first`. Note every step where `SKILL.md` was unclear, and fix `SKILL.md` in the same task.
- [ ] **Step 3: Run** `bash tests/run-all.sh`, `actionlint`, and `shellcheck`. Expected: pass.
- [ ] **Step 4: Run** `scripts/repo-settings.sh audit` and show the output to the user. **Apply only the items they approve.** Expect `ruleset.default-branch` to be `BLOCKED` until `ci-ok` has run on `main`. That's correct, and it is applied after the PR merges.
- [ ] **Step 5: Commit**: `chore: initialize this repository with the skill` + `Closes #<T12>`.
- [ ] **Step 6: Open the `feat/v1` PR** with every `Closes #N` in the body. After the user merges it, re-run `repo-settings.sh apply ruleset.default-branch`, then offer the proof PR (a one-line docs change that should show `ci-ok` green with the heavy jobs skipped).
