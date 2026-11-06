#!/usr/bin/env bash
# toolsmith-repo path and locate with --project: project keys, and the
# project_* paths they print.

. "$(dirname -- "$0")/lib.sh"

# new_project <dir>: a git repo with one commit at <dir>.
new_project() {
    mkdir -p "$1"
    t_git -C "$1" init -q
    t_git -C "$1" commit -q --allow-empty -m init
}

# expected_key <root>: the key the plan's algorithm gives for a canonical root.
expected_key() {
    printf '%s-%s\n' "${1##*/}" "$(printf %s "$1" | t_git hash-object --stdin | cut -c1-6)"
}

exists() {
    [ -e "$1" ] && echo yes || echo no
}

test_key_shape() {
    new_env
    local proj="$T_HOME/src/my app"
    new_project "$proj"
    tr_run path --project "$proj"
    assert_rc "path --project exits 0" 0
    local key repo
    key=$(kv project_key)
    repo=$(kv repo)
    assert_eq "key is <basename>-<6 hex>" yes \
        "$(printf '%s\n' "$key" | grep -Eq '^my app-[0-9a-f]{6}$' && echo yes || echo no)"
    assert_eq "key hashes the canonical root" "$(expected_key "$(t_canonical "$proj")")" "$key"
    assert_eq "project_dir= is repo/projects/<key>" "$repo/projects/$key" "$(kv project_dir)"
    assert_eq "project_catalog= is the project dir's CATALOG.md" \
        "$repo/projects/$key/CATALOG.md" "$(kv project_catalog)"
    assert_eq "global keys still printed" "$repo/CATALOG.md" "$(kv global_catalog)"
    assert_eq "stderr is empty" "" "$ERR"

    tr_run locate --project "$proj"
    assert_rc "locate --project exits 0" 0
    assert_eq "locate gives the same key" "$key" "$(kv project_key)"
    assert_eq "locate gives the same project_dir" "$repo/projects/$key" "$(kv project_dir)"
}

test_subdir_same_key() {
    new_env
    local proj="$T_HOME/src/app"
    new_project "$proj"
    mkdir -p "$proj/lib/deep dir"
    tr_run locate --project "$proj"
    local key=$(kv project_key)
    tr_run locate --project "$proj/lib/deep dir"
    assert_rc "locate on a subdirectory exits 0" 0
    assert_eq "subdirectory gives the root's key" "$key" "$(kv project_key)"

    T_CWD="$proj/lib"
    tr_run locate --project .
    assert_rc "relative --project exits 0" 0
    assert_eq "relative subdirectory gives the root's key" "$key" "$(kv project_key)"
}

test_worktree_same_key() {
    new_env
    local proj="$T_HOME/src/app"
    new_project "$proj"
    t_git -C "$proj" worktree add -q "../wt"
    assert_eq "worktree created" yes "$(exists "$T_HOME/src/wt/.git")"
    tr_run locate --project "$proj"
    local key=$(kv project_key)
    tr_run locate --project "$T_HOME/src/wt"
    assert_rc "locate on the worktree exits 0" 0
    assert_eq "worktree gives the main checkout's key" "$key" "$(kv project_key)"
}

test_same_basename_differs() {
    new_env
    new_project "$T_HOME/a/app"
    new_project "$T_HOME/b/app"
    tr_run locate --project "$T_HOME/a/app"
    local key_a=$(kv project_key)
    tr_run locate --project "$T_HOME/b/app"
    local key_b=$(kv project_key)
    assert_contains "a/app key starts with app-" "app-" "$key_a"
    assert_contains "b/app key starts with app-" "app-" "$key_b"
    assert_eq "keys differ" yes "$( [ "$key_a" != "$key_b" ] && echo yes || echo no )"
}

test_bare_repo() {
    new_env
    local bare="$T_HOME/srv/thing.git"
    mkdir -p "$bare"
    t_git -C "$bare" init -q --bare
    tr_run locate --project "$bare"
    assert_rc "locate on a bare repo exits 0" 0
    assert_eq "bare repo's root is the repo dir" "$(expected_key "$(t_canonical "$bare")")" "$(kv project_key)"
}

test_not_git() {
    new_env
    local plain="$T_HOME/plain dir"
    mkdir -p "$plain"
    local would_be
    would_be="$(t_canonical "$T_HOME")/.local/share/toolsmith/tools"

    tr_run locate --project "$plain"
    assert_rc "locate --project on a plain dir exits 8" 8
    assert_contains "stderr names the dir" "$plain" "$ERR"
    assert_contains "stderr says to use the global scope" "global scope" "$ERR"
    assert_eq "locate still prints repo=" "$would_be" "$(kv repo)"
    assert_eq "locate still prints global_catalog=" "$would_be/CATALOG.md" "$(kv global_catalog)"
    assert_eq "no project_key=" "" "$(kv project_key)"
    assert_eq "git's own error is not passed through" "" \
        "$(printf '%s\n' "$ERR" | grep -i 'fatal')"
    assert_eq "locate created nothing" no "$(exists "$T_HOME/.local")"

    tr_run path --project "$plain"
    assert_rc "path --project on a plain dir exits 8" 8
    assert_contains "path stderr says to use the global scope" "global scope" "$ERR"
    assert_eq "path still prints repo=" "$would_be" "$(kv repo)"
    assert_eq "path still prints global_catalog=" "$would_be/CATALOG.md" "$(kv global_catalog)"
    assert_eq "no project_key=" "" "$(kv project_key)"

    tr_run locate --project "$T_HOME/does not exist"
    assert_rc "locate --project on a missing dir exits 8" 8
}

test_path_does_not_create_project_dir() {
    new_env
    local proj="$T_HOME/src/app"
    new_project "$proj"
    tr_run path --project "$proj"
    assert_rc "path --project exits 0" 0
    local repo=$(kv repo)
    assert_eq "tools repo exists" yes "$(exists "$repo/.git")"
    assert_eq "projects/<key> not created" no "$(exists "$(kv project_dir)")"
    assert_eq "projects/ not created" no "$(exists "$repo/projects")"
    assert_eq "project dir not touched" "" "$(t_git -C "$proj" status --porcelain)"
}

# path and locate always pass their (possibly empty) --project value to
# resolve_scope, so this pins resolve_scope "" to the global scope even
# when the cwd is inside some other git repo.
test_no_project_is_global_from_any_cwd() {
    new_env
    local proj="$T_HOME/src/app"
    new_project "$proj"
    T_CWD=$proj
    local subcommand
    for subcommand in locate path; do
        tr_run "$subcommand"
        assert_rc "$subcommand without --project exits 0 from inside a git repo" 0
        assert_eq "$subcommand prints no project_* keys" "" \
            "$(printf '%s\n' "$OUT" | grep '^project_')"
    done

    T_CWD=$(kv repo)
    tr_run locate
    assert_eq "locate from inside the tools repo prints no project_* keys" "" \
        "$(printf '%s\n' "$OUT" | grep '^project_')"
}

test_usage() {
    new_env
    tr_run path --project
    assert_rc "--project with no dir is a usage error" 1
    assert_contains "stderr names --project" "--project" "$ERR"

    tr_run locate --project ""
    assert_rc "--project with an empty dir is a usage error" 1

    tr_run locate --bogus
    assert_rc "unknown argument is a usage error" 1
    assert_contains "stderr names the argument" "--bogus" "$ERR"

    tr_run --help
    assert_contains "--help documents --project" "--project" "$OUT"
    assert_contains "--help documents exit 8" "8" "$OUT"
}

run_tests
