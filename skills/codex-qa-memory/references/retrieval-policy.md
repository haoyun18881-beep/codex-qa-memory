# 取回策略

## 档位

| 档位 | 场景 | 节点上限 | 字数上限 | 关系跳数 |
| --- | --- | --- | --- | --- |
| quick | 新窗口、压缩后接续、轻量偏好恢复 | 6 | 1200 | 1 |
| project | 继续项目、查当前边界、恢复下一步 | 15 | 3000 | 2 |
| deep | 冲突裁决、规则审查、方案复盘 | 40 | 8000 | 2 |

## 查询顺序

1. 当前用户指令。
2. 当前项目三件套和入口文件。
3. CLI 从 JSONL 机器状态层读取候选集合，并用 Markdown 审计层/source 表核验关键来源。
4. 已 active 的 QA 小节点。
5. 同 scope 的 `soft-active`。
6. 最近事件卡。
7. 相关证据摘要。
8. 历史节点和归档节点。
9. 原始 QA 日记。

QA 记忆不得覆盖当前用户指令和当前项目文件。

用户给出非空历史主题查询，或使用“之前聊过 / 当时怎么定 / 我们做过 / 你还记得吗”等自然回忆说法时，可以把 `candidate（候选）` 历史主题纳入取回结果；输出必须明示 `candidate`，并说明它只是召回线索，不等于 active 规则或当前事实。空查询和普通默认恢复不得混入 candidate。

## CLI 取回治理

取回必须先经过 CLI 或等价脚本治理，再交给 LLM：

1. 解析当前任务、项目、工具、run/thread 和用户显式问法。
2. 读取 `machine\nodes.jsonl`、`machine\edges.jsonl`、`machine\sources.jsonl`；必要时抽样核对 Markdown 审计层。
3. 计算 0/1 标志和数字码过滤项，例如 `same_project`、`cross_project_allowed`、`temporary_authorization`、`runtime_state`、`source_available`。
4. 执行三态 gate、跨项目 gate、敏感 gate、source gate 和预算 gate。
5. 输出 LLM 短包：每条节点必须带 `id + 内容 + code（中文解码）+ source_ref + 取回理由`。

LLM 不应接收裸 JSONL 全量、长表、长日志或纯 `0/1/数字码` 串。

## 跨项目取回规则

跨项目默认允许：

- 用户长期习惯。
- 全局偏好。
- 全局红线。
- 通用执行策略。

跨项目默认禁止：

- 项目状态、项目下一步、项目三件套内容。
- 临时授权、一次性许可、当次任务边界。
- 运行态工具/服务状态、端口、PID、健康检查结果。
- 账号、凭据、发布、付款、安全和外部智能体真实生效区相关判断。

项目状态只能在同一 `scope_id` 内默认取回。用户明确点名“查某项目历史”时，可以作为候选证据返回，但仍不得自动变成当前项目事实。

## 停止条件

- 已能回答当前状态、下一步、边界和风险。
- 新增节点只重复已有结论。
- 命中预算上限。
- 发现冲突但无法裁决，转为 `review_required`。
- 当前任务只需要项目文件，不需要 QA 记忆。

## 常用码组合

| 目的 | 查询条件 |
| --- | --- |
| 当前有效规则 | `type_code in [202] and status_code in [302]` |
| 用户偏好 | `type_code in [201] and status_code in [301,302]`；`301` 只能同 scope 使用 |
| 失败经验 | `type_code in [206] and status_code in [302]` |
| 工具状态 | `type_code in [207] and status_code in [302]` |
| 待复核项 | `status_code in [303,304,311]` |
| QA 系统自身 | `scope_code = 408` |

所有码组合都必须在短包或最终回答里并列中文解码；例如 `type_code in [201]（偏好） and status_code in [301,302]（软生效/当前有效）`。

## 排序与验证原则

排序优先级：

1. 当前用户明确要求和当前项目文件命中。
2. `status_code=302（active，当前有效）` 且 scope 精确匹配。
3. `status_code=301（soft-active，软生效）` 且同 scope。
4. 来源可用、验证充分、最近被主线程采纳。
5. 关系边能支持当前问题，且没有未裁决冲突。

降权或排除：

- `candidate`、`review_required`、`conflict`、`stale`、`archived`、`expired` 默认不作为已生效事实进入答案；只有用户发起具体历史主题查询或自然回忆查询时，`candidate` 可作为候选召回线索返回。
- `source_ref` 缺失、source 表不可用、敏感处理不明时不得默认取回。
- 项目状态、临时授权和运行态状态跨项目命中时必须排除或标 `review_required`。

## 输出要求

输出必须短，并包含来源锚点。遇到冲突时列出冲突，不要合并成一个看似确定的结论。

推荐短包字段：

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
