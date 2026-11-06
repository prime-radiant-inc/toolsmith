#!/usr/bin/env bash
# toolsmith-repo stage and install: base checks, header checks, adoption,
# project scopes, and locking under concurrent installs.

. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/tools-repo-helpers.sh"

# dead_pid: print the PID of a process that has exited.
dead_pid() {
    sh -c 'exit 0' &
    local pid=$!
    wait "$pid"
    printf '%s\n' "$pid"
}

# hold_lock <pid>: create the install lock as if <pid> held it.
hold_lock() {
    mkdir "$REPO/.git/toolsmith.lock"
    printf '%s\n' "$1" >"$REPO/.git/toolsmith.lock/pid"
}

drop_lock() {
    rm -f "$REPO/.git/toolsmith.lock/pid"
    rmdir "$REPO/.git/toolsmith.lock"
}

# stop <pid>: kill a background process and reap it quietly.
stop() {
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
}

test_new_tool() {
    new_repo
    local before
    before=$(head_rev)
    stage x
    assert_rc "stage exits 0" 0
    assert_eq "new tool's base is absent" absent "$BASE"
    case $STAGED in
        "$TMPDIR/toolsmith-$(id -u)/stage/"*/x) t_pass "staged file is in a fresh dir under the staging area" ;;
        *) t_fail "staged file is in a fresh dir under the staging area" "got: $STAGED" ;;
    esac
    assert_eq "nothing to copy for a new tool" no "$(exists "$STAGED")"
    assert_eq "staging dir exists" yes "$(exists "${STAGED%/x}")"

    write_tool "$STAGED" "Does x"
    tr_run install "$STAGED" x --base "$BASE" -m "add x"
    assert_rc "install exits 0" 0
    assert_eq "stderr is empty" "" "$ERR"
    assert_eq "bin/x is executable" yes "$( [ -x "$REPO/bin/x" ] && echo yes || echo no )"
    assert_eq "bin/x has the staged content" "$(cat "$STAGED")" "$(cat "$REPO/bin/x")"
    local line="- $REPO/bin/x -- Does x"
    assert_eq "catalog lists x" "$CATALOG_HEADER
