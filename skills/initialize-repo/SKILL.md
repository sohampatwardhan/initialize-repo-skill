---
name: initialize-repo
description: Use when creating a new GitHub repository, or bringing an existing one up to a professional baseline - README, AGENTS.md, LICENSE, CONTRIBUTING, SECURITY, issue and pull request templates, Dependabot, a CI workflow - or when a docs-only pull request is stuck waiting on required checks or heavy CI, or when merge options, branch rulesets, required checks, labels or security settings should be kept as reviewable code under .github/settings and audited for drift against live GitHub.
---

# Initialize a GitHub repo

## Overview

Set a GitHub repo up for a professional workflow: standard files, CI that skips heavy work on non-logic changes while required checks still report, and repo settings kept as committed JSON under `.github/settings/`.

You do the judgment work: answers, file content, merging into existing files, stack detection. Scripts do the mechanical, risky GitHub writes from declarative JSON. Use the scripts; do not improvise settings changes with ad hoc `gh api` writes.

## Paths

Resolve these paths from the directory containing this SKILL.md. In this file:

- **Skill paths** are written relative to the skill directory: `scripts/preflight.sh`, `scripts/render.sh`, `templates/`, `config/`, `references/`. In commands they appear as `"$SKILL/..."`, where `SKILL` is the absolute path of the skill directory. Set it in each shell you open, or substitute the path.
- **Repo paths** are in the repo being set up and are written from its root: `.github/...`, `./scripts/repo-settings.sh`, `./scripts/ci-scope.sh`. Run every command from the repo root.

Commands are plain POSIX shell with `git`, `gh` and `jq`. On Windows use Git Bash. Write `gh api` endpoints without a leading slash (`gh api licenses/mit`): Git Bash rewrites a leading `/` into a Windows path.

## Rules that always hold

- Never overwrite an existing file, label, template, workflow or setting without showing the change and getting a yes.
- Never change a repo setting without showing the audit and getting explicit approval of the items. Settings affect everyone on the repo.
- Never report something GitHub refused or ignored (`UNAVAILABLE`, `FAILED`, `BLOCKED`) as done.
- Never merge the setup pull request or the proof pull request. A human merges.
- Never add `on: paths:` or `paths-ignore:` to a workflow trigger. In step-level gating (existing repos with named required checks), the only job-level condition allowed on a gated job is `if: ${{ !cancelled() }}`. The new-repo template's job-level `if: needs.scope.outputs.logic == 'true'` on `lint` and `test` is correct as it is, because `ci-ok` is the only required check there. See `references/ci-design.md`.
- Never propose a declined item again. Declined items live in the settings files' `declined` lists.

## Preferences file

Optional, at `~/.config/initialize-repo/defaults.yaml`. Read it yourself (the scripts never do). It holds flat `key: value` lines; every key is optional, and a missing key is asked for in step 2.

See `examples/defaults.yaml` for every key with a comment and placeholder values; the user copies it to that location and edits it.

## Workflow

### 1. Preflight

Run from the repo directory. For a new repo, create its directory first and run from there:

```bash
bash "$SKILL/scripts/preflight.sh" .
```

It prints `key=value` lines: `git`, `gh`, `jq`, `auth`, `scopes`, `repo` (`OWNER/NAME` or `none`), `default_branch`, `situation`, `owner_type`, `issue_types` (`yes` or `no`), plus optional `warning=` lines and, on failure, `error=` lines.

- Exit 1: show every `error=` line to the user as written (each names its fix, such as `gh auth login` or `gh auth refresh -s workflow`) and stop.
- `warning=`: tell the user and continue.
- Keep `repo`, `default_branch`, `owner_type` and `issue_types` for later steps.

Then read the preferences file and act on `situation`:

| `situation` | Meaning | Next |
| --- | --- | --- |
| `new` | No GitHub remote, or no commits yet | Steps 2 to 9. |
| `existing-first` | A GitHub repo with history, no `.github/settings/` | Steps 2 to 9, through a setup pull request. |
| `configured` | `.github/settings/` exists | Second run or re-audit, below. |

For `configured`, check the setup pull request: `gh pr list --head chore/initialize-repo --state all --json number,state,url`.

