# Knowledge Engineering Reference

Detailed rules for the knowledge consumption (design phase) and extraction (merge phase) steps in the autopilot pipeline.

## Knowledge Directory Structure (Three-Layer Progressive Disclosure)

```
.autopilot/
├── index.md              # Layer 1: 索引层（轻量元数据，always loaded）
├── decisions.md          # Layer 2: 全局决策日志（保持兼容）
├── patterns.md           # Layer 2: 全局模式教训（保持兼容）
└── domains/              # Layer 2: 领域分区（按需加载）
    ├── frontend.md
    ├── testing.md
    └── ...
```

- **Layer 1 (Index)**: `index.md` 是路由层，每个条目只有标题 + 标签 + 位置，不含完整内容。Design 阶段 always loaded。
- **Layer 2 (Content)**: `decisions.md`、`patterns.md` 和 `domains/*.md` 是内容层，按需加载。
- **向后兼容**: 无 `index.md` 或无 `domains/` 均 fallback 到全量加载原有文件。

All content files use append-only Markdown, tracked in git. Each file stays ≤100 lines (全局文件); exceeding this triggers a domain migration suggestion.

## Index File Format (index.md)

`index.md` 作为路由层，记录所有知识条目的元数据。格式：

```markdown
# Knowledge Index

## Decisions
- [2026-03-20] worktree 使用 Node.js 重写而非 Shell | tags: worktree, shell, nodejs | → decisions.md

## Patterns
- [2026-03-20] worktree 内 git 路径解析陷阱 | tags: git, worktree, path | → patterns.md

## Domain Knowledge
- frontend: 3 entries | → domains/frontend.md
```

**索引条目格式**: `- [YYYY-MM-DD] {title} | tags: tag1, tag2, tag3 | → {file_path}`

每次提取新知识时同步更新 index.md；索引条目与内容条目保持一一对应。

## Knowledge Formats

### Decision Log Entry (decisions.md / domains/*.md)

```markdown
### [YYYY-MM-DD] {one-line title}
<!-- tags: tag1, tag2, tag3 -->
**Background**: Why this decision was needed
**Choice**: What was selected
**Alternatives rejected**: Options considered but not chosen, and why
**Trade-offs**: Consequences of this choice
```

### Pattern / Lesson Entry (patterns.md / domains/*.md)

```markdown
### [YYYY-MM-DD] {one-line title}
<!-- tags: tag1, tag2, tag3 -->
**Scenario**: When this applies
**Lesson**: Specific practice or anti-pattern
**Evidence**: Concrete example from this autopilot run (command output, file:line, error message)
```

Tags 使用 `<!-- tags: ... -->` HTML comment 格式；每个条目 2-5 个标签，逗号分隔。

## Consumption Rules (Design Phase) — Two-Phase Retrieval

Before entering Plan Mode, scan `.autopilot/` if it exists. 分两阶段执行，控制加载量：

**Phase 1 — Index Scan (<=5s)**: 读取 `index.md`，用当前目标关键词匹配 tags，确定需加载的文件列表（最多 3 个）。

**Phase 2 — Selective Load (<=10s)**: 按 Phase 1 文件列表读取内容，判断相关性，携带相关条目进入 Plan Mode，并在设计文档的 `## 相关历史知识` 中引用。

**Fallback**: 无 `index.md` 时直接全量加载 `decisions.md` 和 `patterns.md`（<=10s）。

**Skip conditions**: 目录不存在、文件为空、或无条目与当前目标匹配时跳过。Never block on knowledge loading.

## Extraction Rules (Merge Phase)

After autopilot-commit completes, review the full autopilot run to extract knowledge worth preserving.

### Record a Decision When
- 设计文档包含 option A vs option B 的权衡分析
- 明确拒绝了某个备选方案并有理由
- 做出了非显而易见的技术选择

### Record a Pattern/Lesson When
- auto-fix 需要 >1 轮调试才解决
- QA 暴露了项目特有的陷阱或约定
- 发现了可复用的代码模式或反模式
- 同类型失败出现在多个 QA Tier

### Do NOT Record
- 无调试洞见的常规 bug 修复；标准实现无设计权衡；CLAUDE.md 中已有的信息

### Execution Steps

