# Toolsmith plugin design

Date: 2026-11-05
Status: draft, revised after builder check and three adversarial reviews
(two rounds)

## Intent

Agents working in Claude Code constantly build small helper scripts:
log trawlers, data mungers, API wrappers, one-off converters. Today each
agent writes its own, saves it wherever it happens to be working, and
nobody ever finds it again. The same log parser gets rewritten session
after session.

The cause is the prompting, not laziness. The standing rule "write a
named, documented script instead of a one-liner" tells agents to write
scripts and says nothing about where they live or whether one already
exists. The answer is always a new file.

Toolsmith is a Claude Code plugin that redirects that instinct. A working
agent never writes a non-mission tool itself. It checks a shared catalog,
and when nothing fits it calls the toolsmith subagent, which owns a shared
tools repository and answers each request by adapting an existing tool or
writing a new one. Changes to existing tools also go through the
toolsmith.

It is general purpose and shareable in the same way superpowers is. It
must not depend on anything in one person's CLAUDE.md.

## Goals

- Working agents stop writing their own helper scripts.
- Tools accumulate in one place, each with a name, help text, and a
  catalog entry, so the next agent finds and reuses them.
- Using an existing tool is as cheap as one read-only command. Getting a
  new or changed tool is one subagent round trip.
- Installing the plugin is the whole setup. No edits to the user's
  CLAUDE.md required.

## Non-goals (day 1)

- Syncing the tools repo across machines. Local repo, local git.
- Enforcement hooks (PreToolUse blocking or warning on script writes).
  Context-injecting hooks are in scope; see below.
- Migrating existing scripts (`~/.local/bin`, scratch directories) into
  the repo.
- Serious test suites for tools. A tool is done when it runs and its help
  text is right.
- Publishing to a marketplace. Structure for it, don't do it.

## Anti-goals

- A toolsmith slow or chatty enough that agents prefer writing a heredoc.
  If a new tool takes more than one subagent round trip in the common
  case, the design has failed.
- A catalog that drifts from the repo. If the toolsmith can't trust the
  catalog it has to read every tool, and the cold-start cost kills it.
- Scope creep into mission work. The toolsmith builds tools, not
  features, and never touches the caller's real data.

## The line between tool and mission

Decision: anything that ships with the project is mission. The
project's scripts directory, its tests, its build glue, a checkpoint
script that lives in the project repo. The working agent writes those
itself, following the project's own rules.

An explicit instruction from the human wins. If the human says "write me a
script in scratch," the agent does that; the skill never argues with the
human.

Everything else is toolsmith territory: code that the agent would run
again or that is real logic, and is not part of the project's
deliverable. That includes code it would save to a file, and it also
includes multi-line scripts fed to an interpreter inline (heredocs,
`python3 -c`, `node -e`). Inline is fine for a single command line, or a
throwaway inspection snippet of at most five lines you won't run again;
`a && b` chains count as a single command line. The test is "would I run this again, or is
it real logic," not "did I save a file." Reviewers pointed out that the file test makes heredocs a
sanctioned escape hatch, which is the exact leak the anti-goal names.

Project-specific doesn't make it mission. A fixture generator, a
migration helper, or a data fix for one project's database is still
toolsmith territory if it doesn't ship. The toolsmith files it in that
project's catalog (see the tools repo below) and still writes it as a
reusable tool: `orders-repair --since <date> --dry-run`, not
`fix-acme-orders-nov`. Decision, round two: the toolsmith should
write more reusable tools, even within a project.

Scratch directories are for data and intermediate outputs only. No
executable code lives there. Claude's scratch directory is deleted on
reboot, so a script left there is lost, not just unfindable.

## Approaches considered

**1. Plugin subagent plus plugin skill (chosen).** The plugin ships an
`agents/toolsmith.md` subagent and a `writing-tools` skill for the
working agent. The toolsmith's own guidance lives with the agent. The
tools repo is separate and local. Working agents check the catalog
themselves and invoke the toolsmith through the normal Agent tool when
they need something built or changed.
Trade-off: the toolsmith starts cold every call, so the catalog and the
agent prompt have to carry everything it needs.

