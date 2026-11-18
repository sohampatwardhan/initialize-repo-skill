# initialize-repo-skill

Agent Skill that initializes GitHub repos for professional development workflows: standard files, logic-scoped CI, settings as code, and issue conventions.

This file is the working guide for agents and developers. `CLAUDE.md` imports it.

## Commands

```text
bash tests/run-all.sh
```

## Conventions

- Commit messages follow Conventional Commits.
- Work on a branch and open a pull request into `main`. Never push to `main` directly.
- Add a line under `## [Unreleased]` in `CHANGELOG.md` for every user-visible change.
- Pin third-party GitHub Actions to a full commit SHA with a version comment.

## This repo

This repo holds the `initialize-repo` skill (`skills/initialize-repo/`), its tests (`tests/`) and its plugin manifests (`.claude-plugin/`). It is also set up with the skill itself, so it looks like the skill's own output.

- Scripts must run on bash 3.2 (the macOS default): no associative arrays, no `mapfile` or `readarray`, no `${var,,}`, no `declare -n`, and no GNU-only flags (`sed -i`, `grep -P`, `readlink -f`, `date -d`). Runtime dependencies are `git`, `gh` and `jq` only.
- Scripts call `gh` as `"${GH:-gh}"`, so tests can substitute `tests/fake-gh/gh`.
- Run `bash tests/run-all.sh` before every commit. CI also runs `shellcheck` and `actionlint`.
- Nothing personal goes into `skills/initialize-repo/`: no author name, licence choice or owner. The repo's own `LICENSE` lives at the root only.
- The dogfood copies must stay in sync with the skill's templates, and `tests/dogfood-sync.test.sh` enforces it:
  - `scripts/repo-settings.sh` and `scripts/ci-scope.test.sh` are byte-identical to `skills/initialize-repo/templates/scripts/`. Change the template, then copy it.
  - `scripts/ci-scope.sh` is identical to the template outside the `# BEGIN SCOPE PATTERNS` / `# END SCOPE PATTERNS` block. Only the patterns inside the block may differ.
  - The `scope` step in `.github/workflows/ci.yml` runs the same script as the template's.

## GitHub workflow

Use everything GitHub lets you attach to an issue, not just the title and body. Fill each field wherever it genuinely fits.

### Fields to consider on every issue

- **Assignees:** assign the requesting user unless told otherwise.
- **Labels:** reuse the repo's existing labels. Do not create new ones unasked.
- **Type:** set exactly one where the repo offers issue types.
  - Task: a specific piece of work (chores, maintenance, refactors, CI, docs).
  - Bug: an unexpected problem or behavior.
  - Feature: a request, idea, or new functionality.
- **Projects and milestone:** use one only if it clearly belongs to this repo's work. A user-level project may be for something unrelated, so check first.
- **Relationships between issues:**
  - Parent and sub-issue: real containment, such as an epic and its parts.
  - Blocked by and blocking: real ordering, where one issue cannot finish before another.
  - Relates to: issues that touch the same area without either of those. This is the default when unsure.
- **Development:** link the pull requests that address the issue, using a closing keyword in the PR body (`Closes #N`).
- **Security alert:** link the relevant alert when the issue is about a vulnerability, if the repo has alerts enabled.

### How to apply

- Read the repo's other open issues and their bodies before linking, so relationships reflect reality rather than guesses.
- Never invent a milestone, parent, or link just to fill a field. A missing relationship is better than a false one.
- Say which fields you set and which you left empty, with a short reason for each.
- Do not change repo settings (for example enabling Dependabot alerts) just to fill a field. Ask first.
- Use `gh` and its GraphQL API (`gh api graphql`) for what the CLI flags do not cover, such as issue types and relationships.

### Repos without issue types

Issue types are not available on every repo. Detect support per repo with GraphQL (`repository.issueTypes`); never infer it from the owner type. Where a repo has no issue types, mark the kind of work with the `bug`, `enhancement` or `task` label instead.

## CI scope

CI runs on every pull request, but heavy checks (lint, tests, builds) run only when a change can affect how the program runs. Documentation-only changes finish quickly and still report success.

- `scripts/ci-scope.sh` reads the changed file paths and prints `logic` or `non-logic`. A path is non-logic only if it matches a non-logic pattern and no always-logic pattern. A path that matches neither is logic, so anything unlisted runs CI.
- The `scope` job in `.github/workflows/ci.yml` runs it. The heavy jobs (`shellcheck`, `actionlint`, `tests`) are gated on its output. `scope` and `ci-ok` always run.
- `ci-ok` is the only required check. It depends on every other job, fails if any failed or was cancelled, and treats skipped jobs as success. Skipped jobs and matrix expansion therefore never leave a required check pending.
- To change what counts as non-logic, edit the `NON_LOGIC` and `ALWAYS_LOGIC` arrays between `# BEGIN SCOPE PATTERNS` and `# END SCOPE PATTERNS` in `scripts/ci-scope.sh`, then add a case for the change to `tests/dogfood-sync.test.sh` (`scripts/ci-scope.test.sh` must stay identical to the template; see below) and run `bash tests/run-all.sh`. Add a glob to `NON_LOGIC` to let matching files skip heavy jobs. Add a path to `ALWAYS_LOGIC` to force CI for it, which wins over `NON_LOGIC`; use this for markdown that a check reads (for example `CHANGELOG.md` when release tooling parses it, by uncommenting its line in `ALWAYS_LOGIC`).
- Workflow files and everything under `scripts/`, `skills/`, `tests/` and `.claude-plugin/` are always logic: the skill's markdown is the product.

Why there is no trigger filter: a workflow-level `on: paths:` or `paths-ignore:` means the workflow never starts for a docs-only change, so a required check never reports and the pull request is stuck on "pending" forever. A job-level `if:` on a matrix job has the same failure. Keep the design: do not replace this with `on: paths:`, and do not make individual stack jobs required.

## Repository settings

`.github/settings/` is the source of truth for this repo's settings:

- `repo.json`: merge options, features, security settings.
- `ruleset-default-branch.json`: the `default-branch` ruleset (pull request required, `ci-ok` required, no force-push or deletion).
- `labels.json`: the label set.

Each file may carry a `declined` list of items deliberately not adopted, with a reason; audit skips them.

- Run `scripts/repo-settings.sh audit` to compare live GitHub with these files. It exits non-zero when they differ.
- Run `scripts/repo-settings.sh apply --dry-run <item>...` to preview, then `apply <item>...` (or `--all`) to change GitHub. Apply only what a maintainer approved.
- Change settings by editing the JSON in a pull request, then apply. Do not change them by hand in the web UI without updating the files.
- If apply reports `BLOCKED` (exit 4), the ruleset requires a check that has not run on `main` yet. Merge the pull request that adds it and run again.
