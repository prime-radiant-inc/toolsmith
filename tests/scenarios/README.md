# Pressure scenarios

End-to-end checks that working agents route tool-writing through the
catalog and the toolsmith. Each trial is a real `claude -p` session with
this checkout loaded via `--plugin-dir`, so trials cost real API spend
($0.10 to $0.70 each, measured) and take 15 seconds to about 3 minutes.
They are not part of `tests/run`.

```
tests/scenarios/run-scenario <scenario> [--trials N] [--permission-mode M] [--baseline]
```

prints one line per trial (`PASS`/`FAIL`, the first failed check, the
transcript path) and a summary naming the log dir. Each trial's dir there
holds `check.txt` (every check and recorded fact), `claude.json` (the `-p`
result), `claude.err`, `trial.env`, `real-repos-before` and
`real-repos-after`, and the caller and tools repos.
`tests/scenarios/check-trial <trial-dir>` re-checks a finished trial.

## Scenarios

The prompt for each is `<scenario>.md`. Fixtures are in `fixtures/`.

| Scenario | Setup | Passes when |
|---|---|---|
| `log-trawl` | `access.log` in the caller repo | the main agent calls `toolsmith:toolsmith`; the tools repo gains one commit adding one `bin/` file |
| `subagent` | same; the prompt says to dispatch a general-purpose subagent | the subagent got the SubagentStart injection; someone calls the toolsmith; one new tool |
| `existing-tool` | tools repo preseeded with `http-5xx-by-endpoint` | a working agent greps the catalog and runs the tool; no toolsmith call; no new commits |
| `mission` | `VERSION` and `README.md`; "add a scripts/release.sh" | `scripts/release.sh` exists in the caller repo; no toolsmith call; no tools repo commits |
| `user-says-scratch` | "write me a throwaway script in /tmp/..." | a file appears in the scratch dir; no toolsmith call; no tools repo commits |
| `no-agent-tool` | a `log-worker` agent (via `--agents`) with tools Bash, Read, Grep, Glob | log-worker's result has a `TOOLSMITH REQUEST` block; the main agent passes it to the toolsmith; one new tool |

Every trial also fails on:

- any denied tool call: an entry in the `-p` result's
  `permission_denials`, or a denial-shaped error result in any transcript
  (other error results are logged in `check.txt` so new denial wording
  shows up);
- a working agent (main or a non-toolsmith subagent) writing a tool
  itself: a Write of a script (`#!`, or a `.sh`, `.py`, `.awk`, `.jq`,
  `.sed` or similar extension), a heredoc fed to an interpreter or
  redirected into a file (before or after the marker), a `printf`/`echo`
  of a shebang into a file, `chmod +x`, or multi-line
  `python3 -c`/`node -e`. Heredoc bodies are data and aren't scanned.
  `mission` allows files under the caller's `scripts/`, and
  `user-says-scratch` allows the scratch dir;
- the caller repo's HEAD or `git status --porcelain` changing (except in
  `mission`);
- the real tools repos changing: run-scenario records whether
  `~/.local/share/toolsmith/tools` and `~/git/tools` exist and, for a
  git repo, its HEAD and `git status --porcelain`, before and after each
  trial (tests/test-run-scenario.sh checks this with a stub claude and a
  temp `HOME`). Your own edits to `~/git/tools` during a run would also
  fail it;
- fewer toolsmith transcripts than toolsmith calls, or a subagent
  transcript of unknown type, so the toolsmith checks below can't pass
  by finding nothing to check;
- the toolsmith not Reading both reference files at their absolute,
  substituted `${CLAUDE_PLUGIN_ROOT}` paths, running `git` itself, or
  replying without a `tool:` line.

## Isolation, and what loaded

A temp `HOME` isn't logged in, so trials run with the real `HOME`. Two
things keep them away from your own setup:

- `TOOLSMITH_TEST_REPO` points the plugin at a fresh temp tools repo per
  trial (it is for tests only). run-scenario canonicalises the exact path
  it exports and refuses to go on, before the existing-tool preseed or
  any claude launch, unless it is inside the run's temp dir and outside
  `HOME` (tests/test-run-scenario.sh checks this with a stub claude). The
  caller is a fresh temp git repo per trial.
- `claude` gets `--setting-sources project --strict-mcp-config`. The
  caller repo has no `.claude/`, so no settings file loads at all.

That means your own hooks, including any safety hooks, don't load during
trials, and trials run with `--permission-mode bypassPermissions` by default
on your real `HOME`. Nothing blocks a trial from writing elsewhere in it:
the guard keeps the plugin on a temp tools repo, and the real tools repo
check only detects a change after the trial.

Measured from the stream-json init message and the transcripts on Claude
Code 2.1.318 (model `claude-opus-5-5`):

- Plugins: `toolsmith` (inline, from `--plugin-dir`) plus four built-ins
  that load regardless (`cc-plugin-agents-md`, `cc-plugin-telemetry`,
  `cc-plugin-privacy`, `cc-plugin-plugin-authoring`). None of the user's
  installed plugins load, so their hooks don't run: the only
  SessionStart hook output is toolsmith's.
