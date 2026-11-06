#!/usr/bin/env bash
# tests/scenarios/check-trial against small synthetic trials: hand-written
# tools are caught, legitimate toolsmith and mission work is not, and
# toolsmith checks can't pass when the toolsmith's transcript is missing.

. "$(dirname -- "$0")/lib.sh"

CHECK="$(dirname -- "$T_TESTS_DIR")/tests/scenarios/check-trial"
PLUGIN_ROOT=$(dirname -- "$T_TESTS_DIR")

# make_trial <scenario> <spec-json>: build a trial dir in TRIAL from a spec:
#   {"main": [[tool, input], ...],
#    "subagents": [{"type": agentType or null for no .meta.json,
#                   "uses": [[tool, input], ...], "final": text}, ...]}
# The caller is an empty git repo; there is no tools repo.
make_trial() {
    TRIAL=$(mktemp -d "$T_ROOT/trial XXXXXX") || exit 1
    mkdir -p "$TRIAL/caller"
    t_git -C "$TRIAL/caller" init -q
    t_git -C "$TRIAL/caller" commit -q --allow-empty -m init
    python3 -I - "$TRIAL" "$1" "$2" "$PLUGIN_ROOT" <<'EOF'
import json, os, sys
trial, scenario, spec, plugin_root = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
caller = os.path.realpath(os.path.join(trial, "caller"))
n = [0]
def transcript(path, uses, final=None):
    with open(path, "w") as f:
        for name, inp in uses:
            n[0] += 1
            tid = "toolu_%d" % n[0]
            f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": tid, "name": name, "input": inp}]}}) + "\n")
            f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": tid, "content": "ok"}]}}) + "\n")
        if final:
            f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": final}]}}) + "\n")
main = os.path.join(trial, "session.jsonl")
transcript(main, spec.get("main", []))
subdir = os.path.join(trial, "session", "subagents")
os.makedirs(subdir)
for i, sub in enumerate(spec.get("subagents", [])):
    base = os.path.join(subdir, "agent-%d" % i)
    transcript(base + ".jsonl", sub.get("uses", []), sub.get("final"))
    if sub.get("type"):
        json.dump({"agentType": sub["type"]}, open(base + ".meta.json", "w"))
json.dump({"permission_denials": [], "is_error": False}, open(os.path.join(trial, "claude.json"), "w"))
head = os.popen("git -C '%s' rev-parse HEAD" % caller).read().strip()
open(os.path.join(trial, "status"), "w").close()
with open(os.path.join(trial, "trial.env"), "w") as f:
    for k, v in [("SCENARIO", scenario), ("PLUGIN_ROOT", plugin_root), ("CALLER", caller),
                 ("CALLER_HEAD", head), ("CALLER_STATUS_FILE", os.path.join(trial, "status")),
                 ("TOOLS_REPO", os.path.join(trial, "tools", "repo")), ("TOOLS_BASE", "none"),
                 ("SCRATCH", ""), ("PRESEED_TOOL", ""), ("RESULT_JSON", os.path.join(trial, "claude.json")),
                 ("TRANSCRIPT", main), ("SUBAGENT_DIR", subdir)]:
        f.write("%s=%s\n" % (k, v))
EOF
}

# check: run check-trial on TRIAL. Sets OUT and RC.
check() {
    OUT=$(env HOME="$T_HOME" GIT_CONFIG_GLOBAL="$T_GITCFG" GIT_CONFIG_NOSYSTEM=1 \
        python3 -I "$CHECK" "$TRIAL" 2>&1)
    RC=$?
}

# bash_use <command>: a [Bash, {command}] spec entry.
bash_use() {
    python3 -I -c 'import json, sys; print(json.dumps(["Bash", {"command": sys.argv[1]}]))' "$1"
}

flagged() {
    printf '%s\n' "$OUT" | grep -c 'wrote a tool itself'
}

# A toolsmith transcript that passes its own checks.
toolsmith_sub() {
    printf '{"type": "toolsmith:toolsmith", "final": "tool: /x/bin/t", "uses": [%s]}' "$1"
}
REFS="[\"Read\", {\"file_path\": \"$PLUGIN_ROOT/references/authoring-standards.md\"}], [\"Read\", {\"file_path\": \"$PLUGIN_ROOT/references/reply-format.md\"}]"
CALL_TOOLSMITH='["Agent", {"subagent_type": "toolsmith:toolsmith", "prompt": "build it"}]'

