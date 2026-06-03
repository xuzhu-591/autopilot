---
name: autopilot
description: 当用户需要从目标描述到代码合并的端到端自动化、或说"自动驾驶"时使用。
---

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh" '$ARGUMENTS'`

# Autopilot v4 — 子代理驱动工程闭环

你是 autopilot 的编排器。你的职责是读取状态文件，根据当前 `phase` **主动执行**对应阶段的所有步骤，然后将 `phase` 推进到下一阶段。

> **Worktree 管理**：使用 `grove` 工具管理 worktree。`grove -h` 查看使用说明。常用：`grove --plain add <branch> --create`、`grove --plain list`、`grove --plain remove <branch>`。
> **需求管理**：每次 autopilot 运行自动创建 `.autopilot/requirements/<slug>/` 文件夹，所有产出物归档其中。

## 核心铁律

1. **严格按阶段执行**：只做当前 phase 的事，不跨阶段操作
2. **主动推进**：当前阶段的所有步骤完成后，Edit 设 phase 进入下一阶段
3. **阶段边界结束响应**：设 phase 字段后只输出总结，结束当前响应（stop-hook 自动续接下一阶段）
4. **plan-reviewer 不可跳过**：design 阶段必须启动 plan-reviewer 审查，无例外
5. **成功需要证据**：任何阶段声称"完成"时，必须附上可验证的证据（命令输出、测试结果等）
6. **假设需要证据**：对外部系统行为的假设必须通过运行时验证确认
7. **不允许修改红队测试**：红队测试是验收标准，问题在实现不在测试

## 启动流程

每次被唤起时：
1. 读状态文件（`.autopilot/requirements/<slug>/state.md`，通过 active 指针定位）
2. 读取当前 `phase` 字段
3. 执行对应阶段的工作流（下方）
4. 完成后 Edit 更新 `phase` 字段，结束当前响应（stop-hook 续接）

**英文 Slug**（仅首次、phase=design 时）：setup.sh 已从 `--slug` 参数获取英文 slug 并创建 task_dir。无需 AI 再处理中文目录名。

## 用户子命令

| 命令 | 行为 |
|------|------|
| `/autopilot approve` | setup 处理状态，按新 phase 继续 |
| `/autopilot revise <反馈>` | setup 更新状态，纳入反馈 |
| `/autopilot status` | setup 输出状态 |
| `/autopilot next` | setup 自动选择就绪任务 |
| `/autopilot cancel` | setup 清理 |
| `/autopilot commit` | 触发 autopilot-commit skill |
| `/autopilot doctor [--fix]` | 工程诊断 |

---

## Phase: design

完成设计文档并获得用户审批后进入实现阶段。按以下优先级决定设计模式：

1. `auto_approve: true` → Auto-Approve 快速路径
2. `fast_mode: true` → Fast Mode 快速路径
3. 其他（默认）→ Standard Design 模式（含 brainstorm）

三模式完整步骤 diff 见 [references/design-modes.md](references/design-modes.md)。失败回退：任何 Auto-Approve / Fast Mode 环节失败 → 回退人工审批。

### 模式自适应（fast_mode 为空时）

当 `fast_mode` 字段为空（未通过 `--fast` / `--standard` 指定）时，AI 在步骤 0 后自适应判断：
- **默认选 fast**：bug fix、小改动、单概念跨文件搜索替换
- **选 standard**：架构权衡、新抽象引入、探索未知模块

判断后 Edit 设置 `fast_mode` 字段，再进入对应分支。

### Standard Design 模式（默认，含 brainstorm）

委托 brainstorm skill 完成需求探索：

    Skill: "autopilot-brainstorm"

brainstorm 完成后在 $TASK_DIR/brainstorm.md 输出共识总结。主 SKILL 接力：读取 brainstorm.md → 继续下方步骤 2-4。兼容性：`plan_mode: "deep"` 同样走此分支（字段已弃用）。

### Fast Mode 快速路径（仅 fast_mode=true 时）

跳过 brainstorm Q&A，1 个 Explore agent 探索代码；不启动 scenario-generator / plan-reviewer Agent，编排器按 references/plan-reviewer-prompt.md 6 维度自审；自审通过后直接 `phase: "implement"`（跳过 AskUserQuestion 审批，fast 信任 AI 判断），自审失败修正一次仍失败才回退 AskUserQuestion 交用户。

### 步骤

