# autopilot v4.0.0 重构设计

## 核心目标

消除回合式 stop-hook 阶段推进机制，改为子代理驱动的线性流程。
解决 plan-reviewer 静默跳过、知识消费/提取弱感知、中文 slug、脚本不可测试四大问题。

**不兼容变更，不考虑向后兼容。**

---

## 架构变更

```
旧模型（拉式）：
  AI 改 phase → stop-hook 下回合检测 → block + 注入 prompt → AI 读 prompt 执行
  → 事后 grep changelog 检测跳过 → 回滚 phase 重做

新模型（推式）：
  Skill 加载 → 读 phase → 主对话主动执行当前阶段步骤 → 完成后改 phase
  → stop-hook 仅验证 phase 合法性，放行（纯门卫）
```

### 阶段流程

```
Turn 1: Skill 加载 → AI 生成英文 slug → setup --slug → 创建 task_dir + state.md

Turn 2: phase=design
  ├ step 0: Read involved repos' .autopilot/decisions.md + patterns.md
  ├ step 1: EnterPlanMode → 探索 → 写 design.md
  ├ step 2: Agent:plan-reviewer → 审查 → 修复（主对话启动，不可跳过）
  └ step 3: Edit phase→implement

Turn 3: phase=implement
  ├ step 0: grove worktree 创建 → 更新 repos.yaml
  ├ step 1: 并行 Agent:blue + Agent:red（信息隔离，主对话并行启动）
  ├ step 2: 合流产物
  └ step 3: Edit phase→qa

Turn 4: phase=qa
  ├ step 0: Tier 0 红队测试 + Tier 1 tsc/lint/build
  ├ step 1: Tier 1.5 场景验证
  ├ step 2: 并行 Agent:design-reviewer + Agent:code-quality-reviewer
  ├ step 3: 报告 + 判定 → 如需审批设 gate: review-accept
  └ step 4: Edit phase→merge

Turn 5: phase=merge
  ├ step 0: Agent:commit-agent →
  │     commit #1: 代码变更（feat/fix/perf）
  │     commit #2: .autopilot/ 知识沉淀（独立提交）
  └ step 1: Edit phase→done
```

---

## 状态模型

### 状态文件精简

```yaml
---
phase: design          # design | implement | qa | merge | done
mode: multi-repo       # single | multi-repo | project
slug: session-retrieval-superadmin
gate: ""               # 审批门："" | "review-accept"
iteration: 1
max_iterations: 30
session_id: xxx
started_at: "2026-05-13T..."
task_dir: /path/to/.autopilot/requirements/xxx
repos_file: /path/to/.autopilot/requirements/xxx/repos.yaml
---
```

删除字段：plan_mode, brief_file, next_task, auto_approve, max_retries, retry_count, knowledge_extracted

### Stop-hook 瘦身：~40 行

```
1. 读 stdin → cwd + session_id
2. init_paths → 无状态文件 → 放行
3. session_id 不匹配 → 放行
4. gate 非空 → 通知 + 放行
5. phase=done → cleanup_active + 放行
6. iteration >= max_iterations → 清理 + 放行
7. 其他 → 放行
```

删除：Section 5 skip detection, Section 6 auto-chain, Section 10 block JSON 构造

---

## 上下文传递

子代理 prompt = Header（角色 + 文件路径清单） + Body（任务指令）。
子代理启动后自举 Read 文件，编排器不在 prompt 中内联大段内容。

```
编排器准备（主对话，每阶段 1-2 次 Read）
  1. Read state.md → 提取目标 + 设计
  2. Read repos.yaml → 提取路径列表
  3. 检查知识文件存在性
  4. 构造子代理 prompt（变量替换）
  5. 启动子代理
```

### 红蓝信息隔离实现

红队 prompt 中 repos.yaml 的 `worktree` 字段在传给红队前被清空。
红队只能通过主仓库 `path` 字段读取源码，无法看到 worktree 中的新代码。

### 并行子代理

所有子代理在主对话层并行启动（不嵌套）：
- implement 阶段：Agent:blue + Agent:red（同一轮响应中并行）
- qa 阶段：Agent:design-reviewer + Agent:code-quality-reviewer（并行）

---

## 知识工程

### 消费（design step 0，硬编码步骤）

```
1. 扫描 repos.yaml 中 involved=true 的 repo 的 .autopilot/：
   - .autopilot/decisions.md
   - .autopilot/patterns.md
   - .autopilot/index.md
2. 全量加载到编排器上下文
3. 传递给后续子代理
```

### 提取（merge 阶段 commit-agent 内部）

```
1. 分析本次 diff
2. 写入目标 repo worktree 的 .autopilot/
3. 独立 git commit（commit #2，与代码提交分离）
4. 判断为"无新增"的明确条件：
   - 无新 API/DB schema/架构决策
   - 无踩坑经验（无 bugfix / 回滚 / 边界条件发现）
   - 变更 < 50 行且仅涉及配置/文案
5. 无论有无新增，变更日志中记录提取结论
```

---

## Slug 生成

```
用户: /autopilot 按OM需求回捞Session（Super Admin功能）

step 0: AI 根据目标语义生成英文 slug
  → "session-retrieval-superadmin"

setup: 接收 --slug 参数，直接使用
  → task_dir: .autopilot/requirements/20260513-session-retrieval-superadmin
```

不再从中文目标文本截取 slug。

---

## Worktree 管理

使用 grove 工具管理 worktree：

```bash
# 创建 worktree
grove --plain add <branch-name> --create

# 列出 worktree
grove --plain list

# 删除 worktree
grove --plain remove <branch-name> [--force]
```

---

## TypeScript 重写范围

| 模块 | 当前 | 新设计 |
|------|------|--------|
| stop-hook.sh | 350 行 bash | ~40 行 bash（纯门卫） |
| setup.sh | 800+ 行 bash | ~200 行 bash（初始化 + 子命令路由）+ TS 共享库 |
| lib.sh | 590 行 bash | 拆分：路径工具 bash + 状态管理 TS |
| SKILL.md | 主对话行为指南 | 重写为子代理驱动流程 |
| references/ | 子代理 prompt 模板 | 保持，更新路径引用 |

核心逻辑 TS 化，仅 stop-hook 和 setup 入口保持 bash（Claude Code hook 机制要求）。

---

## 修订历史

| 日期 | 版本 | 变更 |
|------|------|------|
| 2026-05-13 | v1 | 初始版本 |