$line" "$(cat "$REPO/CATALOG.md")"
    assert_eq "catalog= is the catalog line" "$line" "$(kv catalog)"
    assert_eq "exactly one new commit" 1 "$(t_git -C "$REPO" rev-list --count "$before..HEAD")"
    assert_eq "commit touches bin/x and CATALOG.md only" "$(printf 'M\tCATALOG.md\nA\tbin/x')" "$(changed_in_head)"
    assert_eq "commit= is HEAD" "$(head_rev)" "$(kv commit)"
    assert_eq "commit message is -m" "add x" "$(t_git -C "$REPO" log -1 --format=%s)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
    assert_eq "nothing adopted" "" "$(printf '%s\n' "$OUT" | grep '^adopted=')"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_change_tool() {
    new_repo
    install_new x "Does x"
    stage x
    assert_rc "stage of an existing tool exits 0" 0
    assert_eq "base is the tool's blob hash" "$(t_git -C "$REPO" hash-object bin/x)" "$BASE"
    assert_eq "staged copy has the tool's content" "$(cat "$REPO/bin/x")" "$(cat "$STAGED")"
    printf 'echo more\n' >>"$STAGED"
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    assert_rc "install of a change exits 0" 0
    assert_eq "commit modifies bin/x" "$(printf 'M\tbin/x')" "$(changed_in_head bin/x)"
    assert_eq "bin/x has the change" "$(cat "$STAGED")" "$(cat "$REPO/bin/x")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_base_moved_by_install() {
    new_repo
    stage x
    local first=$STAGED
    stage x
    local second=$STAGED
    assert_eq "each stage gets its own dir" no "$( [ "$first" = "$second" ] && echo yes || echo no )"
    write_tool "$first" "First"
    write_tool "$second" "Second"
    tr_run install "$first" x --base absent -m "first"
    assert_rc "first install exits 0" 0
    local head
    head=$(head_rev)
    tr_run install "$second" x --base absent -m "second"
    assert_rc "second install exits 3" 3
    assert_contains "stderr says to re-stage" "Re-stage" "$ERR"
    assert_eq "no second commit" "$head" "$(head_rev)"
    assert_eq "bin/x is the first install" "$(cat "$first")" "$(cat "$REPO/bin/x")"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_base_moved_by_hand() {
    new_repo
    install_new x "Does x"
    stage x
    printf 'echo by hand\n' >>"$REPO/bin/x"
    local head
    head=$(head_rev)
    printf 'echo staged\n' >>"$STAGED"
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    assert_rc "install after a hand edit exits 3" 3
    assert_contains "stderr says to re-stage" "Re-stage" "$ERR"
    assert_eq "no commit" "$head" "$(head_rev)"
    assert_contains "hand edit kept" "echo by hand" "$(cat "$REPO/bin/x")"
}

test_race() {
    new_repo
    local before
    before=$(head_rev)
    stage a
    local sa=$STAGED
    stage b
    local sb=$STAGED
    write_tool "$sa" "Tool A"
    write_tool "$sb" "Tool B"
    tr_exec install "$sa" a --base absent -m "add a" >"$T_ROOT/a.out" 2>"$T_ROOT/a.err" &
    local pa=$!
    tr_exec install "$sb" b --base absent -m "add b" >"$T_ROOT/b.out" 2>"$T_ROOT/b.err" &
    local pb=$!
    wait "$pa"
    local ra=$?
    wait "$pb"
    local rb=$?
    assert_eq "install a exits 0" 0 "$ra"
    assert_eq "install b exits 0" 0 "$rb"
    assert_eq "install a stderr empty" "" "$(cat "$T_ROOT/a.err")"
    assert_eq "install b stderr empty" "" "$(cat "$T_ROOT/b.err")"
    assert_eq "two new commits" 2 "$(t_git -C "$REPO" rev-list --count "$before..HEAD")"
    assert_eq "catalog has both lines" "$CATALOG_HEADER
- $REPO/bin/a -- Tool A
- $REPO/bin/b -- Tool B" "$(cat "$REPO/CATALOG.md")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_race_same_tool() {
    new_repo
    stage x
    local s1=$STAGED
    stage x
    local s2=$STAGED
    write_tool "$s1" "One"
    write_tool "$s2" "Two"
    tr_exec install "$s1" x --base absent -m "one" >"$T_ROOT/1.out" 2>"$T_ROOT/1.err" &
    local p1=$!
    tr_exec install "$s2" x --base absent -m "two" >"$T_ROOT/2.out" 2>"$T_ROOT/2.err" &
    local p2=$!
    wait "$p1"
    local r1=$?
    wait "$p2"
    local r2=$?
    assert_eq "one install wins, the other sees the base move" "0 3" "$(printf '%s\n%s\n' "$r1" "$r2" | sort | tr '\n' ' ' | sed 's/ $//')"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_stale_lock() {
    new_repo
    hold_lock "$(dead_pid)"
    install_new x "Does x"
    assert_rc "install breaks a lock held by a dead PID" 0
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

# Both installs see the same dead PID. The slower one must not remove the
# lock the faster one took after breaking it.
test_stale_lock_race() {
    new_repo
    stage a
    local sa=$STAGED
    stage b
    local sb=$STAGED
    write_tool "$sa" "Tool A"
    write_tool "$sb" "Tool B"
    hold_lock "$(dead_pid)"
    tr_exec install "$sa" a --base absent -m "add a" >"$T_ROOT/a.out" 2>"$T_ROOT/a.err" &
    local pa=$!
    tr_exec install "$sb" b --base absent -m "add b" >"$T_ROOT/b.out" 2>"$T_ROOT/b.err" &
    local pb=$!
    wait "$pa"
    local ra=$?
    wait "$pb"
    local rb=$?
    assert_eq "install a exits 0" 0 "$ra"
    assert_eq "install b exits 0" 0 "$rb"
    assert_eq "catalog has both lines" "$CATALOG_HEADER
- $REPO/bin/a -- Tool A
- $REPO/bin/b -- Tool B" "$(cat "$REPO/CATALOG.md")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
    assert_eq "lock and break guard released" "no no" \
        "$(exists "$REPO/.git/toolsmith.lock") $(exists "$REPO/.git/toolsmith.lock.break")"
}

test_lock_timeout() {
    new_repo
    sleep 30 &
    local live=$!
    hold_lock "$live"
    local head
    head=$(head_rev)
    stage x
    write_tool "$STAGED" "Does x"
    tr_run install "$STAGED" x --base absent -m "add x" --lock-tries 3
    assert_rc "install exits 4 when the lock stays held" 4
    assert_contains "stderr names the lock" "$REPO/.git/toolsmith.lock" "$ERR"
    assert_eq "no commit" "$head" "$(head_rev)"
    assert_eq "bin/x not written" no "$(exists "$REPO/bin/x")"
    assert_eq "live holder's lock left alone" "$live" "$(cat "$REPO/.git/toolsmith.lock/pid")"
    stop "$live"
}

test_catalog_takes_lock() {
    new_repo
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/stray" "Stray"
    sleep 30 &
    local live=$!
    hold_lock "$live"
    tr_run catalog --lock-tries 3
    assert_rc "catalog exits 4 when the lock stays held" 4
    assert_eq "catalog not rewritten" "$CATALOG_HEADER" "$(cat "$REPO/CATALOG.md")"

    ( sleep 0.3; drop_lock ) &
    local releaser=$!
    tr_run catalog
    wait "$releaser"
    assert_rc "catalog waits for the lock, then exits 0" 0
    assert_eq "catalog rewritten once the lock is free" "$CATALOG_HEADER
- $REPO/bin/stray -- Stray" "$(cat "$REPO/CATALOG.md")"
    assert_eq "catalog released its lock" no "$(exists "$REPO/.git/toolsmith.lock")"
    stop "$live"
}

test_mid_rebase() {
    new_repo
    local head marker
    head=$(head_rev)
    for marker in rebase-merge rebase-apply MERGE_HEAD; do
        case $marker in
            MERGE_HEAD) printf '%s\n' "$head" >"$REPO/.git/$marker" ;;
            *) mkdir "$REPO/.git/$marker" ;;
        esac
        install_new x "Does x"
        assert_rc "install refuses with exit 5 during $marker" 5
        assert_contains "stderr says why ($marker)" "mid-rebase or mid-merge" "$ERR"
        assert_eq "no commit ($marker)" "$head" "$(head_rev)"
        assert_eq "bin/x not written ($marker)" no "$(exists "$REPO/bin/x")"
        assert_eq "lock released ($marker)" no "$(exists "$REPO/.git/toolsmith.lock")"
        case $marker in
            MERGE_HEAD) rm -f "$REPO/.git/$marker" ;;
            *) rmdir "$REPO/.git/$marker" ;;
        esac
    done
}

