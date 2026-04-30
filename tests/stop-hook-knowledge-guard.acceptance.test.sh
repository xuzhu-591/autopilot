#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# stop-hook-knowledge-guard.acceptance.test.sh
#
# 红队验收测试：验证知识工程模块三个 Bug 的修复
#
# Bug 1: stop-hook 守卫 — knowledge_extracted=skipped 时序绕过
# Bug 2: SKILL.md 硬约束 — merge checklist 无 BLOCKING 标记
# Bug 3: 知识提交路由 — Worktree-Aware Extraction 路由到主仓
#
# 测试基于设计文档编写，不读取蓝队实现代码。
#
# 运行: bash tests/stop-hook-knowledge-guard.acceptance.test.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STOP_HOOK="$REPO_ROOT/plugins/autopilot/scripts/stop-hook.sh"
SKILL_MD="$REPO_ROOT/plugins/autopilot/skills/autopilot/SKILL.md"
MERGE_PHASE_MD="$REPO_ROOT/plugins/autopilot/skills/autopilot/references/merge-phase.md"
KNOWLEDGE_ENG_MD="$REPO_ROOT/plugins/autopilot/skills/autopilot/references/knowledge-engineering.md"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=""

# ── 辅助函数 ──────────────────────────────────────────────────────

setup_temp() {
    TEST_TMPDIR=$(mktemp -d)
    # 创建一个模拟 git 仓库结构
    git init --quiet "$TEST_TMPDIR/repo"
    mkdir -p "$TEST_TMPDIR/repo/.autopilot/requirements/test-task"
}

