# Contributing to ServerForge

ServerForge welcomes contributions from anyone. This project is maintained
BDFL-style — all merges into `main` go through one maintainer
([@Prathamesh-Godse](https://github.com/Prathamesh-Godse)) — but that doesn't
mean contributions aren't wanted. It means review is centralized so the
project stays coherent as it grows. Read this doc before opening a PR; it'll
save both of us time.

## Before you start

- **Check open issues first.** If what you want to work on isn't tracked,
  open an issue describing it before writing code — especially for anything
  non-trivial. This avoids wasted work on something that doesn't fit the
  project's direction.
- **For small fixes** (typos, small bugs, docs), just open a PR directly.
- **For anything bigger** (~400+ lines, new features, architectural changes),
  open an issue or start a discussion first. Get a nod before investing real
  time.

## Branching

- Work off `main`. Create a branch named `feature/<short-description>` or
  `fix/<short-description>`.
- Don't push directly to `main` — it's protected, and nobody (including the
  maintainer) merges into it without going through a PR.

## Making changes

- **One PR = one logical change.** Don't bundle an unrelated refactor with a
  bug fix. Split them into separate PRs — this is the single biggest thing
  that keeps review fast.
- **Keep commits clean.** Use imperative mood ("Add retry logic", not "added"
  or "adding"). Squash or rebase away "wip", "fix typo", "oops" commits
  before opening the PR — `git rebase -i` is your friend.
- **Match existing style.** Look at surrounding code before introducing a new
  pattern.
- **Update docs/comments** if your change alters behavior.

## Opening a pull request

- Fill out the PR template completely — What changed, Why, How it was
  tested. PRs with an empty description will be sent back before review.
- Link the related issue if one exists.
- Make sure your branch is up to date with `main` before requesting review.

## Review process

- The maintainer will review, comment, or approve/request changes. Expect a
  response, not silence — if you haven't heard anything in a reasonable time,
  it's fine to ping the PR.
- Feedback is about the code, not you. Expect direct, specific comments
  ("this leaks a file handle on line 42") rather than vague ones.
- If a PR doesn't fit the project's direction, it'll be closed with a clear
  reason — not left open indefinitely. That's not a rejection of you, it's a
  scope decision.
- Once approved, the maintainer merges. Contributors don't have merge rights
  on `main`, even with Write access — this is enforced at the repo settings
  level, not a matter of trust.

## What makes a PR merge faster

- Small, focused, well-tested changes
- A description that explains *why*, not just *what*
- Clean commit history
- No unrelated changes mixed in

## Credit

Contributors are credited in release notes and `CONTRIBUTORS.md`. Thank you
for helping build ServerForge.
