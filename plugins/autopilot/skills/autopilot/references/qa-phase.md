# Phase: qa — 详细工作流

## 项目 QA 模式（mode: "project-qa"）

当 `mode` 为 `project-qa` 时，执行跨任务整体验证：

1. **加载上下文**：读取 `.autopilot/project/design.md` 作为设计参考，读取状态文件 `## 任务完成摘要`
2. **变更范围**：使用 `git diff` 从项目创建以来的所有变更（而非单任务 diff）
3. **Tier 调整**：
   - T0：跳过（无项目级红队测试）
   - T1：全项目构建、测试、lint、类型检查 — 验证跨任务集成
   - T3：聚焦跨任务集成场景（从 design.md 的"跨任务设计约束"提取）
   - T4a：整体架构符合性检查（对照 design.md）
   - T4b：全变更范围代码质量审查
   - T2+：按需
4. **结果判定**：
   - 全部 ✅ → `phase: "done"`（stop-hook 发送 project-complete 通知）
   - 有 ❌ → `gate: "review-accept"`（让用户决定）
   - 不进入 auto-fix（项目 QA 失败需人工判断修复范围）

---

## 目标

全面质量检查。不仅验证"能跑"，还验证"跑得好"。每项检查必须附上命令输出作为证据。

## Tier 编号说明

编号按执行顺序排列：

| Tier | 名称 | Wave | 性质 |
|------|------|------|------|
| T0 | 红队契约测试 | Wave 1（并行） | 必须 |
| T1 | 静态验证 | Wave 1（并行） | 必须 |
| T2 | 回归检查 | Wave 1（并行） | 条件（≥3 文件） |
| T3 | 场景验证（含集成健康检查） | Wave 2（串行） | **必须 + 反跳过** |
| T4a-h | AI 审查 | Wave 3（并行 Agent） | 必须/条件 |
| T5 | 性能保障 | 附加 | 不阻塞 |

## 工作流程

分三波执行，最大化并行效率。每项检查产出明确的 ✅/⚠️/❌ 状态。

### 前置：选择性重跑判断

检查 frontmatter `qa_scope` 字段：
- **`qa_scope: "selective"`**（auto-fix 修复后设置）→ 只重跑上一轮 `### 失败 Tier 清单` 中列出的 Tier + T3，其余 Tier 直接沿用上轮结果标记 ✅
- **无 `qa_scope` 或值为空** → 执行全量 QA（所有 Wave/Tier）
- 全部通过后，清除 `qa_scope` 字段（Edit 为空字符串）

### 前置：变更分析

在 Wave 1 之前必须完成（后续所有检查的输入）：
- 通过 `git diff`/`git status` 识别变更文件
- 分类：前端组件、后端逻辑、配置、测试、文档、样式、依赖
- 判断影响半径：低→轻量验证 | 中→精准验证 | 高→综合验证
- 扫描项目配置识别可用的测试框架和工具

### 前置：范围漂移检测

在 Wave 1 之前执行。对比变更文件与设计文档的声明意图，检测范围漂移。

1. 从状态文件 `## 设计文档` 和 `git log` 提交消息提取**声明意图**（本次变更应该做什么）
2. 运行 `git diff --stat` 对比实际变更文件与声明意图
3. 判定：
   - **SCOPE CREEP**：变更了与声明意图无关的文件（"顺手改"的代码）
   - **REQUIREMENTS MISSING**：设计要求中提到的项在 diff 中无对应实现
4. 输出：

```
Scope Check: [CLEAN / DRIFT DETECTED / REQUIREMENTS MISSING]
Intent: <声明意图 — 一句话>
Delivered: <实际 diff 内容 — 一句话>
[如有漂移：列出每个超出范围的变更]
[如有缺失：列出每个未实现的设计要求]
```

5. 信息性不阻塞流程，结果追加到 QA 报告中。

### Wave 1 — 命令执行（并行）

**在同一轮响应中发出多个 Bash 工具调用**，所有命令独立运行、互不依赖：

**T0: 红队契约测试**（最高优先级）
- 运行所有 `.acceptance.test` 文件（从状态文件 `## 红队验收测试` 读取列表）
- 失败意味着实现未满足设计要求
- 红队未生成测试时，降级为 Wave 3 中 AI 逐项人工验证

**T1: 静态验证**（四项并行，各超时 60s）

按项目技术栈选择对应命令：