**2. Headless Claude run inside the tools repo.** `writing-tools` tells
the agent to shell out to `claude -p` with the tools repo as cwd, and the
toolsmith's rules live in that repo's CLAUDE.md. Rejected: a separate
process, stdout-only results, no Agent tool integration, and it depends
on a repo checkout with a CLAUDE.md in it, which can't ship as a plugin.

**3. Skill without a subagent.** `writing-tools` does the toolsmith work
inline in the working agent. Rejected: burns the mission agent's context
on tool-building and loses the separation between mission work and tool-building.

Approach 1 was chosen, partly by ruling out 2 with the "shareable like
superpowers" constraint.

## Decided design

### Plugin layout

Standard Claude Code plugin, modelled on superpowers:

```
toolsmith/
  .claude-plugin/plugin.json
  agents/
    toolsmith.md                  # the subagent; the ONLY file under agents/
  references/                     # read by the agent via ${CLAUDE_PLUGIN_ROOT}
    authoring-standards.md
    reply-format.md
  bin/
    toolsmith-repo                # all deterministic repo plumbing (see below)
  skills/
    writing-tools/SKILL.md        # the only skill; for working agents
  hooks/hooks.json
  hooks/run-hook.cmd              # copied from superpowers
  hooks/inject                    # takes the event name as an argument
  tests/                          # shell tests for bin/ and hooks/
  docs/
  README.md
```

Nothing but `toolsmith.md` may live under `agents/`. Plugin `agents/`
directories are scanned recursively and every `.md` file loads as an
agent (a file at `agents/toolsmith/reply-format.md` would register as
`toolsmith:toolsmith:reply-format` with every tool), which would hand the
authoring recipe to every working agent. Round two caught this.

Only `writing-tools` ships as a skill. Earlier drafts had three
toolsmith-side skills; reviewers pointed out that every plugin skill is
listed in every agent's context, and an authoring skill in a working
agent's hands is exactly the recipe the plugin exists to withhold. The
toolsmith's guidance goes in its agent prompt and reference files
alongside it. File names above are my call.

### writing-tools (the working agent's skill)

Fires whenever an agent is about to write code that is not part of the
project's deliverable and that it would run again (see the line above).
It says: don't write it. Then:

1. **Check the catalogs yourself.** The hook injects the literal
   absolute paths of the global catalog and, once it exists, the current
   project's catalog, and the exact command to search them
   (`grep -s -i -E '<words>' /abs/CATALOG.md /abs/projects/<key>/CATALOG.md`),
   so the agent never builds a path itself. `-s` because the global
   catalog may not exist yet; no match from a missing file just means "no tools
   yet": go straight to step 2. If a tool fits, run its `--help` and use it. This is a change from the first draft, where
   every lookup went through the subagent. Reviewers made the case that a
   cold subagent start to return one line the agent could grep is the
   most expensive lookup available, and cheapness is the stated reason
   agents won't route around the rule. This means the
   working agent does the "existing tool" case itself; the toolsmith
   handles new and changed.
2. **Otherwise call the toolsmith** with a brief:
   - what the tool must do, in one or two sentences
   - inputs and outputs (files, stdin/stdout, formats)
   - an example invocation the agent wishes it could run
   - the closest existing tool from the catalog, if any
3. **Act on the reply.** The reply (format below) gives an absolute
   command line. If the reply says the tool mutates or sends anything,
   run it with `--dry-run` first.
4. **Tell the human, briefly.** One line in the agent's own words naming
   the tool it used or got built, from the reply's `catalog:` line. On
   first run, pass on the reply's note that a tools repo was created and
   where.

The skill also tells any agent that dispatches subagents to put a
one-line toolsmith pointer in each brief. An agent with no Agent tool
(depth limit, or a `tools:` allowlist without Agent) does not write the
tool itself: it returns the brief to its parent as part of its result,
marked as a toolsmith request, and works around the gap. Round one had
these agents write into the tools repo directly; round two showed that
bypasses the lock, the commit, and the standards, and is common rather
than rare.

