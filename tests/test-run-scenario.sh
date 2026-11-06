#!/usr/bin/env bash
# tests/scenarios/run-scenario's tools-repo guards: a TOOLS_REPO that isn't
# a temp path makes it refuse before it runs toolsmith-repo or claude, and a
# trial that changes the real tools repos fails. A stub claude on PATH
# records any launch, so nothing real ever starts. HOME is a temp dir, so
# the "real" tools repos here are fakes inside it.

. "$(dirname -- "$0")/lib.sh"

RUN_SCENARIO="$(dirname -- "$T_TESTS_DIR")/tests/scenarios/run-scenario"

# stub_env [<shell line>]: temp HOME plus a PATH dir whose claude records
# that it ran, then runs <shell line> (if given) in place of a session.
stub_env() {
    new_env
    STUB_BIN="$T_HOME/stub bin"
    LAUNCHED="$T_HOME/claude-launched"
    mkdir -p "$STUB_BIN"
    printf '#!/bin/sh\necho launched >>"%s"\n%s\necho "{}"\n' "$LAUNCHED" "${1-}" >"$STUB_BIN/claude"
    chmod +x "$STUB_BIN/claude"
}

# run_scenario_as <scenario> <tmpdir>: run one trial of <scenario> with
# TMPDIR=<tmpdir>. Sets OUT, ERR and RC.
run_scenario_as() {
    local scenario=$1
    shift
    mkdir -p "$1"
    env -i PATH="$STUB_BIN:$T_DEFAULT_PATH" HOME="$T_HOME" TMPDIR="$1" \
        GIT_CONFIG_GLOBAL="$T_GITCFG" GIT_CONFIG_NOSYSTEM=1 \
        "$RUN_SCENARIO" "$scenario" >"$T_ROOT/rs stdout" 2>"$T_ROOT/rs stderr"
    RC=$?
    OUT=$(cat "$T_ROOT/rs stdout")
    ERR=$(cat "$T_ROOT/rs stderr")
}

# run_existing_tool <tmpdir>: run the existing-tool scenario (whose setup
# preseeds the tools repo with toolsmith-repo) with TMPDIR=<tmpdir>.
run_existing_tool() {
    run_scenario_as existing-tool "$1"
}

tools_repos_under() {
    find "$1" -path '*/tools/repo' 2>/dev/null | wc -l | tr -d ' '
}

test_refuses_tools_repo_inside_home() {
    command -v python3 >/dev/null 2>&1 || { t_skip "run-scenario guard: python3 is not available"; return; }
    stub_env
    run_existing_tool "$T_HOME/tmp"
    assert_rc "run-scenario exits 2" 2
    assert_contains "stderr says it refused" "refusing to run" "$ERR"
    assert_contains "stderr names the tools repo" "TOOLSMITH_TEST_REPO=" "$ERR"
    assert_eq "claude never launched" no "$( [ -e "$LAUNCHED" ] && echo yes || echo no )"
    assert_eq "toolsmith-repo never created a tools repo" 0 "$(tools_repos_under "$T_HOME/tmp")"
}

# Control: with TMPDIR outside HOME the guard passes, the preseed runs and
# the stub claude launches, so the refusal above isn't vacuous.
test_temp_tools_repo_launches() {
    command -v python3 >/dev/null 2>&1 || { t_skip "run-scenario guard: python3 is not available"; return; }
    stub_env
    run_existing_tool "$T_ROOT/outside home tmp"
    assert_eq "no refusal" "" "$(printf '%s\n' "$ERR" | grep refusing)"
    assert_eq "stub claude launched once" launched "$(cat "$LAUNCHED" 2>/dev/null)"
    assert_eq "preseed created the tools repo" 1 "$(tools_repos_under "$T_ROOT/outside home tmp")"
}

# real_tools_repo: make the fake real ~/git/tools a git repo with a commit.
real_tools_repo() {
    REAL_GIT_TOOLS="$T_HOME/git/tools"
    mkdir -p "$REAL_GIT_TOOLS"
    t_git -C "$REAL_GIT_TOOLS" init -q
    t_git -C "$REAL_GIT_TOOLS" commit -q --allow-empty -m "real"
}

# run_breach <desc> <shell line>: run a log-trawl trial whose stub claude
# runs <shell line>, and check the trial fails naming the real tools repos.
run_breach() {
    command -v python3 >/dev/null 2>&1 || { t_skip "run-scenario breach check: python3 is not available"; return; }
    stub_env "$2"
    real_tools_repo
    run_scenario_as log-trawl "$T_ROOT/outside home tmp"
    assert_eq "$1: stub claude launched" launched "$(cat "$LAUNCHED" 2>/dev/null)"
    assert_rc "$1: run-scenario exits 1" 1
    assert_contains "$1: trial fails on the real tools repos" "FAIL log-trawl" "$OUT"
    assert_contains "$1: reason names the real tools repos" "real tools repos changed" "$OUT"
}

test_breach_creates_global_repo() {
    run_breach "creating ~/.local/share/toolsmith/tools" 'mkdir -p "$HOME/.local/share/toolsmith/tools"'
}

test_breach_dirties_git_tools() {
    run_breach "an untracked file in ~/git/tools" ': >"$HOME/git/tools/stray"'
}

test_breach_commits_to_git_tools() {
    run_breach "a commit in ~/git/tools" 'git -C "$HOME/git/tools" commit -q --allow-empty -m breach'
}

# Control: a trial that leaves the real tools repos alone still fails (the
# stub writes no transcript), but not because of them.
test_no_breach_not_blamed() {
    command -v python3 >/dev/null 2>&1 || { t_skip "run-scenario breach check: python3 is not available"; return; }
    stub_env
    real_tools_repo
    run_scenario_as log-trawl "$T_ROOT/outside home tmp"
    assert_eq "stub claude launched" launched "$(cat "$LAUNCHED" 2>/dev/null)"
    assert_contains "trial ran" "log-trawl" "$OUT"
    assert_eq "real tools repos not blamed" "" "$(printf '%s\n' "$OUT" | grep 'real tools repos')"
}

run_tests