| 检查项 | Node.js / TS | Java (Maven) | Java (Gradle) |
|--------|-------------|--------------|---------------|
| 类型检查 | `tsc --noEmit` | `mvn compile -q` | `gradle compileJava` |
| Lint | `eslint` | `mvn checkstyle:check` / SpotBugs | `gradle checkstyleMain` |
| 单元测试 | `jest` / `vitest` | `mvn test -pl <module>` | `gradle test` |
| 构建 | `npm run build` | `mvn package -DskipTests` | `gradle build -x test` |

> 识别方式：项目根目录有 `pom.xml` → Maven；有 `build.gradle` → Gradle；有 `package.json` → Node.js。多模块 Maven 项目用 `-pl <module>` 限定范围避免全量构建。

**T2: 回归检查**（影响范围跨 3+ 文件时触发）

**执行原则**：遇到失败不中断，标记后继续。记录每项的命令、耗时、退出码、关键输出（前 50 行）。

### Wave 1 失败快速路径（Early Exit to Auto-fix）

Wave 1 完成后统计 T0+T1 ❌ 数量：≥3 → 跳过 Wave 2/3 直接 auto-fix | <3 → 继续 Wave 2 → Wave 3 | auto-fix 后回来执行全量 QA

### Wave 2 — 场景验证（Wave 1 之后，Wave 3 之前，必须执行）

**⚠️ 这是独立的必做步骤，不是 Wave 1 的一部分。Wave 1 所有命令执行完毕后，必须先完成 Wave 2 的全部内容，再启动 Wave 3。**

#### T3 Step 0: 集成健康检查（前置）

验证"系统能跑起来"，是场景执行的环境前提。

**触发条件**（满足任一即必须执行）：
- 变更涉及前端组件（.tsx/.vue/.svelte）→ 需 dev server 启动验证渲染
- 变更涉及 API 端点（route/controller/handler）→ 需端点可达性验证
- 变更涉及模块导出（index.ts / barrel file / package.json exports）→ 需导入完整性验证
- 变更涉及服务端启动逻辑（server.ts/app.ts/main.ts）→ 需服务启动验证

**检查项**：Dev server 启动成功 | API 端点响应 | 导入路径可解析 | 无运行时 crash

**跳过规则**：
- 触发条件不满足 → 标记 `T3 健康检查: N/A（<原因>）`，直接进入 Step 1
- 触发条件满足且通过 → 继续 Step 1
- 触发条件满足但失败 → ❌ 阻塞（环境不就绪，场景无法执行）
- 触发条件满足但跳过 → **必须**在 QA 报告中写入 `T3 健康检查跳过原因:` 字段 → **阻断 auto-approve，强制 `gate: "review-accept"` 人工审批**

#### T3 Step 1+: 真实场景执行

验证"功能在用户视角下能用"。

**前置：变更类型覆盖检查**

在执行场景之前，对照「前置：变更分析」的分类结果，检查验证方案的场景是否覆盖了**核心变更层级**：

| 核心变更类型 | 必须的场景类型 |
|-------------|---------------|
| UI 组件 | dev server + 渲染验证 |
| API 端点 | curl/fetch 调用 |
| CLI/脚本 | 运行命令验证输出 |

> **教训**：little-bee 鼻字 NoseScene.tsx（UI 组件）验证方案只有数据层测试，T3 全通过但渲染时 framer-motion 崩溃。验证方案必须覆盖核心变更层级。

**执行规则**：
- 从设计文档的 `## 验证方案 > 真实测试场景` 读取场景列表（经过上述覆盖检查，可能已补充新场景）
- 执行策略：标记了 `[独立]` 的场景可在同一轮响应中并行执行（多个 Bash 调用），未标记 `[独立]` 的场景按顺序串行执行（场景间可能有前置依赖）
- 每个场景必须记录：`执行:` 实际运行的命令 + `输出:` 命令的真实输出
- **不可跳过**：如果设计文档没有真实测试场景，QA 阶段必须根据变更内容自行设计至少 1 个场景并执行
- 超时：单个场景 60s，总计 180s
- 与 T0/T1 的区别：T0/T1 验证「代码是否正确」，T3 验证「功能在真实用户场景下是否可用」

**服务启动规范**：

