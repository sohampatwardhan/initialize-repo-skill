# Contributing to initialize-repo-skill

## Workflow

1. Open or pick an issue. Use the issue forms; they set the type and label.
2. Branch from `main`. Do not push to `main` directly.
3. Commit using Conventional Commits.
4. Add a line under `## [Unreleased]` in `CHANGELOG.md` for any user-visible change.
5. Open a pull request into `main`. Fill in the template and link the issue with `Closes #N`.
6. Wait for the `ci-ok` check to pass. It is the only required check. Heavy checks are skipped for documentation-only changes, and `ci-ok` still reports success.

## Local checks

```text
bash tests/run-all.sh
```

## Reporting problems

Bugs and ideas go in [issues](https://github.com/sohampatwardhan/initialize-repo-skill/issues). Report security problems privately; see [SECURITY.md](SECURITY.md).
