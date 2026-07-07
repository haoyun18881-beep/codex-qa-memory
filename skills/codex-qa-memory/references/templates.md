# 模板

## 事件卡

```yaml
event_id: EC-YYYYMMDD-001
title: 简短标题
time: YYYY-MM-DD
scope_code: 408
scope_label: qa-memory（QA 存取系统自身范围）
scope: global.codex.qa
summary: 200 字以内说明这件事、结论和为什么重要。
source_ref: path-or-history-id
status_code: 300
status_label: candidate（候选，未生效）
nodes:
  - N-YYYYMMDD-001
sensitive: none
created_at: YYYY-MM-DD
updated_at: YYYY-MM-DD
```

## 小节点

```yaml
node_id: N-YYYYMMDD-001
type_code: 202
type_label: 规则（执行规则、流程规则、红线）
status_code: 300
status_label: candidate（候选，未生效）
scope_code: 408
scope_label: qa-memory（QA 存取系统自身范围）
scope_type: skill
scope_id: codex-qa-memory
content: 一句话，只表达一个事实、偏好、规则、决策或状态。
source_ref: path-or-history-id
event_id: EC-YYYYMMDD-001
created_at: YYYY-MM-DD
updated_at: YYYY-MM-DD
confidence: medium
tags:
  - 标签
sensitive: none
```

要求：

- `content` 推荐 20-80 字。
- 超过 120 字优先拆分或放回事件卡摘要。
- 自动抽取默认 `status_code: 300`。
- 用户明确确认、项目文件落地或主线程采纳后，才能提升为 `302 active`。

## 关系边

```yaml
edge_id: R-YYYYMMDD-001
from: N-YYYYMMDD-001
to: EC-YYYYMMDD-001
rel_code: 105
rel_label: 来源于（A 来源于 B）
status_code: 310
status_label: verified（已验证）
source_ref: path-or-history-id
created_at: YYYY-MM-DD
sensitive: none
```

第一版只长期写确定关系：来源于、同任务、覆盖、依赖、冲突、用户授权、用户否决。

## 取回输出

```text
QA取回包:
mode:
task:
当前有效事实:
适用规则/偏好:
项目/工具边界:
跨项目过滤:
冲突或 review_required:
source_refs:
stopped_by:
```

每条事实或规则推荐一行，格式为：

```text
- N-YYYYMMDD-001: 内容。type_code=202（规则），status_code=302（active，当前有效），scope_code=400（global.codex，全局 Codex 偏好或规则），source_ref=...
```

禁止把 `202 302 400 1 0` 这类裸数字/布尔串作为 LLM 主输入或最终输出。

## source 表记录

```yaml
source_ref: source-id
source_type: qa-diary | project-doc | user-message | skill-doc | command-output
path_or_id: 脱敏路径、文档编号或消息标识
date: YYYY-MM-DD
project_id: project-or-global
thread_id: optional-thread-id
run_id: optional-run-id
excerpt_hash: optional-hash
sensitive_class: none | redacted | secret
availability: available | missing | restricted
```

source 表只存来源指针和脱敏摘要，不存凭据原文、完整私密配置、长日志或完整 QA 日记。

## JSONL 机器层节点

```json
{"node_id":"N-YYYYMMDD-001","event_id":"EC-YYYYMMDD-001","type_code":202,"type_label":"规则","status_code":300,"status_label":"candidate（候选，未生效）","scope_code":408,"scope_label":"qa-memory（QA 存取系统自身范围）","scope_type":"skill","scope_id":"codex-qa-memory","content":"一句话节点内容。","source_ref":"source-id","cross_project_allowed":0,"cross_project_label":"禁止跨项目触发","temporary_authorization":0,"temporary_authorization_label":"不是临时授权","runtime_state":0,"runtime_state_label":"不是运行态状态","sensitive":"none","updated_at":"YYYY-MM-DD"}
```

`cross_project_allowed`、`temporary_authorization`、`runtime_state` 等 0/1 字段由 CLI 计算；短包和 LLM 输出必须保留中文 label。

## 超过 3 个节点时的理由

```text
超过原因：
影响范围：
为什么不能合并成事件卡摘要：
哪些节点需要人工复核：
```
