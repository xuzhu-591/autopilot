# QA 报告模板

将 QA 报告**追加**（不覆盖）到状态文件的 `## QA 报告` 区域：

```markdown
### QA 轮次 N (时间戳)

**T0: 红队契约测试**
✅ user-avatar-upload.acceptance.test.ts: 3 passed (2.5s)
❌ image-crop.acceptance.test.ts: 1 failed — "裁剪后尺寸应为 200x200"

**T1: 静态验证**
✅ 类型检查: 通过 (2.1s) | ✅ ESLint: 通过 (1.3s)
✅ 单元测试: 5 passed (3.5s) | ❌ 构建: 失败 — Module not found

**T3: 场景验证**
T3 健康检查: ✅ dev server 启动成功 (port 3000, 4.2s)
✅ 场景1「用户上传头像」:
  执行: curl -X POST http://localhost:3000/api/upload -F "file=@test.jpg"
  输出: {"avatar_url":"https://..."} (HTTP 200, 1.2s)
❌ 场景2「裁剪后下载」:
  执行: curl http://localhost:3000/api/avatar/123
  输出: Internal Server Error (HTTP 500, 0.3s)

**T4a/4b: AI 审查**
✅ 设计符合性 | ⚠️ 安全: 1 低风险 | ✅ 边界处理

**T5: 性能保障验证**（条件性）
✅ P1 Lighthouse: performance 94 (预算 ≥90 通过)
⚠️ P2 Playwright 性能: 跳过 (无性能断言文件)
✅ P3 Bundle Size: main.js 142KB < 200KB

**总结**: 通过 5 | 警告 1 | 失败 1 → 需修复: 构建失败

### 失败 Tier 清单
- T0: image-crop.acceptance.test.ts — "裁剪后尺寸应为 200x200"
- T1(构建): Module not found
- T3: 场景2「裁剪后下载」 — HTTP 500
```

## T3 报告格式强制

每个场景必须包含 `执行:` 和 `输出:` 两行。以下为错误示范：

```markdown
# ❌ 错误：描述性文字代替执行证据
**T3: 场景验证**
（需启动 dev server 后在浏览器中验证，已通过 jest 验证 API 行为正确性）

# ❌ 错误：只有结论没有命令输出
**T3: 场景验证**
✅ 场景1「API 聚合端点」: 已验证通过
```