| 技术栈 | 检查已有进程 | 启动命令 | 等待时间 | 健康检查 |
|--------|-------------|---------|---------|---------|
| Node.js | `lsof -ti:3000` | `npm run dev &` | `sleep 8` | `curl localhost:3000` |
| Spring Boot | `lsof -ti:8080` | `mvn spring-boot:run &` 或 `java -jar target/*.jar &` | `sleep 15` | `curl localhost:8080/actuator/health` |

先检查端口是否已有进程 → 有则直接用 → 无则后台启动 + 等待 → 不要将多条命令拼接为一行（避免参数解析错误）。Java 服务启动较慢，等待时间需 15s+。

| 场景类型 | 示例 |
|----------|------|
| CLI/Hook/配置 | 运行命令验证输出和退出码，模拟 stdin 验证 stdout |
| API/UI/库函数 | curl 调用端点验证响应，启动 dev server 验证渲染，临时脚本验证返回值 |

#### 防合理化指南（T3 专用）

| 借口 | 现实 |
|------|------|
| T1 单测已覆盖 / tsc 通过就够了 | 单测验证逻辑，场景验证真实运行环境；tsc 只保证类型，不保证运行时正确 |
| dev server 启动太慢 / 太重 | `npm run dev &` + `sleep 8` 即可；健康检查和场景执行共用同一个 dev server |
| 设计文档没写 / 后续手动验证 | 没有就自行设计 1 个；QA 阶段就是验证阶段，"后面再验"= 跳过验证 |
| 蓝队已冒烟 / 场景 1 已验核心 | QA 必须独立执行；little-bee-cli 48 测全过但 4 bug 靠手动发现 |
| 只改了样式 / 只改了文案 | 样式改动可能导致渲染崩溃（CSS Module 引用断裂、Tailwind class 冲突） |
| CI 会跑集成测试 | QA 阶段的目的就是在 CI 前发现问题；"CI 会验"= 把问题踢给下游 |

> **教训**：little-bee 性能优化 — 45 单测全过但场景验证被跳过，集成 bug（缺少 profileId 多一次 fallback 请求）靠手动发现。

> **教训**：little-bee-cli — 48 测全过但 4 bug 靠手动发现，设计了 3 个真实场景只执行了 --help，跳过了需要 server 的场景。

### T5: 性能保障验证（条件性，不阻塞）

需同时满足以下条件才触发：
- 项目是前端/全栈（有 next.config / vite.config / webpack.config + build 产出 HTML）
- 本次变更涉及前端代码（git diff 包含 .tsx/.vue/.svelte/.css/前端组件文件）
- 至少有一个性能工具就位（Lighthouse CI / Playwright 性能断言 / size-limit）
- T3 健康检查已执行（需要 dev server）
- 检查项：运行项目已配置的性能工具（Lighthouse CI / Playwright 性能断言 / size-limit），记录结果
- 失败处理：❌ → ⚠️（建议修复），**不阻塞** review-accept gate，不纳入 Wave 1 快速路径计数
- N/A（无工具或非前端项目）→ 跳过，不影响流程

### Wave 3 — AI 审查（并行 Agent，基于 Wave 1 + Wave 2 结果）

**在同一轮响应中使用 Agent 工具启动全部审查 Agent（T4a-4b + 条件专家）。** 所有 Agent 独立运行、互不依赖，完成后合流。

#### 前置：确定需要启动的专家

基于「前置：变更分析」的分类结果，按以下规则确定要启动的专家 Agent：

| 专家 | 触发条件 | prompt 模板 |
|------|---------|-------------|
| testing | **始终启用** | `references/specialist-testing-prompt.md` |
| maintainability | **始终启用** | `references/specialist-maintainability-prompt.md` |
| security | diff 含后端代码（controller/handler/middleware/auth） | `references/specialist-security-prompt.md` |
| performance | diff 含前端组件或数据库查询 | `references/specialist-performance-prompt.md` |
| data-migration | diff 含 migration 文件 | `references/specialist-data-migration-prompt.md` |
| api-contract | diff 含 API route/controller | `references/specialist-api-contract-prompt.md` |

#### T4a: design-reviewer Agent（设计符合性）

使用 Agent 工具启动 design-reviewer（model: "sonnet"），prompt 参考 `references/design-reviewer-prompt.md` 模板，填入：
- 设计文档（从状态文件 `## 设计文档` 复制）
- Wave 1 + Wave 2 各 Tier 通过/失败状态摘要
- 项目根目录路径

