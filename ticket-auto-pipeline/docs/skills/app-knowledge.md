# app-knowledge

> Reference knowledge base for the project app's business rules, user roles, UI behaviour, and system conventions, built up during ticket work. Use this as a lookup when browsing the site via Playwright or when reasoning about role-based behaviour. Not an interactive skill -- read this file directly when you need context about how the app works. Companion: /nav-hints for click-by-click navigation paths.

## What it does

Holds one project's app knowledge: roles, state mappings, navigation patterns and quirks learned during Playwright sessions and ticket work. The plugin ships only a skeleton (environment URL placeholders, an empty `## Role Scope Registry` section and the append contract). The pipeline reads and writes each project's own copy at `{TICKETS_ROOT}/app-knowledge.md`, beside `nav-hints.md`. That file may be missing or empty, so callers never assume it holds role rules. Before 0.123.0 the pipeline used `~/.claude/skills/app-knowledge/SKILL.md`, a user-level skill that shadowed this plugin skill and showed one project's knowledge in every project; `hooks/unshadow-skills.sh` now moves such a copy aside (renamed, never deleted) so its text can be copied into the right project's tickets root.

## Trigger

**Slash command:** None -- read the SKILL.md file directly as a reference lookup.

**Natural language:** (loaded automatically by ticket-verify and ticket-reproduce)

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| (none) | Read-only reference file | N/A |

## Outputs / Artifacts

| Artifact | Location | Description |
|----------|----------|-------------|
| Role Scope Registry entries | `{TICKETS_ROOT}/app-knowledge.md` | Appended by ticket-appraise-exec Step 3.7 |
| Learnings | `{TICKETS_ROOT}/app-knowledge.md` | Appended below "Append new learnings below this line" |

## How it works

```mermaid
flowchart TD
    A[Plugin skeleton] --> B[Host runtime copy]
    C[ticket-appraise-exec Step 3.7] -->|append| D[Role Scope Registry]
    E[Playwright sessions / ticket work] -->|append| F[Learnings section]
    D --> B
    F --> B
    B --> G{Caller reads}
    G -->|entry recorded| H[Use the recorded rule]
    G -->|empty| I[Derive from ticket, code or UI]
```

## Related skills

- [`/nav-hints`](nav-hints.md) -- click-by-click navigation paths (companion reference)
- [`/ticket-verify`](ticket-verify.md) -- uses app-knowledge to interpret snapshots and navigate
- [`/ticket-reproduce`](ticket-reproduce.md) -- uses app-knowledge to derive reproduction steps
- [`/ticket-appraise-exec`](ticket-appraise-exec.md) -- appends Role Scope Registry entries