- `OPEN`: the first run is not merged yet. Tell the user to merge it (give the URL) and run the skill again, then stop.
- `CLOSED` without a merge: ask the user whether to start over (delete `.github/settings/` locally and treat the repo as `existing-first`) or stop.
- `MERGED`, or no such pull request: if the working tree is clean, switch to the default branch and update it (`git switch <default_branch>`, then `git pull --ff-only`), so the settings files and scripts are the merged ones; otherwise ask first. Go to step 7, then steps 8 and 9.

### 2. Gather

Ask only what the preferences file and the repo don't answer, in one message:

| Ask | When | Used for |
| --- | --- | --- |
| Name | new (suggest the directory name) | `gh repo create`, `PROJECT_NAME`, `REPO` |
| One-line description | always (existing: suggest the GitHub description) | `DESCRIPTION`, `gh repo create --description` |
| Owner, visibility | new only, unless `default_owner` / `default_visibility` | `gh repo create`, `OWNER` |
| Topics (optional) | new only | `gh repo edit --add-topic` |
| Licence | always, unless `license` is set | `LICENSE`, `LICENSE_NAME` |
| Copyright holder | when a licence is chosen, unless `copyright_holder` or `author_name` | `LICENSE` |
| Stack | new: ask; existing: detect and confirm | CI snippet, `.gitignore`, `STACK_COMMANDS`, Dependabot |
| Merge style, required approvals | unless `merge_style` / `required_approvals` (defaults: squash only, 0) | `.github/settings/` |
| Security contact (an email address) | unless the repo already has `SECURITY.md` | `SECURITY_CONTACT` |

- Licence: offer the keys from `gh api licenses | jq -r '.[] | "\(.key)\t\(.name)"'`, plus "no licence". Always ask unless the preference is set; never pick one for the user.
- Stack detection for existing repos: `package.json` means Node, `pyproject.toml` (or `requirements.txt`) Python, `go.mod` Go, `Cargo.toml` Rust. Anything else, or nothing yet, means `placeholder`.
- Visibility: rulesets are not available on private repos whose owner (a personal account or an organisation) is on GitHub Free. The token preflight requires usually can't read the plan (`gh api user` returns `"plan": null` without the `user` scope), so don't try to decide it up front. If the repo will be private, tell the user the default-branch ruleset may not be available on their plan. The authoritative signal comes in step 7: audit's `NOTE ... rulesets are not available on this plan` line, or `UNAVAILABLE` from apply.
- Commit convention: `commit_convention`, default `Conventional Commits`.

### 3. Create or connect

New repo:

1. If the directory is not a git repo yet, run `git init -b main` (or the branch the user wants). That branch is `DEFAULT_BRANCH`.
2. If `repo=none`, create it: `gh repo create OWNER/NAME --private --description "..." --source . --remote origin` (or `--public` / `--internal`). Add topics with `gh repo edit OWNER/NAME --add-topic topic1,topic2`.
3. If `repo` names an existing empty GitHub repo, confirm that it is the right one and use its `default_branch`.

Existing repo:

1. Confirm `repo=OWNER/NAME` with the user. If they meant a repo that is not cloned, clone it with `gh repo clone OWNER/NAME` and start again in that directory.
2. Check `git status --porcelain` is empty. If not, ask the user to commit or stash first.
3. Update the default branch and branch off it: `git switch <default_branch>`, `git pull --ff-only`, `git switch -c chore/initialize-repo`. If that branch already exists, ask whether to reuse it or start over.

### 4. Write files

Render into a temporary directory first, then move each file into the repo. A file that does not exist yet is added. A file that already exists is never replaced: show the difference (`git diff --no-index <existing> <rendered>`) and ask whether to keep it, replace it, or merge the missing parts in. For an existing `AGENTS.md`, offer to append the sections it lacks (GitHub workflow, CI scope, Repository settings). For an existing `CLAUDE.md`, offer to add an `@AGENTS.md` line.