**核心原则**：不信任，独立验证 — Agent 必须读取实际代码逐项比对设计要求。
如果 Wave 1 有大量 ❌，仍然启动审查——可能揭示根本原因。

#### T4b: code-quality-reviewer Agent（代码质量）

使用 Agent 工具启动 code-quality-reviewer（model: "sonnet"），prompt 参考 `references/code-quality-reviewer-prompt.md` 模板，填入：
- 项目根目录路径
- CLAUDE.md 内容或关键项目约定（如果存在）
- Wave 1 + Wave 2 各 Tier 通过/失败状态摘要

**核心原则**：置信度评分过滤 — Agent 按 `references/code-quality-reviewer-prompt.md` 中的审查清单审查，只报告置信度 ≥80 的问题。深度检查已委托给专家子代理（见 Pass 2 注释）。

#### T4c-4h: 专家子代理（并行，条件触发）

对每个满足触发条件的专家，使用 Agent 工具（model: "sonnet"）并行启动，prompt 填入：
- 项目根目录路径
- `git diff --stat` 变更摘要

每个专家输出独立的审查报告（N 个问题 + Strengths + Issues）。全部与 T4a/T4b 在同一轮响应中并行启动。

#### 合流

所有 Agent 完成后：
1. 收集 design-reviewer 产出：设计符合状态 + 问题列表
2. 收集 code-quality-reviewer 产出：Issues（Critical/Important/Minor）+ Assessment
3. 收集各专家产出：按专家类型归类
4. 去重：同一 file:line 被多个专家报告时，保留最高置信度的报告
5. 合并为 QA 报告的 T4 部分

#### 降级策略

- **单 Agent 失败** → 在变更日志记录警告，使用其余 Agent 的结果继续
- **全部 Agent 失败** → 编排器自行执行简化版审查（设计覆盖率 + OWASP Top 10）
- **红队未生成测试** → 设计审查 Agent 额外承担验收检查清单的逐项人工验证
- **专家 Agent 不可用** → 跳过该专家，不阻塞流程

### 产出报告

将 QA 报告写入状态文件的 `## QA 报告` 区域。**写入前先将所有历史轮次报告压缩为一行摘要**（格式：`### 轮次 N (时间) — ✅/❌ 简要结果`），只保留最新一轮完整报告。报告格式和示例参见 `references/qa-report-template.md`。

### 结果判定

**前置检查**（两步，必须按顺序执行）：

**步骤 1 — 场景完整性检查**：统计 T3 报告中 `执行:` 标记数量 E，对比设计文档验证方案中的实际场景总数 N。E < N → ❌ 有场景被跳过，回去补做 Wave 2 中遗漏的场景。同时验证每个场景是否都包含 `执行:` 和 `输出:` 标记，纯描述性文字视为 ❌。

**步骤 2 — 健康检查覆盖检查**：检查变更分析中是否满足 T3 Step 0 触发条件。如满足但报告中健康检查标记为跳过且缺少 `T3 健康检查跳过原因:` 字段 → 回去补做。如有跳过原因 → 强制走人工审批（不论其他 Tier 状态）。

- **全部 ✅（可有 ⚠️）** → 更新 frontmatter：`gate: "review-accept"`
- **T3 健康检查声明跳过** → 更新 frontmatter：`gate: "review-accept"`（即便其他全绿，禁止 auto-approve）
- **有 ❌** → 更新 frontmatter：`phase: "auto-fix"`，在报告末尾列出需修复项清单

#### Auto-Approve 处理

如果 frontmatter `auto_approve` 为 `true` 且全部 ✅ 且 T3 健康检查未声明跳过：
- 跳过 `gate: "review-accept"`，直接更新 `phase: "merge"`
- 追加变更日志：QA 全部通过（auto-approve）

如果 T3 健康检查被声明跳过（即便其他全 ✅）：
- 设置 `auto_approve: false`
- 设置 `gate: "review-accept"`，报告中注明「T3 集成健康检查被跳过，需人工确认跳过合理性」

如果有 ❌：
- 设置 `auto_approve: false`（回退到人工审批）
- 正常设置 `gate: "review-accept"` 或 `phase: "auto-fix"`

### 改进建议

如果 QA 失败项集中在某类基础设施缺失（无测试框架、无类型检查、无 lint 等），在报告末尾追加：
> 多项 QA 检查因项目基础设施不足而跳过或降级。建议运行 `/autopilot doctor` 诊断并改进工程基础设施。
