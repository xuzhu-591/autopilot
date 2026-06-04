# Design 阶段三模式详解

主 SKILL.md `Phase: design` 章节是路由器——只列出决策树和每个模式的入口，详细执行步骤都在本文件。

模式由 frontmatter 两个字段决定，优先级从高到低：`auto_approve > fast_mode > 默认 (Standard)`。

## §1. 三模式速查表

| 模式 | 触发条件 | 跳过的节点 | 失败回退 |
|------|----------|-----------|----------|
| Auto-Approve | `auto_approve: true`（auto-chain 设置） | AskUserQuestion 审批 | 设 `auto_approve: false`，回到 Standard 人工审批 |
| Fast Mode | `fast_mode: true`（启动 `--fast` 或自适应判断） | brainstorm Q&A、scenario-generator、plan-reviewer Agent；T3 必做 | 自审失败修正 1 次仍 FAIL → AskUserQuestion 交用户 |
| Standard | 其他（默认） | 无（全节点保留） | — |

红蓝对抗 / 红队验收测试 / qa Wave 1+2 是核心，三模式都保留不动。

## §2. Auto-Approve 完整工作流

`auto_approve: true` 通常由 stop-hook 的 auto-chain 机制在项目子任务推进时自动设置。design 阶段流程：

1. 执行知识上下文加载（主 SKILL.md 步骤 0）
2. 1 个 Explore agent 快速分析任务相关代码
3. 直接将设计文档写入状态文件 `## 设计文档` 和 `## 实现计划` 区域
4. **Plan 审查（必须执行）**：启动 plan-reviewer Agent（model: "sonnet"，参见 `plan-reviewer-prompt.md`）
5. **PASS** → 追加变更日志，更新 `phase: "implement"`
6. **FAIL** → 设 `auto_approve: false`，回退到 Standard 正常审批流程

## §3. Standard Design 模式详细步骤

委托 `Skill: "autopilot-brainstorm"` 完成需求探索（默认触发，`--fast` 跳过）。

完成后续步骤：

1. 读取 `$TASK_DIR/brainstorm.md`（brainstorm skill 的共识总结产出）
2. 主 SKILL 接力：使用 1-2 个 Explore agent 分析代码库 + 并行启动 scenario-generator Agent
3. 设计文档写入状态文件 `## 设计文档` 和 `## 实现计划` 区域
4. Plan 审查：plan-reviewer Agent 审查（最多 2 轮）
5. AskUserQuestion 审批（通过 / 修改 / 放弃）
6. 审批通过 → `phase: "implement"`

**兼容性**：历史 state.md 中的 `plan_mode: "deep"` 同样走此分支；`plan_mode` 字段已弃用，新代码不读。

## §4. Fast Mode 详细 diff

`fast_mode: true` 时砍掉所有 plan-review 类节点（红蓝对抗 / qa Wave 1+2 是核心，保留不动）：

| 阶段 | Fast Mode 行为 |
|------|---------------|
| design | 知识加载 → **1 个** Explore agent → 设计文档写入状态文件 → 按 `plan-reviewer-prompt.md` 6 维度**自审**（编排器 inline，不启动 scenario-generator / plan-reviewer Agent，不做 brainstorm Q&A）→ 自审通过 → 直接 `phase: "implement"`（跳过 AskUserQuestion 审批，fast 信任 AI 判断） |
| implement | blue-team / red-team 双 Agent 保留不变 |
| qa | T3 必做铁律不变 |

**自适应判断**（`fast_mode` 为空时由 AI 在步骤 0.5 决定）：

- `fast` 触发：bug fix、小改动、单概念跨文件搜索替换、配置调整
- `standard` 触发：架构权衡、新抽象引入、探索未知模块、多方案权衡
- 多文件不意味着复杂；默认倾向选 fast
