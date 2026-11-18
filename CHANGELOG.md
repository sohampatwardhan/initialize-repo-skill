# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `initialize-repo` Agent Skill (`skills/initialize-repo/SKILL.md`) with references for the CI design, the settings baseline and the GitHub issue workflow.
- Content templates: `README.md`, `AGENTS.md`, `CLAUDE.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `.editorconfig`, issue forms, a pull request template and Dependabot.
- Logic-scoped CI template with a `scope` job, a single required `ci-ok` check, and stack snippets for Python, Node, Go, Rust and a placeholder; plus a step-gated example for existing repos with named required checks.
- `scripts/ci-scope.sh` classifier and its tests, shipped to generated repos.
- `scripts/repo-settings.sh` to audit and apply repo settings, labels and the `default-branch` ruleset from `.github/settings/*.json`, with a guard against requiring checks that have never run.
- `scripts/preflight.sh` and `scripts/render.sh` helpers for the skill.
- Claude Code plugin and marketplace manifests, and an example preferences file.
- This repository set up with its own skill: standard files, `ci-ok` CI and `.github/settings/`.