1. 分析状态文件（设计文档、QA 报告、变更日志、auto-fix 历程）中的候选条目
2. 有值得记录的条目：
   a. `mkdir -p .autopilot/`
   b. 从设计文档和代码变更中自动生成 tags
   c. 确定目标文件：通用决策 → `decisions.md`；通用模式 → `patterns.md`；领域特定 → `domains/{domain}.md`
   d. 追加条目（含 `<!-- tags: ... -->`）到目标文件
   e. 更新 `index.md`（不存在则创建）
   f. 全局文件 >100 行时建议用户迁移领域条目到 `domains/`
   g. 确定知识库 git 提交上下文（见下方 Worktree-Aware Extraction）
3. 无值得记录的内容 → 变更日志追加"知识提取：本次无新增"后跳过

**Time limit**: 2 分钟内完成。宁可少写高质量条目，不要穷举。

## Worktree-Aware Extraction

知识提交始终在当前工作分支上，不路由到主仓默认分支。根据 `.autopilot` 是否为符号链接选择提交方式：

#### 分支 1：`.autopilot` 是符号链接（worktree 场景）

`test -L .autopilot` → 是符号链接。`git add .autopilot/` 在符号链接目录下会失败，需要先物化：

```bash
# 1. 记录符号链接目标
SYMLINK_TARGET=$(readlink .autopilot)

# 2. 物化：符号链接 → 真实目录副本
cp -rL .autopilot .autopilot-materialized
rm .autopilot
mv .autopilot-materialized .autopilot

# 3. 写入知识文件后提交（在 worktree 分支上）
git add .autopilot/
git commit -m "docs(knowledge): extract {brief summary}"

# 4. 恢复符号链接（维持 worktree 状态共享）
rm -rf .autopilot
ln -s "$SYMLINK_TARGET" .autopilot
```

#### 分支 2：`.autopilot` 不是符号链接

普通 repo 或无符号链接的 worktree，直接提交：

```bash
git add .autopilot/
git commit -m "docs(knowledge): extract {brief summary}"
```

## Multi-Repo Knowledge Extraction

Multi-repo 模式（`mode: "multi-repo"`）下，CWD 不是 git repo，知识不能存储在 CWD。知识路由到最相关的 repo worktree。

### 路由策略

1. 分析每个知识条目的内容（涉及的模块、技术栈、文件路径）
2. 对照 repos.yaml 中的 involved repos，判断与哪个 repo 关联最大
3. 写入该 repo **worktree** 的 `.autopilot/` 目录

### 执行步骤

```bash
# 1. 确定目标 repo 的 worktree 路径（从 repos.yaml 读取）
TARGET_WT=$(yq -r '.[] | select(.name == "<最相关repo>") | .worktree' repos.yaml)

# 2. 创建知识目录
mkdir -p "$TARGET_WT/.autopilot/"

# 3. 写入知识文件（decisions.md / patterns.md / index.md）
# ... 追加条目 ...

# 4. 在 worktree 内提交
git -C "$TARGET_WT" add .autopilot/
git -C "$TARGET_WT" commit -m "docs(knowledge): extract {brief summary}"
```

### 消费（Design 阶段）

Multi-repo design 阶段加载知识时，扫描各 involved repo 的 `.autopilot/` 目录（原始 repo 路径，非 worktree），聚合所有 `index.md` 进行关键词匹配。

### 边界情况

- 跨 repo 的通用知识（如团队约定）→ 写入关联最大的 repo，不需要多副本
- 某个 repo 无 `.autopilot/` 目录 → `mkdir -p` 创建，首次提取会自动创建 `index.md`
- 无 involved repo 有变更 → 设 `knowledge_extracted: "skipped"`

## Domain Partition Guide

当全局文件超过 100 行时，识别可聚合的同领域条目，创建 `domains/{domain}.md`，迁移后更新 `index.md` 中的路径引用，并从全局文件删除已迁移条目。**迁移操作需要用户确认。**

**常见领域划分**: frontend, backend, testing, infra, database, auth, performance

## Size Management

- 全局文件（decisions.md / patterns.md）超 100 行 → 追加警告注释并通知用户建议迁移
- 领域文件（domains/*.md）超 150 行 → 追加警告注释并通知用户建议拆分或裁剪旧条目
- 不要自动迁移——知识整理需要人工判断