This skill replaces the "write a script instead of a one-liner"
instruction for people who have one. Same instinct, pointed at the
catalog and the toolsmith instead of a new file.

### Hooks

Two context-injecting hooks run one script, `hooks/inject <EventName>`.
It injects the same few lines: what counts as a tool, the literal
catalog path and grep command, call the toolsmith, never write one
yourself.

- **SessionStart** (matcher `startup|clear|compact`), as superpowers does.
  Reaches the main agent.
- **SubagentStart**, matcher `.*`. Reaches every dispatched subagent,
  which is where implementers write helper scripts.

The script takes the event name as an argument and emits it as
`hookSpecificOutput.hookEventName`. Superpowers' script hardcodes
`SessionStart`, and Claude Code 2.1.318 rejects output whose event name
doesn't match the event that ran ("Hook returned incorrect event name"),
so a straight copy would silently inject nothing into subagents.

The toolsmith exemption happens in the script, not the matcher: matchers
can only include, and a plugin agent's `agent_type` is
`toolsmith:toolsmith`, not `toolsmith`. The script reads the hook's stdin
JSON and exits with no output when `agent_type` is `toolsmith:toolsmith`.

The script resolves both catalog paths read-only (it never creates the
repo or a project directory) and injects them as literal absolute paths.
The project key comes from the repo of the hook input's `cwd`, by its
shared git dir (`git rev-parse --git-common-dir`), so every worktree and
subdirectory of one repo shares a project catalog. Outside a git repo
there is no project catalog and only the global one is injected. Hooks
see the real
environment; agents building `$HOME`-based paths themselves is how round
two found two different readings of the location.

An optional AGENTS.md/CLAUDE.md snippet is documented in the README for
harnesses without hooks. It is worded conditionally ("if a toolsmith
agent is available…") so it doesn't send agents to a missing agent after
the plugin is uninstalled or disabled for a project. Because CLAUDE.md is
loaded into subagents, that snippet also reaches subagents.

### The toolsmith subagent

`agents/toolsmith.md` frontmatter, specified because wrong guesses here
silently disable or misbehave:

```yaml
name: toolsmith
description: <when to call; written for the Agent tool's chooser>
model: inherit            # session's model, not CLAUDE_CODE_SUBAGENT_MODEL
omitClaudeMd: true        # see below
tools: Bash, Read, Write, Edit, Glob, Grep   # no Agent: no recursion
```

`omitClaudeMd` requires Claude Code v2.1.271 or later; older versions
ignore it silently, so the README states that as the minimum version.
It matters more than it looks. Custom subagents load the
user's and project's CLAUDE.md by default. A user's CLAUDE.md may well
hand the toolsmith "follow TDD", "create a WIP branch", "ask how to
handle uncommitted changes", and "ask questions one at a time," each of
which contradicts the toolsmith's rules below. Even without such rules
it would hand it the mission project's conventions for a repo that isn't
the project. The agent prompt restates the few rules the toolsmith
needs.

The toolsmith runs with the caller's cwd, which is the mission project,
and neither `cd` nor shell variables persist across Bash calls. So the
toolsmith never runs git itself and never touches the tools repo with
raw shell. All repo plumbing goes through `toolsmith-repo`, which ships
in the plugin's `bin/` (on the Bash tool's PATH while the plugin is
enabled) and resolves the repo path internally on every call. Round two
showed the alternative fails concretely: `git -C "$TOOLS"` with `$TOOLS`
unset in a later call is `git -C ""`, which is the cwd, which is the
user's project.

### toolsmith-repo (deterministic plumbing)

Everything that has one right answer lives in this script, not in agent
prose. It is written test-first with shell tests in `tests/`, which also
squares the plugin with test-first rules for the implementers who
build it. Subcommands:

Every subcommand except `path` takes an optional `--project <dir>`. With
it, the command works on that project's scope (`projects/<key>/bin/` and
its `CATALOG.md`); without it, the global scope.

