#!/usr/bin/env bash
# hooks/inject: the SessionStart and SubagentStart context-injection hook,
# fed real hook JSON on stdin.

. "$(dirname -- "$0")/lib.sh"

PLUGIN_ROOT=$(dirname -- "$T_TESTS_DIR")
HOOK="$PLUGIN_ROOT/hooks/inject"
WRAPPER="$PLUGIN_ROOT/hooks/run-hook.cmd"

# hook_exec <script> <stdin> <args...>: run a hook script under /bin/bash
# (3.2 on macOS) in a clean environment from $T_CWD, as Claude Code would.
# Sets OUT, ERR and RC, and leaves stdout in $OUT_FILE for the json helpers.
OUT_FILE="$T_ROOT/hook stdout"
hook_exec() {
    local script=$1 stdin=$2
    shift 2
    local in_file="$T_ROOT/hook stdin" err_file="$T_ROOT/hook stderr"
    printf '%s' "$stdin" >"$in_file"
    (
        cd -- "$T_CWD" || exit 125
        env -i PATH="$T_PATH" HOME="$T_HOME" GIT_CONFIG_GLOBAL="$T_GITCFG" \
            GIT_CONFIG_NOSYSTEM=1 TMPDIR="${TMPDIR:-/tmp}" \
            CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" ${T_EXTRA_ENV[@]+"${T_EXTRA_ENV[@]}"} \
            /bin/bash "$script" "$@" <"$in_file"
    ) >"$OUT_FILE" 2>"$err_file"
    RC=$?
    OUT=$(cat "$OUT_FILE")
    ERR=$(cat "$err_file")
}

# hook_run <event> <stdin>: run hooks/inject directly.
hook_run() {
    hook_exec "$HOOK" "$2" "$1"
}

# Test-only JSON parsing: plutil ships with macOS, python3 elsewhere. The
# hook itself never needs either. (plutil -lint only understands plists, so
# a conversion is what proves the file is valid JSON.)
#
# json_valid <file>: succeed if the file is one valid JSON document.
json_valid() {
    if [ -x /usr/bin/plutil ]; then
        /usr/bin/plutil -convert xml1 -o /dev/null "$1" 2>/dev/null
    else
        python3 -I -m json.tool "$1" >/dev/null 2>&1
    fi
}

# json_get <file> <dotted.key.path>: print a string value from a JSON file.
json_get() {
    if [ -x /usr/bin/plutil ]; then
        /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
    else
        python3 -I -c '
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    value = value[int(part)] if isinstance(value, list) else value[part]
print(value)
' "$1" "$2" 2>/dev/null
    fi
}

# json_escape <string>: the string's JSON form, without the quotes.
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

context() {
    json_get "$OUT_FILE" hookSpecificOutput.additionalContext
}

event_name() {
    json_get "$OUT_FILE" hookSpecificOutput.hookEventName
}

# The catalog search line the hook gives the agent, built independently.
grep_line() {
    local cmd="grep -s -i -E '<words>'" path
    for path in "$@"; do
        cmd="$cmd '$path'"
    done
    printf '%s' "$cmd"
}

# Expected global catalog path for the default repo location.
global_catalog() {
    printf '%s/.local/share/toolsmith/tools/CATALOG.md' "$(t_canonical "$T_HOME")"
}

# new_project <dir>: create a git repo at <dir> and set PROJECT_CATALOG to
# the catalog path toolsmith-repo locate gives for it.
new_project() {
    mkdir -p "$1"
    t_git init -q "$1"
    tr_run locate --project "$1"
    PROJECT_CATALOG=$(kv project_catalog)
}

no_local_dir() {
    [ -e "$T_HOME/.local" ] && echo yes || echo no
}

# make_project_catalog: create the project catalog new_project located, as
# the first project install would.
make_project_catalog() {
    mkdir -p "${PROJECT_CATALOG%/*}"
    : >"$PROJECT_CATALOG"
}

