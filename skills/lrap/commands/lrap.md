---
description: Generate a long-running agent prompt for a given requirement
argument-hint: Requirement description
---

## Context

- Project directory: !`pwd`
- Git status: !`git rev-parse --is-inside-work-tree 2>/dev/null && echo "repo detected" || echo "No git repository found; proceeding without git history."`
- Current branch: !`git branch --show-current 2>/dev/null || echo 'N/A (not a git repo)'`
- Recent commits: !`git log --oneline -5 2>/dev/null || echo 'N/A (not a git repo)'`
- Current version (if applicable): !`grep -r 'Current version' CLAUDE.md 2>/dev/null | head -1 || echo 'N/A'`
- Project rules: !`head -30 CLAUDE.md 2>/dev/null || echo 'No CLAUDE.md'`

## Your task

Git history and branch info above are **enhancing context, not prerequisites**. If unavailable, generate the implementation roadmap based on directory contents, user requirements, and existing documentation. When git is not available, skip Phase 0 (`EnterWorktree` isolation) and work directly in the project directory.

The user wants to plan the following requirement as a **self-contained long-running agent prompt** — a Markdown document that can be pasted into a fresh Claude Code session for autonomous execution.

**User requirement:**
$ARGUMENTS

## Output format

Generate a complete agent prompt as a Markdown file saved to the project root (e.g. `AGENT_PROMPT_vX.Y.Z.md`). The prompt must follow this structure:

### Required sections

1. **Header** — Title, estimated time, budget (est + 20%), scope summary
2. **Reference** — Current project state, relevant file paths, schemas, constraints
3. **Phase 0 — Safe Fork** (MANDATORY, always the first phase — see template below)
4. **Phases 1–N** — Sequential work phases (3-8 phases typical), each with:
   - Clear goal
   - Step-by-step instructions with exact file paths and code patterns
   - Verification script (bash one-liner or short script) that must pass before proceeding
   - **Phase checkpoint**: after verification passes, commit + tag (see template below)
5. **Completion — Merge / Rollback Instructions** (MANDATORY, always the final section — see template below)
6. **Critical Rules** — Project-specific constraints from CLAUDE.md / CONTENT_POLICY.md / etc.
7. **Work Strategy** — Batch sizes, validation cadence, fallback approach

### Phase 0 — Safe Fork (copy this template verbatim into every generated prompt)

**Step 1 — Verify clean state:**

```bash
if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: Working directory has uncommitted changes. Commit or stash first."
    exit 1
fi
```