- `toolsmith-repo path [--project <dir>]` prints the canonical tools repo
  path, creating and initialising it on first run (cases below), and
  with `--project` also prints the project key and scope directory.
  Read-only after the first run; a project scope directory is created
  lazily by the first `install` into it.
- `toolsmith-repo stage <name>` copies the scope's `bin/<name>` (if it
  exists) into a fresh staging directory under the toolsmith's temp
  space, prints the staged path and the base revision. The toolsmith
  edits the staged copy with Write/Edit and verifies it there.
- `toolsmith-repo install <staged-file> <name> --base <rev> -m <msg>`
  takes the lock, checks the scope's `bin/<name>` is still at `<rev>` (or
  still absent for a new tool), copies the file in, `chmod +x`,
  regenerates that scope's `CATALOG.md`, commits exactly those paths
  (`git commit -- <bin/name> <CATALOG.md> [<PROJECT>]`), releases the
  lock, and prints the tool's catalog line. If the base moved, it exits
  non-zero with a clear message; the toolsmith re-stages and retries
  once.
- `toolsmith-repo move <name> --to global|--project <dir>` promotes a
  project tool to global (or the reverse) in one locked commit, when the
  toolsmith notices a project tool is useful elsewhere.
- `toolsmith-repo catalog` regenerates the scope's catalog and reports any
  untracked or uncommitted files in its `bin/`, which `install` then
  adopts into its commit.

Design choices inside it:

- **Location.** `~/.local/share/toolsmith/tools`. No environment
  override: anyone who wants it elsewhere symlinks it.
  Round two found `TOOLSMITH_HOME` read two ways (parent dir versus the
  repo itself), and nobody needs it on day 1.
  Exception, decided during implementation: a test-only
  `TOOLSMITH_TEST_REPO` variable overrides the location so pressure
  scenarios can run with the real login (a temp `HOME` is not logged
  in) without touching the real tools repo. It is documented as
  test-only.
- **First run, in this order, never with `rm`:** create
  `~/.local/share/toolsmith/` if missing. If the path is a dangling
  symlink, resolve its target against the symlink's own directory (not
  the cwd; `readlink` returns relative targets as-is) and create that.
  If the path doesn't exist, create it. Only then canonicalise with
  `realpath`, which fails on missing paths on macOS. Then: not a git
  repo means `git init`, commit what's there plus README and an empty
  catalog. Never replace the symlink.
- **Git identity.** If no identity is configured, set a repo-local one
  (`git config user.name toolsmith`, `user.email toolsmith@localhost`)
  once at init, and `path` reports that it did so.
- **Branch.** Commits go to the repo's current branch; `install` refuses
  if the repo is mid-rebase or mid-merge, and says so.
- **Locking.** `mkdir`-based lock directory in the repo, with the
  holder's PID inside and stale-lock detection, because `flock` is not on
  stock macOS and a lock can't be held across
  separate Bash calls anyway. The lock covers only `install`, which is
  one process. Concurrency safety comes from the base-revision check,
  not from holding a lock while the agent thinks. Ignored via
  `.git/info/exclude`.
- **Prerequisites.** If `git` (or the macOS Command Line Tools stub) is
  missing, `path` exits with an install hint, and the toolsmith replies
  `tool: none` with that note.

### The toolsmith's procedure

On every invocation, in order:

1. `toolsmith-repo path --project <caller's project root>`, then read
   the global and project catalogs. Decide: existing tool needs a
   change, or new tool. (The caller already checked for an exact fit;
   the toolsmith checks again because the caller's grep may have missed
   a near match.)
   Decide the scope: global unless the tool only makes sense for this
   project (its schema, its API, its file layout). Either way, write it
   parameterized and reusable, not hardcoded to today's case.
2. `toolsmith-repo stage <name>`; write or edit the staged copy.
3. Verify the staged copy (below).
4. `toolsmith-repo install …`.
5. **Reply** in the fixed format.

### Verification and side effects

- `--help` runs and reads right.
- If the brief's example invocation is read-only against the caller's
  files, run it.