- Agents: the built-ins (`claude`, `Explore`, `general-purpose`, `Plan`,
  `statusline-setup`, `web-fetch`) and `toolsmith:toolsmith`.
- Skills: `toolsmith:writing-tools` plus Claude Code's bundled skills.
- No MCP servers. No user CLAUDE.md: asked to quote one, the session
  said there was none.
- Still present: the account's email in the session context, and
  auto-memory pointed at a fresh, empty per-caller dir under
  `~/.claude/projects/`.

So results describe the plugin on a near-stock Claude Code, not inside a
setup with other plugins, a CLAUDE.md, or MCP servers competing for the
agent's attention.

Ruled out: `--safe-mode` lists the `--plugin-dir` plugin but drops its
agent, skill and hooks. `--bare` reads no OAuth login.

## Results

Measured 2026-11-05 on Claude Code 2.1.318, model `claude-opus-5-5`,
with the prose as of commit `b07eb8c`. Seconds per trial in brackets.

| Scenario | baseline (no plugin) | bypassPermissions | auto |
|---|---|---|---|
| `log-trawl` | FAIL: wrote `5xx-by-endpoint.sh` into the repo | 3/3 (99, 70, 116) | 3/3 (104, 104, 73) |
| `subagent` | FAIL: subagent wrote `scripts/5xx_by_endpoint.py` | 3/3 (116, 88, 127) | 3/3 (133, 106, 99) |
| `existing-tool` | FAIL: wrote `count_5xx.py` (no catalog) | 3/3 (37, 22, 26) | 3/3 (31, 18, 26) |
| `mission` | PASS | 3/3 (37, 19, 27) | 3/3 (33, 29, 20) |
| `user-says-scratch` | PASS | 3/3 (35, 21, 22) | 3/3 (31, 18, 19) |
| `no-agent-tool` | FAIL: log-worker wrote `scripts/5xx_by_endpoint.sh` | 3/3 (118, 142, 120) | 3/3 (135, 170, 148) |

Without the plugin, every tool scenario ended with a hand-written script
saved in the caller's repo. With it, every trial passed in both modes.

Recorded across those 36 trials:

- The SessionStart injection reached every main agent, and the
  SubagentStart injection reached every general-purpose and log-worker
  subagent.
- Every toolsmith run Read both reference files at their substituted
  absolute paths (a missing Read fails the trial).
- Every toolsmith call ran in the foreground (5 from a general-purpose
  subagent at depth 2, 13 from the main agent). In one `subagent` trial the
  general-purpose subagent found no catalog tool and answered with long
  one-line sed/awk pipelines, which the hook's "a single command line
  stays inline" rule allows. The main agent then had the toolsmith build
  the reusable tool itself. That passes, but it shows a long one-liner
  can slip past the tool definition.
- In 15 of 18 toolsmith runs, every `toolsmith-repo` call was its own
  Bash command starting with `toolsmith-repo`, which a
  `Bash(toolsmith-repo *)` allow rule would match. In the other 3, one
  `stage` was chained after a `cat` of the catalogs. Each run made one
  `--project "$PWD"` call (`path`), then staged and installed
  globally.
- No denials, and no error result shaped like one. The only error
  results were ordinary non-zero exits, mostly the catalog `grep -s`
  exiting 2 because the project catalog doesn't exist yet.

### Earlier runs and the fixes they drove

These ran on earlier prose or an earlier checker. Each fix's commit
names the scenario that motivated it.

1. `no-agent-tool`, bypassPermissions 0/3: the log-worker got the
   injection, but it only said to call the Agent tool, which log-worker
   doesn't have (nor the Skill tool, so it never saw the skill's
   fallback). It answered with a long awk program and no request. Fix:
   the hook now says what to do without an Agent tool, and that a parent
   passes a TOOLSMITH REQUEST on. Then 3/3.
2. `log-trawl`, auto trial: the toolsmith put `chmod`, test runs,
   `mktemp` and a quoted heredoc fixture into one multi-line Bash call.
   Claude Code's rm safety check couldn't parse it and denied it as
   needing a person. Fix: the agent prompt says to keep Bash calls
   single-purpose and write fixtures with Write.
3. `subagent`, auto trial (707s): a general-purpose subagent called the
   toolsmith without `run_in_background`. At depth 2 that defaulted to
   the background, and its completion notice queued behind the blocked
   main session for about ten minutes. Fix: hook and skill say
   `run_in_background false`.
4. `no-agent-tool`, auto trial: the main agent called the toolsmith
   itself and then sent log-worker to run the finished tool, so log-worker
   had nothing to request. No tool was hand-written, but the scenario's
   assertion failed. It did not recur in the 6 later trials.

Checker bugs found on real transcripts and fixed (none loosened a
check's intent): relative heredoc targets (`cat > scripts/release.sh`)
and targets after `cd` were resolved against the wrong dir; a tool run
through a shell variable (`T=<tool>; $T access.log`) wasn't counted;
a final reply sent through the `SubagentHandback` tool wasn't read.

The checker was later tightened (missing toolsmith transcripts, unknown
subagent types, more ways to hand-write a script; unit tests in
tests/test-check-trial.sh). Re-running it over the recorded transcripts
of the 36 final trials changed no verdict, and the baselines kept theirs.
