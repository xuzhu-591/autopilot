#!/bin/bash

# autopilot 共享函数库
# setup.sh 和 stop-hook.sh 共用的 frontmatter 操作工具
#
# 使用方式：source lib.sh 后调用 init_paths [cwd]
# cwd 可选，传入时会 cd 到该目录再解析路径（解决 worktree 场景下 hook CWD 不可靠问题）

PROJECT_ROOT=""
STATE_FILE=""
TASK_DIR=""

# ── 内部辅助：通过进程树找到 Claude Code 主进程 PID ──────────────
# 仅供 get_claude_session_id() 内部使用，不对外暴露。
_get_claude_pid() {
    local pid=$$
    while [ "$pid" -gt 1 ]; do
        local cmd
        cmd=$(ps -o comm= -p "$pid" 2>/dev/null) || break
        if echo "$cmd" | grep -qi "claude"; then
            echo "$pid"
            return 0
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    echo "$PPID"
}

# 获取当前 Claude Code 会话的 session ID。
# 优先级：
#   1. $CLAUDE_CODE_SESSION_ID 环境变量
#   2. ~/.claude/sessions/<PID>.json 中的 sessionId 字段（通过进程树找 PID）
#   获取不到 → 返回空字符串 + return 1（由调用方决定是否中断）
get_claude_session_id() {
    # 尝试1：从环境变量读取
    if [[ -n "${CLAUDE_CODE_SESSION_ID:-}" ]]; then
        echo "$CLAUDE_CODE_SESSION_ID"
        return 0
    fi

    # 尝试2：通过 PID 从 sessions 文件读取
    local pid
    pid=$(_get_claude_pid)
    local sessions_file="$HOME/.claude/sessions/${pid}.json"
    if [[ -f "$sessions_file" ]]; then
        local sid
        sid=$(grep -o '"sessionId":"[^"]*"' "$sessions_file" 2>/dev/null \
              | sed 's/"sessionId":"//;s/"//' | head -1)
        if [[ -n "$sid" ]]; then
            echo "$sid"
            return 0
        fi
    fi

    # 获取失败
    return 1
}

CLAUDE_SESSION_ID="$(get_claude_session_id)" || true
export CLAUDE_SESSION_ID