- If the tool mutates, deletes, or sends anything, it must implement
  `--dry-run`. The toolsmith first proves the dry-run path on a fixture
  in its own temp directory: the fixture is unchanged afterwards and
  nothing was sent. Only after that may it dry-run against the real
  target. A dry-run flag written seconds ago has never run, so trusting
  it against real data first is how an untested guard sends a real
  email. It never performs the mutating action on the caller's data. The
  reply says the tool mutates and tells the caller to dry-run first.

No test suite. A tool is done when it runs and its help text is right.

### Reply format

Fixed shape so the caller can act without parsing prose:

```
tool: /abs/path/to/bin/name
catalog: <the tool's catalog line, for the caller to quote to the human>
status: new | changed | existing
mutates: yes | no
verified: ran example | dry-run only | help only
assumed: <any gap in the brief the toolsmith filled, or "nothing">
note: <optional: breaking change, repo created at X, fallback identity, etc.>
```

The toolsmith never asks the caller a question. If the brief is thin, it
makes the most reasonable choice and names it under `assumed`. If it
genuinely cannot proceed, it replies with `tool: none` and `note:` saying
what it needs; the caller then re-briefs. This settles what the first
draft left to the builder, because an "ask once" path is a second cold
start and violates the one-round-trip anti-goal.

### The tools repo

```
tools/
  README.md         # what this repo is, how tools get here
  CATALOG.md        # generated; global tools, one line per tool
  bin/              # one executable per global tool
  projects/
    <key>/
      PROJECT       # the project's root path, for humans and for move
      CATALOG.md    # generated; this project's tools
      bin/
```

The project key is the basename of the project's root plus a short hash
of its canonical path (`my-app-3f9a2c`): readable, and two
separate clones both called `app` don't collide. The root is the main
worktree, found from the repo's shared git dir (`git rev-parse
--git-common-dir`), so every worktree and subdirectory of one repo
shares a key. Moving or recloning a project gives it a new key;
re-keying is a later problem.

**The catalog is generated, not hand-edited.** Each tool carries a
header line within its first five lines, behind whatever line-comment
prefix its language uses (`#`, `//`, `--`):

```
# toolsmith-v1: <one-line purpose and when to use it>
```

The regex is anchored to that prefix and the versioned marker, and only
the first five lines are searched, so a tool's help text quoting the
marker doesn't match. Five lines rather than "line 2" because Node
rejects anything but a hashbang on line 1 and Python needs room for an
encoding cookie. Each catalog line is built from the absolute file path
plus the purpose text, never from a self-declared name, so a renamed or
`.py`-suffixed tool can't get a catalog entry that points nowhere. The
`-v1` lets a later plugin release change the format and still read old
tools. Tools must be text scripts; a language with no line comment, or
a compiled binary, is out for day 1.

`toolsmith-repo install` regenerates the affected scope's catalog on
every change, so a lost catalog write is recoverable. This is the concrete answer to the
catalog-drift anti-goal.

Tools are invoked by absolute path. Adding `bin/` to PATH is documented
as optional setup; the plugin never assumes it.

### Tool standards (authoring-standards.md)

The script rules, written generically:

- A tool has a name that says what it does in the domain.
- One of the first five lines is the catalog header above.
- `--help` explains when to use it and why, not just the flags.
- Errors are reported for an agent reader: what went wrong and what to
  try, on stderr, non-zero exit.
- Output is managed for context: show what the caller needs. Overflow
  goes to a file under `${TMPDIR:-/tmp}/toolsmith-$(id -u)/<tool>/` (the
  UID keeps users apart on Linux, where `TMPDIR` is usually unset) unless the
  caller passes `--out`, and the tool prints the path it wrote. Tools
  never drop files into the caller's cwd uninvited.
- Anything that mutates, deletes, or sends implements `--dry-run`.
- Prefer one tool with options over near-duplicates. When a brief is
  close to an existing tool, extend it.
- Changes are additive by default. A renamed flag keeps the old name as
  an alias. A breaking change is allowed but must be named in the reply
  `note` and the commit message, because other live sessions on the
  machine may hold the old command line.