# assert_routing_context <desc>: the context tells the agent what a tool is,
# to call the toolsmith, never to write one itself, and where the skill is.
assert_routing_context() {
    local ctx
    ctx=$(context)
    assert_contains "$1: says what counts as a tool" "would run again" "$ctx"
    assert_contains "$1: real logic counts as a tool" "or that is real logic" "$ctx"
    assert_contains "$1: states the inline threshold" \
        "a single command line, or a throwaway inspection snippet of at most five lines you won't run again" "$ctx"
    assert_contains "$1: names the toolsmith subagent_type" 'subagent_type "toolsmith:toolsmith"' "$ctx"
    assert_contains "$1: says to wait for the toolsmith in the foreground" 'run_in_background false' "$ctx"
    assert_contains "$1: brief names the closest catalog tool" "the closest existing catalog tool, if any" "$ctx"
    assert_contains "$1: says never to write one yourself" "Never write" "$ctx"
    assert_contains "$1: points at the writing-tools skill" "writing-tools" "$ctx"
    assert_contains "$1: says what to do without an Agent tool" "No Agent tool" "$ctx"
    assert_contains "$1: names the request block for the parent" "TOOLSMITH REQUEST" "$ctx"
    assert_contains "$1: tells a parent to pass a request on" "pass it to the toolsmith" "$ctx"
    assert_eq "$1: one term for the concept (deliverable, not mission)" "" \
        "$(printf '%s\n' "$ctx" | grep -i 'mission')"
}

test_session_start() {
    new_env
    new_project "$T_HOME/proj"
    make_project_catalog
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_eq "hookEventName is SessionStart" SessionStart "$(event_name)"
    assert_contains "context has the global catalog path" "$(global_catalog)" "$(context)"
    assert_contains "context has the project catalog path" "$PROJECT_CATALOG" "$(context)"
    assert_contains "context has the grep command for both catalogs" \
        "$(grep_line "$(global_catalog)" "$PROJECT_CATALOG")" "$(context)"
    assert_contains "context says a missing catalog means no tools yet" "no tools yet" "$(context)"
    assert_routing_context "session start"
    assert_eq "context is under 15 lines" yes \
        "$( [ "$(context | wc -l)" -lt 15 ] && echo yes )"
    assert_eq "stderr is empty" "" "$ERR"
}

# The project catalog joins the grep line only once it exists; the global
# catalog is always there, since -s covers it before the first install.
test_project_catalog_absent() {
    new_env
    new_project "$T_HOME/proj"
    tr_run path
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "grep command has only the global catalog" \
        "$(grep_line "$(global_catalog)")"$'\n' "$(context)"
    assert_eq "no project catalog path" "" "$(context | grep 'projects/')"
    assert_routing_context "project catalog absent"
    assert_eq "stderr is empty" "" "$ERR"
}

test_subagent_start() {
    new_env
    new_project "$T_HOME/proj"
    make_project_catalog
    hook_run SubagentStart \
        "{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"general-purpose\",\"cwd\":\"$(json_escape "$T_HOME/proj")\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_eq "hookEventName is SubagentStart" SubagentStart "$(event_name)"
    assert_contains "context has the project catalog path" "$PROJECT_CATALOG" "$(context)"
    assert_routing_context "subagent start"
}

test_toolsmith_exempt() {
    new_env
    new_project "$T_HOME/proj"
    hook_run SubagentStart \
        "{\"hook_event_name\":\"SubagentStart\",\"agent_type\" : \"toolsmith:toolsmith\",\"cwd\":\"$(json_escape "$T_HOME/proj")\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is empty" "" "$OUT"
    assert_eq "stderr is empty" "" "$ERR"
}

