---
name: codex-qa-memory
description: "Codex QA 记忆默认入口。Use FIRST when the user asks for Codex QA 长期记忆、快速恢复记忆、跨项目历史线索、项目历史主题、用户长期偏好、规则、失败经验、事件卡、小节点、数字码索引、QA 记忆取回、从 QA 日记沉淀候选记忆、审查/裁决 QA 记忆节点，或使用自然回忆说法：咱们之前聊过、之前我们说过、我们做过、咱们之前做的、你还记得吗、以前说过、之前定过、之前怎么处理。Only use codex-qa-diary-recall after this skill when the user asks for 原话、日期、证据、session/thread ID、原始日记/原始记录，or when QA memory evidence is insufficient. 不再使用独立每日摘要写入入口。"
---

# Codex QA 存取编排

## 一句话规则

`codex-qa-memory` 是默认入口，负责“先取结构化记忆”；`codex-qa-diary-recall` 是取证兜底，负责“再查原话、日期和 session/thread ID”。新会话遇到自然回忆说法时，必须先用本 skill，不得直接翻 QA 日记或原始 session。

## MCP 优先入口

如果当前 Agent 已连接 Codex QA Memory MCP，结构化召回优先调用只读工具 `qa_memory_recall`；MCP 不可用时再使用本 skill 自带脚本。两条路径遵守同一边界：

- 默认只取 active 记忆；候选只有当前任务确实需要审查时才显式包含，且不能当成有效事实。
- 只有用户明确点名当前项目历史时才传 `project_hint`；项目临时状态、旧授权、thread/run 状态不跨项目召回。
- `quick` 足以回答就停止；需要更多上下文时才升级到 `project` 或 `deep`。
- MCP 结果仍只是带来源的记忆线索，不能覆盖当前用户指令和当前项目文件。

需要原话、日期、证据或 session/thread ID 时，转 `codex-qa-diary-recall`；不要用结构化召回代替证据查询。

## 目标

把 Codex QA 日记从“长档案”升级成低成本、可追溯、可预算取回的记忆层。v2 采用“Markdown 审计层 + JSONL 机器状态层 + CLI 取回治理层 + LLM 短输出包”的四层结构；不自动加工全历史，不自动提升高影响长期规则。用户明确要求全量整理旧日记时，可批量生成 `candidate（候选）` 历史召回主题，但仍不得直接提升 active。

默认根目录：

- QA 日记：`%USERPROFILE%\.codex\qa-diary`
- QA 记忆：`%USERPROFILE%\.codex\qa-memory`
- 主方案：`README.md`

## 路由

| 用户要做 | 使用 |
| --- | --- |
| “之前聊过 / 之前说过 / 我们做过 / 你还记得吗 / 之前定过 / 某项目之前怎么处理” | 本 skill，先做 quick 取回。 |
| 快速恢复长期偏好、规则、失败经验、项目历史主题或跨项目历史线索 | 本 skill。 |
| 从 QA 中沉淀候选事件卡/小节点 | 本 skill |
| 审查、提升、废弃、覆盖 QA 记忆节点 | 本 skill |
| 用户明确要原话、日期、证据、聊天记录、session/thread ID、原始日记或原始记录 | 先判断是否已有 memory 线索；需要证据时转 `codex-qa-diary-recall`。 |
| 本 skill 取回结果不够准、不够全或存在冲突 | 保留本 skill 输出作为线索，再转 `codex-qa-diary-recall` 做窄取证。 |

## 新会话使用顺序

1. 先判断用户是不是在要“记忆”还是“证据”。只要是自然回忆、历史线索、长期偏好、失败经验、规则或项目历史主题，默认属于记忆。
2. 运行本 skill 的 quick / project / deep 取回，按任务需要控制预算。
3. 如果已经能回答，停止扩大，不查原始 QA 日记。
4. 如果用户要原话、日期、session/thread ID，或本 skill 的 source 指针不足以支撑结论，再调用 `codex-qa-diary-recall`。
5. 原始 session JSONL 永远是最后兜底；只有整理后 QA 日记 / manifest 不足，或用户明确要原始记录时，才窄查。

