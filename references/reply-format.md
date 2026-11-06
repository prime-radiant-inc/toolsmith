# Toolsmith reply format

The toolsmith's final message is this block and nothing else, one field
per line, in this order. The caller acts on it without parsing prose.

```
tool: /abs/path/to/bin/name
catalog: <the tool's catalog line, for the caller to quote to the human>
status: new | changed | existing
mutates: yes | no
verified: ran example | dry-run only | help only
assumed: <any gap in the brief the toolsmith filled, or "nothing">
note: <optional: breaking change, repo created at X, fallback identity, etc.>
```

## Fields

- `tool:` the absolute path of the installed tool in the tools repo. The
  caller runs it by this path. Never a staged copy under the temp
  directory.
- `catalog:` the tool's catalog line exactly as `toolsmith-repo install`
  printed it after `catalog=` (or as it appears in the catalog, for an
  existing tool).
- `status:` `new` for a tool that didn't exist, `changed` for an existing
  tool you edited, `existing` for a tool that already did the job
  unchanged.
- `mutates:` `yes` if the tool changes, deletes, or sends anything, even
  only with some flags. Then it has `--dry-run`.
- `verified:` the strongest check that ran.
  - `ran example`: you ran the brief's example invocation, which was
    read-only, against the caller's files, and it did the job.
  - `dry-run only`: the tool mutates; you proved `--dry-run` on a
    fixture, and perhaps dry-ran it against the real target. The
    mutating action itself never ran.
  - `help only`: only `--help` ran, because there was no example, or the
    example couldn't run safely or at all here. Say why under `note`.
- `assumed:` every gap in the brief you filled with your own choice (a
  flag name, a default, an output format, the scope), so the caller can
  re-brief if a guess is wrong. `nothing` if the brief covered it all.
- `note:` leave the line out when there is nothing to say. Otherwise one
  line, with items separated by `; `. Always include:
  - every `note=` line `toolsmith-repo` printed (the tools repo was
    created at a path, a fallback git identity was set, and so on);
  - any breaking change, and the old command line it breaks;
  - any `adopted=` files that `install` committed alongside the tool;
  - the scope, if you put the tool in a project scope, or fell back to
    global because the caller isn't in a git repo.

## `tool: none`

The toolsmith never asks the caller a question. A thin brief gets the
most reasonable choice, named under `assumed`. When it genuinely cannot
proceed (the brief is mission work, a prerequisite is missing, the tools
repo is mid-rebase, the lock never came free), the reply is exactly:

```
tool: none
note: <what went wrong or what is missing, and what the caller or human should do next>
```

The caller then re-briefs, or passes the note to the human.

## For the caller

- If `mutates: yes`, run the tool with `--dry-run` first and read what it
  says it will do.
- Tell the human in one line which tool you used or got built, quoting
  the `catalog:` line. On first run, pass on any `note` saying the tools
  repo was created and where.

## Example

```
tool: /Users/me/.local/share/toolsmith/tools/bin/log-errors-by-host
catalog: - /Users/me/.local/share/toolsmith/tools/bin/log-errors-by-host -- Group log lines by host and count errors; use to find a noisy host.
status: new
mutates: no
verified: ran example
assumed: hosts are the third whitespace-separated field unless --host-field says otherwise
note: created tools repo at /Users/me/.local/share/toolsmith/tools
```