| Repo file | Source |
| --- | --- |
| `README.md`, `AGENTS.md`, `CLAUDE.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `.editorconfig` | `templates/` (same name), rendered |
| `.github/ISSUE_TEMPLATE/*.yml`, `.github/pull_request_template.md` | `templates/.github/`, rendered |
| `.github/dependabot.yml` | `templates/.github/dependabot.yml`, rendered with `--insert STACK_ECOSYSTEM=<file>` |
| `.github/workflows/ci.yml` | new repos: `templates/.github/workflows/ci.yml`, rendered with `--insert STACK_JOBS=templates/ci/<stack>.yml`; existing repos: step 5 |
| `./scripts/repo-settings.sh`, `./scripts/ci-scope.sh`, `./scripts/ci-scope.test.sh` | `templates/scripts/`, copied unchanged |
| `LICENSE` | `gh api licenses/<key>` |
| `.gitignore` | `gh api gitignore/templates/<Lang>` |
| `.github/settings/*.json` | `config/`, copied and adjusted |

**Render** the content templates (everything in `templates/` except `templates/ci/`, `templates/scripts/` and `templates/.github/workflows/`) into a temporary directory, passing every value; keys a template doesn't use are ignored. Run it as one shell command, with `SKILL` and the answer variables (`NAME`, `DESCRIPTION`, `OWNER`, `BRANCH`, `HOLDER`, `LICENSE_NAME`, `CONTACT`, `CONVENTION`, `STACK_COMMANDS`) set in the same shell. For an existing repo, `OWNER` and `NAME` come from `repo=`. A value for a file the repo keeps its own copy of (say `SECURITY_CONTACT` when `SECURITY.md` stays) can be any text; that rendered file is discarded.

```bash
TMP="$(mktemp -d)"
: > "$TMP/ecosystem.yml"   # then write the stack's Dependabot entry into it, if any
(cd "$SKILL/templates" && find . -type f ! -path './ci/*' ! -path './scripts/*' ! -path './.github/workflows/*') |
  while IFS= read -r rel; do
    bash "$SKILL/scripts/render.sh" "$SKILL/templates/$rel" "$TMP/out/$rel" \
      PROJECT_NAME="$NAME" DESCRIPTION="$DESCRIPTION" OWNER="$OWNER" REPO="$NAME" \
      DEFAULT_BRANCH="$BRANCH" YEAR="$(date +%Y)" COPYRIGHT_HOLDER="$HOLDER" \
      LICENSE_NAME="$LICENSE_NAME" SECURITY_CONTACT="$CONTACT" \
      COMMIT_CONVENTION="$CONVENTION" STACK_COMMANDS="$STACK_COMMANDS" \
      --insert STACK_ECOSYSTEM="$TMP/ecosystem.yml" || echo "render failed: $rel"
  done
```

For a new repo (or an existing one with no workflows), render the CI workflow with the stack's snippet (`node.yml` here; pick from the table below):

```bash
bash "$SKILL/scripts/render.sh" "$SKILL/templates/.github/workflows/ci.yml" "$TMP/out/.github/workflows/ci.yml" \
  DEFAULT_BRANCH="$BRANCH" --insert STACK_JOBS="$SKILL/templates/ci/node.yml"
```

`render.sh` exits 1 (output still written) when a `{{PLACEHOLDER}}` is left, and 2 on bad usage. Fix the cause and render again. `LICENSE_NAME` is the licence's `spdx_id` (`MIT`, `Apache-2.0`). With no licence, remove the README's licence section instead. `STACK_COMMANDS` and the Dependabot entry come from this table (the entry is a YAML list item, written to a file for `--insert`; for `placeholder` use an empty file):

| Stack | `STACK_COMMANDS` | Dependabot `package-ecosystem` | `.gitignore` template | CI snippet |
| --- | --- | --- | --- | --- |
| Python | `uv sync`, `uvx ruff check .`, `uv run pytest` | `uv` (or `pip` without `uv.lock`) | `Python` | `templates/ci/python.yml` |
| Node | `npm ci`, `npm run lint --if-present`, `npm test` | `npm` | `Node` | `templates/ci/node.yml` |
| Go | `go vet ./...`, `go test ./...` | `gomod` | `Go` | `templates/ci/go.yml` |
| Rust | `cargo clippy --all-targets -- -D warnings`, `cargo test` | `cargo` | `Rust` | `templates/ci/rust.yml` |
| placeholder | a line saying build and test commands are still to come | none | ask, or skip | `templates/ci/placeholder.yml` |

Put one command per line in `STACK_COMMANDS`. A Dependabot entry looks like:

```yaml
- package-ecosystem: npm
  directory: /
  schedule:
    interval: weekly
```

**Check the stack snippet's prerequisites** before using it. If one is missing, use `templates/ci/placeholder.yml` instead and say so in the summary:

- Node: `package.json` with a real `test` script, and `package-lock.json` (`npm ci` fails without it).
- Python: `pyproject.toml` with pytest as a dev dependency and at least one test (pytest exits 5 when it collects none).
- Go: `go.mod`.
- Rust: `Cargo.toml`. The snippet uses the runner's preinstalled toolchain; add `rust-toolchain.toml` to pin one.

**Issue forms:** if `issue_types=no`, delete the top-level `type:` line (`type: Bug`, `type: Feature`, `type: Task`) from each rendered `$TMP/out/.github/ISSUE_TEMPLATE/*.yml`. Keep the `- type: textarea` lines under `body:`. The forms' labels (`bug`, `enhancement`, `task`) mark the kind of issue instead.

**LICENSE and .gitignore** are staged in `$TMP/out/` like the rendered files, then moved into the repo by the same add-or-ask rule. An existing `LICENSE` is kept unless the user asks to replace it; take `LICENSE_NAME` from `gh api repos/OWNER/NAME | jq -r '.license.spdx_id'`. For an existing `.gitignore`, show the lines the staged one would add and ask before appending them.

Fill the licence's copyright-line tokens (MIT and BSD use `[year]` and `[fullname]`), and leave "how to apply" appendices (Apache, GPL) as they are:

```bash
gh api licenses/mit | jq -r --arg y "$(date +%Y)" --arg n "$HOLDER" \
  '.body | gsub("\\[year\\]"; $y) | gsub("\\[fullname\\]"; $n)' > "$TMP/out/LICENSE"
gh api gitignore/templates/Node | jq -r '.source' > "$TMP/out/.gitignore"
```

**Settings:** copy the defaults, then adjust them to the answers with `jq` (write to a temporary file and move it back; there is no in-place edit):

```bash
mkdir -p .github/settings
cp "$SKILL/config/repo.json" "$SKILL/config/labels.json" "$SKILL/config/ruleset-default-branch.json" .github/settings/
f=.github/settings/ruleset-default-branch.json
jq --argjson n 1 '.rules |= map(if .type == "pull_request" then .parameters.required_approving_review_count = $n else . end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
```

- Merge style: set the chosen `allow_*_merge` key in `repo.json` to `true` and the other two to `false`.
- Existing repo whose wiki is on: ask whether it is in use; if so set `repo.has_wiki` to `true`.
- Existing repo with required checks: in `ruleset-default-branch.json`, replace the `ci-ok` entry with the repo's current required check names (step 5, item 1, shows how to find them).
- Anything the user does not want goes in that file's `declined` list with a reason, as `{"item": "<item id>", "reason": "..."}`. `references/settings-baseline.md` explains every setting and which file each item belongs to.

For an existing repo, now run `bash ./scripts/repo-settings.sh audit` once (read-only). Its `NOTE` lines show another ruleset on the default branch or classic branch protection. Settle those now, as `references/settings-baseline.md` describes, before the files are committed.

**Final check:** no placeholder remains in any file you wrote: `grep -rnE '\{\{[A-Z0-9_]+\}\}' <files>` prints nothing. (GitHub Actions `${{ ... }}` expressions are not placeholders.)

### 5. CI in existing repos

Skip this step for new repos.

1. Find the required checks:
   - Rulesets: `gh api repos/OWNER/NAME/rules/branches/<default_branch> | jq -r '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context'`
   - Classic protection: `gh api repos/OWNER/NAME/branches/<default_branch>/protection | jq -r '.required_status_checks.contexts[]?'` (HTTP 404 means none).
2. No workflows under `.github/workflows/`: treat CI as for a new repo (template `ci.yml` plus a snippet, `ci-ok` required).
3. Workflows exist: adapt them in place with step-level gating. Read `references/ci-design.md` and follow `references/examples/step-gated.yml`: add a `scope` job to each workflow that holds a required check, add `scope` to each heavy job's `needs:`, give each such job the job-level `if: ${{ !cancelled() }}`, make its first step the guard that fails the job when `needs.scope.result != 'success'`, and give every heavy step after it `if: needs.scope.outputs.logic == 'true'`. Jobs keep running and keep their names, and a failed `scope` job fails them instead of skipping them (a skipped required check counts as passing). In step-level gating, the only job-level condition allowed on a gated job is `if: ${{ !cancelled() }}`. Never add a parallel `ci-ok` gate or a second ruleset. If nothing is required yet, ask which existing check names to require, or remove the `required_status_checks` rule from the ruleset file.
4. Rewrite what the templates say about `ci-ok` to match: the CI scope and Repository settings sections of `AGENTS.md`, and the `ci-ok` item in the Workflow list of `CONTRIBUTING.md`, should name the repo's required checks and describe step-level gating.
5. Look for markdown that checks read (see `references/ci-design.md`) and add it to `ALWAYS_LOGIC` in `./scripts/ci-scope.sh`, with a test case in `./scripts/ci-scope.test.sh`. Run `bash ./scripts/ci-scope.test.sh`.
6. Backtest before turning the skip on. Run the scope script on the file lists of the last 10 merged pull requests (`gh pr list --state merged --limit 10 --json number,files`, then `jq` per pull request into `./scripts/ci-scope.sh`):

   ```bash
   gh pr list --state merged --limit 10 --json number,files | jq -c '.[]' |
     while IFS= read -r pr; do
       n="$(printf '%s' "$pr" | jq -r '.number')"
       kind="$(printf '%s' "$pr" | jq -r '.files[].path' | bash ./scripts/ci-scope.sh)"
       printf '#%s\t%s\n' "$n" "$kind"
     done
   ```

   Show the user which pull requests would have skipped heavy CI (`non-logic`). If one of them changed something a check reads, fix the patterns and run it again. Put the table in the setup pull request's body.
7. If `actionlint` is installed, run it on each changed workflow.

### 6. Commit

Commit messages follow the chosen commit convention.

New repo: commit everything to the default branch and push it, before any ruleset is applied. Check `git status` first, and ask before committing files you did not write (a local `.env`, build output):

```bash
git add -A
git commit -m "chore: initialize repository"
git push -u origin <default_branch>
```

Then wait for the first CI run on the default branch, so `ci-ok` has reported before step 7. The run can take a few seconds to appear; repeat the list until it does:

```bash
gh run list --workflow ci.yml --branch <default_branch> --commit "$(git rev-parse HEAD)" --limit 1 --json databaseId,status,conclusion
gh run watch <databaseId> --exit-status
```

If the run fails, fix it now (often missing scaffolding; switch to the placeholder snippet if needed), push, and wait again.

Existing repo: commit on `chore/initialize-repo`, push, and open the setup pull request. Add only the files you wrote, not unrelated changes:

```bash
git add <files written in steps 4 and 5>
git commit -m "chore: initialize repository"
git push -u origin chore/initialize-repo
gh pr create --base <default_branch> --head chore/initialize-repo \
  --title "chore: initialize repository" --body-file "$TMP/pr-body.md"
```

The body lists the files added and changed, the CI changes, the backtest table, the settings the user approved, and that the ruleset is applied after merge by running the skill again. Never merge this pull request.

### 7. Settings

Audit first:

```bash
bash ./scripts/repo-settings.sh audit
```

Exit 0 means nothing differs, 1 means differences, 2 means an error (show stderr and stop). Output lines are tab-separated:

- `DIFF  <item>  live=<now>  desired=<proposed>`, one per differing item. A ruleset diff is followed by indented unified-diff lines.
- `NOTE  ...`: rulesets not available on this plan, another ruleset on the default branch, or classic branch protection. Handle these as `references/settings-baseline.md` describes.

Show the user a table of item, current value and proposed value, and ask which items to apply. Treat silence as no. For each item the user rejects, ask for a short reason and add it to the right file's `declined` list, then commit the edit:

- New repo: commit and push to the default branch now, while the ruleset is not on yet, then wait for that commit's CI run as in step 6.
- Existing repo, first run: commit and push to `chore/initialize-repo`.
- `configured`: commit on a new branch and open a pull request for it. Never merge it.

When a ruleset already exists and differs, warn that applying replaces it entirely (see `references/settings-baseline.md`).

Apply only the approved items, by id. Quote ids with spaces, and name `security.vulnerability_alerts` before `security.automated_security_fixes`. Preview first with `--dry-run`, which prints `WOULD  METHOD endpoint` lines and calls nothing:

```bash
bash ./scripts/repo-settings.sh apply --dry-run repo.allow_auto_merge "labels.good first issue" ruleset.default-branch
bash ./scripts/repo-settings.sh apply repo.allow_auto_merge "labels.good first issue" ruleset.default-branch
```

`--all` applies every differing item; use it only when the user approved all of them. Read every output line; the exit code is only the worst case (precedence 2, then 1, then 4, then 3):

| Line | Exit | Meaning and what to do |
| --- | --- | --- |
| `APPLIED  <item>` | 0 | Done. |
| `UNAVAILABLE  <item>  <reason>` | 3 | GitHub refused it on this plan (HTTP 403/422), or accepted the request but did not change the value. Report it plainly as not applied. Rulesets do not work on private repos whose owner, personal account or organisation, is on GitHub Free. Offer to decline it so later audits stay quiet. |
| `FAILED  <item>  <reason>` | 1 | Another error. Report it with the reason. |
| `BLOCKED  <item>  ...` | 4 | The ruleset requires a check that has not run on the default branch yet, so it was not written. |
| `NOTE  <item> is declined (...); skipped` | - | Already declined. |

On `BLOCKED` (exit 4):

- Existing repo: stop here. The other approved items in the same call were still applied; report them. Tell the user to merge the setup pull request (give its URL), let CI run on the default branch, and run the skill again; step 1 detects the second run. Do not retry.
- New repo: `ci-ok` has not reported on the default branch head yet. Wait for that CI run (step 6), then apply `ruleset.default-branch` again.
- Never pass `--allow-unseen-checks` on your own. Use it only if the user asks after confirming the check really reports on pull requests.

After applying, run `audit` again and confirm that only declined, unavailable or blocked items remain.

### 8. Summary

Report, in this order:

- Files: added, merged, and left unchanged (with why).
- Settings: applied; not available on this plan (`UNAVAILABLE`), with the reason; failed; blocked, with the next step.
- Declined items and their reasons.
- Follow-ups, for example: replace the placeholder CI job once code exists; add the missing scaffolding (lockfile, tests) the stack snippet needs; merge the setup pull request and run the skill again to apply the ruleset; remove classic branch protection after migrating.

If the user wants the follow-ups tracked as issues, create them as `references/github-workflow.md` describes. With `issue_types=yes`, set the type (Task, Bug, Feature) through `gh api graphql`; with `issue_types=no`, use the `bug`, `enhancement` or `task` label. Assign the user when `assign_self` is true or unset.

### 9. Offer a Proof PR

Offer to open a one-line docs pull request that shows the skip working. Open it only after a yes, and for an existing repo only after the setup pull request is merged:

```bash
git switch <default_branch> && git pull --ff-only
git switch -c docs/ci-skip-proof
# add one line to README.md
git commit -am "docs: show that docs-only changes skip heavy CI"
git push -u origin docs/ci-skip-proof
gh pr create --base <default_branch> --title "docs: show that docs-only changes skip heavy CI" --body "Docs-only change: heavy CI should skip while required checks pass."
gh pr checks --watch
```

Show the result: heavy jobs (or steps) skipped, required checks green. Never merge it.

## Common mistakes

| Mistake | Instead |
| --- | --- |
| Applying the ruleset before the first push of a new repo | Push, wait for CI, then apply. |
| Retrying after `BLOCKED` in an existing repo | Stop; the setup pull request must be merged first. |
| Reporting `UNAVAILABLE` as done | Say it was not applied and why. |
| Adding `ci-ok` next to existing required checks | Step-level gating in the existing workflows. |
| Running a stack snippet without its lockfile, tests or manifest | Use `templates/ci/placeholder.yml` and list the follow-up. |
| Applying `--all` because the audit was shown | Apply only the ids the user approved. |
