#!/usr/bin/env bash
# Plugin layout: the one toolsmith agent, its fixed frontmatter, the reference
# files its prompt points at, and `claude plugin validate`.

. "$(dirname -- "$0")/lib.sh"

PLUGIN_ROOT=$(dirname -- "$T_TESTS_DIR")
AGENT="$PLUGIN_ROOT/agents/toolsmith.md"

# frontmatter <file>: the lines between the opening --- and the next ---.
frontmatter() {
    sed -n '1{/^---$/!q;};1d;/^---$/q;p' "$1"
}

# flat <file>: the file's text with each run of whitespace, line breaks
# included, squeezed to one space, so a phrase matches however it wraps.
flat() {
    tr -s ' \n\t' '   ' <"$1"
}

# Every .md under agents/ loads as an agent, so anything besides toolsmith.md
# would hand its contents to every working agent.
test_only_one_agent() {
    local found
    found=$(cd -- "$PLUGIN_ROOT" && find agents -name '*.md')
    assert_eq "agents/ holds only toolsmith.md" "agents/toolsmith.md" "$found"
}

test_frontmatter() {
    local fm field
    fm=$(frontmatter "$AGENT")
    for field in 'name: toolsmith' 'model: inherit' 'omitClaudeMd: true' \
        'tools: Bash, Read, Write, Edit, Glob, Grep'; do
        assert_eq "frontmatter has '$field'" "$field" \
            "$(printf '%s\n' "$fm" | grep -x -F -- "$field")"
    done
    assert_contains "frontmatter has a description" "description: " "$fm"
}

test_references_exist() {
    local refs ref
    refs=$(grep -o '\${CLAUDE_PLUGIN_ROOT}/[A-Za-z0-9._/-]*' -- "$AGENT" |
        sed 's/\.*$//' | sort -u)
    assert_contains "prompt points at authoring-standards.md" \
        '${CLAUDE_PLUGIN_ROOT}/references/authoring-standards.md' "$refs"
    assert_contains "prompt points at reply-format.md" \
        '${CLAUDE_PLUGIN_ROOT}/references/reply-format.md' "$refs"
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if [ -f "$PLUGIN_ROOT/${ref#'${CLAUDE_PLUGIN_ROOT}/'}" ]; then
            t_pass "$ref exists"
        else
            t_fail "$ref exists" "no such file under $PLUGIN_ROOT"
        fi
    done <<EOF
$refs
EOF
}

# Exit codes the prompt doesn't handle one by one must still have a rule, or
# a cold model may follow stderr's remedies into raw git.
test_unlisted_exit_codes() {
    assert_contains "prompt has a catch-all for other exit codes" \
        "Any other non-zero exit from any toolsmith-repo command" "$(cat "$AGENT")"
}

