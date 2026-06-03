---
name: lefan-motion-net-pr-push
description: Lefan's PR push flow for motion.net — runs C# code review, gates on user-confirmed fixes, enforces csharpier, runs Roslyn analyzer diagnostic pass, regenerates OpenAPI schemas when DTOs/websockets/pub-sub changed, then opens a draft PR (push with --no-verify) and runs signoff.
version: 1.1.0
---

# Lefan motion.net PR Push

Personal pipeline for shipping a motion.net branch as a draft PR. Run from the repo root on a feature branch with committed changes.

## Process

### Step 1: C# Code Review

Invoke the `/dotnet-csharp-code-review` skill on the pending changes (current branch vs. its upstream/base).

- Collect findings.
- Group by severity (blocker / suggestion / nit).
- Present a numbered list to the user.

**STOP. Wait for user.**

Ask: "Which findings should I fix? (numbers, `all`, `blockers`, or `none`)"

Do not proceed until the user replies.

### Step 2: Apply Confirmed Fixes

For each fix the user approved:

1. Read the file.
2. Apply the change.
3. After all fixes are written, commit with a conventional message, e.g. `chore(<scope>): Address code review feedback`.

If user said `none`, skip to Step 3.

### Step 3: Format with CSharpier

Determine which directories were touched, then format only those paths (csharpier is slow on the whole repo):

```bash
git diff --name-only <base>..HEAD -- '*.cs' | awk -F/ 'NF>2{print $1"/"$2"/"$3}' | sort -u
```

Run:

```bash
dotnet csharpier format <changed-dirs>
dotnet csharpier check <changed-dirs>
```

- If `check` fails after `format`, read the offending file and resolve manually (rare — usually an editor mid-edit issue).
- If there are now uncommitted formatting changes, commit them: `chore(<scope>): Apply csharpier formatting`.

### Step 4: Roslyn Analyzer Diagnostic Pass

csharpier covers whitespace only. Semantic analyzers (CA*, IDE*, nullable, unused symbols) require a separate pass. Pre-commit `build-checked-no-warnings` hook will catch these on push, so flag them before that gate.

Collect diagnostics for the changed files:

1. **Preferred — IDE diagnostics.** If `mcp__ide__getDiagnostics` MCP tool is available, call it for each changed `.cs` file. Fastest, no rebuild.
2. **Fallback — warnings-as-errors build.** Build touched projects:

```bash
dotnet build <changed-csproj-paths> -warnaserror -nologo -v q
```

Resolve csproj paths from changed dirs:

```bash
git diff --name-only <base>..HEAD -- '*.cs' \
  | awk -F/ 'NF>1{print $1"/"$2}' | sort -u \
  | while read d; do find "$d" -maxdepth 2 -name '*.csproj' 2>/dev/null; done
```

Triage findings into three buckets:

- **Actionable** — real bugs, true nullable issues, unused usings/symbols, dead code. Fix.
- **False positives in domain context** — e.g. CA1054 "URI params shouldn't be strings" on Google Ads `TrackingUrlTemplate` (placeholder tokens like `{lpurl}` are not valid `Uri`). Suppress with `[SuppressMessage(...)]` + `Justification` explaining why.
- **Out of scope** — pre-existing diagnostics in code untouched by this PR. Leave alone; do not expand scope.

STOP and surface the actionable + false-positive list to user with the same numbered-fix prompt as Step 1: "Apply diagnostic fixes? (numbers, `all`, `none`)". Do not auto-suppress without confirmation — suppressions are durable and need justification text.

After confirmed fixes, commit: `chore(<scope>): Address analyzer diagnostics`. Then re-run the build (or IDE diagnostics) to confirm clean.

If user says `none`, note "Analyzer pass deferred to pre-push hook" in the final report and continue.

### Step 5: Schema Generation Heuristic

Run:

```bash
git diff --name-only <base>..HEAD
```

Schema regen is **required** if any changed path matches any of:

- `**/Dtos/**`, `**/Dto/**`, `*Dto.cs`, `*Request.cs`, `*Response.cs`
- `**/WebSockets/**`, `*WebSocket*.cs`, `*Hub.cs`
- `**/PubSub/**`, `*PubSubCommand*.cs`, `*PubSubEvent*.cs`, `*IntegrationEvent*.cs`
- `**/Contracts/**`, `*Contract.cs`
- `**/OpenApi/**`, `*Controller.cs` with route attribute changes
- `**/Proto/**`, `*.proto`

If any match → run the broad regen:

