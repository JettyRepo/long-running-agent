---
description: Generate a long-running agent prompt for a given requirement
argument-hint: Requirement description
---

## Context

- Project directory: !`pwd`
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -5`
- Current version (if applicable): !`grep -r 'Current version' CLAUDE.md 2>/dev/null | head -1 || echo 'N/A'`
- Project rules: !`head -30 CLAUDE.md 2>/dev/null || echo 'No CLAUDE.md'`

## Your task

The user wants to plan the following requirement as a **self-contained long-running agent prompt** — a Markdown document that can be pasted into a fresh Claude Code session for autonomous execution.

**User requirement:**
$ARGUMENTS

## Output format

Generate a complete agent prompt as a Markdown file saved to the project root (e.g. `AGENT_PROMPT_vX.Y.Z.md`). The prompt must follow this structure:

### Required sections

1. **Header** — Title, estimated time, budget (est + 20%), scope summary
2. **Reference** — Current project state, relevant file paths, schemas, constraints
3. **Phases** — Sequential phases (3-8 phases typical), each with:
   - Clear goal
   - Step-by-step instructions with exact file paths and code patterns
   - Verification script (bash one-liner or short script) that must pass before proceeding
4. **Critical Rules** — Project-specific constraints from CLAUDE.md / CONTENT_POLICY.md / etc.
5. **Work Strategy** — Batch sizes, validation cadence, fallback approach

### Writing principles

- **Self-contained**: The agent has never seen this project. Include all necessary context (file paths, schemas, field names, current values).
- **Verifiable**: Every phase ends with a concrete verification command. No "looks good" — use assert/grep/count checks.
- **Sequential with gates**: Phase N+1 cannot start until Phase N verification passes.
- **Concrete over abstract**: Say "edit line 425 of jcqp.html" not "update the version". Say "mean ≤ 12 words" not "make options shorter".
- **Batch-safe**: For large changes (>30 items), specify batch size and per-batch validation.
- **Time-bounded**: Include realistic time estimates per phase. Total should be achievable in one session (6-12 hours).
- **Preserve invariants**: List what must NOT break (tests, existing features, file formats).

### Do NOT include

- Vague instructions ("improve the code", "make it better")
- Steps that require human judgment mid-execution (the agent runs autonomously)
- External dependencies that may not be available (APIs, services)
- Changes outside the project directory without explicit confirmation

## After generating

1. Save the prompt to a file in the project root
2. Show the user a summary: phases, estimated time, key risks
3. Ask if they want to adjust anything before the prompt is finalized