当前用户指令和当前项目文件优先于 QA 记忆。QA 记忆只能作证据和上下文，不得覆盖当前事实。
每日解释性摘要不再作为本系统入口；后续不新写、不维护，也不把它当作长期记忆来源。需要证据时查原始 QA 日记；需要长期上下文时先查本 skill 的 active 节点和 candidate 历史主题，candidate 只作召回线索。

## v2 分层

1. Markdown 审计层：`00-总入口.md`、`01-码表.md`、`02-模板.md`、`03-索引.md`、`records\YYYY-MM.md`、`candidates\YYYY-MM.md`、`maintenance\YYYY-MM-DD.md`，供主线程审查、追溯和人工裁决。
2. JSONL 机器状态层：`machine\events.jsonl`、`machine\nodes.jsonl`、`machine\edges.jsonl`、`machine\sources.jsonl`、`machine\audit.jsonl`、`machine\terms.jsonl`，供脚本排序、校验、过滤和生成短包；不得把裸 0/1 或裸数字码直接当作 LLM 主输入。
3. CLI 取回治理层：脚本负责读取 Markdown/JSONL、计算 0/1 标志和数字码、按 policy gate 排序过滤、校验 source 表，并输出带中文解码的短包。
4. LLM 短输出包：LLM 只接收当前任务需要的最小上下文；所有 `type_code`、`status_code`、`scope_code`、`rel_code` 和布尔标志必须并列短中文解码。

## 长期偏好边界

本系统里的“长期偏好”默认指 `%USERPROFILE%\.codex\qa-memory` 里的小节点，不是全局 `AGENTS.md`，也不是依赖 Codex 产品内置记忆。QA 日记是证据来源；全局 `AGENTS.md` 只放稳定硬规则、红线和入口指向。普通偏好只有在用户明确说“以后都按这个 / 记住 / 这是规则 / 不要再这样做”，或被多次使用并经主线程复核后，才提升为 active 节点。

跨项目默认只允许取回用户长期习惯、全局偏好、全局红线和通用执行策略。项目状态、临时授权、运行态工具/服务状态、一次性任务结果和当前项目三件套内容不得跨项目触发，除非当前用户明确点名要查对应项目历史。

QA memory 提升和降级按 [references/promotion-policy.md](references/promotion-policy.md) 执行；`candidate`、`soft-active`、`active` 三态由 policy gate 裁决，抽取器建议不得直接生效。

## 工作流

1. 判断任务类型：
   - `write-candidate`：从少量 QA/摘要中生成候选事件卡和小节点。
   - `retrieve`：按任务档位取回最小上下文。
   - `review`：审查候选、冲突、覆盖、废弃或提升。
   - `maintain`：维护码表、模板、索引和脚本。

2. 按需读取 reference：
   - 写候选：读 [references/write-policy.md](references/write-policy.md) 和 [references/templates.md](references/templates.md)。
   - 取回：读 [references/retrieval-policy.md](references/retrieval-policy.md)。
   - 查码表：读 [references/codebook.md](references/codebook.md)。
   - 改目录或索引：读 [references/storage-layout.md](references/storage-layout.md)。
   - 审查提升、降级或软记忆：读 [references/promotion-policy.md](references/promotion-policy.md)。

3. 控制成本：
   - 默认每次 QA 沉淀 0-3 个小节点。
   - 超过 3 个小节点必须写明原因、影响范围和需要人工复核的节点。
   - 第一版只建确定关系边：来源于、同任务、覆盖、依赖、冲突、用户授权、用户否决。

4. 写入边界：
   - 自动抽取默认只能写 `candidate（候选）` 或输出建议。
   - 高影响规则、授权、安全、凭据、服务、发布、外部智能体真实生效区、全局执行纪律必须人工确认后才能提升。
   - 不把凭据原文、私密配置、大日志全文或完整 QA 日记写进记忆节点。
   - Markdown 审计层保留可读裁决；JSONL 机器状态层只保存结构化字段和脱敏 source 指针。

