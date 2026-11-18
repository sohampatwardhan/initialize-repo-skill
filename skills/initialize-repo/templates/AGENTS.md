# {{PROJECT_NAME}}

{{DESCRIPTION}}

This file is the working guide for agents and developers. `CLAUDE.md` imports it.

## Commands

```text
{{STACK_COMMANDS}}
```

## Conventions

- Commit messages follow {{COMMIT_CONVENTION}}.
- Work on a branch and open a pull request into `{{DEFAULT_BRANCH}}`. Never push to `{{DEFAULT_BRANCH}}` directly.
- Add a line under `## [Unreleased]` in `CHANGELOG.md` for every user-visible change.
- Pin third-party GitHub Actions to a full commit SHA with a version comment.

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
- The `scope` job in `.github/workflows/ci.yml` runs it. Heavy jobs (`lint`, `test`) are gated on its output, and `checks` always runs.
- `ci-ok` is the only required check. It depends on every other job, fails if any failed or was cancelled, and treats skipped jobs as success. Skipped jobs and matrix expansion therefore never leave a required check pending.
- To change what counts as non-logic, edit the `NON_LOGIC` and `ALWAYS_LOGIC` arrays between `# BEGIN SCOPE PATTERNS` and `# END SCOPE PATTERNS` in `scripts/ci-scope.sh`, then update and run `scripts/ci-scope.test.sh`. Add a glob to `NON_LOGIC` to let matching files skip heavy jobs. Add a path to `ALWAYS_LOGIC` to force CI for it, which wins over `NON_LOGIC`; use this for markdown that a check reads (for example `CHANGELOG.md` when release tooling parses it, by uncommenting its line in `ALWAYS_LOGIC`).
- Workflow files and everything under `scripts/` are always logic.

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
- If apply reports `BLOCKED` (exit 4), the ruleset requires a check that has not run on `{{DEFAULT_BRANCH}}` yet. Merge the pull request that adds it and run again.