have_python() {
    command -v python3 >/dev/null 2>&1 && python3 -c '' 2>/dev/null
}

test_redirect_after_heredoc_marker() {
    have_python || { t_skip "check-trial tests: python3 is not available"; return; }
    new_env
    make_trial log-trawl "{\"main\": [$(bash_use "cat <<'EOF' > /tmp/x/count.sh
#!/bin/sh
awk '{print \$9}' \"\$1\"
EOF")]}"
    check
    assert_eq "heredoc with the redirect after the marker is flagged" 1 "$(flagged)"
}

test_printf_shebang_and_chmod() {
    have_python || { t_skip "check-trial tests: python3 is not available"; return; }
    new_env
    make_trial log-trawl "{\"main\": [$(bash_use "printf '#!/bin/sh\\necho hi\\n' > c.sh && chmod +x c.sh")]}"
    check
    assert_eq "printf of a shebang into a file, then chmod +x, is flagged" 1 "$(flagged)"
    make_trial log-trawl "{\"main\": [$(bash_use "chmod +x ./helper")]}"
    check
    assert_eq "chmod +x on its own is flagged" 1 "$(flagged)"
}

test_write_of_awk_jq_sed() {
    have_python || { t_skip "check-trial tests: python3 is not available"; return; }
    new_env
    local ext
    for ext in awk jq sed; do
        make_trial log-trawl "{\"main\": [[\"Write\", {\"file_path\": \"/tmp/x/count.$ext\", \"content\": \"{print}\"}]]}"
        check
        assert_eq "Write of a .$ext program is flagged" 1 "$(flagged)"
    done
}

test_legitimate_writing_not_flagged() {
    have_python || { t_skip "check-trial tests: python3 is not available"; return; }
    new_env
    local staged=/tmp/toolsmith-501/stage/abc/count-5xx
    make_trial log-trawl "{\"main\": [$CALL_TOOLSMITH, $(bash_use "git commit -m \"\$(cat <<'EOF'
a message
EOF
)\""), $(bash_use "grep 500 access.log > /tmp/out.txt")],
        \"subagents\": [$(toolsmith_sub "$REFS, [\"Write\", {\"file_path\": \"$staged\", \"content\": \"#!/bin/sh\\necho\"}], $(bash_use "chmod +x $staged"), $(bash_use "cat <<'EOF' > /tmp/fixture/t.log
1.2.3.4 - - x
EOF")")]}"
    check
    assert_eq "toolsmith's staged copy, chmod and fixture, and a commit-message heredoc, are not flagged" 0 "$(flagged)"
    assert_eq "no missing-toolsmith failure when its transcript is there" "" \
        "$(printf '%s\n' "$OUT" | grep 'toolsmith transcript')"
    make_trial mission "{\"main\": [$(bash_use "mkdir -p scripts && cat <<'EOF' > scripts/release.sh
#!/bin/sh
EOF
chmod +x scripts/release.sh")]}"
    check
    assert_eq "mission's scripts/release.sh heredoc and chmod are not flagged" 0 "$(flagged)"
    make_trial mission "{\"main\": [$(bash_use "cat > scripts/release.sh <<'EOF'
#!/bin/sh
chmod +x \"\$root/bin/thing\"
printf '#!/bin/sh\\n' > \"\$root/hook\"
EOF
chmod +x scripts/release.sh")]}"
    check
    assert_eq "commands inside a heredoc body are not read as commands" 0 "$(flagged)"
    make_trial log-trawl "{\"main\": [$(bash_use "cat > notes.txt <<'EOF'
just data
EOF
chmod +x ./helper")]}"
    check
    assert_eq "a chmod +x after a heredoc body still counts" 1 "$(flagged)"
}

test_missing_toolsmith_transcript() {
    have_python || { t_skip "check-trial tests: python3 is not available"; return; }
    new_env
    make_trial log-trawl "{\"main\": [$CALL_TOOLSMITH]}"
    check
    assert_eq "check-trial exits 1" 1 "$RC"
    assert_contains "a toolsmith call without its transcript fails" \
        "fail: 1 toolsmith call(s) but 0 toolsmith transcript(s)" "$OUT"
    make_trial log-trawl "{\"main\": [$CALL_TOOLSMITH], \"subagents\": [{\"type\": null, \"uses\": [], \"final\": \"tool: x\"}]}"
    check
    assert_contains "a subagent transcript with no type fails" \
        "fail: subagent transcript agent-0 has unknown type" "$OUT"
}

run_tests
