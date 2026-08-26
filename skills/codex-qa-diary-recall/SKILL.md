---
name: codex-qa-diary-recall
description: "Codex QA 取证兜底，只读查找本机 Codex QA 日记、manifest、聊天记录和 Codex session/thread ID 映射。Use only when the user explicitly asks for 原话、日期、证据、聊天记录、某天/某项目 QA、session ID、thread ID、原始日记/原始记录，or after codex-qa-memory is insufficient and exact evidence is needed. Do not use as the default response to natural memory phrases like 之前聊过/你还记得吗; use codex-qa-memory first. 原始 JSONL 只能最后窄查。"
---

# Codex QA Diary Recall

## 一句话规则

本 skill 是证据室，不是记忆门口。新会话遇到“之前聊过 / 我们做过 / 你还记得吗”这类自然回忆，必须先用 `codex-qa-memory`；只有需要原话、日期、证据、session/thread ID，或 QA memory 证据不足时，才使用本 skill。

## MCP 优先入口

如果当前 Agent 已连接 Codex QA Memory MCP，证据查询优先调用只读工具 `qa_diary_search`；MCP 不可用或整理后的日记证据不足时，再按下面的 manifest → 日记正文流程窄查。

- 优先给日期、关键词、`session_id` 中最窄的已知定位条件。
- MCP v1 不读取原始 Codex session JSONL；无结果不等于不存在，只能报告已查范围并按本 skill 的原始 fallback Gate 决定是否继续。
- 不把 manifest 的本机绝对路径、`cwd` 或其他私密路径当作回答内容。
- 查询结果只是来源证据，不得直接提升为 active 记忆；需要沉淀候选时转 `codex-qa-memory`。

## 目标

只读查找本机 Codex QA 日记和会话索引。优先使用整理后的 `qa-diary`，不要一上来全文读取原始 Codex session JSONL。

如果用户要的是结构化长期记忆取回，而不是原始 QA 日记证据，例如“取回 QA 记忆”“快速恢复记忆”“事件卡”“小节点”“数字码索引”“从 QA 日记沉淀候选记忆”，使用 `codex-qa-memory`。自然回忆口吻如“之前聊过”“之前说过”“我们做过”“你还记得吗”默认也先用 `codex-qa-memory`；只有用户要求原话、日期、证据、聊天记录或 session/thread ID，或结构化记忆证据不足时，才转本 skill。本 skill 负责原始日记、manifest、session/thread ID 和证据锚点。

## 和 codex-qa-memory 的分工

| 场景 | 先用谁 | 说明 |
| --- | --- | --- |
| 自然回忆：之前聊过、之前定过、我们做过、还记得吗 | `codex-qa-memory` | 先取结构化记忆和候选历史主题。 |
| 用户要长期偏好、规则、失败经验、项目历史线索 | `codex-qa-memory` | 本 skill 不做长期记忆裁决。 |
| 用户要原话、日期、证据、聊天记录、session/thread ID | 本 skill | 只读查整理后的 QA 日记、manifest 和必要锚点。 |
| QA memory 命中不准、不全或冲突 | 本 skill | 用 memory 的 source 指针做窄取证，不扩大成全文搜索。 |
| 用户明确要原始 JSONL，或 qa-diary / manifest 缺失 | 本 skill 的原始 fallback | 只窄查必要片段，不 dump 整个 JSONL。 |

硬规则：

- 不得因为用户说“之前聊过 / 你还记得吗”就直接进本 skill；这类请求先走 `codex-qa-memory`。
- 不得把本 skill 查到的原始日记直接提升为 active 记忆；需要沉淀候选时转 `codex-qa-memory`。
- 不得把 `_index.md` 的旧 `Main-Agent Summary` 当作当前长期记忆入口。
- 不得默认读取原始 session JSONL；原始 JSONL 只能作为最后兜底。

## 固定路径

- QA 日记根目录：`%USERPROFILE%\.codex\qa-diary`
- 每日索引：`%USERPROFILE%\.codex\qa-diary\YYYY-MM-DD\_index.md`
- 每日 manifest：`%USERPROFILE%\.codex\qa-diary\YYYY-MM-DD\_meta\manifest.jsonl`
- 日记正文：`projects\*.md` / `general\*.md`
- 原始 session fallback：`%USERPROFILE%\.codex\sessions`
- 提取器项目：`<repo>\codex-qa-memory`

