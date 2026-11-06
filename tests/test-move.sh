#!/usr/bin/env bash
# toolsmith-repo move: moving a tool between the global and a project scope
# in one commit, and refusing or rolling back cleanly when it can't.

. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/tools-repo-helpers.sh"

# new_project: fresh tools repo plus a git repo for a project, with a space
# in its path. Sets PROJ, PDIR (its scope dir) and KEY.
new_project() {
    new_repo
    PROJ="$T_HOME/src/my app"
    mkdir -p "$PROJ"
    t_git -C "$PROJ" init -q
    tr_run locate --project "$PROJ"
    PDIR=$(kv project_dir)
    KEY=$(kv project_key)
}

test_promote() {
    new_project
    install_new x "Does x" --project "$PROJ"
    local content before
    content=$(cat "$PDIR/bin/x")
    before=$(head_rev)
    tr_run move x --project "$PROJ" --to global
    assert_rc "move --to global exits 0" 0
    assert_eq "stderr is empty" "" "$ERR"
    assert_eq "tool gone from the project's bin/" no "$(exists "$PDIR/bin/x")"
    assert_eq "tool is executable in the global bin/" yes "$( [ -x "$REPO/bin/x" ] && echo yes || echo no )"
    assert_eq "tool content unchanged" "$content" "$(cat "$REPO/bin/x")"
    local line="- $REPO/bin/x -- Does x"
    assert_eq "project catalog no longer lists x" "$CATALOG_HEADER" "$(cat "$PDIR/CATALOG.md")"
    assert_eq "global catalog lists x" "$CATALOG_HEADER
$line" "$(cat "$REPO/CATALOG.md")"
    assert_eq "catalog= is the new catalog line" "$line" "$(kv catalog)"
    assert_eq "exactly one new commit" 1 "$(t_git -C "$REPO" rev-list --count "$before..HEAD")"
    assert_eq "commit moves the tool and updates both catalogs" \
        "$(printf 'M\tCATALOG.md\nA\tbin/x\nM\tprojects/%s/CATALOG.md\nD\tprojects/%s/bin/x' "$KEY" "$KEY")" \
        "$(changed_in_head)"
    assert_eq "commit message names the move" "Move x to global" "$(t_git -C "$REPO" log -1 --format=%s)"
    assert_eq "commit= is HEAD" "$(head_rev)" "$(kv commit)"
    assert_eq "PROJECT kept" "$(t_canonical "$PROJ")" "$(cat "$PDIR/PROJECT")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_demote() {
    new_project
    install_new x "Does x"
    local content before
    content=$(cat "$REPO/bin/x")
    before=$(head_rev)
    tr_run move x --project "$PROJ" --to project
    assert_rc "move --to project exits 0" 0
    assert_eq "stderr is empty" "" "$ERR"
    assert_eq "tool gone from the global bin/" no "$(exists "$REPO/bin/x")"
    assert_eq "tool is executable in the project's bin/" yes "$( [ -x "$PDIR/bin/x" ] && echo yes || echo no )"
    assert_eq "tool content unchanged" "$content" "$(cat "$PDIR/bin/x")"
    assert_eq "PROJECT created with the project root" "$(t_canonical "$PROJ")" "$(cat "$PDIR/PROJECT")"
    local line="- $PDIR/bin/x -- Does x"
    assert_eq "global catalog no longer lists x" "$CATALOG_HEADER" "$(cat "$REPO/CATALOG.md")"
    assert_eq "project catalog lists x" "$CATALOG_HEADER
$line" "$(cat "$PDIR/CATALOG.md")"
    assert_eq "catalog= is the new catalog line" "$line" "$(kv catalog)"
    assert_eq "exactly one new commit" 1 "$(t_git -C "$REPO" rev-list --count "$before..HEAD")"
    assert_eq "commit moves the tool, updates both catalogs and adds PROJECT" \
        "$(printf 'M\tCATALOG.md\nD\tbin/x\nA\tprojects/%s/CATALOG.md\nA\tprojects/%s/PROJECT\nA\tprojects/%s/bin/x' "$KEY" "$KEY" "$KEY")" \
        "$(changed_in_head)"
    assert_eq "commit message names the move" "Move x to project $KEY" "$(t_git -C "$REPO" log -1 --format=%s)"
    assert_eq "commit= is HEAD" "$(head_rev)" "$(kv commit)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_demote_into_existing_project() {
    new_project
    install_new y "Project y" --project "$PROJ"
    install_new x "Does x"
    tr_run move x --project "$PROJ" --to project
    assert_rc "move into an existing project exits 0" 0
    assert_eq "project catalog lists both" "$CATALOG_HEADER
- $PDIR/bin/x -- Does x
- $PDIR/bin/y -- Project y" "$(cat "$PDIR/CATALOG.md")"
    assert_eq "commit leaves PROJECT alone" "" "$(changed_in_head "projects/$KEY/PROJECT")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_round_trip() {
    new_project
    install_new x "Does x" --project "$PROJ"
    tr_run move x --project "$PROJ" --to global
    assert_rc "promote exits 0" 0
    tr_run move x --project "$PROJ" --to project
    assert_rc "demote back exits 0" 0
    assert_eq "tool is back in the project" yes "$( [ -x "$PDIR/bin/x" ] && echo yes || echo no )"
    assert_eq "global catalog empty again" "$CATALOG_HEADER" "$(cat "$REPO/CATALOG.md")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

# A global excludes file that ignores bin/ must not stop either direction
# of move committing the tool, and move adopts ignored strays in both
# scopes as install does, leaving dotfiles out.
test_global_ignore_of_bin() {
    new_project
    ignore_bin_globally
    install_new x "Does x" --project "$PROJ"
    assert_rc "project install under a global bin/ ignore exits 0" 0
    write_tool "$PDIR/bin/pstray" "Project stray"
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/gstray" "Global stray"
    printf 'junk\n' >"$PDIR/bin/.DS_Store"
    tr_run move x --project "$PROJ" --to global
    assert_rc "promote under a global bin/ ignore exits 0" 0
    assert_eq "promote commits the tool in the global bin/" \
        "$(printf 'A\tbin/x\nD\tprojects/%s/bin/x' "$KEY")" "$(changed_in_head bin/x "projects/$KEY/bin/x")"
    assert_contains "ignored project stray adopted" "adopted=$PDIR/bin/pstray" "$OUT"
    assert_contains "ignored global stray adopted" "adopted=$REPO/bin/gstray" "$OUT"
    assert_eq "strays committed" "$(printf 'A\tbin/gstray\nA\tprojects/%s/bin/pstray' "$KEY")" \
        "$(changed_in_head bin/gstray "projects/$KEY/bin/pstray")"
    assert_eq ".DS_Store not adopted" "" "$(printf '%s\n' "$OUT" | grep -F ".DS_Store")"
    assert_eq ".DS_Store not committed" "" "$(t_git -C "$REPO" ls-files -- "projects/$KEY/bin/.DS_Store")"
    tr_run move x --project "$PROJ" --to project
    assert_rc "demote under a global bin/ ignore exits 0" 0
    assert_eq "demote commits the tool in the project's bin/" \
        "$(printf 'D\tbin/x\nA\tprojects/%s/bin/x' "$KEY")" "$(changed_in_head bin/x "projects/$KEY/bin/x")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}


test_moves_hand_edits_with_the_tool() {
    new_project
    install_new x "Does x" --project "$PROJ"
    printf 'echo by hand\n' >>"$PDIR/bin/x"
    tr_run move x --project "$PROJ" --to global
    assert_rc "move of a hand-edited tool exits 0" 0
    assert_contains "hand edit moved with the tool" "echo by hand" "$(cat "$REPO/bin/x")"
    assert_eq "hand edit committed" "$(cat "$REPO/bin/x")" "$(t_git -C "$REPO" show HEAD:bin/x)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

# Both catalogs are regenerated from the work tree, so move commits every
# other uncommitted file in either scope's bin/, as install does.
test_adopts_uncommitted_in_both_scopes() {
    new_project
    install_new x "Does x" --project "$PROJ"
    install_new keep "Keep"
    write_tool "$PDIR/bin/pstray" "Project stray"
    write_tool "$REPO/bin/g stray" "Global stray"
    printf 'echo edited\n' >>"$REPO/bin/keep"
    tr_run move x --project "$PROJ" --to global
    assert_rc "move exits 0" 0
    assert_contains "project stray adopted" "adopted=$PDIR/bin/pstray" "$OUT"
    assert_contains "global stray with a space adopted" "adopted=$REPO/bin/g stray" "$OUT"
    assert_contains "hand-modified global tool adopted" "adopted=$REPO/bin/keep" "$OUT"
    assert_eq "moved tool not reported as adopted" "" \
        "$(printf '%s\n' "$OUT" | grep -F -e "adopted=$REPO/bin/x" -e "adopted=$PDIR/bin/x")"
    assert_eq "commit has the move, both catalogs and the adopted files" \
        "$(printf 'M\tCATALOG.md\nA\tbin/g stray\nM\tbin/keep\nA\tbin/x\nM\tprojects/%s/CATALOG.md\nA\tprojects/%s/bin/pstray\nD\tprojects/%s/bin/x' "$KEY" "$KEY" "$KEY")" \
        "$(changed_in_head)"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_adopts_deletions() {
    new_project
    install_new x "Does x"
    install_new gone "Gone"
    install_new pgone "Project gone" --project "$PROJ"
    rm -f "$REPO/bin/gone" "$PDIR/bin/pgone"
    tr_run move x --project "$PROJ" --to project
    assert_rc "move exits 0" 0
    assert_contains "deleted global tool adopted" "adopted=$REPO/bin/gone" "$OUT"
    assert_contains "deleted project tool adopted" "adopted=$PDIR/bin/pgone" "$OUT"
    assert_eq "commit deletes both" "$(printf 'D\tbin/gone\nD\tprojects/%s/bin/pgone' "$KEY")" \
        "$(changed_in_head bin/gone "projects/$KEY/bin/pgone")"
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

# A failed move commit leaves files it would have adopted untouched.
test_commit_failure_with_strays() {
    new_project
    install_new x "Does x" --project "$PROJ"
    write_tool "$PDIR/bin/pstray" "Project stray"
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/gstray" "Global stray"
    local before
    before=$(repo_state)
    fail_commits
    tr_run move x --project "$PROJ" --to global
    expect_rolled_back "move with strays" "$before"
}

test_dest_exists() {
    new_project
    install_new x "Global x"
    install_new x "Project x" --project "$PROJ"
    local before
    before=$(repo_state)
    tr_run move x --project "$PROJ" --to global
    assert_rc "promote onto an existing global tool exits 9" 9
    assert_contains "stderr names the destination" "$REPO/bin/x" "$ERR"
    assert_eq "nothing changed (promote)" "$before" "$(repo_state)"
    tr_run move x --project "$PROJ" --to project
    assert_rc "demote onto an existing project tool exits 9" 9
    assert_contains "stderr names the destination" "$PDIR/bin/x" "$ERR"
    assert_eq "nothing changed (demote)" "$before" "$(repo_state)"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_missing_source() {
    new_project
    local before
    before=$(repo_state)
    tr_run move x --project "$PROJ" --to global
    assert_rc "promoting a missing tool exits 1" 1
    assert_contains "stderr names the project scope searched" "project $KEY ($PDIR/bin)" "$ERR"
    assert_eq "nothing changed (promote)" "$before" "$(repo_state)"
    tr_run move x --project "$PROJ" --to project
    assert_rc "demoting a missing tool exits 1" 1
    assert_contains "stderr names the global scope searched" "global scope ($REPO/bin)" "$ERR"
    assert_eq "nothing changed, no project dir created" "$before" "$(repo_state)"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
}

test_untracked_source() {
    new_project
    mkdir -p "$REPO/bin"
    write_tool "$REPO/bin/x" "Does x"
    local before
    before=$(repo_state)
    tr_run move x --project "$PROJ" --to project
    assert_rc "moving an uncommitted tool exits 2" 2
    assert_contains "stderr says to install it first" "Install it first" "$ERR"
    assert_eq "nothing changed" "$before" "$(repo_state)"
}

test_mid_rebase() {
    new_project
    install_new x "Does x"
    local before
    mkdir "$REPO/.git/rebase-merge"
    before=$(repo_state)
    tr_run move x --project "$PROJ" --to project
    assert_rc "move refuses with exit 5 mid-rebase" 5
    assert_contains "stderr says why" "mid-rebase or mid-merge" "$ERR"
    assert_eq "nothing changed" "$before" "$(repo_state)"
    assert_eq "lock released" no "$(exists "$REPO/.git/toolsmith.lock")"
    rmdir "$REPO/.git/rebase-merge"
}

test_no_identity() {
    new_project
    install_new x "Does x"
    : >"$T_GITCFG"
    tr_run move x --project "$PROJ" --to project
    assert_rc "move with no git identity exits 0" 0
    assert_contains "note says an identity was set" "note=no git identity configured" "$OUT"
    assert_eq "commit made as toolsmith" "toolsmith <toolsmith@localhost>" \
        "$(t_git -C "$REPO" log -1 --format='%an <%ae>')"
}

# A failed commit puts back everything the move wrote: the tool, both
# catalogs, the index, and a project dir the move created.
test_commit_failure_demote_new_project() {
    new_project
    install_new x "Does x"
    printf 'user edit\n' >>"$REPO/README.md"
    t_git -C "$REPO" add README.md
    local before
    before=$(repo_state)
    fail_commits
    tr_run move x --project "$PROJ" --to project
    expect_rolled_back "demote" "$before"
    assert_eq "projects/ removed" no "$(exists "$REPO/projects")"

    allow_commits
    tr_run move x --project "$PROJ" --to project
    assert_rc "retry exits 0" 0
    assert_eq "user's staged change still staged and uncommitted" "M  README.md" "$(status_of "$REPO")"
}

test_commit_failure_promote() {
    new_project
    install_new x "Does x" --project "$PROJ"
    local before
    before=$(repo_state)
    fail_commits
    tr_run move x --project "$PROJ" --to global
    expect_rolled_back "promote" "$before"
    assert_eq "global bin/ removed" no "$(exists "$REPO/bin")"

    allow_commits
    tr_run move x --project "$PROJ" --to global
    assert_rc "retry exits 0" 0
    assert_eq "work tree clean" "" "$(status_of "$REPO")"
}

test_usage() {
    new_project
    install_new x "Does x"
    local before
    before=$(repo_state)
    tr_run --help
    assert_contains "--help lists move" "toolsmith-repo move" "$OUT"
    assert_contains "--help documents exit 9" "9 the move destination already exists" "$OUT"
    tr_run move
    assert_rc "move without a name exits 1" 1
    tr_run move x --to project
    assert_rc "move without --project exits 1" 1
    tr_run move x --project "$PROJ"
    assert_rc "move without --to exits 1" 1
    tr_run move x --project "$PROJ" --to elsewhere
    assert_rc "move --to elsewhere exits 1" 1
    assert_contains "stderr names the choices" "global or project" "$ERR"
    tr_run move ../x --project "$PROJ" --to project
    assert_rc "move of a bad name exits 1" 1
    tr_run move x y --project "$PROJ" --to project
    assert_rc "move with an extra argument exits 1" 1
    tr_run move x --project "$PROJ" --to project --bogus
    assert_rc "unknown move argument exits 1" 1
    tr_run move x --project "$T_HOME" --to project
    assert_rc "move with a --project outside git exits 8" 8
    assert_eq "nothing changed" "$before" "$(repo_state)"
}

run_tests