Language is the toolsmith's choice per tool, within the header rule.
Shell for small glue, Python for anything with real parsing. Each tool
must run with what's already on the machine; declaring dependencies is a
later problem. On a fresh Mac `python3` is a stub until the Command Line
Tools are installed; the README lists that as a prerequisite.

### Permissions

Plugins can't ship permission allowlist entries. What each mode does to
a toolsmith call, per the current permission docs:

- `bypassPermissions`: no prompts.
- `auto`: unverified. Auto mode only allows local file operations in the
  working directory by default, and its classifier may judge writing
  executables and committing under `~/.local/share` as beyond the
  user's request. After three blocks in a row it falls back to
  prompting. A pressure scenario under `--permission-mode auto` settles
  this before the README claims anything.
- `acceptEdits`: covers file edits inside the working directory and
  `additionalDirectories` only. The tools repo is outside the project by
  design, and `chmod`, running the tool, `git add`, `git commit` are
  Bash, so they prompt.
- `default`: everything above prompts, and the working agent gets a
  fresh prompt the first time it runs each new `bin/` tool.

The README documents an optional settings addition for people who want
default or acceptEdits mode to be quiet:

- `permissions.additionalDirectories` containing the tools repo path
  (real path, not the symlink), which covers reads and edits there.
- A `Bash(toolsmith-repo *)` allow rule. Since all writes, `chmod`, and
  git go through that one command, this replaces round one's
  `git -C` and machine-wide `chmod` rules. Round two showed the `git -C`
  rule was never scoped anyway: a second `-C` later in the same command
  silently retargets git.

The "no config edits" goal means none are required for the plugin to
direct agents. A quiet default-mode experience is opt-in.

The plugin does not ship a PreToolUse hook that approves its own
commands, even though plugin hooks can skip prompts. Decision,
round two: a plugin quietly granting itself permissions is the wrong
default; the allow rule stays opt-in in the README.

## Constraints

- Must work as an ordinary Claude Code plugin installed from a
  marketplace, with no edits to the user's config beyond installing it.
- No enforcement hooks. Context-injecting hooks only.
- Local repo, local git. No network.
- Light verification of tools. The plugin itself is verified properly:
  - `toolsmith-repo` is built test-first with shell tests covering:
    first run (missing path, missing parent, dangling relative symlink,
    non-git dir, no git identity), two `install`s racing on the same
    tool, base-revision conflict, project key derivation (same basename
    in two paths, path outside any git repo), project install and
    `move` between scopes, catalog regeneration across `#` and
    `//` headers and a header-quoting help text, and adoption of
    untracked `bin/` files.
  - `hooks/inject` is tested for both events with real stdin JSON:
    correct `hookEventName` each time, no output for
    `agent_type: toolsmith:toolsmith`, literal global catalog path
    present, project catalog path present inside a git repo once that
    catalog exists, and absent outside one or before it exists.
  - `claude plugin validate` passes, and a loaded session lists exactly
    one toolsmith agent.
  - Baseline-versus-with-skill pressure scenarios for `writing-tools`,
    run in isolation: a temp caller repo, a temp `HOME` (so the tools
    repo is a temp one, never the real tools repo), the plugin
    loaded with `--plugin-dir` from the working tree, and an explicit
    `--permission-mode`. Assertions read the session JSONL, including
    subagent transcripts, not stdout: the caller's HEAD and status are
    unchanged and the tools repo gained exactly the expected commit.
    A denied write must fail the scenario, not pass it vacuously. Each
    scenario runs several times, since the failures are probabilistic.
    At least one runs as a dispatched subagent and one under
    `--permission-mode auto`.
- Match superpowers' conventions where they exist (hook wrapper, skill
  frontmatter, plugin.json) so the two feel like one family.

## Left to the builder

- Exact wording of the skill, the agent prompt, the reference files, and
  the injected hook text.
- Stale-lock timeout and the retry count on a base-revision conflict.
- README content and the optional AGENTS.md snippet.
- An uninstall note in the README: remove the optional snippet, and
  restore any "write a script" guidance it replaced in the user's
  CLAUDE.md.