test_no_header() {
    new_repo
    local head
    head=$(head_rev)
    stage x
    printf '#!/bin/sh\necho no header\n' >"$STAGED"
    tr_run install "$STAGED" x --base absent -m "add x"
    assert_rc "install without a header exits 7" 7
    assert_contains "stderr names the marker" "toolsmith-v1:" "$ERR"
    assert_eq "no commit" "$head" "$(head_rev)"
    assert_eq "bin/x not written" no "$(exists "$REPO/bin/x")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_staged_file_unreadable() {
    new_repo
    local head
    head=$(head_rev)
    tr_run install "$T_HOME/no such file" x --base absent -m "add x"
    assert_rc "missing staged file exits 2" 2
    assert_contains "stderr names the file" "$T_HOME/no such file" "$ERR"

    stage x
    write_tool "$STAGED" "Does x"
    chmod 000 "$STAGED"
    tr_run install "$STAGED" x --base absent -m "add x"
    assert_rc "unreadable staged file exits 2, not 7" 2
    assert_contains "stderr names the file" "$STAGED" "$ERR"
    chmod 644 "$STAGED"
    assert_eq "no commit" "$head" "$(head_rev)"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_bad_name() {
    new_repo
    local name
    stage x
    write_tool "$STAGED" "Does x"
    for name in ../evil Foo .hidden -x 'a b' 'a/b'; do
        tr_run stage "$name"
        assert_rc "stage '$name' exits 1" 1
        tr_run install "$STAGED" "$name" --base absent -m "add"
        assert_rc "install '$name' exits 1" 1
    done
    assert_eq "nothing written outside bin/" no "$(exists "$REPO/evil")"
    assert_eq "bin/ not created" no "$(exists "$REPO/bin")"
}

test_adopts_untracked() {
    new_repo
    install_new keep "Keep"
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/stray" "Stray"
    write_tool "$REPO/bin/with space" "Spaced"
    printf 'echo edited\n' >>"$REPO/bin/keep"
    install_new x "Does x"
    assert_rc "install exits 0" 0
    assert_contains "untracked stray adopted" "adopted=$REPO/bin/stray" "$OUT"
    assert_contains "name with a space adopted" "adopted=$REPO/bin/with space" "$OUT"
    assert_contains "hand-modified tool adopted" "adopted=$REPO/bin/keep" "$OUT"
    assert_eq "installed tool not reported as adopted" "" "$(printf '%s\n' "$OUT" | grep -F "adopted=$REPO/bin/x")"
    assert_eq "commit has the tool, the catalog and the adopted files" \
        "$(printf 'M\tCATALOG.md\nM\tbin/keep\nA\tbin/stray\nA\tbin/with space\nA\tbin/x')" "$(changed_in_head)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_adopts_deletion() {
    new_repo
    install_new gone "Gone"
    rm -f "$REPO/bin/gone"
    install_new x "Does x"
    assert_rc "install exits 0" 0
    assert_contains "deleted tool adopted" "adopted=$REPO/bin/gone" "$OUT"
    assert_eq "commit deletes bin/gone" "$(printf 'D\tbin/gone')" "$(changed_in_head bin/gone)"
    assert_eq "catalog no longer lists it" "$CATALOG_HEADER
- $REPO/bin/x -- Does x" "$(cat "$REPO/CATALOG.md")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

# A global excludes file that ignores bin/ must not stop install committing
# the tool, or change what it adopts: the adopted set is the catalogued set.
# A hand-dropped stray is adopted even though the ignore matches it; a
# dotfile like .DS_Store is neither catalogued nor committed.
test_global_ignore_of_bin() {
    new_repo
    ignore_bin_globally
    install_new keep "Keep"
    assert_rc "install under a global bin/ ignore exits 0" 0
    assert_eq "commit adds the tool" "$(printf 'A\tbin/keep')" "$(changed_in_head bin/keep)"
    printf 'echo edited\n' >>"$REPO/bin/keep"
    write_tool "$REPO/bin/stray" "Stray"
    write_tool "$REPO/bin/with space" "Spaced"
    printf 'junk\n' >"$REPO/bin/.DS_Store"
    install_new x "Does x"
    assert_rc "second install exits 0" 0
    assert_contains "hand-modified tracked tool adopted" "adopted=$REPO/bin/keep" "$OUT"
    assert_contains "ignored stray adopted" "adopted=$REPO/bin/stray" "$OUT"
    assert_contains "ignored stray with a space adopted" "adopted=$REPO/bin/with space" "$OUT"
    assert_eq ".DS_Store not adopted" "" "$(printf '%s\n' "$OUT" | grep -F ".DS_Store")"
    assert_eq "commit has the tool, the catalog, the edit and the strays" \
        "$(printf 'M\tCATALOG.md\nM\tbin/keep\nA\tbin/stray\nA\tbin/with space\nA\tbin/x')" "$(changed_in_head)"
    assert_eq ".DS_Store not catalogued" "" "$(grep -F ".DS_Store" "$REPO/CATALOG.md")"
    assert_eq ".DS_Store not committed" "" "$(t_git -C "$REPO" ls-files -- bin/.DS_Store)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}


test_leaves_other_staged_changes() {
    new_repo
    printf 'user edit\n' >>"$REPO/README.md"
    t_git -C "$REPO" add README.md
    install_new x "Does x"
    assert_rc "install exits 0" 0
    assert_eq "commit leaves README.md out" "" "$(changed_in_head README.md)"
    assert_eq "README.md change still staged" "M  README.md" "$(status_of "$REPO")"
}

test_reinstall_unchanged() {
    new_repo
    install_new x "Does x"
    local head
    head=$(head_rev)
    stage x
    tr_run install "$STAGED" x --base "$BASE" -m "no-op"
    assert_rc "install of an unchanged tool exits 0" 0
    assert_eq "no new commit" "$head" "$(head_rev)"
    assert_eq "commit= is the existing HEAD" "$head" "$(kv commit)"
    assert_contains "note says nothing changed" "note=nothing changed" "$OUT"
    assert_eq "catalog= still printed" "- $REPO/bin/x -- Does x" "$(kv catalog)"
}

test_project_install() {
    new_repo
    local proj="$T_HOME/src/my app"
    mkdir -p "$proj"
    t_git -C "$proj" init -q
    tr_run locate --project "$proj"
    local pdir key
    pdir=$(kv project_dir)
    key=$(kv project_key)
    local global_before
    global_before=$(cat "$REPO/CATALOG.md")

    install_new x "Project x" --project "$proj"
    assert_rc "project install exits 0" 0
    assert_eq "tool is in the project's bin/" yes "$( [ -x "$pdir/bin/x" ] && echo yes || echo no )"
    assert_eq "PROJECT holds the project root" "$(t_canonical "$proj")" "$(cat "$pdir/PROJECT")"
    local line="- $pdir/bin/x -- Project x"
    assert_eq "project catalog lists x" "$CATALOG_HEADER
$line" "$(cat "$pdir/CATALOG.md")"
    assert_eq "catalog= is the project catalog line" "$line" "$(kv catalog)"
    assert_eq "global catalog unchanged" "$global_before" "$(cat "$REPO/CATALOG.md")"
    assert_eq "commit adds the tool, catalog and PROJECT" \
        "$(printf 'A\tprojects/%s/CATALOG.md\nA\tprojects/%s/PROJECT\nA\tprojects/%s/bin/x' "$key" "$key" "$key")" \
        "$(changed_in_head)"
    assert_eq "global bin/ not created" no "$(exists "$REPO/bin")"

    stage x --project "$proj"
    assert_eq "project stage base is the project tool's hash" \
        "$(t_git -C "$REPO" hash-object "projects/$key/bin/x")" "$BASE"
    install_new y "Project y" --project "$proj"
    assert_rc "second project install exits 0" 0
    assert_eq "second install leaves PROJECT alone" "" "$(changed_in_head "projects/$key/PROJECT")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_caller_repo_untouched() {
    new_repo
    local caller="$T_HOME/caller repo"
    mkdir -p "$caller"
    t_git -C "$caller" init -q
    printf 'one\n' >"$caller/file"
    t_git -C "$caller" add file
    t_git -C "$caller" commit -q -m "caller commit"
    printf 'two\n' >>"$caller/file"
    t_git -C "$caller" add file
    printf 'loose\n' >"$caller/untracked"
    local head status
    head=$(t_git -C "$caller" rev-parse HEAD)
    status=$(status_of "$caller")
    T_CWD=$caller

    install_new x "Does x"
    assert_rc "global install from inside another repo exits 0" 0
    stage x
    printf 'echo more\n' >>"$STAGED"
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    assert_rc "change from inside another repo exits 0" 0
    install_new y "Project y" --project "$caller"
    assert_rc "project install for the caller's repo exits 0" 0

    assert_eq "caller HEAD unchanged" "$head" "$(t_git -C "$caller" rev-parse HEAD)"
    assert_eq "caller status unchanged" "$status" "$(status_of "$caller")"
    assert_eq "tools repo work tree clean" "" "$(status_of "$REPO")"
}

# The base must hash the tool's raw bytes, whatever the caller's repo does
# with line endings. Here the caller converts CRLF, and stage and install
# run from different directories.
test_base_ignores_caller_line_endings() {
    new_repo
    local caller="$T_HOME/caller repo"
    mkdir -p "$caller"
    t_git -C "$caller" init -q
    t_git -C "$caller" config core.autocrlf true
    stage x
    printf '#!/bin/sh\r\n# toolsmith-v1: Does x\r\necho x\r\n' >"$STAGED"
    tr_run install "$STAGED" x --base "$BASE" -m "add x"
    assert_rc "install of a CRLF tool exits 0" 0
    T_CWD=$caller
    stage x
    assert_eq "base is the hash of the raw bytes" \
        "$(t_git -C "$REPO" hash-object --no-filters bin/x)" "$BASE"
    printf 'echo more\r\n' >>"$STAGED"
    T_CWD=$T_HOME
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    assert_rc "install from outside the caller repo accepts the base" 0
}

test_no_identity() {
    new_repo
    : >"$T_GITCFG"
    install_new x "Does x"
    assert_rc "install with no git identity exits 0" 0
    assert_contains "note says an identity was set" "note=no git identity configured" "$OUT"
    assert_eq "repo-local identity set" toolsmith "$(t_git -C "$REPO" config --local user.name)"
    assert_eq "commit made as toolsmith" "toolsmith <toolsmith@localhost>" \
        "$(t_git -C "$REPO" log -1 --format='%an <%ae>')"
}

# A failed commit rolls back everything the install wrote, including what it
# staged; files it would have adopted, and the user's own staged changes,
# are left exactly as they were.
test_commit_failure_new_tool() {
    new_repo
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/stray" "Stray"
    printf 'user edit\n' >>"$REPO/README.md"
    t_git -C "$REPO" add README.md
    local before
    before=$(repo_state)
    fail_commits
    install_new x "Does x"
    expect_rolled_back "new tool" "$before"

    allow_commits
    tr_run install "$STAGED" x --base "$BASE" -m "add x"
    assert_rc "retry with the same --base exits 0" 0
    assert_contains "retry adopts the stray" "adopted=$REPO/bin/stray" "$OUT"
    assert_eq "user's staged change still staged and uncommitted" "M  README.md" "$(status_of "$REPO")"
}

test_commit_failure_changed_tool() {
    new_repo
    install_new x "Does x"
    stage x
    printf 'echo more\n' >>"$STAGED"
    local before
    before=$(repo_state)
    fail_commits
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    expect_rolled_back "changed tool" "$before"

    allow_commits
    tr_run install "$STAGED" x --base "$BASE" -m "change x"
    assert_rc "retry with the same --base exits 0" 0
    assert_eq "bin/x has the change" "$(cat "$STAGED")" "$(cat "$REPO/bin/x")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_commit_failure_project_first_install() {
    new_repo
    local proj="$T_HOME/src/proj"
    mkdir -p "$proj"
    t_git -C "$proj" init -q
    local before
    before=$(repo_state)
    fail_commits
    install_new x "Project x" --project "$proj"
    expect_rolled_back "project first install" "$before"
    assert_eq "projects/ removed" no "$(exists "$REPO/projects")"

    allow_commits
    tr_run install "$STAGED" x --base "$BASE" -m "add x" --project "$proj"
    assert_rc "retry with the same --base exits 0" 0
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_usage() {
    new_repo
    tr_run --help
    assert_contains "--help lists stage" "toolsmith-repo stage" "$OUT"
    assert_contains "--help lists install" "toolsmith-repo install" "$OUT"
    assert_contains "--help documents --lock-tries" "--lock-tries" "$OUT"
    stage x
    write_tool "$STAGED" "Does x"
    tr_run stage
    assert_rc "stage without a name exits 1" 1
    tr_run install "$STAGED" x -m "add x"
    assert_rc "install without --base exits 1" 1
    tr_run install "$STAGED" x --base absent
    assert_rc "install without -m exits 1" 1
    tr_run install "$STAGED" --base absent -m "add x"
    assert_rc "install without a name exits 1" 1
    tr_run install "$STAGED" x --base absent -m "add x" --lock-tries none
    assert_rc "non-numeric --lock-tries exits 1" 1
    tr_run install "$STAGED" x --base absent -m "add x" --bogus
    assert_rc "unknown install argument exits 1" 1
    assert_eq "bin/ not created" no "$(exists "$REPO/bin")"
}

run_tests
