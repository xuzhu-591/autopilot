# 审查清单

## code-quality-reviewer（Tier 2b）

核心审查清单已合并到 `code-quality-reviewer-prompt.md`，覆盖 Pass 1 CRITICAL（安全、竞态、LLM 信任边界、枚举完整性）和 Pass 2 INFORMATIONAL（模式一致性、边界处理、错误处理质量、代码组织、版本一致性）。

## 专家子代理（Tiers 2c-2h）

深度检查已委托给条件触发的并行专家 Agent，每个专家有独立的 prompt 模板：

| 专家 | 文件 | 触发条件 |
|------|------|---------|
| testing | `specialist-testing-prompt.md` | 始终启用 |
| maintainability | `specialist-maintainability-prompt.md` | 始终启用 |
| security | `specialist-security-prompt.md` | diff 含后端/auth 代码 |
| performance | `specialist-performance-prompt.md` | diff 含前端或查询代码 |
| data-migration | `specialist-data-migration-prompt.md` | diff 含 migration 文件 |
| api-contract | `specialist-api-contract-prompt.md` | diff 含 API route |

详见 `qa-phase.md` Wave 2 章节。
