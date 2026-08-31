# QA memory 提升与降级策略

## 三态

- `candidate`：自动抽取候选，默认不生效，不进入回答。
- `soft-active`：低风险软记忆，只作带来源参考证据。
- `active`：硬记忆，可默认取回，但仍低于当前用户指令和当前项目文件。

## 最小字段

- 节点必填：`status_code`、`status_label`、`scope_code`、`scope_type`、`scope_id`、`source_ref`、`created_at`、`last_hit_at`、`risk_type`。
- 数字码字段必须配套短中文解码字段：`type_label`、`status_label`、`scope_label`；关系边还必须有 `rel_label`。
- 机器层布尔标志如 `cross_project_allowed`、`temporary_authorization`、`runtime_state` 由 CLI 计算，不由 LLM 凭空写裸 0/1。
- `soft-active` 必须有明确 scope、source 和 timestamp；不得静默跨项目取回。
- `active` 必须另加：`promoted_by`、`promoted_at`、`promotion_reason`。
- `active` 和 `soft-active` 必须能在 `machine\sources.jsonl` 的 source 表中解析到来源类别、日期和脱敏指针。
- 校验脚本必须检查三态字段；字段缺失时不得判定 PASS。

## Policy Gate

1. 当前用户指令、当前项目文件和已生效 `active` 规则优先。
2. 自动抽取默认 `candidate`；`suggested_status=soft-active` 只代表抽取器建议。
3. 最终状态必须由本 gate 计算；风险分类失败或三态字段缺失时默认 `candidate`。
4. 命中 denylist 或高风险内容时不得自动进入 `soft-active`；高风险提升仍需用户明确确认。
5. 命中 allowlist、字段完整、scope 明确、source 可追溯且无冲突时，可进入 `soft-active`。
6. 用户明确确认或 Codex 主线程复核后，才能提升 `active`。
7. Codex subagent 不得直接提升长期 `active`；只能返回建议和证据。
8. 跨项目 gate 必须先于排序生效：只有用户长期习惯、全局偏好、全局红线和通用执行策略可默认跨项目取回。
9. 项目状态、临时授权、运行态工具/服务状态不得因 active 状态跨项目触发；用户明确点名历史项目时也只能作为候选证据返回。

## Allowlist

- 稳定称呼。
- 非敏感输出格式偏好。
- 低影响工作习惯。
- 项目内普通背景事实（仅同项目或同 scope 默认取回）。
- 常用路径。
- 已验证工具状态（仅同工具/scope，运行态状态不得跨项目默认触发）。
- 失败经验。

## Denylist

- 凭据、账号、token、cookie、授权、密码、private key。
- 安全边界、发布、删除、服务启停或重配。
- 付款、跨项目规则、身份或关系判断。
- 医疗、法律、金融建议。
- 外部智能体真实生效区修改。
- 项目状态跨项目默认触发。
- 临时授权、一次性许可或当次任务边界跨项目复用。
- 端口、PID、health、服务启停结果等运行态事实跨项目默认触发。

## 取回优先级

1. 当前用户指令。
2. 当前项目文件。
3. `active`。
4. 同 scope `soft-active`。
5. `candidate`。

`candidate` 默认不进回答；只有用户询问候选，或明确说“之前可能提过”时才可作为候选证据返回。

## Source Gate

- 每个可取回节点必须有 `source_ref`，并能在 source 表中找到 `source_type`、`path_or_id`、`date`、`sensitive_class` 和 `availability`。
- source 表只保存脱敏路径、标识和哈希；不得保存凭据原文、完整私密配置或长日志正文。
- `availability=missing`、`sensitive_class=secret` 或来源无法核验时，不得提升为 `active`。
- source 与 Markdown 审计层冲突时，默认降为 `review_required`。

## 降级

- 30 天未被主线程采用、引用或进入最终判断：降低取回权重。
- 90 天未被主线程采用、引用或进入最终判断：降回 `candidate`。
- 单纯召回不算命中；只有主线程采用、引用或进入最终判断时，才更新 `last_hit_at`。

## Non-goals

不引入 pinned、复杂评分、强依赖数据库、向量库、知识图谱或多级审批。SQLite 可作为未来可选缓存，但不是 v2 主存储或提升前置条件。
