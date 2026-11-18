# initialize-repo-skill

Agent Skill that initializes GitHub repos for professional development workflows: standard files, logic-scoped CI, settings as code, and issue conventions.

## What it does

The `initialize-repo` skill sets up a new GitHub repository, or brings an existing one up to the same baseline:

- **Standard files:** `README.md`, `AGENTS.md` (with `CLAUDE.md` importing it), `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `LICENSE`, `.editorconfig`, issue forms, a pull request template and Dependabot.
- **Logic-scoped CI:** a `scope` job classifies the changed files, heavy jobs run only when a change can affect how the program runs, and a single required check, `ci-ok`, always reports. Docs-only pull requests finish in seconds and never wait on "pending". Existing repos with named required checks get step-level gating instead, so check names do not change.
- **Settings as code:** merge options, security settings, labels and a default-branch ruleset live as JSON under `.github/settings/`. `scripts/repo-settings.sh audit` compares them with live GitHub, and `apply` changes only the items a person approves.
- **Issue conventions:** `AGENTS.md` tells agents to set assignees, labels, issue types and relationships on every issue.

It started in a repo where a one-line `AGENTS.md` change was blocked by seven required CI jobs and had to be merged with an admin bypass. The lessons from that fix are built into the CI design; see [`skills/initialize-repo/references/ci-design.md`](skills/initialize-repo/references/ci-design.md).

This repository is set up with its own skill.

## Install

### Claude Code plugin marketplace

```text
/plugin marketplace add sohampatwardhan/initialize-repo-skill
/plugin install initialize-repo@initialize-repo-skill
```

### skills CLI

```bash
npx skills add sohampatwardhan/initialize-repo-skill -g
```

Install globally (`-g`). A project-scope install puts the skill inside the repo you are about to set up.

### Manual

Copy `skills/initialize-repo/` into your tool's skills directory, for example `~/.claude/skills/initialize-repo/` for Claude Code.

### Preferences (optional)

Fetch the example [`defaults.yaml`](skills/initialize-repo/examples/defaults.yaml) and uncomment the keys you want answered the same way every time. Every key ships commented out; the agent asks for anything not set.

```bash
curl -fsSL --create-dirs -o ~/.config/initialize-repo/defaults.yaml \
  https://raw.githubusercontent.com/sohampatwardhan/initialize-repo-skill/main/skills/initialize-repo/examples/defaults.yaml
```

## Usage

Ask your agent to set up the repository, for example "initialize this repo" or "create a new GitHub repo for my project". In Claude Code you can also run `/initialize-repo` (or `/initialize-repo:initialize-repo` when installed as a plugin). The skill runs a preflight check, asks for anything it cannot work out, writes the files, adapts CI, and shows a settings audit. It changes a repo setting only after you approve that item. On an existing repo it works on a `chore/initialize-repo` branch and opens a pull request; it never merges it.

## Requirements

- `git`, `gh` (authenticated, with the `repo` and `workflow` scopes) and `jq`. If `gh auth status` does not list `workflow`, run `gh auth refresh -s workflow`.
- bash 3.2 or later. On Windows, use Git Bash.

## Development

```bash
bash tests/run-all.sh
```

The tests need `yq`. They also run `actionlint` and `markdownlint-cli2` (through `npx`) when available. CI runs `shellcheck`, `actionlint` and the tests.

Design and plan:

- [Design](docs/superpowers/specs/2026-11-17-initialize-repo-skill-design.md)
- [Implementation plan](docs/superpowers/plans/2026-11-17-initialize-repo-skill.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Agents should also read [AGENTS.md](AGENTS.md).

## License

Released under the MIT license. See [LICENSE](LICENSE).