test_outside_git() {
    new_env
    mkdir -p "$T_HOME/plain"
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/plain")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "grep command has only the global catalog" \
        "$(grep_line "$(global_catalog)")"$'\n' "$(context)"
    assert_eq "no project catalog path" "" "$(context | grep 'projects/')"
    assert_eq "stderr is empty" "" "$ERR"
}

# With no cwd, or an empty one, the hook asks for the global scope only:
# --project "" would be a usage error.
test_no_cwd() {
    new_env
    new_project "$T_HOME/proj"
    T_CWD="$T_HOME/proj"
    local stdin
    for stdin in '{"hook_event_name":"SessionStart","source":"startup"}' \
                 '{"hook_event_name":"SessionStart","cwd":"","source":"startup"}'; do
        hook_run SessionStart "$stdin"
        assert_rc "exits 0 for $stdin" 0
        assert_eq "valid JSON for $stdin" yes "$(json_valid "$OUT_FILE" && echo yes)"
        assert_contains "global catalog only for $stdin" \
            "$(grep_line "$(global_catalog)")"$'\n' "$(context)"
        assert_eq "no project catalog from the process cwd for $stdin" "" \
            "$(context | grep 'projects/')"
    done
}

test_before_repo_exists() {
    new_env
    new_project "$T_HOME/proj"
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "context greps the would-be global catalog only" \
        "$(grep_line "$(global_catalog)")"$'\n' "$(context)"
    assert_eq "no project catalog path" "" "$(context | grep 'projects/')"
    assert_eq "~/.local not created" no "$(no_local_dir)"
}

# TOOLSMITH_TEST_REPO reaches the hook through toolsmith-repo locate.
test_test_repo_override() {
    new_env
    T_EXTRA_ENV=("TOOLSMITH_TEST_REPO=$T_HOME/scenario tools/repo")
    new_project "$T_HOME/proj"
    local repo
    repo="$(t_canonical "$T_HOME")/scenario tools/repo"
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_contains "project catalog is under the override" "$repo/projects/" "$PROJECT_CATALOG"
    assert_contains "context greps the override's global catalog" \
        "$(grep_line "$repo/CATALOG.md")"$'\n' "$(context)"
    assert_eq "~/.local not created" no "$(no_local_dir)"
    assert_eq "override not created" no "$( [ -e "$T_HOME/scenario tools" ] && echo yes || echo no )"
}

test_dangling_symlink() {
    new_env
    mkdir -p "$T_HOME/.local/share/toolsmith"
    ln -s ../../../target/tools "$T_HOME/.local/share/toolsmith/tools"
    new_project "$T_HOME/proj"
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    local target_catalog
    target_catalog="$(t_canonical "$T_HOME")/target/tools/CATALOG.md"
    assert_contains "context greps the symlink target's would-be global catalog" \
        "$(grep_line "$target_catalog")"$'\n' "$(context)"
    assert_eq "symlink target not created" no \
        "$( [ -e "$T_HOME/target" ] && echo yes || echo no )"
}

test_space_in_cwd() {
    new_env
    local dir="$T_HOME/my \"odd\" proj\\dir"
    new_project "$dir"
    make_project_catalog
    assert_contains "locate found the odd project" "/projects/" "$PROJECT_CATALOG"
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\": \"$(json_escape "$dir")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "context has the odd project's catalog path" "$PROJECT_CATALOG" "$(context)"
}