# 检查指定 session ID 是否仍存活（在 ~/.claude/sessions/ 中找到对应记录）。
# 参数: session_id (UUID 格式)
# 返回: 0=存活, 1=不存在/已过期
_session_is_alive() {
    local sid="$1"
    [[ -z "$sid" ]] && return 1
    local sessions_dir="$HOME/.claude/sessions"
    [[ -d "$sessions_dir" ]] || return 1
    local f
    for f in "$sessions_dir"/*.json; do
        [[ -f "$f" ]] || continue
        if grep -q "\"sessionId\":\"${sid}\"" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

init_paths() {
    local target_cwd="${1:-}"
    local caller_session="${2:-$CLAUDE_SESSION_ID}"
    local strict="${3:-false}"
    if [[ -n "$target_cwd" ]] && [[ -d "$target_cwd" ]]; then
        cd "$target_cwd" || return
    fi
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    # Session ID 为空时无法路由
    if [[ -z "$caller_session" ]]; then
        STATE_FILE=""
        TASK_DIR=""
        return
    fi

    # Session-based 路由
    local session_active="$PROJECT_ROOT/.autopilot/active.session.$caller_session"
    if [[ -f "$session_active" ]]; then
        local slug
        slug=$(cat "$session_active")
        TASK_DIR="$PROJECT_ROOT/.autopilot/requirements/$slug"
        STATE_FILE="$TASK_DIR/state.md"
        return
    fi

    # strict 模式：仅 session 路由，不回退（stop-hook 使用，防止跨 session 劫持）
    if [[ "$strict" == "true" ]]; then
        STATE_FILE=""
        TASK_DIR=""
        return
    fi

    # 扫描 requirements/ 中唯一活跃且未被其他 session 持有的任务，自动绑定
    local req_dir="$PROJECT_ROOT/.autopilot/requirements"
    if [[ -d "$req_dir" ]]; then
        # 收集已被活跃 session 持有的 slug
        local held_slugs=""
        for af in "$PROJECT_ROOT/.autopilot"/active.session.*; do
            [[ -f "$af" ]] || continue
            local af_sid="${af##*/active.session.}"
            if _session_is_alive "$af_sid"; then
                held_slugs="${held_slugs}|$(cat "$af")"
            fi
        done

        # 扫描未完成且未被持有的任务
        local candidates=()
        local candidate_dirs=()
        while IFS= read -r sf; do
            [[ -f "$sf" ]] || continue
            local sf_phase
            sf_phase=$(sed -n 's/^phase: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$sf")
            [[ "$sf_phase" == "done" || -z "$sf_phase" ]] && continue
            local sf_slug
            sf_slug=$(basename "$(dirname "$sf")")
            # 跳过已被其他 session 持有的
            if [[ -n "$held_slugs" ]] && echo "$held_slugs" | grep -qF "|$sf_slug"; then
                continue
            fi
            candidates+=("$sf_slug")
            candidate_dirs+=("$(dirname "$sf")")
        done < <(find "$req_dir" -maxdepth 2 -name "state.md" 2>/dev/null | sort -r)

        if [[ ${#candidates[@]} -eq 1 ]]; then
            # 唯一活跃任务，自动绑定
            echo "${candidates[0]}" > "$session_active"
            TASK_DIR="${candidate_dirs[0]}"
            STATE_FILE="$TASK_DIR/state.md"
        else
            # 0 或多个候选，无法自动绑定
            STATE_FILE=""
            TASK_DIR=""
        fi
    else
        STATE_FILE="$PROJECT_ROOT/.autopilot/autopilot.local.md"
        TASK_DIR=""
    fi
}

parse_frontmatter() {
    [[ ! -f "$STATE_FILE" ]] && { echo ""; return; }
    sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE"
}

get_field() {
    local fm; fm=$(parse_frontmatter)
    echo "$fm" | grep "^${1}:" | sed "s/${1}: *//" | sed 's/^"\(.*\)"$/\1/'
}

set_field() {
    local temp="${STATE_FILE}.tmp.$$"
    sed "s/^${1}: .*/${1}: ${2}/" "$STATE_FILE" > "$temp"
    mv "$temp" "$STATE_FILE"
}

append_changelog() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local temp="${STATE_FILE}.tmp.$$"
    awk -v entry="- [${ts}] ${1}" \
        '/^## 变更日志/ { print; getline; print entry; print; next } { print }' \
        "$STATE_FILE" > "$temp"
    mv "$temp" "$STATE_FILE"
}

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ── Task Slug 生成 ──────────────────────────────────────────────

# 生成需求管理文件夹的 slug。格式: YYYYMMDD-<目标前30字符清洗>
# 参数: goal (目标描述文本)
generate_task_slug() {
    local goal="$1"
    local date_prefix
    date_prefix=$(date +%Y%m%d)
    # 取前 30 字符，替换空格和特殊字符为连字符，去除尾部连字符
    local slug
    slug=$(printf '%.30s' "$goal" | tr ' /:*?"<>|\\' '-' | sed 's/-*$//' | sed 's/^-*//')
    # 空 slug 时使用时间戳
    if [[ -z "$slug" ]]; then
        slug="task-$(date +%H%M%S)"
    fi
    echo "${date_prefix}-${slug}"
}

# ── 需求管理路径设置 ────────────────────────────────────────────

# 创建 requirements 文件夹并设置 active 指针和路径变量。
# 参数: slug [session_id]
# 副作用: 更新 TASK_DIR, STATE_FILE 全局变量；写入 active 指针（session 格式）
setup_requirement_dir() {
    local slug="$1"
    local session_id="${2:-$CLAUDE_SESSION_ID}"
    TASK_DIR="$PROJECT_ROOT/.autopilot/requirements/$slug"
    mkdir -p "$TASK_DIR"
    echo "$slug" > "$PROJECT_ROOT/.autopilot/active.session.$session_id"
    STATE_FILE="$TASK_DIR/state.md"
}

# ── DAG 解析函数 ──────────────────────────────────────────────

# 返回 DAG 中第一个就绪任务 ID（pending + 依赖全部 done），
# 如果所有任务已完成返回 "ALL_DONE"，否则返回空字符串。
get_first_ready_task() {
    local dag_file="$1"
    [[ ! -f "$dag_file" ]] && return
    awk '
    /^[[:space:]]*-[[:space:]]*id:/ {
        gsub(/.*id:[[:space:]]*"?/, ""); gsub(/".*/, ""); id=$0
        title=""; status=""; deps=""
    }
    /^[[:space:]]*(title|name):/ {
        gsub(/.*:[[:space:]]*"?/, ""); gsub(/".*/, ""); title=$0
    }
    /^[[:space:]]*status:/ {
        gsub(/.*status:[[:space:]]*"?/, ""); gsub(/".*/, ""); status=$0
    }
    /^[[:space:]]*depends_on:/ {
        gsub(/.*depends_on:[[:space:]]*/, ""); deps=$0
    }
    {
        if (id != "" && title != "" && status != "") {
            ids[++n] = id
            statuses[id] = status
            dep_lists[id] = deps
            id=""; title=""; status=""; deps=""
        }
    }
    END {
        all_done = 1; first_ready = ""
        for (i = 1; i <= n; i++) {
            tid = ids[i]
            if (statuses[tid] != "done" && statuses[tid] != "skipped") all_done = 0
            if (statuses[tid] != "pending") continue
            if (first_ready != "") continue
            d = dep_lists[tid]
            gsub(/[\[\]" ]/, "", d)
            ready = 1
            if (d != "") {
                split(d, darr, ",")
                for (j in darr) {
                    if (darr[j] != "" && statuses[darr[j]] != "done") {
                        ready = 0; break
                    }
                }
            }
            if (ready) first_ready = tid
        }
        if (first_ready != "") print first_ready
        else if (all_done && n > 0) print "ALL_DONE"
    }' "$dag_file"
}

# ── Brief 模式状态文件创建 ────────────────────────────────────

# 为项目 DAG 中的任务创建 brief 模式状态文件。
# 参数: task_file session_id max_iterations max_retries auto_approve
# 注意: 调用前必须先通过 setup_requirement_dir 设置 STATE_FILE 和 TASK_DIR
create_brief_state_file() {
    local brief_file="$1"
    local session_id="${2:-}"
    local max_iterations="${3:-30}"
    local max_retries="${4:-3}"
    local auto_approve="${5:-false}"

    local brief_content
    brief_content=$(head -100 "$brief_file")

    # 解析 depends_on，收集 handoff 文件
    local handoff_content=""
    local brief_dir
    brief_dir=$(dirname "$brief_file")
    local deps
    deps=$(sed -n 's/.*depends_on:.*\[//p' "$brief_file" 2>/dev/null | sed 's/\].*//;s/[",]/ /g' || true)
    local dep handoff
    for dep in $deps; do
        dep="${dep//\"/}"
        handoff="$brief_dir/${dep}.handoff.md"
        if [[ -f "$handoff" ]]; then
            handoff_content="${handoff_content}
--- handoff: ${dep} ---
$(head -50 "$handoff")
"
        fi
    done

    # 读取架构设计摘要
    local design_summary=""
    local design_file="$PROJECT_ROOT/.autopilot/project/design.md"
    if [[ -f "$design_file" ]]; then
        design_summary="
--- 架构设计摘要 ---
$(head -60 "$design_file")"
    fi

    # 知识库提示
    local knowledge_hint=""
    if [[ -f "$PROJECT_ROOT/.autopilot/index.md" ]]; then
        knowledge_hint="
> 📚 项目知识库已存在: .autopilot/。design 阶段请先加载相关知识上下文。"
    fi

    mkdir -p "$(dirname "$STATE_FILE")"

    cat > "$STATE_FILE" <<EOF
---
active: true
phase: "design"
gate: ""
iteration: 1
max_iterations: $max_iterations
max_retries: $max_retries
retry_count: 0
mode: "single"
plan_mode: ""
brief_file: "$brief_file"
next_task: ""
auto_approve: $auto_approve
knowledge_extracted: ""
task_dir: "$TASK_DIR"
session_id: $session_id
started_at: "$(now_iso)"
---

## 目标
$brief_content
$handoff_content
$design_summary
$knowledge_hint

## 设计文档
(待 design 阶段填充)

## 实现计划
(待 design 阶段填充)

## 红队验收测试
(待 implement 阶段填充)

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [$(now_iso)] autopilot 初始化（brief 模式），任务: $(basename "$brief_file")
EOF
}

# ── Multi-Repo 辅助函数 ────────────────────────────────────────

# 检测 yq 是否可用。
# 返回: 0=可用, 1=不可用
check_yq() {
    command -v yq &>/dev/null
}

# 扫描当前目录下最多 2 层的 git 仓库。
# 输出: 每行一个 repo 绝对路径（去重排序）
discover_repos() {
    find . -maxdepth 2 -name ".git" 2>/dev/null | while IFS= read -r gitdir; do
        local repo_dir
        repo_dir="$(cd "$(dirname "$gitdir")" && pwd)"
        echo "$repo_dir"
    done | sort -u
}

# 判断当前状态是否为 multi-repo 模式。
# 返回: 0=是, 1=否
is_multi_repo() {
    local mode
    mode=$(get_field "mode" || true)
    [[ "$mode" == "multi-repo" ]]
}

# 获取 repos.yaml 文件路径。
# 依赖: TASK_DIR 已初始化
get_repos_file() {
    if [[ -n "$TASK_DIR" ]]; then
        echo "$TASK_DIR/repos.yaml"
    else
        echo "$PROJECT_ROOT/.autopilot/repos.yaml"
    fi
}

# 获取所有 involved=true 的 repo 信息。
# 输出: 每行格式 "name<TAB>path<TAB>worktree"
# 依赖: yq
get_involved_repos() {
    local repos_file
    repos_file=$(get_repos_file)
    [[ ! -f "$repos_file" ]] && return
    yq -r '.[] | select(.involved == true) | [.name, .path, .worktree] | @tsv' "$repos_file"
}

# 获取所有 repo 信息（无论 involved 状态）。
# 输出: 每行格式 "name<TAB>path<TAB>worktree<TAB>involved"
get_all_repos() {
    local repos_file
    repos_file=$(get_repos_file)
    [[ ! -f "$repos_file" ]] && return
    yq -r '.[] | [.name, .path, .worktree, .involved] | @tsv' "$repos_file"
}

# 为指定 repo 创建 grove worktree。
# 参数: repo_path branch_name
# 输出: worktree 绝对路径（从 grove stdout 解析）
# 返回: 0=成功, 1=失败
create_grove_worktree() {
    local repo_path="$1"
    local branch_name="$2"
    local output
    output=$(cd "$repo_path" && grove --plain add "$branch_name" --create 2>&1) || return 1
    # grove 输出最后一行是 worktree 路径
    echo "$output" | tail -1
}

# 更新 repos.yaml 中指定 repo 的字段。
# 参数: repo_name field_name value
# 依赖: yq
set_repo_field() {
    local repo_name="$1"
    local field_name="$2"
    local value="$3"
    local repos_file
    repos_file=$(get_repos_file)
    [[ ! -f "$repos_file" ]] && return 1
    local temp="${repos_file}.tmp.$$"
    yq "(.[] | select(.name == \"$repo_name\")).$field_name = \"$value\"" "$repos_file" > "$temp"
    mv "$temp" "$repos_file"
}

# 更新 repos.yaml 中指定 repo 的 boolean 字段。
# 参数: repo_name field_name value(true/false)
# 依赖: yq
set_repo_bool() {
    local repo_name="$1"
    local field_name="$2"
    local value="$3"
    local repos_file
    repos_file=$(get_repos_file)
    [[ ! -f "$repos_file" ]] && return 1
    local temp="${repos_file}.tmp.$$"
    yq "(.[] | select(.name == \"$repo_name\")).$field_name = $value" "$repos_file" > "$temp"
    mv "$temp" "$repos_file"
}

# 生成 repos.yaml 文件。
# 参数: repo_paths（换行分隔的绝对路径列表，通过 stdin）
# 输出: 写入 repos.yaml
generate_repos_yaml() {
    local repos_file
    repos_file=$(get_repos_file)
    mkdir -p "$(dirname "$repos_file")"

    local paths=()
    while IFS= read -r repo_path; do
        [[ -z "$repo_path" ]] && continue
        paths+=("$repo_path")
    done

    if [[ ${#paths[@]} -eq 0 ]]; then
        yq -n '[]' > "$repos_file"
        return
    fi

    local yq_expr='['
    local first=true
    for rp in "${paths[@]}"; do
        local rn
        rn=$(basename "$rp")
        if $first; then
            first=false
        else
            yq_expr="$yq_expr, "
        fi
        yq_expr="$yq_expr{\"name\": \"$rn\", \"path\": \"$rp\", \"worktree\": \"\", \"involved\": false}"
    done
    yq_expr="$yq_expr]"

    yq -n "$yq_expr" > "$repos_file"
}

# ── 全项目 QA 状态文件创建 ─────────────────────────────────────

# 所有 DAG 任务完成后，创建全项目 QA 验证状态文件。
# 参数: session_id
# 注意: 调用前必须先通过 setup_requirement_dir 设置 STATE_FILE 和 TASK_DIR
create_project_qa_state_file() {
    local session_id="${1:-}"

    # 收集所有 handoff 摘要
    local handoff_summary=""
    local tasks_dir="$PROJECT_ROOT/.autopilot/project/tasks"
    if [[ -d "$tasks_dir" ]]; then
        local hf
        for hf in "$tasks_dir"/*.handoff.md; do
            [[ -f "$hf" ]] || continue
            handoff_summary="${handoff_summary}
### $(basename "$hf" .handoff.md)
$(head -30 "$hf")
"
        done
    fi

    # 读取架构设计
    local design_content=""
    local design_file="$PROJECT_ROOT/.autopilot/project/design.md"
    if [[ -f "$design_file" ]]; then
        design_content=$(head -100 "$design_file")
    fi

    mkdir -p "$(dirname "$STATE_FILE")"

    cat > "$STATE_FILE" <<EOF
---
active: true
phase: "qa"
gate: ""
iteration: 1
max_iterations: 10
max_retries: 2
retry_count: 0
mode: "project-qa"
plan_mode: ""
brief_file: ""
next_task: ""
auto_approve: true
knowledge_extracted: ""
task_dir: "$TASK_DIR"
session_id: $session_id
started_at: "$(now_iso)"
---

## 目标
全项目集成 QA 验证：检查所有已完成任务的整体集成质量。

加载 .autopilot/project/design.md 作为设计参考。
加载 .autopilot/project/dag.yaml 了解任务拓扑。

## 设计文档
$design_content

## 任务完成摘要
$handoff_summary

## QA 报告
(待 qa 阶段填充)

## 变更日志
- [$(now_iso)] 全项目 QA 启动
EOF
}

# ── Active 指针清理 ──────────────────────────────────────────────

# 清理指定 session 的 active 指针
# 参数: session_id (可选，默认 $CLAUDE_SESSION_ID)
cleanup_active() {
    local session_id="${1:-$CLAUDE_SESSION_ID}"
    rm -f "$PROJECT_ROOT/.autopilot/active.session.$session_id"
}

# 清理过期的 active 文件（session 已不存在的）
cleanup_stale_actives() {
    for f in "$PROJECT_ROOT/.autopilot"/active.session.*; do
        [[ -f "$f" ]] || continue
        local sid="${f##*/active.session.}"
        _session_is_alive "$sid" || rm -f "$f"
    done
}