# Claude Code lists every skill by its description, and the description is
# what makes an agent pick the skill up, so it states the trigger.
test_skill_frontmatter() {
    local skill_md dir fm
    if [ -f "$PLUGIN_ROOT/skills/writing-tools/SKILL.md" ]; then
        t_pass "skills/writing-tools/SKILL.md exists"
    else
        t_fail "skills/writing-tools/SKILL.md exists" "no such file under $PLUGIN_ROOT"
    fi
    for skill_md in "$PLUGIN_ROOT"/skills/*/SKILL.md; do
        [ -f "$skill_md" ] || continue
        dir=$(basename -- "$(dirname -- "$skill_md")")
        fm=$(frontmatter "$skill_md")
        assert_eq "$dir skill's name matches its directory" "name: $dir" \
            "$(printf '%s\n' "$fm" | grep '^name:')"
        assert_eq "$dir skill's description starts with 'Use when'" \
            "description: Use when" \
            "$(printf '%s\n' "$fm" | grep '^description:' | cut -c1-21)"
    done
}

# The skill must agree with the agent and the hook on the two edge cases a
# literal model would otherwise resolve badly: a mission-work refusal
# (agents/toolsmith.md rule 5) and context with no catalog search command
# (hooks/inject's fallback, or a harness with no hooks).
test_skill_edge_cases() {
    local skill
    skill=$(flat "$PLUGIN_ROOT/skills/writing-tools/SKILL.md")
    assert_contains "skill says a mission-work tool: none means write it in the project" \
        "says it is mission work, write it in the project" "$skill"
    assert_contains "agent's rule 5 still calls a refusal mission work" \
        "it is mission work for the caller to write in the project" "$(flat "$AGENT")"
    assert_contains "skill covers context with no search command" \
        "let the toolsmith search" "$skill"
    assert_contains "hook's fallback still lets the toolsmith search" \
        "let the toolsmith search" "$(flat "$PLUGIN_ROOT/hooks/inject")"
}

# In auto mode, a long multi-line Bash call carrying heredoc fixture data
# can fail Claude Code's command safety check, and only a person can lift
# that denial (log-trawl pressure scenario).
test_fixtures_via_write() {
    assert_contains "agent writes fixture files with Write, not heredocs" \
        "Create fixture files with Write, not with a heredoc or printf in Bash" "$(flat "$AGENT")"
}

# A toolsmith call left to default to the background from a nested subagent
# deadlocked a -p session (subagent pressure scenario, auto mode).
test_skill_foreground_call() {
    assert_contains "skill says to call the toolsmith in the foreground" \
        "run_in_background: false" "$(flat "$PLUGIN_ROOT/skills/writing-tools/SKILL.md")"
}

# The skill and the hook must define a tool, and the inline threshold, in
# the same words, or a literal model reads two rules.
test_tool_definition_agrees() {
    local skill hook threshold
    skill=$(flat "$PLUGIN_ROOT/skills/writing-tools/SKILL.md")
    hook=$(flat "$PLUGIN_ROOT/hooks/inject")
    threshold="a single command line, or a throwaway inspection snippet of at most five lines you won't run again"
    assert_contains "skill counts real logic as a tool" "code that you would run again or that is real logic" "$skill"
    assert_contains "hook counts real logic as a tool" "code that you would run again or that is real logic" "$hook"
    assert_contains "skill states the inline threshold" "$threshold" "$skill"
    assert_contains "hook states the inline threshold" "$threshold" "$hook"
    assert_eq "skill has no other five-line wording" "" \
        "$(printf '%s\n' "$skill" | grep -i -e 'about five' -e 'over five')"
}

# If a reference file can't be read, the toolsmith has no standards or reply
# format to follow, so it must stop with tool: none instead of improvising.
test_agent_reference_read_failure() {
    assert_contains "agent stops with tool: none if a reference Read fails" \
        'If either Read fails, stop: reply `tool: none` with a `note:` naming the path' "$(flat "$AGENT")"
}

# An existing tool keeps its scope except for the promote-on-change rule,
# and a tool is demoted to a project only when the brief asks.
test_agent_scope_rules() {
    assert_contains "scope rule points at the promote exception" \
        "An existing tool stays in the scope it is in, unless the next paragraph applies." "$(flat "$AGENT")"
    assert_contains "demote only on request" \
        'The reverse is `--to project`; use it only when the brief asks for it.' "$(flat "$AGENT")"
}

# before <desc> <first> <second> <text>: checks <first> occurs in <text>, and
# before <second>.
before() {
    local head
    case $4 in
        *"$2"*) head=${4%%"$2"*} ;;
        *) t_fail "$1" "missing: $2"; return ;;
    esac
    case $head in
        *"$3"*) t_fail "$1" "'$3' comes before '$2'" ;;
        *) t_pass "$1" ;;
    esac
}

# Outside Claude Code there is no toolsmith agent and no hook, so the skill
# branches on what the agent has. Claude Code's branch comes first, so its
# reader can stop there.
test_skill_harness_branches() {
    local skill branch1 branch2 branch3
    skill=$(flat "$PLUGIN_ROOT/skills/writing-tools/SKILL.md")
    branch1='If your Agent tool offers `toolsmith:toolsmith`'
    branch2='If there is no toolsmith agent but you have a subagent tool'
    branch3="If you have no subagent tool at all, this skill doesn't apply"
    assert_contains "skill has the Claude Code branch" "$branch1" "$skill"
    assert_contains "skill has the generic-subagent branch" "$branch2" "$skill"
    assert_contains "skill has the no-subagent branch" "$branch3" "$skill"
    before "Claude Code branch comes before the generic one" "$branch1" "$branch2" "$skill"
    before "generic branch comes before the no-subagent one" "$branch2" "$branch3" "$skill"
    assert_contains "skill finds the catalogs read-only without a hook" \
        'bin/toolsmith-repo locate --project "$PWD"' "$skill"
    assert_contains "skill puts toolsmith-repo's absolute path in the prompt" \
        'the absolute path of `toolsmith-repo`' "$skill"
    assert_contains "skill names Codex's clean-context spawn" 'fork_turns: "none"' "$skill"
    assert_contains "skill names Gemini's generalist agent" 'agent_name: "generalist"' "$skill"
    assert_contains "skill stops a toolsmith that loads it" \
        "If you are the toolsmith yourself, this skill doesn't apply to you" "$skill"
    before "the toolsmith guard comes before the generic branch" \
        "If you are the toolsmith yourself" "$branch2" "$skill"
    assert_contains "generic catalog search quotes the paths" \
        "grep -s -i -E '<words>' \"<global_catalog>\" \"<project_catalog>\"" "$skill"
    assert_contains "Pi's subagent tool is described, not named" \
        "a subagent tool from the optional pi-subagents package, if installed" "$skill"
}

# The generic branch reaches plugin files by paths relative to the skill's
# directory; every one must exist.
test_skill_relative_paths() {
    local dir rel
    dir="$PLUGIN_ROOT/skills/writing-tools"
    for rel in ../../bin/toolsmith-repo ../../agents/toolsmith.md \
        ../../references/authoring-standards.md ../../references/reply-format.md; do
        assert_contains "skill names $rel" "$rel" "$(flat "$dir/SKILL.md")"
        if [ -f "$dir/$rel" ]; then
            t_pass "$rel exists from the skill's directory"
        else
            t_fail "$rel exists from the skill's directory" "no such file: $dir/$rel"
        fi
    done
}

# Pasted into a generic subagent, the agent prompt has no PATH entry for
# toolsmith-repo and no ${CLAUDE_PLUGIN_ROOT}; the brief carries both.
test_agent_generic_fallbacks() {
    local agent
    agent=$(flat "$AGENT")
    assert_contains "agent uses toolsmith-repo's absolute path when it isn't on PATH" \
        "If \`toolsmith-repo\` isn't on your PATH, use the absolute path your brief gives" "$agent"
    assert_contains "agent uses reference text already in its brief" \
        "If your brief already includes the full text of both files" "$agent"
    # A generic subagent inherits the harness's skills and bootstrap, which
    # tell it to hand tool-writing to the toolsmith: that is itself.
    assert_contains "agent doesn't delegate to itself" \
        "the writing-tools skill and any instruction to call the toolsmith don't apply to you" "$agent"
}

# OpenCode's agent is generated from agents/toolsmith.md, and validate only
# checks it against its own recorded hash, so an agent edit needs a
# regenerate to reach OpenCode.
test_opencode_agent_current() {
    local body='1,/^---$/d'
    assert_eq "OpenCode agent body matches agents/toolsmith.md (run everyharness generate)" \
        "$(sed "$body" "$AGENT")" \
        "$(sed "$body" "$PLUGIN_ROOT/.opencode/agent/toolsmith.md")"
}

# The generic path has only been checked on Claude Code's own scenarios.
test_readme_generic_path_untested() {
    assert_contains "README says the generic path is untested" \
        "untested outside Claude Code" "$(flat "$PLUGIN_ROOT/README.md")"
}

test_validate() {
    if ! command -v claude >/dev/null 2>&1; then
        t_skip "claude plugin validate: claude is not on PATH"
        return
    fi
    new_env
    OUT=$(cd -- "$PLUGIN_ROOT" &&
        HOME="$T_HOME" GIT_CONFIG_GLOBAL="$T_GITCFG" GIT_CONFIG_NOSYSTEM=1 \
            claude plugin validate . 2>&1)
    RC=$?
    ERR=$OUT
    assert_rc "claude plugin validate . exits 0" 0
}

run_tests
