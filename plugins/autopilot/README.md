# autopilot v4 — 子代理驱动工程闭环

从目标描述到代码合并，全程自动化。**子代理驱动线性流程**，每个阶段硬编码关键步骤，不再依赖 stop-hook prompt 注入。

## v4 核心变更

| 维度 | v3 | v4 |
|------|-----|-----|
| 阶段推进 | stop-hook 注入 prompt（拉式） | 主对话主动执行（推式） |
| Plan Reviewer | 事后 changelog grep 检测 + 回滚 | design 阶段硬编码步骤，不可能跳过 |
| 知识工程 | 弱文本提示 + 知识提取守卫 | design step 0 强制加载 + merge 独立 commit |
| Slug | 中文目标截取 | AI 预生成英文 --slug |
| Stop-hook | 350 行（五重职责） | ~60 行（纯门卫） |
| 上下文传递 | 内联 prompt 注入 | 子代理 prompt 引用文件路径，自举 Read |

## 工作流程

```
用户输入目标 → AI生成英文slug → setup创建task_dir
  → design: 知识加载 → Plan Mode → plan-reviewer(强制) → 审批
  → implement: grove worktree → 并行蓝队+红队(信息隔离) → 合流
  → qa: Tier 0/1/1.5/2 → 报告+判定
  → merge: commit-agent(代码提交) → 知识提取(独立commit) → done
```

## 快速开始

```bash
# 推荐：在 worktree 中运行（隔离代码改动）
grove --plain add autopilot-my-feature --create

# 启动全流程闭环
/autopilot --slug user-avatar-upload 实现用户头像上传功能

# 审批
/autopilot approve     # 批准当前审批门
/autopilot revise <反馈> # 要求修改
```

## 命令

| 命令 | 说明 |
|------|------|
| `/autopilot <目标>` | 启动全流程闭环 |
| `/autopilot --slug <slug> <目标>` | 指定英文 slug 启动 |
| `/autopilot commit` | 智能提交 |
| `/autopilot doctor [--fix]` | 工程健康度诊断 |
| `/autopilot approve` | 批准当前审批门 |
| `/autopilot revise <反馈>` | 要求修改 |
| `/autopilot status` | 查看状态 |
| `/autopilot cancel` | 取消 |
| `/autopilot continue` | 恢复之前未完成的任务 |
| `/autopilot next` | 查找就绪任务（项目模式） |

## 选项

| 选项 | 说明 |
|------|------|
| `--slug <english-slug>` | 指定英文任务目录名（kebab-case） |
| `--multi-repo` | 强制多仓库模式 |
| `--project` | 强制项目模式 |
| `--single` | 强制单任务模式 |
| `--max-iterations <n>` | 最大迭代次数 (默认: 30) |

## Worktree 管理

使用 `grove` 工具：`grove -h` 查看使用说明。

```bash
grove --plain add <branch-name> --create    # 创建 worktree
grove --plain list                           # 列出 worktree
grove --plain remove <branch-name>           # 删除 worktree
```
