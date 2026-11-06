---
name: writing-tools
description: Use when about to write a script, a heredoc, or a multi-line python3 -c or node -e, or to save code to a scratch directory, that isn't part of the project's deliverable. Covers helper tools such as log trawlers, data converters, API wrappers, fixture generators, and one-off data fixes, and dispatching subagents that might write them.
---

# Writing tools

Don't write helper tools yourself. Find one in the catalog, or have the
toolsmith subagent build it. Tools then live in one shared repo with a
name, help text and a catalog entry, so the next agent finds them instead
of writing another script nobody sees again.

## Tool or mission?

- **Mission:** anything that ships with the project. Its scripts
  directory, its tests, its build glue, code that lives in its repo. Write
  that yourself, following the project's rules.
- **Tool:** code that you would run again or that is real logic, and is
  not part of the project's deliverable. A saved script, and also a
  multi-line heredoc, `python3 -c` or `node -e`. Project-specific
  doesn't make it mission: a fixture generator, migration helper or data
  fix for this project's database goes to the toolsmith if it doesn't
  ship.
- **Inline is fine for:** a single command line, or a throwaway
  inspection snippet of at most five lines you won't run again.
  `a && b | c` counts as a single command line.

The test is "would I run this again, or is it real logic," not "did I
save a file."

An explicit instruction from the human wins. If they say "write me a
script in scratch," do that.

Scratch directories hold data and intermediate output only, never code.
Claude's scratch directory is wiped on reboot, so a script left there is
lost.

| Thought | Reality |
|---|---|
| "It's just a quick heredoc" | More than five lines, or worth running twice, is a tool. |
| "It's only for this project" | Unshipped project code is still the toolsmith's. |
| "I'll stash it in /tmp or scratch" | Gone on reboot, and nobody can find it. |
| "Calling the toolsmith is slower" | One round trip, and the tool is reusable. |

## The steps

1. **Search the catalogs yourself.** Your session context normally has a
   "Toolsmith:" block with the exact `grep -s -i -E '<words>' ...` command
   and the literal catalog paths. Run it with a few words for what you
   need. Never build a catalog path yourself. No match, or a catalog that
   doesn't exist yet, means no tool: go to step 2. If a tool fits, run it
   with `--help`, then use it by its absolute path. If your context has
   no search command and no `toolsmith:toolsmith` agent, find the
   catalogs as "Without the toolsmith agent" below says. Otherwise skip
   to step 2 and let the toolsmith search.
2. **Otherwise call the toolsmith.** If your Agent tool offers
   `toolsmith:toolsmith`, use it with `subagent_type:
   "toolsmith:toolsmith"` and `run_in_background: false` (you need its
   reply before you can go on), and a brief of:
   - what the tool must do, in one or two sentences
   - inputs and outputs (files, stdin/stdout, formats)
   - an example invocation you wish you could run
   - the closest existing tool from the catalog, if any
   It never asks questions; a thin brief gets guesses.

   If you are the toolsmith yourself, this skill doesn't apply to you:
   follow your own instructions. If there is no toolsmith agent but you
   have a subagent tool, send the
   same brief to a general-purpose subagent as "Without the toolsmith
   agent" below says.

   If you have no subagent tool at all, this skill doesn't apply, unless
   you are a subagent working for a parent agent: then follow "If you
   have no Agent tool" below. Otherwise tell the human once that the
   toolsmith needs a subagent tool, then work normally.
3. **Act on the reply.** Run the tool by the absolute path on its `tool:`
   line. If `mutates: yes`, run it with `--dry-run` first and read what it
   says it will do. Check `assumed:`; if a guess is wrong, call the
   toolsmith again with a corrected brief. `tool: none` means it didn't
   build one, and its `note:` says why. If the note says it is mission
   work, write it in the project, following the project's rules.
   Otherwise re-brief, or pass the note to the human. Don't write the
   tool yourself instead.
4. **Tell the human, in one line,** which tool you used or got built,
   quoting the reply's `catalog:` line. If the `note:` says a tools repo
   was created, pass on where.

## Dispatching subagents

Put a one-line toolsmith pointer in every subagent brief, for example:
"Don't write helper scripts; search the tool catalog or call the
toolsmith:toolsmith agent (see the toolsmith:writing-tools skill)."

## If you have no Agent tool

Don't write the tool yourself, and don't write into the tools repo. Put
the brief in your result to your parent, marked as a toolsmith request:

```
TOOLSMITH REQUEST
do: <what the tool must do>
io: <inputs and outputs>
example: <invocation you wish you could run>
closest: <closest catalog tool, or none>
```

Then work around the gap with existing commands and finish what you can.
A parent that gets a toolsmith request calls the toolsmith with it.

## Without the toolsmith agent

Outside Claude Code there is no `toolsmith:toolsmith` agent and no hook,
so you find the catalogs and brief a general-purpose subagent yourself.
The paths below are relative to the directory this SKILL.md is in; make
each one absolute before you use it.

1. **Find the catalogs.** Run
   `<this skill's directory>/../../bin/toolsmith-repo locate --project "$PWD"`.
   It is read-only. It prints `global_catalog=` and, inside a git repo,
   `project_catalog=`; exit 8 only means there is no project scope. Search
   them with
   `grep -s -i -E '<words>' "<global_catalog>" "<project_catalog>"`
   and carry on as in step 1. If `locate` fails, let the toolsmith search.
2. **Build the subagent prompt.** Read `../../agents/toolsmith.md` (its
   body only: skip the frontmatter between the first two `---` lines),
   `../../references/authoring-standards.md` and
   `../../references/reply-format.md`. The prompt holds, in this order:
   - the agent file's body, in full
   - the absolute path of `toolsmith-repo`, as a line
     `toolsmith-repo: /absolute/path/to/bin/toolsmith-repo`
   - both reference files in full, each under its file name
   - your brief, as in step 2
   The subagent gets everything in this one prompt and reads nothing
   from the plugin itself.
3. **Launch the subagent with that prompt, in a fresh context, and wait
   for its reply.** Known subagent tools:
   - Codex: `spawn_agent` with `fork_turns: "none"`
   - Gemini CLI: `invoke_agent` with `agent_name: "generalist"`
   - Kimi Code: `Agent` with `subagent_type: "coder"`
   - Hermes: `delegate_task`; put the full prompt where its parameters
     take the task description
   - Muse: `subagent_spawn`
   - Devin CLI: `run_subagent` with the `subagent_general` profile
   - Pi: a subagent tool from the optional pi-subagents package, if
     installed
   - OpenCode, Cursor and others: your harness's subagent tool, with its
     general-purpose agent. If your agent list offers a `toolsmith`
     agent (the OpenCode files include one), you may use it instead; it
     still needs the same full prompt.

Then act on the reply as in steps 3 and 4.
