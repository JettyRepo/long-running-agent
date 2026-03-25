# /lrap — Long-Running Agent Prompt Generator

A Claude Code skill that generates self-contained agent prompts for single-session autonomous execution.

## Relationship to the Harness

The harness (`harness.sh`) runs **multi-session loops** — dozens of automated sessions, each implementing one feature from `features.json`.

`/lrap` generates **single-session prompts** — one comprehensive prompt that an operator pastes into a fresh Claude Code session for a 6-12 hour autonomous run covering multiple phases of a planned task.

```
harness.sh  → Many sessions × 1 feature each  → Greenfield projects (20-200 features)
/lrap       → 1 session × many phases          → Planned upgrades to existing codebases
```

## When to Use Which

| Scenario | Tool |
|----------|------|
| Build a new project from scratch | `harness.sh` with `features.json` |
| Overhaul an existing codebase (refactor, content update, migration) | `/lrap` |
| Multi-day project with dozens of features | `harness.sh` |
| Single-day task with 3-8 sequential phases | `/lrap` |

## Installation

Copy `skills/lrap/` to your Claude Code skills directory:

```bash
cp -r skills/lrap ~/.claude/skills/lrap
```

Then restart Claude Code. The `/lrap` command becomes available in any project.

## Usage

```
/lrap Migrate the auth system from JWT to OAuth2 with backward compatibility
/lrap Add internationalization support for Japanese and Korean
/lrap Refactor the monolithic API into 5 microservices with shared database migration
```

## Output

A Markdown file (`AGENT_PROMPT_vX.Y.Z.md`) saved to the project root, containing:

1. **Header** — Title, time estimate, budget
2. **Reference** — Current project state, file paths, schemas, constraints
3. **Phases** (3-8) — Each with goal, step-by-step instructions, and verification gate
4. **Critical Rules** — Project-specific constraints (from CLAUDE.md, etc.)
5. **Work Strategy** — Batch sizes, validation cadence, fallback approach

## Prompt Design Principles

The generated prompts follow these principles (learned from production use):

- **Self-contained**: Assumes the executing agent has never seen the project
- **Verifiable**: Every phase ends with a concrete assert/grep/count check
- **Sequential with gates**: Phase N+1 cannot start until Phase N verification passes
- **Concrete over abstract**: Exact file paths, line numbers, target values — never vague
- **Batch-safe**: Large changes specify batch size and per-batch validation
- **Time-bounded**: Realistic estimates per phase, total 6-12 hours

## Origin

Developed from production experience where manually-written agent prompts orchestrated multi-hour autonomous sessions covering data pipeline rebuilds, content overhauls, and infrastructure deployment across 10+ sequential versions.