# A single quote in a path must not break the shell quoting of the grep line.
test_single_quote_in_home() {
    new_env
    local home="$T_HOME/it's home"
    mkdir -p "$home"
    T_HOME=$home
    T_CWD=$home
    hook_run SessionStart '{"hook_event_name":"SessionStart","source":"startup"}'
    assert_rc "exits 0" 0
    local quoted
    quoted=$(global_catalog)
    quoted=${quoted//\'/\'\\\'\'}
    assert_contains "single quote is shell-escaped in the grep line" \
        "grep -s -i -E '<words>' '$quoted'" "$(context)"
}

# Control characters in a path must be JSON-escaped, not emitted raw.
test_control_chars_in_home() {
    new_env
    local home="$T_HOME/a"$'\001'"b"$'\037'"c"
    mkdir -p "$home"
    T_HOME=$home
    T_CWD=$home
    hook_run SessionStart '{"hook_event_name":"SessionStart","source":"startup"}'
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "control characters are sent as \\u escapes" '\u0001b\u001fc' "$OUT"
    assert_contains "context decodes to the literal catalog path" \
        "$(grep_line "$(global_catalog)")" "$(context)"
}

# Claude Code can start hooks with an empty PATH (anthropics/claude-code#43127).
# The hook gives toolsmith-repo the system dirs so it still finds git.
test_empty_path() {
    new_env
    new_project "$T_HOME/proj"
    make_project_catalog
    T_PATH=''
    hook_run SessionStart \
        "{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$(json_escape "$T_HOME/proj")\",\"source\":\"startup\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_contains "context has the grep command for both catalogs" \
        "$(grep_line "$(global_catalog)" "$PROJECT_CATALOG")" "$(context)"
    assert_eq "stderr is empty" "" "$ERR"
}

# If locate fails (here: the git on PATH is a broken stub, like the macOS
# Command Line Tools shim), the hook still succeeds and sends the agent to the
# toolsmith.
test_locate_fails() {
    new_env
    new_project "$T_HOME/proj"
    local stub_bin="$T_ROOT/bin with git stub"
    mkdir -p "$stub_bin"
    printf '#!/bin/sh\necho "xcrun: error: invalid active developer path" >&2\nexit 1\n' >"$stub_bin/git"
    chmod +x "$stub_bin/git"
    T_PATH=$stub_bin
    hook_run SubagentStart \
        "{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"general-purpose\",\"cwd\":\"$(json_escape "$T_HOME/proj")\"}"
    assert_rc "exits 0" 0
    assert_eq "stdout is valid JSON" yes "$(json_valid "$OUT_FILE" && echo yes)"
    assert_eq "hookEventName is SubagentStart" SubagentStart "$(event_name)"
    assert_contains "context says the catalog location is unknown" \
        "catalog location couldn't be determined" "$(context)"
    assert_eq "no grep command" "" "$(context | grep 'grep -s')"
    assert_routing_context "locate failure"
    assert_eq "stderr is empty" "" "$ERR"
}

test_via_wrapper() {
    new_env
    new_project "$T_HOME/proj"
    local stdin="{\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"general-purpose\",\"cwd\":\"$(json_escape "$T_HOME/proj")\"}"
    hook_run SubagentStart "$stdin"
    local direct=$OUT
    hook_exec "$WRAPPER" "$stdin" inject SubagentStart
    assert_rc "wrapper exits 0" 0
    assert_eq "wrapper output matches the direct run" "$direct" "$OUT"

    T_PATH=''
    hook_exec "$WRAPPER" "$stdin" inject SubagentStart
    assert_rc "wrapper exits 0 with an empty PATH" 0
    assert_eq "valid JSON with an empty PATH" yes "$(json_valid "$OUT_FILE" && echo yes)"
}

test_hooks_json() {
    local file="$PLUGIN_ROOT/hooks/hooks.json" event matcher
    assert_eq "hooks.json is valid JSON" yes "$(json_valid "$file" && echo yes)"
    for event in SessionStart SubagentStart; do
        case $event in
            SessionStart) matcher='startup|clear|compact' ;;
            SubagentStart) matcher='.*' ;;
        esac
        assert_eq "$event matcher" "$matcher" "$(json_get "$file" "hooks.$event.0.matcher")"
        assert_eq "$event command" "\"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd\" inject $event" \
            "$(json_get "$file" "hooks.$event.0.hooks.0.command")"
        assert_eq "$event runs under bash" bash "$(json_get "$file" "hooks.$event.0.hooks.0.shell")"
    done
}

run_tests
