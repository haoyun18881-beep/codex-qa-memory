# 存储布局

根目录：`%USERPROFILE%\.codex\qa-memory`

## v2 层次

QA memory v2 有四层，职责不能混在一起：

- Markdown 审计层：人读、人审、人裁决，保留事件卡、小节点、关系边、索引和候选。
- JSONL 机器状态层：脚本读写的结构化镜像，负责排序、过滤、校验和命中统计。
- CLI 取回治理层：脚本把审计层和机器层收敛成预算内短包。
- LLM 短输出包：只给 LLM 当前任务需要的事实、规则、边界、风险和来源，不给长日志、长表或裸码串。

## Markdown 审计层

```text
00-总入口.md
01-码表.md
02-模板.md
03-索引.md
records/
candidates/
maintenance/
```

Markdown 层只创建 4 个入口文件和 3 个按需目录，不默认为每个日期、项目、工具建空目录。需要时按需创建月度文件或按日期维护报告。

## JSONL 机器状态层

```text
machine/
  events.jsonl
  nodes.jsonl
  edges.jsonl
  sources.jsonl
  audit.jsonl
  terms.jsonl
```

机器层是 v2 主结构化状态，不是大数据库。每行一个 JSON object，字段必须脱敏、可校验、可从 Markdown 审计层或 source 表追溯。

| 文件 | 用途 | 最小字段 |
| --- | --- | --- |
| `machine\events.jsonl` | 事件卡机器镜像 | `event_id`、`title`、`time`、`scope_code`、`scope_label`、`status_code`、`status_label`、`source_ref`、`updated_at` |
| `machine\nodes.jsonl` | 小节点机器镜像和当前可取回状态 | `node_id`、`event_id`、`type_code`、`type_label`、`status_code`、`status_label`、`scope_code`、`scope_label`、`scope_type`、`scope_id`、`content`、`source_ref`、`risk_type`、`sensitive`、`updated_at` |
| `machine\edges.jsonl` | 确定关系边 | `edge_id`、`from`、`to`、`rel_code`、`rel_label`、`status_code`、`status_label`、`source_ref`、`updated_at` |
| `machine\sources.jsonl` | source 表，统一来源指针 | `source_ref`、`source_type`、`path_or_id`、`date`、`project_id`、`thread_id`、`run_id`、`excerpt_hash`、`sensitive_class`、`availability` |
| `machine\audit.jsonl` | 机器层维护审计 | `audit_id`、`run_id`、`action`、`status`、`actor`、`source_ids`、`changed_files`、`created_at` |
| `machine\terms.jsonl` | 术语、别名和自然查询入口 | `term_id`、`terms`、`canonical`、`target_ids`、`scope_id`、`status_code`、`updated_at` |

取回运行记录 `recalls.jsonl` 和主线程采纳命中日志 `hitlog.jsonl` 以后可按需增加；v2 最小可用版本不把它们作为必备文件，避免把未实现能力写成硬依赖。

`0/1` 标志和数字码由 CLI 计算并校验；LLM 输出和短包必须同时带中文标签，例如 `scope_code: 400（global.codex，全局 Codex 偏好或规则）`。禁止把纯 `0/1` 裸串或裸数字码作为 LLM 主输入。

SQLite 只能作为未来可选缓存或加速索引；v2 主存储是 Markdown 审计层和 JSONL 机器状态层。

## 文件命名

- 事件卡编号：`EC-YYYYMMDD-NNN`
- 小节点编号：`N-YYYYMMDD-NNN`
- 关系边编号：`R-YYYYMMDD-NNN`
- 已采纳记录：`records\YYYY-MM.md`
- 候选记录：`candidates\YYYY-MM.md`
- 维护报告：`maintenance\YYYY-MM-DD.md`

文件名必须表达日期、编号、主题和状态；禁止默认名、无意义名和 `final/final2/最终最终版`。

## 索引原则

- `03-索引.md` 只放短项、路径、id、状态和摘要。
- 原文只放来源指针。
- 大材料不进索引正文。
- 同一节点的完整内容只在 `records\YYYY-MM.md` 或 `candidates\YYYY-MM.md` 维护。
- JSONL 机器层不得绕开 Markdown 审计层直接制造无法审查的 active 事实。
- `sources.jsonl` 是机器层 source 表；所有可取回节点、事件卡和关系边必须能通过 `source_ref` 找到来源类别、日期和脱敏路径/标识。
- 数字码只做字段、过滤条件和排序特征，不做深层目录路径。

## 跨项目存储边界

- 可标记为跨项目默认取回的内容只限用户长期习惯、全局偏好、全局红线和通用执行策略。
- 项目状态、临时授权、运行态工具/服务状态、一次性任务结果必须写入具体 `scope_type` / `scope_id`，默认只能同项目或同 scope 取回。
- 过期授权和运行态状态必须有 `expires_at` 或等价说明；不得因历史 active 状态跨项目触发当前操作。
