# NNNN. 标题

- **Status**: Proposed | Accepted | Superseded by NNNN | Deprecated
- **Date**: YYYY-MM-DD
- **Epic / Story**: （对应 `docs/investment-intelligence-rollout.md` 的 Story ID）

## Context

描述面临的架构问题、约束、触发本决策的事件。列出至少 2 个备选方案及其代价。

约束可来自：

- `docs/investment-intelligence-rollout.md` 的 §2 通用约定
- 上游 ADR（显式引用编号）
- 现有代码事实（`AGENTS.md` 列出的已知坑点）

## Decision

最终选择。用陈述句、可执行（"系统必须 …"、"不允许 …"），而不是愿景式。

## Consequences

- **Positive**：本决策带来的好处。
- **Negative**：本决策带来的代价、限制、需要补偿的措施。
- **Neutral / Neutrality Risks**：需要后续 ADR 或监控的事项。

## Compliance Check

后续 PR 如何证明仍遵守本 ADR：

- 代码/测试层面的断言点（哪个文件、哪类测试）
- Review checklist 的检查项
- 若违反应如何升级（修订本 ADR 或回滚 PR）

## References

- 关联 ADR（被本 ADR 依赖、约束、或细化）
- 关联文档（rollout 计划章节、AGENTS.md 条目、外部规范）
