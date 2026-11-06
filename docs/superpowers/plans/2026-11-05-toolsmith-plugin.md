# Toolsmith Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the toolsmith Claude Code plugin: a `writing-tools` skill and context hooks that stop working agents from writing their own helper scripts, a `toolsmith` subagent that builds and changes tools, and a tested `toolsmith-repo` script that owns all tools-repo plumbing.

**Architecture:** Deterministic work (locating and initialising the tools repo, project keys, catalog generation, locking, staging, installing, committing) lives in one bash script, `bin/toolsmith-repo`, built test-first. Judgment lives in prose: the toolsmith agent prompt plus two reference files, and the `writing-tools` skill. One hook script, `hooks/inject`, runs on SessionStart and SubagentStart and injects literal catalog paths that it gets from `toolsmith-repo locate`.

**Tech Stack:** bash (must run on macOS's stock bash 3.2), git, Claude Code plugin format (plugin.json, agents/, skills/, hooks/hooks.json, bin/).

**Spec:** `docs/superpowers/specs/2026-11-05-toolsmith-plugin-design.md`. Read it before starting any task. Where this plan and the spec disagree, the plan wins only on the points listed under "Deviations from the spec" below.

## Global Constraints

- Every script runs under `/bin/bash` 3.2: no associative arrays, no `mapfile`/`readarray`, no `${var,,}`, no `|&`, no `coproc`.
- Canonicalise directories with `cd -P -- "$d" && pwd -P` in a subshell, not `realpath`/`readlink -f`.
- No runtime dependency beyond bash, git, and POSIX utilities that ship with macOS and Linux. No jq, no python, no flock.
- Tools repo location is fixed: `$HOME/.local/share/toolsmith/tools`. No environment override.
- Catalog header marker: `toolsmith-v1:`, within a tool's first five lines, behind `#`, `//`, or `--`.
- Overflow/temp space: `${TMPDIR:-/tmp}/toolsmith-$(id -u)/`.
- Agent frontmatter exactly: `name: toolsmith`, `model: inherit`, `omitClaudeMd: true`, `tools: Bash, Read, Write, Edit, Glob, Grep`.
- Nothing but `agents/toolsmith.md` lives under `agents/`.
- Minimum Claude Code version: 2.1.271 (for `omitClaudeMd`).
- The plugin ships no PreToolUse hook and no permission-approving hook.
- Tests never touch the real `~/.local/share/toolsmith`: every test sets `HOME` to a temp dir, and sets `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM=1`.
- Test output is pristine: a passing run prints one summary line per test file and nothing else on stdout.

## Deviations from the spec

Decided while planning.

1. **`toolsmith-repo locate`** is added: a strictly read-only twin of `path` that the hook calls. The spec says the hook resolves paths read-only. Sharing the script keeps the project-key logic in one place.
2. **Project key uses the main worktree.** The key comes from `git rev-parse --git-common-dir`, so every worktree and subdirectory of one repo shares a project catalog. The spec says "git toplevel". Worktrees are common, and per-worktree catalogs would scatter tools.
3. **The lock directory lives in `.git/toolsmith.lock`**, not the work tree, so no `info/exclude` entry is needed.
4. **`move` syntax:** `toolsmith-repo move <name> --project <dir> --to global|project`.

## Review Focus

1. Paths containing spaces (`HOME`, the project dir, the staged file). Every command must work; tests in Tasks 1, 2 and 4 use a space in the temp `HOME`.
2. A git worktree or subdirectory of the same project must map to the same project key (Task 2).
3. The hook runs before the tools repo exists, or while `~/.local/share/toolsmith/tools` is a dangling symlink. It still emits valid JSON with the would-be paths and creates nothing (Task 6).
4. A staged tool with no `toolsmith-v1:` header in its first five lines: `install` refuses with exit 7 instead of committing an uncatalogued tool (Task 4).
5. A tool edited by hand (uncommitted) in the repo between `stage` and `install`: the base check rejects with exit 3 (Task 4).

## toolsmith-repo interface (used by every task)

Output is `key=value` lines on stdout, one per line, so callers can read them without parsing prose. Errors go to stderr as `toolsmith-repo: <what went wrong>. <what to try>.`

| Exit | Meaning |
|---|---|
| 0 | ok |
| 1 | usage error, or bad name |
| 2 | operation failed (filesystem or git error) |
| 3 | base revision moved |
| 4 | lock timeout |
| 5 | repo mid-rebase or mid-merge |
| 6 | prerequisite missing (git) |
| 7 | staged file has no `toolsmith-v1:` header |
| 8 | `--project` dir is not inside a git repo |
| 9 | move destination already exists |

Keys:
- `repo=`, `global_catalog=`, `project_key=`, `project_dir=`, `project_catalog=` from `path` and `locate`
- `note=` (repeatable)
- `staged=`, `base=` (blob hash from `git hash-object`, or `absent`) from `stage`
- `catalog=` (the tool's catalog line), `commit=`, `adopted=` (repeatable) from `install`/`move`

Catalog file format:
```
# Tools catalog. Generated by toolsmith-repo; do not edit.
- /abs/repo/bin/json-extract -- Pull fields out of JSON lines; use for log trawling.
- /abs/repo/bin/old-thing -- (no toolsmith-v1 header)
```
Lines are sorted by path. The purpose text is whatever follows the marker, with trailing whitespace stripped.

---

### Task 1: Test harness, plugin skeleton, `path` and `locate` (global scope)

**Files:**
- Create: `.claude-plugin/plugin.json`, `bin/toolsmith-repo`, `tests/lib.sh`, `tests/run`, `tests/test-repo-path.sh`

**Interfaces:**
- Produces:
  - `toolsmith-repo path` and `toolsmith-repo locate`, both printing `repo=` and `global_catalog=`.
  - `tests/lib.sh` functions:
    - `new_env` (sets `T_HOME`, a temp dir with a space in its name; sets `T_GITCFG`, a temp global config with identity `Test <test@example.com>`)
    - `tr_run <args...>`, which runs `bin/toolsmith-repo` under `env -i PATH HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM=1 TMPDIR` and sets `OUT`, `ERR`, `RC`
    - `assert_eq <desc> <want> <got>`, `assert_contains <desc> <needle> <haystack>`, `assert_rc <desc> <want>`
    - `kv <key>`, which prints the first `key=` value from `OUT`
  - `tests/run`: runs every `tests/test-*.sh` and prints `PASS name` or `FAIL name (log: path)` per file. Full logs go to `${TMPDIR:-/tmp}/toolsmith-tests-$(id -u)/`. Exits non-zero on any failure. `--help` explains this.

- [ ] **Step 1: Write the failing tests** in `tests/test-repo-path.sh`:
  - `fresh_home`: no `~/.local/share` at all. `path` exits 0. `repo=` equals `$T_HOME/.local/share/toolsmith/tools` canonicalised. The repo is a git repo with one commit containing `README.md` and `CATALOG.md` (header line only). `note=` contains `created tools repo at`.
  - `dangling_relative_symlink`: `tools -> ../../../target/tools` (relative), with the target missing. Run from a different cwd. The target is created at the path relative to the symlink's directory, not the cwd. The symlink is still a symlink afterwards. `repo=` is the canonical target.
  - `existing_non_git_dir`: `tools/` exists with `bin/foo` and isn't a git repo. After `path` it is a git repo whose first commit contains `bin/foo`, `README.md` and `CATALOG.md`.
  - `no_git_identity`: `GIT_CONFIG_GLOBAL=/dev/null`. `git -C repo config user.email` is `toolsmith@localhost`, and a `note=` mentions the repo-local identity.
  - `second_run_is_quiet`: running `path` twice gives the same `repo=`, no new commit, and no `note=`.
  - `locate_creates_nothing`: on a fresh home, `locate` exits 0 and prints `repo=` and `global_catalog=` for the would-be path, and `$T_HOME/.local` does not exist afterwards. Same with a dangling symlink: the target is not created.
  - `git_missing`: `PATH=/nonexistent:/bin` with git hidden (copy bash and the needed utilities into a temp bin, without git). `path` exits 6 and stderr says to install git.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-repo-path.sh`.
- [ ] **Step 3: Implement** `path` and `locate` in `bin/toolsmith-repo`, following the spec's first-run order. Treat git as missing when `command -v git` fails or when `git --version` exits non-zero, which is how the macOS Command Line Tools stub behaves. Write `plugin.json` with `name: toolsmith`, `version: 0.1.0`, `description`, `author` `{name: <author>, email: <author email>}` and `license: MIT`, matching superpowers' fields. The README seeded into a new tools repo is three or four lines saying what the repo is and that `toolsmith-repo` manages it.
- [ ] **Step 4: Run** `tests/run`. Expected: `PASS test-repo-path.sh`, and nothing else printed.
- [ ] **Step 5: Commit** with `git add .claude-plugin bin tests` and the message `toolsmith-repo: path and locate with first-run handling`.

### Task 2: Project scope and project keys

**Files:**
- Modify: `bin/toolsmith-repo`
- Test: `tests/test-project-key.sh`

**Interfaces:**
- Consumes: Task 1's harness and `path`/`locate`.
- Produces: `path --project <dir>` and `locate --project <dir>` add `project_key=`, `project_dir=` and `project_catalog=`. There's an internal function `resolve_scope [<project-dir>]` that sets `SCOPE_DIR` (repo root, or `repo/projects/<key>`) and `SCOPE_KEY` (empty for global); Tasks 3 to 5 use it.

Key algorithm:
1. `common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)`.
2. If `common` ends in `/.git`, the root is its parent; otherwise (a bare repo) the root is `common`. Canonicalise the root.
3. The key is `<basename of root>-<first 6 chars of: printf %s "$root" | git hash-object --stdin>`.

- [ ] **Step 1: Write the failing tests:**
  - `key_shape`: a project at `$T_HOME/src/my app` gives `project_key` matching `^my app-[0-9a-f]{6}$`, and `project_dir` = `repo/projects/<key>`.
  - `subdir_same_key`: `--project` on a subdirectory gives the same key as the project root.
  - `worktree_same_key`: `git worktree add ../wt` gives the same key as the main checkout.
  - `same_basename_differs`: `$T_HOME/a/app` and `$T_HOME/b/app` give different keys.
  - `not_git`: `--project` on a plain dir exits 8, and stderr says to use the global scope. `locate` still prints `repo=` and `global_catalog=` on stdout before exiting 8, because the hook relies on that.
  - `path_does_not_create_project_dir`: `projects/<key>` doesn't exist after `path --project`.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-project-key.sh`.
- [ ] **Step 3: Implement** `resolve_scope` and the `--project` option on `path`/`locate`.
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 5: Commit** with the message `toolsmith-repo: project keys shared across worktrees`.

### Task 3: Catalog generation

**Files:**
- Modify: `bin/toolsmith-repo`
- Test: `tests/test-catalog.sh`

**Interfaces:**
- Consumes: `resolve_scope`.
- Produces:
  - `toolsmith-repo catalog [--project <dir>]`: rewrites the scope's `CATALOG.md`, and prints `untracked=<path>` for each untracked or modified file in the scope's `bin/`.
  - Internal `write_catalog <scope_dir>` and `header_purpose <file>` (prints the purpose, or nothing), reused by `install` and `move`.

Header match: the first 5 lines only, with the ERE `^[[:space:]]*(#|//|--)[[:space:]]*toolsmith-v1:[[:space:]]*(.*[^[:space:]])[[:space:]]*$`.

- [ ] **Step 1: Write the failing tests:**
  - `hash_header`: a bash tool with the header on line 2 gives the line `- <abs>/bin/a -- Purpose A`.
  - `slash_header`: a node tool (`#!/usr/bin/env node`, then `// toolsmith-v1: Purpose B`) is listed.
  - `python_cookie`: a python tool with an encoding cookie on line 2 and the header on line 3 is listed.
  - `header_too_late`: header on line 6 gives `(no toolsmith-v1 header)`.
  - `quoted_in_help`: a tool whose line 2 header is `Real`, and whose line 20 contains `# toolsmith-v1: Fake`, gives `Real` only.
  - `sorted_and_header_line`: the first line is the generated-file header, and tools are sorted.
  - `untracked_reported`: an uncommitted `bin/new` appears as `untracked=`.
  - `project_scope`: `catalog --project` writes `projects/<key>/CATALOG.md` and leaves the global one alone.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-catalog.sh`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 5: Commit** with the message `toolsmith-repo: generated catalogs`.

### Task 4: `stage` and `install`, with locking

**Files:**
- Modify: `bin/toolsmith-repo`
- Test: `tests/test-install.sh`

**Interfaces:**
- Consumes: `resolve_scope`, `write_catalog`, `header_purpose`.
- Produces:
  - `toolsmith-repo stage <name> [--project <dir>]` prints `staged=` (a file in a fresh `mktemp -d` under `${TMPDIR:-/tmp}/toolsmith-$(id -u)/stage/`) and `base=`.
  - `toolsmith-repo install <staged-file> <name> --base <rev> -m <msg> [--project <dir>]` prints `catalog=`, `commit=` and `adopted=`*.
  - Internal `with_lock <cmd...>`, used by `move`.

Rules:
- `name` must match `^[a-z0-9][a-z0-9._-]*$`; otherwise exit 1.
- Base = `git hash-object` of the scope's working-tree `bin/<name>`, or `absent`.
- Lock: `mkdir .git/toolsmith.lock`, write `$$` to `.git/toolsmith.lock/pid`. If `mkdir` fails and that PID isn't alive (`kill -0`), remove the lock and retry. Retry every 0.1s for up to 100 tries, then exit 4. Release on exit via `trap`.
- Inside the lock, in order:
  1. Refuse with exit 5 if `.git/rebase-merge`, `.git/rebase-apply` or `.git/MERGE_HEAD` exists.
  2. Check the base; exit 3 if it moved.
  3. Check the header; exit 7 if missing.
  4. Copy the file and `chmod +x` it.
  5. On a project's first install, create `projects/<key>/` and write `PROJECT` containing the project root path.
  6. `write_catalog`.
  7. `git add` and `git commit -- <paths>`, where paths are the tool, the catalog, `PROJECT` if new, and any untracked or modified files in the scope's `bin/` (each one printed as `adopted=`).

Steps:
- [ ] **Step 1: Write the failing tests:**
  - `new_tool`: stage, write a staged file with a header, install. `bin/x` is executable. The catalog has its line. The repo has exactly one new commit touching `bin/x` and `CATALOG.md`. `catalog=` matches the catalog line.
  - `change_tool`: stage an existing tool, then install. `base=` was its blob hash and the commit modifies it.
  - `base_moved_by_install`: two stages of the same new name, then two installs. The first gives 0, the second gives 3, and stderr says to re-stage.
  - `base_moved_by_hand`: stage, hand-edit `bin/x` in the repo without committing, then install. Exit 3.
  - `race`: two `install`s of different new tools launched in the background at the same moment both exit 0, giving two commits and a catalog with both lines.
  - `stale_lock`: precreate `.git/toolsmith.lock/pid` holding a dead PID; install succeeds.
  - `lock_timeout`: precreate a lock with the PID of a live `sleep 30`; install exits 4 (run with a reduced retry count via an internal test-only flag `--lock-tries 3`, documented in `--help`).
  - `mid_rebase`: create `.git/rebase-merge/`; install exits 5.
  - `no_header`: exit 7, and nothing committed.
  - `bad_name`: `../evil` and `Foo` exit 1.
  - `adopts_untracked`: an untracked `bin/stray` gets committed and reported as `adopted=`.
  - `project_install`: install with `--project` creates `projects/<key>/bin/x`, `PROJECT` and the project catalog. The global catalog is unchanged.
  - `caller_repo_untouched`: run every install from a cwd inside a separate temp git repo. That repo's HEAD and `git status --porcelain` are unchanged afterwards.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-install.sh`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS, and the `race` test passes in 5 consecutive runs (`for i in 1 2 3 4 5; do tests/run || break; done`).
- [ ] **Step 5: Commit** with the message `toolsmith-repo: stage and install with base checks and locking`.

### Task 5: `move` between scopes

**Files:**
- Modify: `bin/toolsmith-repo`
- Test: `tests/test-move.sh`

**Interfaces:**
- Consumes: `with_lock`, `resolve_scope`, `write_catalog`.
- Produces: `toolsmith-repo move <name> --project <dir> --to global|project`. It runs `git mv`, regenerates both catalogs, makes one commit, and prints `catalog=` and `commit=`.

- [ ] **Step 1: Write the failing tests:**
  - `promote`: a project tool moved `--to global` is gone from the project catalog, present in the global one, and done in one commit.
  - `demote`: the reverse works.
  - `dest_exists`: exit 9, nothing changed.
  - `missing_source`: exit 1, with a message naming the scope searched.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-move.sh`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 5: Commit** with the message `toolsmith-repo: move tools between scopes`.

### Task 6: Context-injection hooks

**Files:**
- Create: `hooks/hooks.json`, `hooks/run-hook.cmd` (verbatim copy from superpowers 7.0.2), `hooks/inject`, `tests/test-hook.sh`

**Interfaces:**
- Consumes: `toolsmith-repo locate [--project <cwd>]`, called as `"$PLUGIN_ROOT/bin/toolsmith-repo"`, with exit 8 meaning global only.
- Produces: `hooks/inject <EventName>`. It reads hook JSON on stdin and prints `{"hookSpecificOutput":{"hookEventName":"<EventName>","additionalContext":"..."}}`, or nothing when `agent_type` is `toolsmith:toolsmith`.

hooks.json follows superpowers' entry shape. Two events:
- `SessionStart`, matcher `startup|clear|compact`, command `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" inject SessionStart`
- `SubagentStart`, matcher `.*`, command `"${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" inject SubagentStart`

`inject` behaviour:
- Read stdin with `IFS= read -r -d '' input || true`.
- Pull out `agent_type` and `cwd` with a bash regex on `"key"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"`, then unescape `\\` and `\"`.
- Escape the context for JSON the way superpowers' `escape_for_json` does.
- The context must contain:
  - what counts as a tool, in one line
  - the exact grep command with literal absolute catalog paths
  - that a missing catalog means no tools yet
  - to call the Agent tool with `subagent_type` `toolsmith:toolsmith`
  - to never write a non-mission tool yourself
  - to invoke the `writing-tools` skill for details

  Keep it under 15 lines; exact wording is the builder's.

Steps:
- [ ] **Step 1: Write the failing tests.** Validate the JSON with `/usr/bin/plutil -lint` on macOS, or `python3 -m json.tool` if available. These are test-only tools, which the global constraint allows.
  - `session_start`: stdin `{"hook_event_name":"SessionStart","cwd":"<git repo>","source":"startup"}` gives valid JSON. `hookEventName` is `SessionStart`. The context contains the literal global catalog path and the project catalog path.
  - `subagent_start`: stdin with `"agent_type":"general-purpose"` gives `hookEventName` `SubagentStart`.
  - `toolsmith_exempt`: `"agent_type":"toolsmith:toolsmith"` gives empty stdout and exit 0.
  - `outside_git`: a non-git `cwd` gives only the global path, with no `projects/`.
  - `before_repo_exists`: a fresh `HOME` still gives valid JSON with the would-be paths, and `$HOME/.local` is not created.
  - `dangling_symlink`: same as above, and the symlink target is not created.
  - `space_in_cwd`: a `cwd` with a space and an escaped quote is parsed correctly.
  - `via_wrapper`: running through `hooks/run-hook.cmd inject SubagentStart` gives the same output.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-hook.sh`.
- [ ] **Step 3: Implement** `hooks/inject` and `hooks/hooks.json`; copy `run-hook.cmd`.
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 5: Commit** with the message `hooks: inject tool-routing context on SessionStart and SubagentStart`.

### Task 7: The toolsmith agent and its reference files

**Files:**
- Create: `agents/toolsmith.md`, `references/authoring-standards.md`, `references/reply-format.md`, `tests/test-layout.sh`

**Interfaces:**
- Consumes: the whole `toolsmith-repo` interface above (the agent prompt quotes the subcommands and exit codes it must handle).
- Produces: the agent `toolsmith:toolsmith` and the reply format that Task 8's skill tells callers to read.

Content requirements:
- **Frontmatter:** as in Global Constraints. The `description` tells the Agent chooser to use it for building or changing a reusable tool, never for mission work.
- **The prompt body:**
  - Restates the rules the toolsmith needs, since CLAUDE.md is omitted.
  - Gives the procedure from the spec's "The toolsmith's procedure" section, with exact `toolsmith-repo` commands.
  - Explains how to handle exit codes 3 (re-stage, retry once), 4, 5, 6 and 7.
  - Covers the scope decision, and that every tool is parameterized and reusable even inside a project.
  - Forbids running git or touching the tools repo with raw shell.
  - Forbids asking the caller questions.
  - Points at `${CLAUDE_PLUGIN_ROOT}/references/authoring-standards.md` and `reply-format.md`, telling the agent to read both on every invocation.
- **authoring-standards.md:** the spec's "Tool standards" section, plus the header rule with one example per comment style, plus the fixture-first dry-run rule.
- **reply-format.md:** the spec's reply block and the `tool: none` rule.

Steps:
- [ ] **Step 1: Write the failing test** `tests/test-layout.sh`:
  - `only_one_agent`: `find agents -name '*.md'` prints exactly `agents/toolsmith.md`.
  - `frontmatter`: the four fixed fields are present with exact values.
  - `references_exist`: every `${CLAUDE_PLUGIN_ROOT}/...` path in `agents/toolsmith.md` exists.
  - `validate`: `claude plugin validate .` exits 0. Skip with a printed `SKIP` line if `claude` isn't on PATH. `tests/run` must count a skip as a pass but list it in its summary.
- [ ] **Step 2: Run** `tests/run`. Expected: `FAIL test-layout.sh`.
- [ ] **Step 3: Write the three files.**
- [ ] **Step 4: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 5: Commit** with the message `toolsmith agent and reference files`.

### Task 8: `writing-tools` skill and README

**Files:**
- Create: `skills/writing-tools/SKILL.md`, `README.md`
- Modify: `tests/test-layout.sh`

Content requirements:
- **SKILL.md frontmatter:** `name: writing-tools`. Its `description` starts with "Use when" and names the trigger: about to write a script, a heredoc, or a multi-line `python3 -c`/`node -e`, or to save code to scratch, that isn't part of the project's deliverable.
- **SKILL.md body:**
  - The tool/mission line from the spec, including:
    - the human-instruction override
    - project-specific-but-unshipped code going to the toolsmith
    - the inline allowance: one command line, or a throwaway snippet under about five lines
    - scratch being wiped on reboot
  - The four steps from the spec's writing-tools section.
  - The brief's four fields.
  - The dispatcher rule: put a toolsmith pointer in each subagent brief.
  - The no-Agent-tool rule: return a marked toolsmith request to your parent.
  - Telling the human in one line.
- **README:**
  - What it is, and the minimum Claude Code version (2.1.271).
  - Prerequisites (git; on macOS, the Command Line Tools).
  - Where the repo lives, and relocating it by symlink.
  - Optional quiet-mode settings: `permissions.additionalDirectories` with the real repo path, and `Bash(toolsmith-repo *)`.
  - Optional `bin/` on PATH.
  - The conditional AGENTS.md/CLAUDE.md snippet.
  - An uninstall note.
  - How to run `tests/run`.
  - Auto mode: say it is unverified until Task 9 reports, then update with the result.

Steps:
- [ ] **Step 1:** Add `skill_frontmatter` to `tests/test-layout.sh`: the `name` matches its directory, and `description` starts with `Use when`. Run it to see it fail.
- [ ] **Step 2: Write** SKILL.md and README.md.
- [ ] **Step 3: Run** `tests/run`. Expected: all PASS.
- [ ] **Step 4: Commit** with the message `writing-tools skill and README`.

### Task 9: Pressure scenarios

**Files:**
- Create: `tests/scenarios/run-scenario`, `tests/scenarios/*.md` (one prompt per scenario), `tests/scenarios/README.md`

**Interfaces:**
- Consumes: the whole plugin, loaded with `--plugin-dir <worktree>`.
- Produces: `tests/scenarios/run-scenario <scenario> [--trials N] [--permission-mode M] [--baseline]`. It prints one line per trial: `PASS`/`FAIL` plus the reason, and the transcript path. `--baseline` runs without the plugin.

- [ ] **Step 1: Check isolation is possible.** Run `HOME=$(mktemp -d) claude -p "say ok" --plugin-dir .` and see whether it authenticates. If it fails, **stop and ask the author**. The fix (a test-only override of the repo location, or a credentials approach) reverses a spec decision, so it's their call. Do not add an environment override on your own.
- [ ] **Step 2: Write the harness.** For each trial:
  1. Create a temp caller git repo with one commit, and a temp `HOME`.
  2. Run `claude -p` with `--plugin-dir`, the scenario prompt and the permission mode.
  3. Find the session JSONL and its `subagents/*.jsonl` under the temp config dir.
  4. Assert from the transcripts:
     - the main agent invoked the Agent tool with `toolsmith:toolsmith`
     - no `Write` of an executable and no heredoc interpreter call by the working agent
     - the caller's HEAD and `git status --porcelain` are unchanged
     - the tools repo gained exactly one commit adding one `bin/` file
     - no tool call in any transcript was denied; a denial fails the trial
- [ ] **Step 3: Write the scenarios:**
  - `log-trawl`: "count 5xx responses per endpoint in access.log", with a fixture log in the caller repo.
  - `subagent`: the main agent is told to dispatch a general-purpose subagent for the log task. This checks the SubagentStart injection reaches the subagent.
  - `existing-tool`: the tools repo is preseeded with a matching tool. Passes if the agent greps the catalog and uses the tool with no toolsmith call.
  - `mission`: "add a scripts/release.sh to this repo". Passes if the agent writes it in the project and makes no toolsmith call.
  - `user-says-scratch`: "write me a throwaway script in /tmp". Passes if the agent complies directly.
- [ ] **Step 4: Run** each scenario with `--baseline` once, then with the plugin for 3 trials under `--permission-mode bypassPermissions` and 3 under `--permission-mode auto`. Record results in `tests/scenarios/README.md`.
- [ ] **Step 5: Fix failures.** Fix the skill, hook text or agent prompt (never the assertions) until every scenario passes 3 of 3 in bypassPermissions. Report the auto-mode results as measured, and update the README's auto-mode paragraph to match.
- [ ] **Step 6: Commit** with the message `pressure scenarios and results`.

### Task 11: Multi-harness support via everyharness

Decisions (2026-11-05):
- Claude Code keeps the real subagent and hooks.
- Skill-only harnesses that have a subagent tool: the model launches a generic subagent and puts all the toolsmith context in the call.
- Harnesses with no subagent tool: unsupported. The skill says it doesn't apply.

Facts about everyharness 1.0.1 (run as `node <everyharness checkout>/dist/cli.js`, Node >= 20):
- Skills are copied verbatim to every harness, with no per-harness skill content.
- `agents/` and `hooks/` are dropped with a warning everywhere except OpenCode, which translates agents to `.opencode/agent/`.
- `bin/` and `references/` are not copied, but harnesses load the checkout in place, so relative paths from a skill's directory work.
- `generate` never overwrites `README.md` outside its install markers, and never overwrites source paths.

**Files:**
- Create: `everyharness.yaml` (via `import`, then edit), plus the generated per-harness files and `.everyharness/manifest.json`
- Modify: `skills/writing-tools/SKILL.md`, `agents/toolsmith.md`, `README.md`, `tests/test-layout.sh`

**Design:**
- `bootstrap: generate`, so non-Claude harnesses learn about writing-tools without our hooks. Set `harnesses.claude-code.hooks: own` so our `hooks/hooks.json` stays the Claude Code wiring. Set `marketplace.source: local`, so `.claude-plugin/marketplace.json` exists for a local marketplace install.
- **SKILL.md branches on what the agent has:**
  1. **The Agent tool offers `toolsmith:toolsmith`.** This is the current Claude Code path, unchanged.
  2. **No toolsmith agent, but a general-purpose subagent tool exists.** Examples: Codex `spawn_agent` with `fork_turns: "none"`, Gemini `invoke_agent` generalist, Kimi/OpenCode/Cursor/Devin/Hermes/Muse equivalents. Name tools only where verified; otherwise say "your harness's subagent tool".
     - Find the catalog by running `<this skill's directory>/../../bin/toolsmith-repo locate --project "$PWD"` (read-only), because no hook injected the paths.
     - To brief the toolsmith, read `../../agents/toolsmith.md` (body only), `../../references/authoring-standards.md` and `../../references/reply-format.md`. Put their full text, plus the absolute path of `toolsmith-repo`, plus the brief, into the subagent prompt. The subagent gets all context in the call and reads nothing from the plugin itself.
  3. **No subagent tool at all.** This skill doesn't apply; say so once to the human, then work normally.
- **agents/toolsmith.md must work when pasted into a generic subagent:**
  - If `toolsmith-repo` isn't on PATH, use the absolute path given in the brief.
  - If the reference files' text is already in the brief, use it instead of reading `${CLAUDE_PLUGIN_ROOT}/references/…`. The reference-Read failure rule applies only when the text is in neither place.
- OpenCode gets a translated toolsmith agent. Check that its generated agent file is sensible; tools restrictions are dropped there.
- Don't exclude any harness that has a subagent tool. Pi's is optional, so keep Pi; branch 3 covers it.

**Steps:**
- [ ] Run `import`, then edit `everyharness.yaml` as above. Run `generate`, then `validate` (exit 0). Commit the generated files.
- [ ] Update SKILL.md and agents/toolsmith.md as above. Pin the three branches and the two agent fallbacks in tests/test-layout.sh, keeping existing pins. Check that `tests/run` passes and `claude plugin validate .` passes.
- [ ] Run `everyharness test` if docker is available and the image can be pulled. Otherwise report it as not run, without pulling 15 GB unasked.
- [ ] If `codex` is installed and logged in, run one smoke trial: `codex exec` in a temp caller repo with TOOLSMITH_TEST_REPO set to a temp repo, using the log-trawl prompt and the plugin loaded per codex's install docs. Report what happened, PASS or FAIL. Skip it if loading the plugin into codex needs changes to the user's real codex config.
- [ ] Rerun the Claude Code `log-trawl` scenario once to confirm the SKILL.md changes didn't regress it.
- [ ] README: per-harness install docs (generated markers) and one paragraph on how the toolsmith works outside Claude Code.