## 查询流程

1. 判断用户给的是会话 ID、日期、关键词、项目名，还是模糊问题。
   - 模糊自然回忆、项目历史主题、长期偏好、规则或失败经验：停止本流程，改用 `codex-qa-memory`。
   - 原话、日期、证据、聊天记录、session/thread ID 或原始记录：继续本流程。
2. 如果需要最新材料，且提取器存在，先补跑一次同步：

```powershell
$env:PYTHONPATH='<repo>\qa-logger\src'
python -m qa_logger scan-sessions
```

这只追加/更新 `qa-diary`，不要改摘要区，也不要写 Codex Memories 或 OpenClaw。

3. 查会话 ID / session ID / thread ID：
   - 先用 `rg "<id>" %USERPROFILE%\.codex\qa-diary -g "manifest.jsonl"` 或等价命令查每日 manifest。
   - 从 manifest 读取 `session.id`、`session.path`、`target`、`anchor`、`question_time`、`answer_times`。
   - 再读取对应日期下的 `target` 日记正文，按 `anchor` 或关键词定位相关 Q/A。
   - 如果多个 manifest 命中，按日期和 `question_time` 汇总，不要默认只取第一条。

4. 查某天或今天的 Codex QA：
   - 先读当天 `_index.md` 的 `Script Timeline`；若旧的 `Main-Agent Summary` 存在，只能作为 legacy（历史遗留）辅助线索。
   - 只有需要具体问答时，再读 `_index.md` 表中指向的 `projects/*.md` 或 `general/*.md`。

5. 查关键词或项目：
   - 先用 `rg -n "<keyword>" %USERPROFILE%\.codex\qa-diary -g "*.md"`。
   - 只打开最相关的少量文件和锚点附近内容。
   - 返回路径、日期、锚点和简短摘录，不回传整篇日记。

6. 只有在以下情况才读原始 JSONL：
   - `qa-diary` 不存在或明显没有同步。
   - manifest 查不到但用户给了明确会话 ID。
   - 用户明确要求“原始记录/原始 JSONL”。
   - 需要排查提取器是否漏记。

原始 JSONL fallback 也必须窄读：先用文件名或 `rg` 定位，再按时间/关键词抽取必要片段，不要 dump 整个 JSONL。

7. 结构化记忆边界。
   - 不从本 skill 自动生成事件卡、小节点或 active 规则。
   - 不把 `_index.md` 的 `Main-Agent Summary` 当作最终快速恢复记忆包；该摘要入口已停止维护。
   - 需要最小上下文取回时，先用 `codex-qa-memory` 读取 `%USERPROFILE%\.codex\qa-memory\03-索引.md`；只有证据不足时再回到本 skill 窄读 QA 日记。

## 输出要求

回答必须包含：

- 查询路径：日记 / manifest / 原始 JSONL fallback。
- 命中证据：日期、文件路径、anchor 或行号、session ID。
- 结论置信度：high / medium / low。
- 若未同步或结果不完整，明确说明缺口和下一步可验证动作。

## 安全与边界

- 本 skill 默认只读；不要更新 `_index.md` 的 `Main-Agent Summary`，也不要新写每日解释性摘要。
- 本 skill 不写 `%USERPROFILE%\.codex\qa-memory`；需要写候选或维护 QA 记忆时改用 `codex-qa-memory`。
- 不输出 key、token、cookie、Authorization、Bearer、private key 或完整私密配置值。
- 不把完整长日记、完整原始 session JSONL、完整工具输出贴回聊天。
- 若发现疑似未脱敏内容，只报告“存在疑似敏感内容，未复述原文”。

## 常用命令

```powershell
rg -n "<session-id-or-keyword>" "%USERPROFILE%\.codex\qa-diary"
rg -n "<session-id>" "%USERPROFILE%\.codex\qa-diary" -g "manifest.jsonl"
Get-Content -Raw "%USERPROFILE%\.codex\qa-diary\YYYY-MM-DD\_index.md"
```
