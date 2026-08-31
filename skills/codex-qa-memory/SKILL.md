---
name: codex-qa-memory
description: "Retired read-only compatibility layer for auditing a frozen local QA memory archive. Use only when the user explicitly asks to inspect the retired codex-qa-memory system or its historical nodes. Ordinary personal recall should use personal-knowledge-recall; exact evidence should use codex-qa-diary-recall."
---

# Codex QA Memory（已退役兼容层）

## 当前状态

自动候选记忆层已经退出推荐架构。Obsidian 负责长期知识；普通历史召回使用 `personal-knowledge-recall`，原话、日期和 Session/Thread ID 取证使用 `codex-qa-diary-recall`。

已有数据可以保留在 `%USERPROFILE%\.codex\qa-memory` 作为冻结、可回滚的历史档案，但不再参与普通召回，也不得重新生成候选记忆。

## 仅允许的用途

- 用户明确要求审计旧 QA memory 节点、状态、来源或退役历史时，只读检查必要的最小范围。
- 需要验证迁移是否遗漏时，可按明确节点 ID 对照当前知识库条目。
- 输出必须把旧节点标为“冻结历史证据”，不得当成当前事实。

## 禁止事项

- 不运行 `qa_memory_maintain.ps1`、`qa_memory_candidates.ps1` 或其他候选写入流程。
- 不创建、提升、覆盖或恢复 candidate、soft-active、active 节点。
- 不重新启用 `Codex QA Memory Hourly Maintenance`。
- 不把冻结候选批量导入 Obsidian，不用旧 QA memory 覆盖当前用户指令、项目文件或知识库条目。
- 不删除 QA 日记、QA Diary Watcher、QA Diary Health 或原始 Session。

## 安全

只读审计时不输出密码、Token、Cookie、密钥、私钥、完整私密配置或长日志。来源冲突、缺失或敏感状态不明时只报告风险，不自行恢复旧节点。
