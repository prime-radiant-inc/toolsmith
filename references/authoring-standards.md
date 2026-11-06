# Tool standards

Every tool in the tools repo meets these. They are what make a tool worth
finding again: the next agent reads the catalog line, runs `--help`, and
uses the tool without reading its source.

## Name

- The name says what the tool does in the domain: `json-extract`,
  `orders-repair`, `log-errors-by-host`. Not how it works (`jq-wrapper`),
  not when it was written (`fix-nov`), not who asked (`acme-script`).
- `toolsmith-repo` accepts lowercase letters, digits, `.`, `_` and `-`,
  starting with a letter or digit.
- No language suffix (`.py`, `.sh`). The tool is invoked by name, and a
  suffix becomes a lie the day the tool is rewritten in another language.

## The catalog header

One of the first five lines is the catalog header: a line comment in the
tool's own language, then `toolsmith-v1:`, then one line saying what the
tool does and when to use it. The catalog is generated from these lines,
so a tool without one is invisible to every other agent, and
`toolsmith-repo install` refuses it (exit 7).

The exact shape: optional leading spaces, then `#`, `//` or `--`, then
optional spaces, then `toolsmith-v1:`, then the purpose text. Only the
first five lines count. Keep the purpose to one line; it is the whole
catalog entry.

Shell, `#` (bash, sh):

```bash
#!/usr/bin/env bash
# toolsmith-v1: Pull fields out of JSON lines; use for trawling structured logs.
```

Python, `#`, with room for an encoding cookie:

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# toolsmith-v1: Group log lines by host and count errors; use to find a noisy host.
```

Node, `//` (Node rejects anything but a hashbang on line 1, so the header
goes on line 2 or later):

```js
#!/usr/bin/env node
// toolsmith-v1: Diff two package-lock.json files by package; use when reviewing dependency bumps.
```

Lua, `--` (only where `lua` is already installed; check with
`command -v lua`):

```lua
#!/usr/bin/env lua
-- toolsmith-v1: Convert a TSV file to a Markdown table; use for pasting data into docs.
```

Tools are text scripts. A language with no line comment, or a compiled
binary, can't carry the header and is out.

## Help text

- `--help` and `-h` print help to stdout and exit 0.
- The help says when to use the tool and why, before the flags. An agent
  reading only the help must be able to tell whether this is the right
  tool.
- It lists every flag and argument, gives at least one example
  invocation, and says plainly whether the tool changes, deletes, or sends
  anything.

## Parameterized and reusable

Write every tool for the next caller, not just this one. That holds for
project-scoped tools too: write `orders-repair --since <date> --dry-run`,
not `fix-acme-orders-nov`.

- Paths, dates, IDs, hostnames, URLs and thresholds are arguments or
  flags, with sensible defaults where one exists. Nothing from today's
  brief is hardcoded.
- Read from files named on the command line or from stdin; write to
  stdout unless the output is large (below).

## Errors

Errors are written for an agent reader: say what went wrong and what to
try, on stderr, and exit non-zero.

```
json-extract: no field 'user.id' in line 14 of app.log. Run with --list-fields to see what's there.
```

## Output and context

- Show what the caller needs and no more. An agent pays for every line
  of output in its context.
- Overflow goes to a file under `${TMPDIR:-/tmp}/toolsmith-$(id -u)/<tool>/`
  unless the caller passes `--out <path>`. The tool prints the path it
  wrote, so the caller can read the rest if it needs to. The UID keeps
  users apart on Linux, where `TMPDIR` is usually unset.
- A tool never drops files into the caller's current directory
  uninvited.

## Side effects and --dry-run

Anything that mutates, deletes, or sends implements `--dry-run`. With it,
the tool prints exactly what it would do and does none of it: no file
written, no row changed, no request sent.

Prove the dry-run before trusting it. A `--dry-run` flag written seconds
ago has never run, and trusting it against real data first is how an
untested guard sends a real email. So, in this order:

1. Build a fixture in a fresh temp directory of your own
   (`mktemp -d "${TMPDIR:-/tmp}/toolsmith-$(id -u)/fixture.XXXXXX"`): a few
   sample files, a scratch SQLite database, a stub endpoint, whatever the
   tool acts on.
2. Run the tool with `--dry-run` against the fixture. Check that its
   output describes the change, that the fixture is byte-for-byte
   unchanged afterwards, and that nothing was sent.
3. Only then may you run `--dry-run` against the caller's real target.

Never run the mutating action itself on the caller's data. The caller
does that, after its own dry-run.

## One tool, extended

- Prefer one tool with options over near-duplicates. When a brief is
  close to an existing tool, extend that tool.
- Changes are additive by default. A renamed flag keeps the old name as
  an alias. Existing output formats stay the default; new formats go
  behind a flag.
- A breaking change is allowed, but name it in the reply's `note` and in
  the commit message. Other live sessions on this machine may be holding
  the old command line.

## Language

Your choice per tool, within the header rule. Shell for small glue,
Python for anything with real parsing.

- Each tool runs with what is already on the machine. Don't install
  packages and don't depend on anything outside the standard library.
- Before choosing Python, check that `python3 --version` works. On a
  fresh Mac, `python3` is a stub until the Command Line Tools are
  installed.
- Shell tools run under the system bash, which is 3.2 on macOS: no
  associative arrays, no `mapfile`/`readarray`, no `${var,,}`, no `|&`.

## Done

A tool is done when it runs and its help text is right. Don't write a
test suite for it.
