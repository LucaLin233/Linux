# AI 开发规则

本文件适用于仓库根目录及全部子目录。所有 AI Agent 必须遵守以下规则。

## 强制规则

- 禁止直接推送 `main`；所有改动必须通过 Pull Request。
- 一个问题域对应一个 PR，不混入无关修改。
- 分支名固定为 `<agent>/<type>-<slug>`，例如 `luno/chore-ai-github-workflow`。
- 任务分支必须从最新 `origin/main` 创建。
- 修改前必须明确目标、范围、风险和验收标准。
- 只修改任务相关文件；禁止顺手重构、格式化或清理无关内容。
- 推送前，生产宿主机仅执行差异检查及改动脚本的 `bash -n`；全量分析和测试由 PR CI 完成。
- 本机重测试必须使用原生资源限制及权限隔离；无法隔离或超限时停止，不自动提高额度或转宿主机执行。
- 文档修改不强制本地全套测试，但 PR 仍须通过必需 CI。
- 禁止使用 `[skip ci]` 或任何等价方式跳过 CI。
- 禁止 force push，包括 `--force` 和 `--force-with-lease`。
- PR 必须等待全部 CI 完成并通过；当前基础检查包括 `Ubuntu 24.04 lint and tests` 和 `Debian 13 tests`。
- CI 和独立复核完成后，未经用户再次明确确认，不得合并 PR。
- 合并方式固定为 Squash merge。
- 合并后必须删除任务分支。
- PR 标题必须采用 Conventional Commit，并作为最终 squash commit 标题。

## 标准操作顺序

1. 获取最新 `main`：拉取远端并确认本地基于最新 `origin/main`。
2. 从最新 `origin/main` 创建符合命名规则的任务分支。
3. 实施满足目标的最小改动。
4. 执行差异检查（`git diff --check` 并复核 diff），仅对改动的 Shell 脚本运行 `bash -n`；生产宿主机不运行全量 ShellCheck 或完整测试集。全量分析和测试交由 PR CI；其他本机重测试必须满足上述隔离与资源限制规则。
5. 优先创建一个逻辑提交；允许临时多提交，最终由 Squash merge 合并为一个提交。
6. 推送任务分支，禁止直接推送 `main`。
7. 创建 PR，标题采用 Conventional Commit，正文说明 Summary、Scope、Validation、Risks 和 Rollback。
8. 等待全部 CI 完成并通过。
9. 独立复核相对 `origin/main` 的完整 diff，确认没有无关修改。
10. 获取用户对合并操作的再次明确确认。
11. 使用 Squash merge 合并，并删除任务分支。

## PR 期间同步 `main`

如果 `main` 在 PR 期间发生变化：

- 使用 GitHub 的 **Update branch**，或通过普通 merge 将最新 `origin/main` 合入任务分支。
- 不得通过 force push 重写已推送历史。
- 更新任务分支后，重新等待全部 CI 完成并通过。