```bash
./build.sh --target=gen-open-api
```

For targeted regen when only one document area changed, prefer:

- DTOs/controllers only → `./build.sh --target=gen-open-api-schema`
- Websocket only → `./build.sh --target=gen-open-api-document --document-name=websocket`
- Pub-sub only → `./build.sh --target=gen-open-api-pubsub`
- Proto only → `./build.sh --target=gen-open-api-proto`

After regen:

```bash
git status --porcelain
```

If artifacts changed, commit: `chore(<scope>): Regenerate OpenAPI artifacts`.

If no match → skip this step. State: "Schema regen skipped — no DTO/websocket/pub-sub changes detected."

### Step 6: Compose the PR

**Stacked PRs are common in this flow.** The current branch may sit on top of another in-flight feature branch rather than `main`. The PR must target that stack parent, NOT `main`. Resolve in this priority:

1. **User-provided base** (e.g. "base is `feat/foo`") — use verbatim.
2. **Local upstream** of current branch:
   ```bash
   git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null
   ```
   Normalize `origin/<branch>` → `<branch>`.
3. **Branch the current branch was forked from** — fall back to:
   ```bash
   git log --decorate --simplified-by-decoration --oneline HEAD~..origin/main 2>/dev/null
   ```
   or inspect `git reflog` / `git config branch.<current>.merge`. If still unclear, STOP and ask the user — never silently default to `main`.

If the resolved base is not `main`, confirm with the user once: "Base will be `<base>` (stacked PR). Proceed?" — this prevents accidentally landing a stack-parent's commits into `main`.

Look at `git log <base>..HEAD --format='%s%n%b'` and the diff to draft:

**Title** — conventional commit format from CLAUDE.md: `feat(area): Description no period`
- Pick type from majority of commits (feat/fix/chore).
- Scope = motion.net feature area (e.g. `ad-engine`, `crm`, `forms`, `messaging`, `llm`).
- Sentence case, no trailing period.

**Body** — fill the repo PR template if one exists at `.github/PULL_REQUEST_TEMPLATE/auto-ticket.no-qa.md` (or `default.md`).

Body must encode **why the PR is needed**, not just what changed. Structure:

```
## Why
<1-3 sentences: the user-visible problem, business reason, or upstream constraint forcing this change. If unclear from commits, ASK the user before composing.>

## What changed
- <bullet per logical change, not per commit>

## Test plan
- [ ] <verification steps>
```

Keep it tight. The "Why" is mandatory — if the reason is not derivable from commits/diff, ask the user one question before writing the body.

### Step 7: Push and Open Draft PR

Push with `--no-verify` (user preference for this flow). For a **new branch**, this also sets upstream:

```bash
git push --no-verify -u origin <branch>
```

Open as **draft**, explicitly passing `--base` (never rely on `gh`'s default, which is `main`):

```bash
gh pr create --draft --base "<base>" --head "<branch>" --title "<title>" --body "<body>"
```

If a PR already exists for the branch, instead:

```bash
gh pr edit <number> --base "<base>" --title "<title>" --body "<body>"
```

Pass `--base` on edit too — if the prior PR targeted the wrong base, this re-points it.

### Step 8: Signoff

Per project CLAUDE.md, run after PR creation:

```bash
./scripts/signoff-pr.sh
```

### Step 9: Report

```
## PR Pushed

**PR:** #<n> — <title>
**URL:** <url>
**Base:** <base>
**Status:** Draft

### Pipeline
- Review fixes applied: <count or "none">
- csharpier: pass
- Analyzer diagnostics: <count fixed / count suppressed / deferred>
- Schema regen: <ran target / skipped>
- Push: --no-verify
- Signoff: <ok / failed>
```

## Safety Rules

- NEVER skip Step 1 user confirmation. No fixes without explicit approval.
- NEVER use `gh pr ready` or `gh pr merge`. Always draft.
- NEVER omit `--draft` on create.
- `--no-verify` is intentional here (user preference). Do not extend it to other repos.
- If csharpier check still fails after format, STOP — do not push broken formatting.
- NEVER auto-apply `[SuppressMessage]` attributes without user confirmation — suppressions are durable code annotations.
- Analyzer diagnostics in untouched files are out of scope; do not expand the PR to fix pre-existing issues.
- If schema regen produces unexpected diffs in unrelated files, STOP and ask.

## When to Use

- Branch ready to ship as draft PR for motion.net.
- After implementation + local testing complete.
- Replaces the generic `/wonderly-pr-push` for this repo.
