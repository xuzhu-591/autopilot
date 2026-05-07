#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# deprecate-active-singleton.acceptance.test.sh
#
# 红队验收测试：废弃 active 单例文件，统一 PID 路由
#
# 验证点：
# 1. init_paths() 不再读取 .autopilot/active，仅用 active.{PID} 或扫描 requirements/
# 2. setup_requirement_dir() 不再写入 .autopilot/active
# 3. cleanup_active() 不再删除 .autopilot/active
# 4. cleanup_stale_actives() 移除残留的 .autopilot/active
# 5. 无 PID 指针 + 恰好 1 个活跃任务 → init_paths 自动绑定
# 6. 无 PID 指针 + 多个活跃任务 → init_paths 不自动绑定
# 7. continue.sh 仅写入 active.$PPID，不写 active
#
# 测试基于设计文档编写，不读取蓝队实现代码。
#
# 运行: bash tests/deprecate-active-singleton.acceptance.test.sh
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_SH="$REPO_ROOT/plugins/autopilot/scripts/lib.sh"
CONTINUE_SH="$REPO_ROOT/plugins/autopilot/scripts/continue.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=""

# ── 辅助函数 ──────────────────────────────────────────────────────

setup_temp() {
    TEST_TMPDIR=$(mktemp -d)
    # 创建模拟 git 仓库
    git init --quiet "$TEST_TMPDIR/repo"
    mkdir -p "$TEST_TMPDIR/repo/.autopilot/requirements"
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

# 创建一个最小的状态文件
# 参数: state_file_path phase
create_minimal_state() {
    local state_file="$1"
    local phase="$2"
    mkdir -p "$(dirname "$state_file")"
    cat > "$state_file" <<EOF
---
active: true
phase: "$phase"
gate: ""
iteration: 1
max_iterations: 30
max_retries: 3
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: false
knowledge_extracted: ""
task_dir: "$(dirname "$state_file")"
session_id:
started_at: "2026-05-07T00:00:00Z"
---

## 目标
测试任务

## 设计文档
(略)

## 实现计划
(略)

## 红队验收测试
(略)

## QA 报告
(略)

## 变更日志
- [2026-05-07T00:00:00Z] 初始化
EOF
}

# 辅助：在独立 bash 子进程中 source lib.sh 并执行命令，返回 stdout
# 参数: 要执行的 bash 脚本片段
# 用法: run_in_bash "init_paths ... ; echo \$STATE_FILE"
run_in_bash() {
    bash -c "
        source \"$LIB_SH\"
        $1
    " 2>/dev/null || true
}

# ============================================================================
# 测试 1: init_paths 使用 PID 路由，忽略 active 单例
# ============================================================================

echo ""
echo "══════════════════════════════════════════════════════════"
echo "测试组: 废弃 active 单例文件，统一 PID 路由"
echo "══════════════════════════════════════════════════════════"

test_1_pid_routing_exclusive() {
    local test_name="1. init_paths 使用 PID 路由，忽略 active 单例指向的不同 slug"
    setup_temp

    local repo="$TEST_TMPDIR/repo"

    # 创建两个任务目录
    mkdir -p "$repo/.autopilot/requirements/task-pid"
    mkdir -p "$repo/.autopilot/requirements/task-singleton"
    create_minimal_state "$repo/.autopilot/requirements/task-pid/state.md" "implement"
    create_minimal_state "$repo/.autopilot/requirements/task-singleton/state.md" "design"

    # PID 文件指向 task-pid
    echo "task-pid" > "$repo/.autopilot/active.12345"
    # active 单例指向 task-singleton（不同的 slug）
    echo "task-singleton" > "$repo/.autopilot/active"

    local result
    result=$(run_in_bash "init_paths '$repo' '12345'; echo \"\$STATE_FILE\"")

    if [[ "$result" == *"/task-pid/state.md" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "STATE_FILE=$result (应包含 task-pid)"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 2: init_paths 不回退到 active 单例
# ============================================================================

test_2_no_fallback_to_active() {
    local test_name="2. init_paths 无 PID 文件时不读取 active 单例（通过扫描发现任务）"
    setup_temp

    local repo="$TEST_TMPDIR/repo"

    # 创建任务目录
    mkdir -p "$repo/.autopilot/requirements/task-old"
    create_minimal_state "$repo/.autopilot/requirements/task-old/state.md" "implement"

    # 只有 active 单例，没有 PID 文件
    echo "task-old" > "$repo/.autopilot/active"
    # 另外创建一个指向不同 slug 的 active 单例（验证不是从 active 读的）
    echo "nonexistent-slug" > "$repo/.autopilot/active"

    # 使用一个不存在 active 文件的 PID
    local result
    result=$(run_in_bash "init_paths '$repo' '99999'; echo \"\$STATE_FILE\"")

    # STATE_FILE 应指向 task-old（通过扫描 requirements/ 发现，非读取 active 单例）
    # active 单例指向 nonexistent-slug，但扫描逻辑找到了 task-old
    if [[ "$result" == *"/task-old/state.md" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "STATE_FILE 应通过扫描找到 task-old，实际: $result"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 3: init_paths 自动绑定唯一活跃任务
# ============================================================================

test_3_auto_bind_single_task() {
    local test_name="3. init_paths 无 PID 指针时自动绑定唯一活跃任务"
    setup_temp

    local repo="$TEST_TMPDIR/repo"
    local my_pid="77777"

    # 创建唯一的活跃任务（非 done 阶段）
    mkdir -p "$repo/.autopilot/requirements/task-a"
    create_minimal_state "$repo/.autopilot/requirements/task-a/state.md" "implement"

    # 没有任何 active.* 文件

    local result
    result=$(run_in_bash "init_paths '$repo' '$my_pid'; echo \"\$STATE_FILE\"")

    if [[ "$result" == *"/task-a/state.md" ]]; then
        # 验证 active.$my_pid 被创建
        if [[ -f "$repo/.autopilot/active.$my_pid" ]]; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "STATE_FILE 正确但 active.$my_pid 未被创建"
        fi
    else
        assert_fail "$test_name" "STATE_FILE=$result (应指向 task-a)"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 4: init_paths 多任务时不自动绑定
# ============================================================================

test_4_no_auto_bind_multiple_tasks() {
    local test_name="4. init_paths 多活跃任务时不自动绑定"
    setup_temp

    local repo="$TEST_TMPDIR/repo"
    local my_pid="77777"

    # 创建两个活跃任务
    mkdir -p "$repo/.autopilot/requirements/task-a"
    mkdir -p "$repo/.autopilot/requirements/task-b"
    create_minimal_state "$repo/.autopilot/requirements/task-a/state.md" "implement"
    create_minimal_state "$repo/.autopilot/requirements/task-b/state.md" "qa"

    # 没有任何 active.* 文件

    local result
    result=$(run_in_bash "init_paths '$repo' '$my_pid'; echo \"\$STATE_FILE\"")

    if [[ -z "$result" ]] || [[ "$result" == "" ]]; then
        # 验证没有创建 active.$my_pid
        if [[ ! -f "$repo/.autopilot/active.$my_pid" ]]; then
            assert_pass "$test_name"
        else
            assert_fail "$test_name" "STATE_FILE 为空但 active.$my_pid 被意外创建"
        fi
    else
        assert_fail "$test_name" "STATE_FILE 应为空但得到: $result"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 5: init_paths 跳过被活跃 PID 持有的任务
# ============================================================================

test_5_skip_task_held_by_live_pid() {
    local test_name="5. init_paths 跳过被活跃 PID 持有的任务（不自动绑定）"
    setup_temp

    local repo="$TEST_TMPDIR/repo"
    local my_pid="77777"
    # 使用当前 shell 的 PPID 作为"活跃进程"（kill -0 $PPID 一定成功）
    local holder_pid="$$"

    # 创建唯一的活跃任务
    mkdir -p "$repo/.autopilot/requirements/task-a"
    create_minimal_state "$repo/.autopilot/requirements/task-a/state.md" "implement"

    # task-a 被 holder_pid 持有
    echo "task-a" > "$repo/.autopilot/active.$holder_pid"

    local result
    result=$(run_in_bash "init_paths '$repo' '$my_pid'; echo \"\$STATE_FILE\"")

    # STATE_FILE 应为空（task-a 被其他 session 持有）
    if [[ -z "$result" ]] || [[ "$result" == "" ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "STATE_FILE 应为空但得到: $result (task-a 被 PID $holder_pid 持有)"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 6: setup_requirement_dir 不创建 active 单例
# ============================================================================

test_6_setup_no_active_singleton() {
    local test_name="6. setup_requirement_dir 不创建 active 单例文件"
    setup_temp

    local repo="$TEST_TMPDIR/repo"
    local my_pid="77777"

    # 在子进程中执行，因为 setup_requirement_dir 会修改文件系统
    bash -c "
        source '$LIB_SH'
        init_paths '$repo' '$my_pid'
        setup_requirement_dir 'my-slug' '$my_pid'
    " 2>/dev/null || true

    # 验证 active.$my_pid 存在且内容正确
    if [[ ! -f "$repo/.autopilot/active.$my_pid" ]]; then
        assert_fail "$test_name" "active.$my_pid 未被创建"
        cleanup_temp
        return
    fi

    local content
    content=$(cat "$repo/.autopilot/active.$my_pid")
    if [[ "$content" != "my-slug" ]]; then
        assert_fail "$test_name" "active.$my_pid 内容错误: $content"
        cleanup_temp
        return
    fi

    # 验证 active 单例不存在
    if [[ -f "$repo/.autopilot/active" ]]; then
        assert_fail "$test_name" "active 单例不应被创建"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 7: cleanup_active 只移除 PID 文件，不动 active 单例
# ============================================================================

test_7_cleanup_only_pid_file() {
    local test_name="7. cleanup_active 只移除 PID 文件，不删除 active 单例"
    setup_temp

    local repo="$TEST_TMPDIR/repo"
    local my_pid="77777"

    # 创建任务
    mkdir -p "$repo/.autopilot/requirements/my-task"
    create_minimal_state "$repo/.autopilot/requirements/my-task/state.md" "done"

    # 创建两个文件
    echo "my-task" > "$repo/.autopilot/active.$my_pid"
    echo "my-task" > "$repo/.autopilot/active"

    bash -c "
        source '$LIB_SH'
        PROJECT_ROOT='$repo'
        TASK_DIR='$repo/.autopilot/requirements/my-task'
        STATE_FILE='\$TASK_DIR/state.md'
        cleanup_active '$my_pid'
    " 2>/dev/null || true

    # 验证 PID 文件已移除
    if [[ -f "$repo/.autopilot/active.$my_pid" ]]; then
        assert_fail "$test_name" "active.$my_pid 应被删除但仍存在"
        cleanup_temp
        return
    fi

    # 验证 active 单例仍然存在（cleanup_active 不再管它）
    if [[ ! -f "$repo/.autopilot/active" ]]; then
        assert_fail "$test_name" "active 单例不应被删除但已被移除"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 8: cleanup_stale_actives 移除残留 active 文件
# ============================================================================

test_8_cleanup_stale_removes_singleton() {
    local test_name="8. cleanup_stale_actives 移除残留 active 单例和死 PID 文件"
    setup_temp

    local repo="$TEST_TMPDIR/repo"

    # 创建残留的 active 单例
    echo "old-task" > "$repo/.autopilot/active"
    # 创建一个死 PID 的 active 文件（PID 99998 几乎不可能存活）
    echo "dead-task" > "$repo/.autopilot/active.99998"

    bash -c "
        source '$LIB_SH'
        PROJECT_ROOT='$repo'
        cleanup_stale_actives
    " 2>/dev/null || true

    local failed=0

    # 验证 active 单例被移除
    if [[ -f "$repo/.autopilot/active" ]]; then
        echo "        active 单例仍存在（应被 cleanup_stale_actives 移除）"
        failed=1
    fi

    # 验证死 PID 文件被移除
    if [[ -f "$repo/.autopilot/active.99998" ]]; then
        echo "        active.99998 仍存在（应被移除）"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "见上方详细信息"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 9: 并行 session 互不干扰
# ============================================================================

test_9_parallel_sessions() {
    local test_name="9. 并行 session 互不干扰"
    setup_temp

    local repo="$TEST_TMPDIR/repo"

    # 创建两个任务
    mkdir -p "$repo/.autopilot/requirements/task-a"
    mkdir -p "$repo/.autopilot/requirements/task-b"
    create_minimal_state "$repo/.autopilot/requirements/task-a/state.md" "implement"
    create_minimal_state "$repo/.autopilot/requirements/task-b/state.md" "qa"

    # 两个不同 PID 分别指向不同任务
    echo "task-a" > "$repo/.autopilot/active.111"
    echo "task-b" > "$repo/.autopilot/active.222"

    # session 111 应看到 task-a
    local result_111
    result_111=$(run_in_bash "init_paths '$repo' '111'; echo \"\$STATE_FILE\"")

    # session 222 应看到 task-b
    local result_222
    result_222=$(run_in_bash "init_paths '$repo' '222'; echo \"\$STATE_FILE\"")

    local failed=0

    if [[ "$result_111" != *"/task-a/state.md" ]]; then
        echo "        session 111 应指向 task-a 但实际: $result_111"
        failed=1
    fi

    if [[ "$result_222" != *"/task-b/state.md" ]]; then
        echo "        session 222 应指向 task-b 但实际: $result_222"
        failed=1
    fi

    if [[ $failed -eq 0 ]]; then
        assert_pass "$test_name"
    else
        assert_fail "$test_name" "并行 session 路由结果不正确"
    fi

    cleanup_temp
}

# ============================================================================
# 测试 10: continue.sh 只写 active.$PPID，不写 active
# ============================================================================

test_10_continue_only_writes_pid_file() {
    local test_name="10. continue.sh 只写 active.\$PPID，不写 active 单例"
    setup_temp

    local repo="$TEST_TMPDIR/repo"

    # 创建一个未完成任务
    mkdir -p "$repo/.autopilot/requirements/task-continue"
    create_minimal_state "$repo/.autopilot/requirements/task-continue/state.md" "implement"

    # 确保没有 active 文件
    rm -f "$repo/.autopilot/active"
    rm -f "$repo/.autopilot"/active.*

    # 运行 continue.sh（传入序号 1 自动选择）
    (cd "$repo" && bash "$CONTINUE_SH" 1) >/dev/null 2>&1 || true

    # 验证没有写入 active 单例
    if [[ -f "$repo/.autopilot/active" ]]; then
        assert_fail "$test_name" "continue.sh 不应写入 active 单例文件"
    else
        assert_pass "$test_name"
    fi

    cleanup_temp
}

# ============================================================================
# 执行所有测试
# ============================================================================

test_1_pid_routing_exclusive
test_2_no_fallback_to_active
test_3_auto_bind_single_task
test_4_no_auto_bind_multiple_tasks
test_5_skip_task_held_by_live_pid
test_6_setup_no_active_singleton
test_7_cleanup_only_pid_file
test_8_cleanup_stale_removes_singleton
test_9_parallel_sessions
test_10_continue_only_writes_pid_file

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