cleanup_temp() {
    if [[ -n "$TEST_TMPDIR" ]] && [[ -d "$TEST_TMPDIR" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

trap cleanup_temp EXIT

assert_pass() {
    local test_name="$1"
    echo "  PASS: $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_fail() {
    local test_name="$1"
    local detail="${2:-}"
    echo "  FAIL: $test_name"
    if [[ -n "$detail" ]]; then
        echo "        $detail"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# 创建状态文件
# 参数: state_file phase knowledge_extracted changelog_content [extra_sections]
create_state_file() {
    local state_file="$1"
    local phase="$2"
    local knowledge_extracted="$3"
    local changelog_content="$4"
    local extra_sections="${5:-}"

    cat > "$state_file" <<EOF
---
active: true
phase: "$phase"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: ""
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: "$knowledge_extracted"
repos_file: ""
task_dir: "$TEST_TMPDIR/repo/.autopilot/requirements/test-task"
session_id:
started_at: "2026-04-30T00:00:00Z"
---

## 目标
测试知识提取守卫

## 设计文档
这是设计文档区域
$extra_sections

## 实现计划
(略)

## 红队验收测试
(略)

## QA 报告
(略)

## 变更日志
$changelog_content
EOF
}

# 运行 stop-hook.sh 并捕获输出
# 参数: cwd
# 返回: stdout 输出
#
# 注意：stop-hook.sh 使用 `timeout 5 cat` 读取 stdin，但 macOS 可能没有
# timeout 命令，此时 HOOK_INPUT 为空，init_paths 回退到 shell 的 pwd。
# 因此我们需要在 temp repo 目录下执行 stop-hook，使 pwd 回退生效。
# session_id 在状态文件中留空，绕过 session 隔离守卫。
run_stop_hook() {
    local cwd="$1"

    # 在 temp repo 目录下执行 stop-hook.sh
    # stdin 提供空 JSON（timeout cat 在 macOS 上无法读取，但以防万一）
    (cd "$cwd" && bash "$STOP_HOOK" <<< '{}' 2>/dev/null) || true
}

# ============================================================================
# 修复 1: stop-hook 守卫测试
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════"
echo "修复 1: stop-hook 守卫增强 — knowledge_extracted=skipped 验证"
echo "══════════════════════════════════════════════════════════"

# ── 测试 1.1: 拦截测试 ──
# phase=done + knowledge_extracted=skipped + 变更日志不含"知识提取"
# 期望: stop-hook 输出 JSON 包含 "decision":"block" + phase 被回滚到 merge
test_1_1_intercept_skipped_without_evidence() {
    local test_name="1.1 拦截: skipped 但变更日志无证据 → block + 回滚到 merge"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    # 设置 active 指针
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    # 创建状态文件: phase=done, knowledge_extracted=skipped, 变更日志无"知识提取"
    create_state_file "$state_file" "done" "skipped" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化
- [2026-04-30T00:01:00Z] 代码实现完成
- [2026-04-30T00:02:00Z] QA 通过
- [2026-04-30T00:03:00Z] merge 完成"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    # 验证 1: 输出包含 block decision
    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        # 验证 2: phase 被回滚到 merge
        local current_phase
        current_phase=$(grep '^phase:' "$state_file" | head -1 | sed 's/phase: *//; s/"//g')
        if [[ "$current_phase" == "merge" ]]; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "phase 未回滚到 merge, 当前值: $current_phase"
        fi
    else
        assert_fail "$test_name" "未输出 block decision。输出: $output"
    fi

    cleanup_temp
}

# ── 测试 1.2: 正常通过测试 ──
# phase=done + knowledge_extracted=skipped + 变更日志含"知识提取：本次无新增"
# 期望: stop-hook 不输出 block（正常通过，走 done 清理逻辑）
test_1_2_pass_skipped_with_evidence() {
    local test_name="1.2 通过: skipped + 变更日志有知识提取证据 → 正常放行"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    # 变更日志含"知识提取"文本
    create_state_file "$state_file" "done" "skipped" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化
- [2026-04-30T00:01:00Z] 代码实现完成
- [2026-04-30T00:02:00Z] QA 通过
- [2026-04-30T00:03:00Z] merge 完成
- [2026-04-30T00:04:00Z] 知识提取：本次无新增，设 skipped"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    # 验证: 不应输出 block decision（对于 done phase + 正常 skipped，应走清理逻辑）
    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        assert_fail "$test_name" "不应输出 block，但收到: $output"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ── 测试 1.3: 防误判测试 ──
# phase=done + knowledge_extracted=skipped + 设计文档区域含"知识提取"但变更日志区域不含
# 期望: stop-hook 仍然拦截（证据必须在变更日志区域）
test_1_3_false_positive_prevention() {
    local test_name="1.3 防误判: 设计文档含'知识提取'但变更日志不含 → 仍拦截"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    # 设计文档区域含"知识提取"，但变更日志区域不含
    create_state_file "$state_file" "done" "skipped" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化
- [2026-04-30T00:01:00Z] 代码实现完成
- [2026-04-30T00:02:00Z] merge 完成" \
        "
知识提取的设计决策：使用 decisions.md 记录重要决策"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    # 验证: 应输出 block decision（设计文档区域的"知识提取"不能算作证据）
    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        # 验证 phase 被回滚到 merge
        local current_phase
        current_phase=$(grep '^phase:' "$state_file" | head -1 | sed 's/phase: *//; s/"//g')
        if [[ "$current_phase" == "merge" ]]; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "phase 未回滚到 merge, 当前值: $current_phase"
        fi
    else
        assert_fail "$test_name" "应输出 block 但未拦截。输出: $output"
    fi

    cleanup_temp
}

# ── 测试 1.4: knowledge.extract 英文关键词也算证据 ──
# phase=done + knowledge_extracted=skipped + 变更日志含"knowledge extraction"
# 期望: 正常通过（grep -qE 匹配 "knowledge.extract"）
test_1_4_english_keyword_evidence() {
    local test_name="1.4 通过: 变更日志含 'knowledge extraction' 英文证据 → 放行"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    create_state_file "$state_file" "done" "skipped" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化
- [2026-04-30T00:01:00Z] implementation done
- [2026-04-30T00:02:00Z] knowledge extraction: nothing new to add
- [2026-04-30T00:03:00Z] merge complete"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        assert_fail "$test_name" "不应输出 block，英文关键词应算作证据。输出: $output"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ── 测试 1.5: knowledge_extracted=true 仍然正常通过（不受新守卫影响） ──
test_1_5_true_still_passes() {
    local test_name="1.5 回归: knowledge_extracted=true → 不受新守卫影响，正常放行"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    # knowledge_extracted=true，变更日志无需包含证据
    create_state_file "$state_file" "done" "true" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化
- [2026-04-30T00:01:00Z] merge 完成"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        assert_fail "$test_name" "knowledge_extracted=true 不应被拦截。输出: $output"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ── 测试 1.6: knowledge_extracted 为空仍触发旧守卫（回归保护） ──
test_1_6_empty_still_triggers_old_guard() {
    local test_name="1.6 回归: knowledge_extracted 为空 → 旧守卫仍触发回滚"
    setup_temp

    local state_file="$TEST_TMPDIR/repo/.autopilot/requirements/test-task/state.md"

    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active.$$"
    echo "test-task" > "$TEST_TMPDIR/repo/.autopilot/active"

    # knowledge_extracted 为空
    create_state_file "$state_file" "done" "" \
        "- [2026-04-30T00:00:00Z] autopilot 初始化"

    local output
    output=$(run_stop_hook "$TEST_TMPDIR/repo")

    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "knowledge_extracted 为空应被旧守卫拦截。输出: $output"
    fi

    cleanup_temp
}

# 运行修复 1 的所有测试
test_1_1_intercept_skipped_without_evidence
test_1_2_pass_skipped_with_evidence
test_1_3_false_positive_prevention
test_1_4_english_keyword_evidence
test_1_5_true_still_passes
test_1_6_empty_still_triggers_old_guard

# ============================================================================
# 修复 2: SKILL.md 内容验证
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════"
echo "修复 2: SKILL.md 硬编码知识提取时序验证"
echo "══════════════════════════════════════════════════════════"

# ── 测试 2.1: SKILL.md merge checklist 包含 BLOCKING 标记 ──
test_2_1_skill_md_blocking_marker() {
    local test_name="2.1 SKILL.md merge checklist 包含 BLOCKING 标记"

    if [[ ! -f "$SKILL_MD" ]]; then
        assert_fail "$test_name" "SKILL.md 文件不存在: $SKILL_MD"
        return
    fi

    # 验证 SKILL.md 中知识提取步骤带有 BLOCKING 标记
    if grep -qi "BLOCKING" "$SKILL_MD"; then
        # 进一步验证 BLOCKING 与知识提取在相关上下文中
        # 搜索 merge 阶段附近是否有 BLOCKING + 知识相关内容
        if grep -iE "(知识|knowledge).*BLOCKING|BLOCKING.*(知识|knowledge)" "$SKILL_MD" >/dev/null 2>&1 || \
           { grep -n "BLOCKING" "$SKILL_MD" >/dev/null 2>&1 && grep -n "merge" "$SKILL_MD" >/dev/null 2>&1; }; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "BLOCKING 标记存在但可能与知识提取/merge 无关"
        fi
    else
        assert_fail "$test_name" "SKILL.md 中未找到 BLOCKING 标记"
    fi
}

# ── 测试 2.2: phase: done 步骤有前置条件文本 ──
test_2_2_phase_done_precondition() {
    local test_name="2.2 SKILL.md phase:done 步骤有前置条件"

    if [[ ! -f "$SKILL_MD" ]]; then
        assert_fail "$test_name" "SKILL.md 文件不存在: $SKILL_MD"
        return
    fi

    # 验证存在 phase: done 的前置条件说明
    # 设计文档要求: `phase: done` 增加前置条件：knowledge_extracted 已设置 + 变更日志有知识提取记录
    local has_precondition=false

    # 搜索 knowledge_extracted 与 phase.*done 或 done 前置条件的关联
    if grep -E "knowledge_extracted.*(前置|precondition|before|必须|MUST|BLOCKING)" "$SKILL_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi
    # 也检查反向：前置条件文本引用 knowledge_extracted
    if grep -E "(前置条件|precondition).*(knowledge_extracted|知识提取)" "$SKILL_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi
    # 检查 done 设置步骤是否有 knowledge 前置约束
    if grep -E "phase.*done.*(knowledge|知识)" "$SKILL_MD" >/dev/null 2>&1 || \
       grep -E "(knowledge|知识).*(phase.*done|设.*done)" "$SKILL_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi

    if [[ "$has_precondition" == "true" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "SKILL.md 中未找到 phase:done 的知识提取前置条件"
    fi
}

# ── 测试 2.3: merge-phase.md 步骤 3 标注"MUST before step 5" ──
test_2_3_merge_phase_step_ordering() {
    local test_name="2.3 merge-phase.md 知识提取步骤标注为必须先于 phase:done"

    if [[ ! -f "$MERGE_PHASE_MD" ]]; then
        assert_fail "$test_name" "merge-phase.md 文件不存在: $MERGE_PHASE_MD"
        return
    fi

    # 设计文档: merge-phase.md 步骤 3 标注"MUST before step 5"
    # 以及步骤 5 增加前置条件
    local has_ordering=false

    # 检查 MUST + before + step 的组合
    if grep -iE "MUST.*before.*step" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_ordering=true
    fi
    # 也检查中文等价表达
    if grep -E "必须.*(之前|先于|前置)" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_ordering=true
    fi
    # 检查前置条件文本
    if grep -iE "(precondition|前置条件|prerequisite)" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_ordering=true
    fi

    if [[ "$has_ordering" == "true" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "merge-phase.md 未找到知识提取步骤的顺序约束"
    fi
}

# ── 测试 2.4: merge-phase.md 步骤 5 增加前置条件 ──
test_2_4_merge_phase_step5_precondition() {
    local test_name="2.4 merge-phase.md phase:done 步骤有前置条件"

    if [[ ! -f "$MERGE_PHASE_MD" ]]; then
        assert_fail "$test_name" "merge-phase.md 文件不存在: $MERGE_PHASE_MD"
        return
    fi

    # 验证 phase:done 相关步骤提到 knowledge_extracted 前置条件
    local has_precondition=false

    if grep -E "(knowledge_extracted|知识提取).*(前置|precondition|before|MUST|必须)" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi
    if grep -E "(done|完成).*(knowledge_extracted|知识提取)" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi
    # 也检查变更日志证据要求
    if grep -E "(变更日志|changelog).*(证据|evidence|记录|knowledge)" "$MERGE_PHASE_MD" >/dev/null 2>&1; then
        has_precondition=true
    fi

    if [[ "$has_precondition" == "true" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "merge-phase.md phase:done 步骤未提及 knowledge_extracted 前置条件"
    fi
}

# 运行修复 2 的所有测试
test_2_1_skill_md_blocking_marker
test_2_2_phase_done_precondition
test_2_3_merge_phase_step_ordering
test_2_4_merge_phase_step5_precondition

# ============================================================================
# 修复 3: knowledge-engineering.md 内容验证
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════"
echo "修复 3: 知识提交统一到当前工作分支验证"
echo "══════════════════════════════════════════════════════════"

# ── 测试 3.1: 旧的 MAIN_REPO 提交模式已移除 ──
test_3_1_main_repo_removed() {
    local test_name="3.1 旧 MAIN_REPO 提交路由已移除"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档: 旧的 `git -C "$MAIN_REPO"` 提交模式已被移除
    if grep -E 'git\s+-C\s+.*MAIN_REPO' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        assert_fail "$test_name" "仍包含 git -C \$MAIN_REPO 提交模式"
    elif grep -E 'MAIN_REPO' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        # MAIN_REPO 引用可能以其他形式存在（如变量赋值），检查是否在 git 命令上下文中
        if grep -E 'git.*(commit|add|push).*MAIN_REPO|MAIN_REPO.*(git|commit|add|push)' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
            assert_fail "$test_name" "仍包含 MAIN_REPO 相关的 git 提交逻辑"
        else
            # MAIN_REPO 可能只是在解释旧行为的上下文中被提及，不算提交模式
            assert_pass "$test_name"
        fi
    else
        assert_pass "$test_name"
    fi
}

# ── 测试 3.2: 新增物化符号链接步骤（cp -rL） ──
test_3_2_materialize_symlink() {
    local test_name="3.2 新增物化符号链接步骤 (cp -rL)"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档: 符号链接场景使用物化（cp -rL）→ 提交 → 恢复符号链接
    local has_materialize=false

    # 检查 cp -rL 命令
    if grep -E 'cp\s+-rL' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_materialize=true
    fi
    # 也检查等价的 cp 选项组合（如 cp -r -L、cp --dereference）
    if grep -E 'cp\s+.*-L|--dereference' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_materialize=true
    fi

    if [[ "$has_materialize" == "true" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "未找到 cp -rL 物化符号链接步骤"
    fi
}

# ── 测试 3.3: readlink 检测符号链接 ──
test_3_3_readlink_check() {
    local test_name="3.3 包含 readlink 检测符号链接"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档提到使用 readlink 检测符号链接
    if grep -E 'readlink' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        assert_pass "$test_name"
    else
        # 也检查等价的符号链接检测方式
        if grep -E '(-L\s|test\s+-L|if\s+\[.*-L)' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "未找到 readlink 或等价的符号链接检测"
        fi
    fi
}

# ── 测试 3.4: 恢复符号链接步骤存在 ──
test_3_4_restore_symlink() {
    local test_name="3.4 恢复符号链接步骤存在"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档: 物化 → 提交 → 恢复符号链接
    local has_restore=false

    # 检查 ln -s (创建/恢复符号链接)
    if grep -E 'ln\s+-s' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_restore=true
    fi
    # 也检查中文描述
    if grep -E '恢复符号链接|恢复.*symlink|restore.*symlink|还原.*链接' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_restore=true
    fi

    if [[ "$has_restore" == "true" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "未找到恢复符号链接的步骤 (ln -s 或相关描述)"
    fi
}

# ── 测试 3.5: 两分支逻辑（符号链接 vs 非符号链接） ──
test_3_5_two_branch_logic() {
    local test_name="3.5 两分支逻辑: 符号链接 vs 非符号链接"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档: Worktree-Aware Extraction 改为两分支逻辑
    # 需要同时有符号链接分支和非符号链接/直接提交分支
    local has_symlink_branch=false
    local has_direct_branch=false

    # 检查符号链接分支（包含物化相关关键词）
    if grep -E '符号链接|symlink|symbolic' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_symlink_branch=true
    fi

    # 检查非符号链接/直接分支（直接 git add + commit）
    if grep -E '非符号链接|直接.*(git add|commit)|非.*symlink|not.*symlink|without.*symlink' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_direct_branch=true
    fi
    # 也检查条件分支结构
    if grep -E '(否则|else|otherwise|非链接|不是.*链接)' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_direct_branch=true
    fi

    if [[ "$has_symlink_branch" == "true" ]] && [[ "$has_direct_branch" == "true" ]]; then
        assert_pass "$test_name"
    else
        local detail=""
        [[ "$has_symlink_branch" != "true" ]] && detail="缺少符号链接分支 "
        [[ "$has_direct_branch" != "true" ]] && detail="${detail}缺少非符号链接分支"
        assert_fail "$test_name" "$detail"
    fi
}

# ── 测试 3.6: 不再路由到主仓库（三分支变两分支） ──
test_3_6_no_main_repo_route() {
    local test_name="3.6 不再包含三分支中的'路由到主仓库'分支"

    if [[ ! -f "$KNOWLEDGE_ENG_MD" ]]; then
        assert_fail "$test_name" "knowledge-engineering.md 文件不存在: $KNOWLEDGE_ENG_MD"
        return
    fi

    # 设计文档: 旧版有三分支（符号链接 / worktree 无符号链接 / 非 worktree）
    # 新版改为两分支（符号链接 / 非符号链接），不再路由到 MAIN_REPO
    # 检查旧的提交到主仓库的**指令性**模式是否被移除
    local has_main_repo_commit=false

    # 检查 git -C "$MAIN_REPO" 代码模式
    if grep -E 'git\s+-C\s+"\$MAIN_REPO"' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_main_repo_commit=true
    fi
    # 检查 cd "$MAIN_REPO" 代码模式
    if grep -E 'cd\s+"\$MAIN_REPO"|cd\s+\$MAIN_REPO' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_main_repo_commit=true
    fi
    # 检查旧的三分支中"非 worktree"场景提交到主仓的指令
    if grep -E '(切换到|切回|回到|cd.*)(主仓库|原始仓库|main.repo).*(commit|提交|git add)' "$KNOWLEDGE_ENG_MD" >/dev/null 2>&1; then
        has_main_repo_commit=true
    fi

    if [[ "$has_main_repo_commit" == "true" ]]; then
        assert_fail "$test_name" "仍包含路由到主仓库的提交指令"
    else
        assert_pass "$test_name"
    fi
}

# 运行修复 3 的所有测试
test_3_1_main_repo_removed
test_3_2_materialize_symlink
test_3_3_readlink_check
test_3_4_restore_symlink
test_3_5_two_branch_logic
test_3_6_no_main_repo_route

# ============================================================================
# 结果汇总
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════"
echo "测试结果汇总"
echo "══════════════════════════════════════════════════════════"
echo "  通过: $PASS_COUNT"
echo "  失败: $FAIL_COUNT"
echo "  总计: $((PASS_COUNT + FAIL_COUNT))"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "FAILED: $FAIL_COUNT 个测试未通过"
    exit 1
else
    echo "ALL PASSED"
    exit 0
fi
