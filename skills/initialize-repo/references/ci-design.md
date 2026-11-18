# CI design

How the generated CI skips heavy work on changes that cannot affect how the program runs, while every required check still reports. Read this before writing or adapting a workflow.

## Why it is built this way

The design came from a real repo where a one-line `AGENTS.md` change was blocked by seven required CI jobs (build and test, image builds, Compose checks) and had to be merged with an admin bypass. Fixing it taught these lessons:

- Markdown cannot change how a program runs, so CI should do heavy work only when implementation or logic changes.
- A workflow-level `on: paths:` / `paths-ignore:` filter means the workflow never starts on a docs-only pull request. Its required checks never report, and the pull request waits on "pending" forever.
- A job-level `if:` on a **matrix** job has the same failure. When the condition is false the job is skipped before the matrix expands, so a check named `test (ubuntu-latest)` is never created, and a ruleset that requires that name waits forever.
- Some markdown *is* read by checks (an expiry check that parses `.security/**/*.md`, release scripts that read `CHANGELOG.md`). That markdown counts as logic.
- Unlisted paths must default to "run CI". A wrong "skip" lets a broken change merge; a wrong "run" only costs minutes.
- The docs-only decision belongs in a small script with its own tests, checked against the file lists of real past pull requests.
- `AGENTS.md` must explain why the skip is built this way, or a later agent will "simplify" it back into a trigger filter.

## The scope script

`scripts/ci-scope.sh` (in the generated repo; the skill's copy is `templates/scripts/ci-scope.sh`) reads changed paths on stdin, one per line, and prints `logic` or `non-logic`. It always exits 0.

- The patterns sit between `# BEGIN SCOPE PATTERNS` and `# END SCOPE PATTERNS` in two bash arrays. A `*` also matches `/`.
- `ALWAYS_LOGIC` is checked first. Defaults: `.github/workflows/*`, `scripts/*`, and a commented-out `'CHANGELOG.md'` line to uncomment when release tooling reads it.
- `NON_LOGIC` defaults: `*.md`, `*.txt`, `docs/*`, `LICENSE*`, `.gitignore`, `*/.gitignore`, `.github/ISSUE_TEMPLATE/*`, `.github/pull_request_template.md`.
- A path that matches neither array is logic. Empty input is logic. One logic path makes the whole change logic.

When you change the patterns, add a case for each change to `scripts/ci-scope.test.sh` and run `bash scripts/ci-scope.test.sh`. To find markdown that a check reads, search the workflows and scripts for markdown paths, for example `grep -rn '\.md' .github/workflows scripts Makefile package.json 2>/dev/null`, and put each such path in `ALWAYS_LOGIC`.

## The scope job

The `scope` job checks out with `fetch-depth: 2` and, on `pull_request`, runs `git diff --name-only HEAD^1 HEAD | bash scripts/ci-scope.sh`. On a pull request `HEAD` is GitHub's merge commit and `HEAD^1` is the base branch tip, so the diff is exactly what the pull request changes. No third-party action is involved. On `push` (and `workflow_dispatch`) the scope is always `logic`, so the default branch is always fully checked. The job exposes `outputs.logic` as `true` or `false`.

The scope tests run on every pull request too, so a broken pattern edit fails CI: the new-repo template runs `bash scripts/ci-scope.test.sh` in its always-on `checks` job, and the step-gated example runs it in `scope`.

## Two gating modes

### Mode 1: job-level gate plus `ci-ok` (new repos)

Used by `templates/.github/workflows/ci.yml` with a snippet from `templates/ci/`.

- `scope` and `checks` always run.
- Heavy jobs (`lint`, `test`) have `needs: scope` and `if: needs.scope.outputs.logic == 'true'`.
- `ci-ok` has `needs:` every other job and `if: always()`. It fails when any needed job failed or was cancelled, and treats skipped as success.
- `ci-ok` is the **only** required check. Because nothing else is required, a skipped job, a matrix that never expands, or a renamed stack job never leaves a required check pending.
- When a stack job is added, renamed or split, add it to `ci-ok`'s `needs:`. A job missing from that list can fail without blocking the merge.

Use this mode for new repos, and for existing repos that have no workflows yet.

### Mode 2: step-level gate (existing repos with named required checks)

Existing repos already require check names such as `build` or `test (ubuntu-latest)`. Changing those names would mean changing the ruleset, and a parallel `ci-ok` gate would leave the old names required and still slow. So keep every job and its name, and gate inside the job instead:

- Every job still runs and reports. Never add a job-level `if:` that depends on the scope.
- Add a `scope` job to **each** workflow file that holds a required check (`needs:` works only within one workflow), and add `scope` to the `needs:` of each heavy job. Adding `needs:` does not change a check's name.
- Give each heavy step `if: needs.scope.outputs.logic == 'true'`: checkout, toolchain setup, caches, builds, tests, uploads. Cheap steps may stay ungated.
- Leave jobs that read markdown (link checkers, expiry checks) ungated, or make sure the files they read are in `ALWAYS_LOGIC`.
- Required check names, matrix ones included, stay the same, and the ruleset's `required_status_checks` keep the existing names. Do not add `ci-ok` and do not add a second ruleset.

On a docs-only pull request each job starts, skips its heavy steps, and finishes green in seconds.

Worked example with a matrix job: [examples/step-gated.yml](examples/step-gated.yml).

Limits of step-level gating:

- `services:` containers and a job-level `container:` start before any step runs, so they cannot be gated; the job still finishes quickly.
- A job that calls a reusable workflow (`jobs.<id>.uses:`) has no steps to gate. Pass `needs.scope.outputs.logic` to it as an input and gate the steps inside the called workflow, or leave that job ungated.
- If the `scope` job itself fails, jobs that need it are skipped, and GitHub counts a skipped required check as passing. Keep the `scope` job trivial (it defaults to `logic` whenever classification has no input) and treat a red `scope` job as a failed build.

## Backtest before turning the skip on

Before an existing repo's setup pull request turns on the skip, run the scope script against the file lists of the last 10 merged pull requests and show the user which would have skipped heavy CI:

```bash
gh pr list --state merged --limit 10 --json number,title,files |
  jq -c '.[]' |
  while IFS= read -r pr; do
    n="$(printf '%s' "$pr" | jq -r '.number')"
    t="$(printf '%s' "$pr" | jq -r '.title')"
    kind="$(printf '%s' "$pr" | jq -r '.files[].path' | bash ./scripts/ci-scope.sh)"
    printf '#%s\t%s\t%s\n' "$n" "$kind" "$t"
  done
```

Read every `non-logic` row. If a pull request in that list changed something a check reads, add that path to `ALWAYS_LOGIC`, add a test case, and run the backtest again.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| `on: paths:` / `paths-ignore:` | The workflow never starts, so required checks stay pending. |
| Job-level `if:` on required jobs | Skipped matrix jobs never create their per-matrix check names. |
| A path-filter action from the Marketplace | A third-party dependency for what `git diff --name-only` does. |
| Requiring each stack job | Any skipped, renamed or matrix job can block merges. `ci-ok` (mode 1) or step-level gating (mode 2) avoids it. |
