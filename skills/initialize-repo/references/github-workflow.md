# GitHub workflow

Use everything GitHub lets you attach to an issue, not just the title and body. Fill each field wherever it genuinely fits.

## Fields to consider on every issue

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

## How to apply

- Read the repo's other open issues and their bodies before linking, so relationships reflect reality rather than guesses.
- Never invent a milestone, parent, or link just to fill a field. A missing relationship is better than a false one.
- Say which fields you set and which you left empty, with a short reason for each.
- Do not change repo settings (for example enabling Dependabot alerts) just to fill a field. Ask first.
- Use `gh` and its GraphQL API (`gh api graphql`) for what the CLI flags do not cover, such as issue types and relationships.

## Repos without issue types

Issue types are not available on every repo. Detect support per repo with GraphQL (`repository.issueTypes`); never infer it from the owner type. Where a repo has no issue types, mark the kind of work with the `bug`, `enhancement` or `task` label instead.