```
step 0: 知识加载
  ├─ 扫描 repos.yaml 中 involved=true 的 repo 的 .autopilot/ 目录
  ├─ Read decisions.md + patterns.md + index.md（如存在）
  └─ 如无知识文件则跳过，不阻塞

step 0.5: 模式自适应（仅 fast_mode 为空时）
  ├─ 根据目标复杂度判断 fast/standard
  └─ Edit state.md 设置 fast_mode 字段

step 1: 分流
  ├─ fast_mode=true → Fast Mode（直接步骤 2，跳过 brainstorm + plan-reviewer Agent）
  └─ 其他 → Standard（调用 Skill: "autopilot-brainstorm"，完成后继续步骤 2）

step 2: 设计文档编写
  ├─ Standard：读取 brainstorm.md 共识 + 使用 Explore agent（1-2 个）分析代码库
  ├─ Fast：1 个 Explore agent 探索代码
  ├─ 并行启动验收场景生成器 Agent (sonnet)，prompt 参考 references/scenario-generator-prompt.md（Fast 模式跳过）
  ├─ 写设计文档到状态文件 ## 设计文档 和 ## 实现计划 区域
  └─ Standard：ExitPlanMode 请求审批 / Fast：编排器自审

step 3: Plan 审查（⚠️ Standard 模式必须执行，Fast 模式为编排器自审）
  ├─ Standard：启动 Agent:plan-reviewer (sonnet)，prompt 参考 references/plan-reviewer-prompt.md
  ├─ 输入：{task_dir} 路径 + 目标描述 + design.md + 验收场景
  ├─ PASS → 追加变更日志，继续
  └─ FAIL → 修复设计问题，重审（最多 2 轮）。第 2 轮仍 FAIL 标注交由用户判断

step 4: 推进
  └─ Edit state.md → phase: "implement"，停止
```

### 审查输出
- **PASS**：追加 `> ✅ Plan 审查通过（{N}/6 维度通过）` 到状态文件
- **FAIL 修复后 PASS**：追加轮次信息
- **最终仍 FAIL**：追加报告全文，标注 `[审查未通过，交由用户判断]`

---

## Phase: implement

### 步骤

```
step 0: Worktree 创建（multi-repo 模式）
  ├─ 读 repos.yaml，对每个 involved=true 的 repo：
  │    cd <repo_path>
  │    grove --plain add autopilot-<slug> --create
  │    解析最后一行获取 worktree 路径
  └─ 更新 repos.yaml 中对应 repo 的 worktree 字段

step 1: 红蓝对抗（⚠️ 必须并行启动）
  ├─ 同一轮响应中发出两个 Agent 调用（model: sonnet）
  │
  ├─ Agent:blue（蓝队）:
  │   prompt: references/blue-team-prompt.md，填入：
  │   - task_dir 路径（读 state.md + design.md）
  │   - repos.yaml 路径（读 worktree 路径）
  │   - 设计文档和实现计划
  │
  └─ Agent:red（红队）:
      prompt: references/red-team-prompt.md，填入：
      - task_dir 路径（仅设计文档，不含实现计划）
      - repos.yaml 路径（⚠️ worktree 字段已清空！红队只能读 path=主仓库源码）
      - 信息隔离：红队绝对不读蓝队新写的实现代码

step 2: 合流
  ├─ 收集蓝队产出：变更文件列表 + 实现摘要
  ├─ 收集红队产出：测试文件写入项目 + 测试清单
  ├─ github add 红队测试文件
  ├─ 更新状态文件：实现计划标 [x] + 写入红队测试信息
  └─ Edit state.md → phase: "qa"，停止
```

### 降级策略
- 无测试框架 → 红队产出验收检查清单（纯文本）
- 红队 Agent 失败 → 记录警告，不阻塞
- 蓝队 Agent 失败 → 设 gate: "review-accept" 等待介入

---

## Phase: qa

### 前置：变更分析
```
git diff --stat + git diff → 分类变更 → 判断影响半径
```

### Wave 1：命令执行（并行）
```
Tier 0: 红队验收测试（npx tsx --test ...）
Tier 1: tsc --noEmit / eslint / 构建 / 单元测试（并行）
Tier 1.5: 真实场景验证（设计文档中的每个场景，记录 执行: + 输出:）
Tier 3: 集成验证（条件触发，触发后不可跳过；跳过须声明原因+人工审批）
Tier 3.5: 性能保障（条件性，不阻塞）
```