**Step 2 — Enter worktree** (use Claude Code's built-in `EnterWorktree` tool):

Call `EnterWorktree` with `name: "lrap/<TASK_SLUG>"`.

This automatically:
- Creates an isolated worktree in `.claude/worktrees/lrap/<TASK_SLUG>` with a new branch based on HEAD
- Switches the session's working directory into the worktree
- Manages cleanup on session exit (prompts to keep or remove)

**Step 3 — Capture worktree metadata:**

```bash
BRANCH=$(git branch --show-current)
WORKTREE_DIR=$(pwd)
TASK_NAME="<TASK_SLUG>"
echo "✓ Worktree active: $WORKTREE_DIR"
echo "  Branch: $BRANCH (based on $(git rev-parse --short HEAD))"
```

**Step 4 — Bootstrap environment (if applicable):**

```bash
# e.g.: npm install, pip install -r requirements.txt, etc.
```

**Step 5 — Verify baseline — run tests before any changes:**

```bash
# e.g.: npm test, pytest, etc.
```

**CRITICAL**: After Phase 0, `EnterWorktree` has already switched the session's working directory to the worktree. All subsequent phases work in this directory automatically — no explicit `cd` needed. File paths in the prompt must be relative, not absolute to the original project directory.

### Phase checkpoint (insert at the end of every Phase 1–N, after verification passes)

```bash
# ── Phase N checkpoint ──
git add -A
git commit -m "lrap(phase-N): <short description of what this phase accomplished>"
git tag "lrap/${TASK_NAME}-phase-N"
echo "✓ Checkpoint: lrap/${TASK_NAME}-phase-N"
```

### Completion — Merge / Rollback Instructions (copy verbatim as the final section)

```markdown
## After Completion

All work is on the worktree branch. The original directory is completely untouched.
The agent session will prompt to keep or remove the worktree on exit — choose **keep** to review before merging.

### Find worktree branch and path
    git worktree list
    # Worktree: .claude/worktrees/lrap/<TASK_NAME>
    # Note the branch name from the output

### Accept all changes (merge into base branch)
    BRANCH=$(git -C .claude/worktrees/lrap/<TASK_NAME> branch --show-current)
    git merge "$BRANCH"
    git worktree remove .claude/worktrees/lrap/<TASK_NAME>
    git branch -D "$BRANCH"
    # optional: clean up tags
    git tag -d $(git tag -l 'lrap/<TASK_NAME>-*')

### Accept all changes as a single squashed commit
    BRANCH=$(git -C .claude/worktrees/lrap/<TASK_NAME> branch --show-current)
    git merge --squash "$BRANCH"
    git commit -m "feat: <description>"
    git worktree remove .claude/worktrees/lrap/<TASK_NAME>
    git branch -D "$BRANCH"

### Roll back to a specific phase (e.g. keep Phase 1-2, discard Phase 3+)
    cd .claude/worktrees/lrap/<TASK_NAME>
    git reset --hard lrap/<TASK_NAME>-phase-2
    # Then continue working from Phase 2, or merge this state

### Discard everything (full rollback)
    git worktree remove --force .claude/worktrees/lrap/<TASK_NAME>
    # Branch name from `git worktree list` above
    git branch -D <BRANCH>
    git tag -d $(git tag -l 'lrap/<TASK_NAME>-*')

### Inspect side-by-side
    diff -rq . .claude/worktrees/lrap/<TASK_NAME> --exclude=node_modules --exclude=.git
```

Replace `<TASK_NAME>` and `<BRANCH>` with actual values. `<TASK_NAME>` is the slug from Phase 0. `<BRANCH>` is auto-generated by `EnterWorktree` — obtain it via `git worktree list`.

### Writing principles

- **Self-contained**: The agent has never seen this project. Include all necessary context (file paths, schemas, field names, current values).
- **Worktree-aware**: Phase 0 uses `EnterWorktree` to create an isolated worktree. The session's CWD is automatically switched — no explicit `cd` needed. File paths must be relative.
- **Checkpointed**: Every phase ends with a commit + tag. The agent can be rolled back to any phase boundary.
- **Verifiable**: Every phase ends with a concrete verification command. No "looks good" — use assert/grep/count checks.
- **Sequential with gates**: Phase N+1 cannot start until Phase N verification passes.
- **Concrete over abstract**: Say "edit line 425 of jcqp.html" not "update the version". Say "mean ≤ 12 words" not "make options shorter".
- **Batch-safe**: For large changes (>30 items), specify batch size and per-batch validation.
- **Time-bounded**: Include realistic time estimates per phase. Total should be achievable in one session (6-12 hours).
- **Preserve invariants**: List what must NOT break (tests, existing features, file formats).
- **Never touch the original directory**: `EnterWorktree` isolates all writes, edits, and git operations in the worktree. The original directory remains on the base branch with zero modifications.

### Do NOT include

- Vague instructions ("improve the code", "make it better")
- Steps that require human judgment mid-execution (the agent runs autonomously)
- External dependencies that may not be available (APIs, services)
- Changes outside the worktree (the original project directory must NEVER be modified)
- Phase 0 must NOT be skipped, reordered, or merged with Phase 1

## After generating

1. Save the prompt to a file in the project root
2. Show the user a summary: phases, estimated time, key risks
3. Confirm the `EnterWorktree` name and task slug look correct
4. List the rollback options available (phase-level, full discard)
5. Ask if they want to adjust anything before the prompt is finalized
