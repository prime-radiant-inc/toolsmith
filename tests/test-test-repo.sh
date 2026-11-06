#!/usr/bin/env bash
# TOOLSMITH_TEST_REPO: the test-only override of the tools repo location,
# used by the pressure scenarios so they can run with the real login without
# touching the real tools repo.

. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/tools-repo-helpers.sh"

# new_override_env: fresh env with TOOLSMITH_TEST_REPO pointing at a path
# (with a space) that does not exist yet. Sets OVERRIDE to that path and
# OVERRIDE_CANON to its would-be canonical form.
new_override_env() {
    new_env
    TMPDIR="$T_HOME/tmp dir"
    mkdir -p "$TMPDIR"
    OVERRIDE="$T_HOME/scenario tools/repo"
    OVERRIDE_CANON="$(t_canonical "$T_HOME")/scenario tools/repo"
    T_EXTRA_ENV=("TOOLSMITH_TEST_REPO=$OVERRIDE")
}

no_default_dir() {
    [ -e "$T_HOME/.local" ] && echo yes || echo no
}

test_path_uses_override() {
    new_override_env
    tr_run path
    assert_rc "path exits 0" 0
    local repo=$OVERRIDE_CANON
    assert_eq "repo= is the override" "$repo" "$(kv repo)"
    assert_eq "global_catalog= is under the override" "$repo/CATALOG.md" "$(kv global_catalog)"
    assert_contains "first run created the repo there" "note=created tools repo at $repo" "$OUT"
    assert_eq "override repo has its first commit" 1 "$(t_git -C "$repo" rev-list --count HEAD)"
    assert_eq "default location untouched" no "$(no_default_dir)"
    assert_eq "stderr is empty" "" "$ERR"
}

test_locate_uses_override_read_only() {
    new_override_env
    local proj="$T_HOME/proj"
    mkdir -p "$proj"
    t_git init -q "$proj"
    tr_run locate --project "$proj"
    assert_rc "locate exits 0" 0
    local repo=$OVERRIDE_CANON
    assert_eq "repo= is the would-be override" "$repo" "$(kv repo)"
    assert_contains "project_catalog= is under the override" "$repo/projects/" "$(kv project_catalog)"
    assert_eq "override not created" no "$( [ -e "$T_HOME/scenario tools" ] && echo yes || echo no )"
    assert_eq "default location untouched" no "$(no_default_dir)"
}

test_empty_override_means_default() {
    new_env
    T_EXTRA_ENV=("TOOLSMITH_TEST_REPO=")
    tr_run path
    assert_rc "path exits 0" 0
    assert_eq "repo= is the default location" \
        "$(t_canonical "$T_HOME/.local/share/toolsmith/tools")" "$(kv repo)"
}

test_override_through_install_and_move() {
    new_override_env
    local proj="$T_HOME/proj"
    mkdir -p "$proj"
    t_git init -q "$proj"
    install_new x "Does x" --project "$proj"
    assert_rc "install exits 0" 0
    REPO=$OVERRIDE_CANON
    assert_contains "catalog= line is under the override" "$REPO/projects/" "$(kv catalog)"
    assert_eq "commit= is the override repo's HEAD" "$(head_rev)" "$(kv commit)"
    tr_run move x --project "$proj" --to global
    assert_rc "move exits 0" 0
    assert_eq "moved into the override's bin/" "- $REPO/bin/x -- Does x" "$(kv catalog)"
    tr_run catalog
    assert_rc "catalog exits 0" 0
    assert_eq "override catalog lists x" "$CATALOG_HEADER
- $REPO/bin/x -- Does x" "$(cat "$REPO/CATALOG.md")"
    assert_eq "default location untouched" no "$(no_default_dir)"
}

test_help_says_test_only() {
    new_env
    tr_run --help
    assert_rc "--help exits 0" 0
    assert_contains "--help names the variable" "TOOLSMITH_TEST_REPO" "$OUT"
    assert_contains "--help says it is for tests only" "for tests only" "$OUT"
}

run_tests
