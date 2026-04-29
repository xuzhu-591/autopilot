# 状态文件格式指南

## 状态文件字段说明

状态文件 `.autopilot/autopilot.local.md` 的 frontmatter 包含以下字段：
- `phase`: 当前阶段（design → implement → qa → auto-fix → merge → done），AI 更新
- `gate`: 审批门标记，AI 更新
- `iteration`: 当前迭代次数，stop-hook 自动递增，AI 不修改
- `max_iterations`: 最大迭代次数，AI 不修改
- `retry_count`: auto-fix 重试计数，AI 更新
- `qa_scope`: 选择性重跑标记，AI 更新
- `knowledge_extracted`: 知识提取完成标记，AI 在 merge 阶段设为 `"true"`（有新增）或 `"skipped"`（无新增）。stop-hook 的 phase=done 守卫检查此字段，缺失或空值会回滚到 merge。
- `repos_file`: repos.yaml 绝对路径（仅 multi-repo 模式），AI 不修改
- `session_id`: 会话 ID，AI 不修改

## 更新原则

使用 Edit 工具精确修改字段值，不要用 Write 重写整个文件。

## 红队验收测试区域格式

```markdown
## 红队验收测试

### 测试文件
- `src/__tests__/user-avatar.acceptance.test.ts` — 头像上传完整流程

### 验收标准
1. 用户可以上传 JPG/PNG 格式的头像图片
2. 上传后自动裁剪为 200x200 尺寸
```

## 变更日志写入

在 `## 变更日志` 标题下方追加新记录行。格式：
```
- [2026-03-16T10:05:00Z] design 阶段完成，等待用户审批
```

## repos.yaml 格式（Multi-Repo 模式专用）

repos.yaml 存储在 `$TASK_DIR/repos.yaml`，由 setup.sh 自动创建，记录发现的子 git 仓库及其状态。

```yaml
- name: raven                                    # repo 目录名
  path: /Users/amazonite/code/sdd/raven          # repo 绝对路径
  worktree: ""                                   # grove 创建的 worktree 路径（implement 阶段填入）
  involved: false                                # 是否涉及本次任务（design 阶段更新）

- name: raven-cli
  path: /Users/amazonite/code/sdd/raven-cli
  worktree: /Users/amazonite/.grove/worktrees/raven-cli/autopilot-xxx
  involved: true
```

**字段操作**使用 `yq` 工具：
- 查看所有 repo：`yq -r '.[].name' repos.yaml`
- 设 involved：`yq '(.[] | select(.name == "raven")).involved = true' -i repos.yaml`
- 设 worktree：`yq '(.[] | select(.name == "raven")).worktree = "/path"' -i repos.yaml`
- 获取 involved repos：`yq -r '.[] | select(.involved == true) | [.name, .worktree] | @tsv' repos.yaml`
