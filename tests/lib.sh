# Shared helpers for toolsmith tests. Source this from a tests/test-*.sh file,
# define test_* functions, then call run_tests at the end of the file.
#
# Every test runs in its own subshell against a temp HOME, so nothing here can
# touch the real ~/.local/share/toolsmith or the real git config.

T_TESTS_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
TR_BIN="$(dirname -- "$T_TESTS_DIR")/bin/toolsmith-repo"

# PATH that toolsmith-repo sees by default. /usr/bin:/bin comes first so the
# script runs under the system bash (3.2 on macOS), the version we promise.
T_DEFAULT_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# Scratch space for this test file, beside the logs that tests/run writes.
# Removed when the test file exits.
T_TMP=${TMPDIR:-/tmp}
T_ROOT_PARENT="${T_TMP%/}/toolsmith-tests-$(id -u)"
mkdir -p "$T_ROOT_PARENT"
T_ROOT=$(mktemp -d "$T_ROOT_PARENT/work.XXXXXX") || exit 1

# Remove T_ROOT, but only if it is still a work.XXXXXX dir directly under
# T_ROOT_PARENT, so a clobbered T_ROOT can never delete anything else.
t_cleanup() {
    local suffix=${T_ROOT#"$T_ROOT_PARENT"/work.}
    case $suffix in
        "$T_ROOT"|''|*/*|*..*)
            printf 'lib.sh: refusing to remove %s: not a test work dir under %s/\n' \
                "$T_ROOT" "$T_ROOT_PARENT" >&2
            return 1
            ;;
    esac
    rm -rf -- "$T_ROOT"
}
trap t_cleanup EXIT

T_FAILS=0

# new_env: fresh temp HOME (with a space in its name) and a git global config
# with a test identity. Sets T_HOME, T_GITCFG, and resets T_PATH, T_CWD,
# T_LC_ALL and T_EXTRA_ENV, which tr_run uses. Tests may override T_GITCFG,
# T_PATH, T_CWD, T_LC_ALL (a locale to run under, e.g. C.UTF-8; empty means
# none) and T_EXTRA_ENV (an array of NAME=value pairs to add) after this.
new_env() {
    T_HOME=$(mktemp -d "$T_ROOT/home XXXXXX") || exit 1
    T_GITCFG=$(mktemp "$T_ROOT/gitconfig XXXXXX") || exit 1
    printf '[user]\n\tname = Test\n\temail = test@example.com\n' >"$T_GITCFG"
    T_PATH=$T_DEFAULT_PATH
    T_CWD=$T_HOME
    T_LC_ALL=''
    T_EXTRA_ENV=()
}

# ignore_bin_globally: give the test user a global excludes file that ignores
# bin/ directories and .DS_Store, as some people's dotfiles do. Call after
# new_env.
ignore_bin_globally() {
    printf 'bin/\n.DS_Store\n' >"$T_HOME/global-ignore"
    printf '[core]\n\texcludesFile = %s\n' "$T_HOME/global-ignore" >>"$T_GITCFG"
}

# tr_exec <args...>: run bin/toolsmith-repo in a clean environment from $T_CWD,
# leaving its stdout and stderr alone. Use it directly to run several at once
# in the background; otherwise use tr_run.
tr_exec() {
    : "${T_HOME:?new_env must run before tr_exec}"
    (
        cd -- "$T_CWD" || exit 125
        env -i PATH="$T_PATH" HOME="$T_HOME" GIT_CONFIG_GLOBAL="$T_GITCFG" \
            GIT_CONFIG_NOSYSTEM=1 TMPDIR="${TMPDIR:-/tmp}" \
            ${T_LC_ALL:+"LC_ALL=$T_LC_ALL"} ${T_EXTRA_ENV[@]+"${T_EXTRA_ENV[@]}"} \
            "$TR_BIN" "$@"
    )
}

# tr_run <args...>: run bin/toolsmith-repo in a clean environment from $T_CWD.
# Sets OUT (stdout), ERR (stderr) and RC (exit status).
tr_run() {
    local out_file="$T_ROOT/stdout" err_file="$T_ROOT/stderr"
    tr_exec "$@" >"$out_file" 2>"$err_file"
    RC=$?
    OUT=$(cat "$out_file")
    ERR=$(cat "$err_file")
}

# t_git <args...>: run git as the test user (temp HOME, test git config).
t_git() {
    env HOME="$T_HOME" GIT_CONFIG_GLOBAL="$T_GITCFG" GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# t_canonical <dir>: physical path of an existing directory.
t_canonical() {
    (cd -P -- "$1" && pwd -P)
}

# kv <key>: first value for key= in OUT.
kv() {
    printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n 1
}

t_pass() {
    printf 'ok - %s\n' "$1"
}

# t_skip <desc>: a check that could not run here. Counts as a pass;
# tests/run lists it on the file's summary line.
t_skip() {
    printf 'SKIP - %s\n' "$1"
}

t_fail() {
    printf 'not ok - %s\n' "$1"
    shift
    printf '    %s\n' "$@"
    T_FAILS=$((T_FAILS + 1))
}

# assert_eq <desc> <want> <got>
assert_eq() {
    if [ "$2" = "$3" ]; then
        t_pass "$1"
    else
        t_fail "$1" "want: $2" "got:  $3"
    fi
}

# assert_contains <desc> <needle> <haystack>
assert_contains() {
    case $3 in
        *"$2"*) t_pass "$1" ;;
        *) t_fail "$1" "missing: $2" "in:      $3" ;;
    esac
}

# assert_rc <desc> <want>: checks RC from the last tr_run. On failure the
# captured stderr is shown, since it usually says why.
assert_rc() {
    if [ "$RC" = "$2" ]; then
        t_pass "$1"
    else
        t_fail "$1" "want exit: $2" "got exit:  $RC" "stderr: $ERR"
    fi
}

# run_tests: run every test_* function defined so far, each in a subshell.
# Exits non-zero if any assertion failed or any test exited non-zero.
run_tests() {
    local name failed=0
    for name in $(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p'); do
        printf '# %s\n' "$name"
        if ! ( T_FAILS=0; "$name"; [ "$T_FAILS" -eq 0 ] ); then
            printf '# %s FAILED\n' "$name"
            failed=$((failed + 1))
        fi
    done
    if [ "$failed" -ne 0 ]; then
        printf '# %d test(s) failed\n' "$failed"
        exit 1
    fi
    printf '# all tests passed\n'
}
