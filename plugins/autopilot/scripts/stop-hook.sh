#!/bin/bash

# autopilot Stop Hook — 门卫 + 续接（v4.1.1）
# 路径解析 → session 隔离 → 审批门 → done 清理 → 迭代上限 → 续接。
# 阶段未完成且无 gate 时输出 block JSON，让 Claude Code 自动续接下一轮。
#
# 安全策略：任何未预期的错误都放行（exit 0）。
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── 0. 读 stdin ──

HOOK_INPUT=$(timeout 5 cat 2>/dev/null || true)
HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)

[[ -z "$HOOK_SESSION" ]] && exit 0

init_paths "$HOOK_CWD" "$HOOK_SESSION" "true"

if [[ -z "$STATE_FILE" ]] || [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# ── 1. 解析 ──

PHASE=$(get_field "phase" || true)
GATE=$(get_field "gate" || true)
ITERATION=$(get_field "iteration" || true)
MAX_ITERATIONS=$(get_field "max_iterations" || true)
STATE_SESSION=$(get_field "session_id" || true)

# ── 2. Session 隔离 ──

if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
    exit 0
fi

# ── 3. 审批门 ──

if [[ -n "$GATE" ]]; then
    bash "$SCRIPT_DIR/notify.sh" "$GATE" 2>/dev/null || true
    exit 0
fi

# ── 4. phase=done → 清理 ──

if [[ "$PHASE" == "done" ]]; then
    bash "$SCRIPT_DIR/notify.sh" complete 2>/dev/null || true
    cleanup_active "$HOOK_SESSION"
    exit 0
fi

# ── 5. max_iterations ──

[[ ! "$ITERATION" =~ ^[0-9]+$ ]] && ITERATION=0
[[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] && MAX_ITERATIONS=30

if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
    echo "autopilot: 达到最大迭代次数 ($MAX_ITERATIONS)。" >&2
    bash "$SCRIPT_DIR/notify.sh" error 2>/dev/null || true
    cleanup_active "$HOOK_SESSION"
    exit 0
fi

# ── 6. 递增 iteration ──

set_field "iteration" "$((ITERATION + 1))"

# ── 7. 续接 ──
# phase 未完成 + 无 gate → 输出 block JSON，Claude Code 注入 prompt 续接下一轮

printf '{"decision":"block","reason":"继续执行 autopilot（当前 phase: %s）。读取状态文件，按 skill 指引执行当前阶段工作流。"}\n' "$PHASE"
