# Settings baseline

What each default in `config/*.json` does, and why it is the default. These files seed the generated repo's `.github/settings/`. From then on the repo's copies are the desired state, and the repo's own `./scripts/repo-settings.sh` (copied from the skill's `templates/scripts/`) compares them with live GitHub and applies only the items a person approves.

## Item ids

Every setting is one item. `audit` prints item ids, and `apply` takes them:

| Item id | File | Written with |
| --- | --- | --- |
| `repo.<key>` | `repo.json`, under `repo` | `PATCH repos/{owner}/{repo}` |
| `security.<key>` | `repo.json`, under `security` | `PUT`/`DELETE` on the Dependabot endpoints, or `PATCH repos/{owner}/{repo}` for secret scanning |
| `labels.<name>` | `labels.json` | `POST` (missing) or `PATCH` (different) on the label |
| `ruleset.default-branch` | `ruleset-default-branch.json` | `POST` (missing) or `PUT` (different) on the ruleset |

Label names can contain spaces (`labels.good first issue`). Quote such ids on the command line.

## `repo.json`: merging and features

| Key | Default | Why |
| --- | --- | --- |
| `allow_squash_merge` | `true` | One commit per pull request keeps the default branch readable. The `merge_style` preference changes which of the three merge keys is `true`. |
| `allow_merge_commit` | `false` | Off when squash is the merge style. |
| `allow_rebase_merge` | `false` | Off when squash is the merge style. |
| `delete_branch_on_merge` | `true` | Merged branches are removed, so stale branches do not pile up. |
| `allow_auto_merge` | `true` | A pull request can be set to merge once its required checks pass. |
| `has_issues` | `true` | The GitHub workflow guidance relies on issues. |
| `has_wiki` | `false` | Docs live in the repo, where they are reviewed. For an existing repo whose wiki is on, ask before turning it off: it may be in use. If it is, set `has_wiki` to `true`. |

The Projects tab is not managed. It is left as it is.

`PATCH repos/{owner}/{repo}` returns 200 even when GitHub ignored a field. The script reads the response back, and a value that did not change is reported as `UNAVAILABLE`, never as `APPLIED`.

## `repo.json`: security

| Key | Default | Why |
| --- | --- | --- |
| `vulnerability_alerts` | `enabled` | Dependabot alerts for known vulnerable dependencies. |
| `automated_security_fixes` | `enabled` | Dependabot security update pull requests. Needs alerts on, so apply `security.vulnerability_alerts` first (name it first on the command line). |
| `secret_scanning` | `enabled` | Detects committed secrets. Free on public repos. On private repos it needs a paid add-on, so GitHub refuses it or ignores it, and the script reports `UNAVAILABLE`. |
| `secret_scanning_push_protection` | `enabled` | Blocks a push that contains a detected secret. Same availability as secret scanning. |

Values are `enabled` or `disabled`.

## `labels.json`

GitHub's default labels plus `task`. `task` is the label fallback for repos without issue types, alongside `bug` (Bug) and `enhancement` (Feature), and it is what `templates/.github/ISSUE_TEMPLATE/task.yml` applies. Dependabot creates `dependencies` itself when it first needs it.

The script creates missing labels and corrects a label's colour or description. It never deletes a label and ignores labels that are not in the file, so an existing repo keeps its own labels.

## `ruleset-default-branch.json`

The file is a repository ruleset request body, sent as is (minus `declined`).

| Part | Default | Why |
| --- | --- | --- |
| `name` | `default-branch` | The script finds the live ruleset by this name. |
| `target`, `conditions` | branch, `~DEFAULT_BRANCH` | Follows the default branch even if it is renamed. |
| `enforcement` | `active` | The rules are enforced, not just evaluated. |
| `pull_request` rule | required, 0 approvals | Every change reaches the default branch through a pull request. Approvals default to 0 because a solo developer cannot approve their own pull request; the `required_approvals` preference changes `required_approving_review_count`. Stale-review dismissal, code-owner review, last-push approval and thread resolution are off. |
| `required_status_checks` rule | `ci-ok` | New repos require only `ci-ok`, which always reports (see `ci-design.md`). Existing repos list their own required check names here instead. `strict_required_status_checks_policy` is `false`, so a pull request does not have to be rebased on every new commit to the default branch. `do_not_enforce_on_create` is `false`. |
| `non_fast_forward` rule | on | No force-pushes to the default branch. |
| `deletion` rule | on | The default branch cannot be deleted. |
| `bypass_actors` | repository admin role (`actor_id` 5), `bypass_mode: pull_request` | See below. |

### The bypass choice

Admins can bypass the ruleset, but only when merging a pull request. An admin can merge a pull request without waiting for checks or approvals, which a solo maintainer sometimes needs. Nobody, admins included, can push straight to the default branch. `bypass_mode: always` would allow direct pushes and is not used.

### A PUT replaces the whole ruleset

When the ruleset already exists and differs, `apply` sends `PUT repos/{owner}/{repo}/rulesets/{id}` with the whole file. GitHub replaces the ruleset entirely: any rule or parameter that the file does not contain is removed or reset to GitHub's default. Audit compares only the parameters the file names, so such a parameter does not show up as a difference beforehand.

Before applying over a live ruleset, compare the file with `gh api repos/{owner}/{repo}/rulesets/{id}` and copy anything the repo should keep into the file first.

### Adopting an existing ruleset

Audit prints `NOTE other ruleset targets default branch: <name>` when another ruleset already covers the default branch. Do not add a second one. Either adopt it (set `name` in the file to its name and copy its rules, conditions and bypass actors into the file, then change only what the user approves), or decline `ruleset.default-branch`.

### Classic branch protection

Audit prints `NOTE classic branch protection is enabled on <branch>` when the old-style protection is on. Report it and offer to migrate: put the same required checks in the ruleset file, apply the ruleset, and only after it is `APPLIED`, with the user's explicit approval, remove the classic protection with `gh api -X DELETE repos/{owner}/{repo}/branches/{branch}/protection`. If the user does not want to migrate, decline `ruleset.default-branch`.

### The required-check guard

A ruleset that requires a check before that check has ever run would leave every pull request stuck. Before writing the ruleset, `apply` looks for each required check name among the check runs and commit statuses on the default branch head, and on the head of the most recently merged pull request. If a name is missing, it prints `BLOCKED` and exits 4 without writing the ruleset. `--allow-unseen-checks` skips the guard; use it only when the user asks, after confirming that the check really reports on pull requests.

## Plan limits

- **Rulesets** are not available on private repos owned by a free personal account. Audit prints `NOTE ruleset.default-branch rulesets are not available on this plan` instead of a difference, and an apply is refused and reported as `UNAVAILABLE`. Making the repo public or upgrading the plan lifts the limit.
- **Secret scanning and push protection** on private repos need a paid add-on.
- **Issue types** exist only on some repos. The skill checks per repo (preflight's `issue_types`), never from the owner type, and falls back to the `bug` / `enhancement` / `task` labels.

`UNAVAILABLE` covers both an HTTP 403/422 refusal and a 200 response that left the value unchanged. Report it as not applied, with the reason the script printed. Never count it as a success.

## Declining an item

Each file can carry a `declined` list. A declined item is skipped by `audit` and `apply` and is not proposed again:

```json
"declined": [
  { "item": "repo.has_wiki", "reason": "the wiki holds the user guide" }
]
```

Put the entry in the file that defines the item: `repo.*` and `security.*` in `repo.json`, `labels.*` in `labels.json`, `ruleset.*` in `ruleset-default-branch.json`.