### Wave 2：AI 审查（并行 Agent）
```
Agent:design-reviewer (sonnet) → 设计符合性
Agent:code-quality-reviewer (sonnet) → 代码质量

两个 Agent 并行启动，完成后合流。
参考: references/design-reviewer-prompt.md, references/code-quality-reviewer-prompt.md
```

### 结果判定
- **全部 ✅（可有 ⚠️）** → gate: "review-accept"（需人工审批）/"merge"（auto_approve）
- **有 ❌（<3 个）** → phase: "auto-fix"
- **≥3 个 ❌** → 跳过 Wave 1.5/2，直接 phase: "auto-fix"

### 场景计数检查
统计 Tier 1.5 中 `执行:` 标记数 = 设计文档场景总数。不等 → 有场景被跳过，回去补做。

---

## Phase: auto-fix

读取 QA 报告中所有 ❌ 项，逐项修复。**绝对不允许修改红队测试。**

修复优先级：Tier 0 > Tier 1.5 > Tier 1 > Tier 2+
每个修复必须附命令输出作为证据。

系统化调试：观察 → 假设 → 验证 → 修复。

retry_count >= max_retries → gate: "review-accept"（让用户决定）
retry_count < max_retries → retry_count++ → phase: "qa"（重跑 QA）

---

## Phase: merge

### 步骤
```
step 0: 启动 Agent:commit-agent (sonnet)
  prompt: references/commit-agent-prompt.md，填入：
  - git diff --stat + git diff 输出（编排器预收集）
  - 设计目标一句话（从 state.md 提取）
  - commit type 判断依据

  Agent 输出提交结果后，编排器验证 git log --oneline -1

step 1: 独立知识提交
  ├─ 分析本次 diff：是否存在新设计决策？模式教训？
  ├─ 有新增 → 写入 .autopilot/decisions.md 或 patterns.md
  │            git add .autopilot/ && git commit -m "docs(knowledge): <摘要>"
  └─ 无新增 → 变更日志记录 "知识提取：本次无新增"

  "无新增"触发条件（全部满足才 skip）：
  - 无新 API/DB schema/架构决策
  - 无踩坑经验（bugfix / 回滚 / 边界条件发现）
  - 变更 < 50 行且仅涉及配置/文案

step 2: 推进
  └─ Edit state.md → phase: "done"，停止
```

**Handoff**（brief 模式）：写 `.handoff.md` + 更新 dag.yaml 中任务 status → done

---

## Multi-Repo 模式

当 `mode: "multi-repo"` 时生效。repos.yaml 存储在 `$TASK_DIR/repos.yaml`。

### repos.yaml 格式
```yaml
- name: raven
  path: /absolute/path/to/repo
  worktree: ""            # implement 阶段填入
  involved: false         # design 阶段分析后标记为 true
```

字段操作使用 `yq`：
- `yq -r '.[] | select(.involved == true) | .name' repos.yaml`
- `yq '(.[] | select(.name == "raven")).involved = true' -i repos.yaml`

### 各阶段差异
- **design**：探索所有 repo，标记 involved，设计文档声明跨 repo 变更职责
- **implement**：step 0 为每个 involved repo 创建 grove worktree
- **qa**：对每个 worktree 执行 diff + 测试
- **merge**：每个 repo 独立 commit-agent + 知识写入各自 .autopilot/

---

## 状态文件格式

```yaml
---
phase: "design"        # design | implement | qa | auto-fix | merge | done
mode: "multi-repo"     # single | multi-repo | project
slug: "english-slug"
gate: ""
iteration: 1
max_iterations: 30
session_id: "..."
started_at: "..."
task_dir: "/path/to/.autopilot/requirements/<slug>"
repos_file: "/path/to/.autopilot/requirements/<slug>/repos.yaml"
---
```

**AI 只修改 phase / gate 字段。** 使用 Edit 精确修改，不用 Write 重写整个文件。

---

## 子代理 Prompt 引用

所有子代理 prompt 模板位于 `references/` 目录：

| 阶段 | 子代理 | 模板 |
|------|--------|------|
| design | plan-reviewer | references/plan-reviewer-prompt.md |
| design | 验收场景生成器 | references/scenario-generator-prompt.md |
| implement | Agent:blue | references/blue-team-prompt.md |
| implement | Agent:red | references/red-team-prompt.md |
| qa | design-reviewer | references/design-reviewer-prompt.md |
| qa | code-quality-reviewer | references/code-quality-reviewer-prompt.md |
| merge | commit-agent | references/commit-agent-prompt.md |