5. 取回边界：
   - 快速恢复：最多 6 个节点，1200 字，1 跳关系。
   - 项目接续：最多 15 个节点，3000 字，2 跳关系。
   - 深度审查：最多 40 个节点，8000 字，2 跳关系。
   - 非空历史主题查询或自然回忆说法可纳入 `candidate（候选）` 历史主题；输出必须明示候选状态，不能当作 active 规则执行。
   - 到预算、已能回答当前问题、遇到不可裁决冲突时停止扩大。
   - CLI 先完成排序、验证和中文解码；LLM 输出必须短，不回传裸 JSONL、长表或只有数字码/0/1 的串。

## 脚本

可用脚本：

```powershell
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa-mem.ps1" get -Mode quick
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa-mem.ps1" validate
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa_memory_recall.ps1" -Mode quick
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa_memory_candidates.ps1" -Date 2026-07-06
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa_memory_maintain.ps1" -Date 2026-07-06
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa_memory_validate.ps1"
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.codex\skills\codex-qa-memory\scripts\qa_diary_health.ps1"
```

`qa_memory_recall.ps1` 和 `qa_memory_validate.ps1` 只读 `%USERPROFILE%\.codex\qa-memory`。`qa_memory_candidates.ps1` 默认只读 `qa-diary\YYYY-MM-DD\_index.md` 并输出候选；只有显式 `-WriteCandidate` 时才写入 `candidates\YYYY-MM.md`，仍不写 active。

`qa_memory_maintain.ps1` 是自动维护入口：读取当天 `qa-diary\YYYY-MM-DD\_index.md`，追加缺失的 `candidate（候选）` 历史主题、机器层 JSONL、`terms.jsonl` 查询别名、`audit.jsonl` 审计和 `maintenance\YYYY-MM-DD.md` 报告，然后运行校验；它不得提升 active，也不得写全局 `AGENTS.md`。当前本机计划任务通过 `run_qa_memory_maintain_hidden.vbs` 隐藏启动，每小时触发一次，并用 `-RequireCodexRunning` 保证 Codex 未运行时直接退出不写文件。

`qa_diary_health.ps1` 是 QA 日记健康检查入口：核对计划任务路径、watcher（监视器）心跳、日记新鲜度以及 manifest（清单）与 Markdown 锚点一致性。连续两次失败或发现路径/锚点硬错误时写入 `_watcher\ALERT.json` 并返回非零；恢复后自动清除告警。计划任务可通过 `run_qa_diary_health_hidden.vbs` 无窗口启动，脚本内部的缺失索引探针也禁止创建控制台窗口。

脚本是 v2 CLI 取回治理入口：负责 source 表核验、三态 gate、跨项目过滤、排序、预算截断、术语别名匹配和短中文解码。取回运行记录和命中日志以后可按需增加，但不是 v2 最小必备文件。SQLite 只能作为未来可选缓存，不是 v2 主存储，也不能成为取回前置依赖。

## 输出要求

取回应输出：

```text
任务判定：
当前有效事实：
适用规则：
用户偏好：
项目/工具边界：
相关证据：
冲突或废弃提醒：
风险：
下一步：
停止原因：
```

写候选应输出或写入事件卡、小节点和关系边，并保留来源指针、状态码、作用域码、类型码和敏感处理结论。

取回包必须同时包含机器字段和短中文解码，例如 `status_code: 302（active，当前有效）`、`cross_project_allowed: 0（禁止跨项目触发）`。禁止把 `302 400 1 0` 这类裸串作为 LLM 主输入或最终输出。

## 安全规则

- 不输出 key、token、cookie、Authorization、Bearer、private key、密码或完整私密配置值。
- 不用 QA 记忆覆盖当前用户指令、当前项目三件套或当前运行验证。
- 不自动全文扫描全部 QA 日记；只有用户明确要求整理旧账时，才可按日期批量抽取 candidate 历史主题。
- 不把数字码做成深层路径；数字码只做查询条件和索引字段。
- 不让 Codex subagent 直接提升长期 active 记忆；必须由主线程裁决。
- 不把项目状态、临时授权、运行态工具/服务状态跨项目默认召回。
