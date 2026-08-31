# Codex QA Memory · Codex + Obsidian 的本地长期记忆

给 Codex 留一份不会随着窗口关闭一起消失、随时能回头查的本地 QA 日记。

推荐和 Obsidian、每日/每周自动化、[Personal Knowledge Recall](https://github.com/haoyun18881-beep/personal-knowledge-recall) 一起用。平时先从 Obsidian 找已经整理好的经验；需要当时的原话、日期、会话编号或证据位置，再回到 Codex QA 日记取证。

换窗口、跨项目，哪怕隔了一年，之前定过的规则、说过的话和踩过的坑，也不用从头翻整段旧对话。

- 🧠 **永不失忆**：QA 日记和会话索引持续保存在本机
- ⚡ **先找知识，再查证据**：Obsidian 负责长期知识，Codex QA 负责原始依据
- 🔐 **有据可查**：需要时可以定位日期、原话、Session ID 和 Thread ID

---

## 它解决了什么问题

AI 一换窗口，很容易忘掉之前做过什么。直接把整段旧对话重新塞进上下文，又慢、费 Token，还容易找错。

现在的分工很简单：

- **Obsidian**：保存经过整理的经验、项目、主题和长期知识。
- **Codex QA**：持续记录问答，保留日记、manifest 和证据位置。
- **Personal Knowledge Recall**：先查 Obsidian；知识不够时，再按需进入 QA 证据层。

推荐召回顺序：

`当前指令和项目事实 → Obsidian → QA 日记/manifest → 原始 Session 最后兜底`

已经退役的 `codex-qa-memory` 候选层不再参与普通召回，也不会由新安装流程创建或启用。旧用户已有的 QA memory 数据不会被安装器删除，可继续冻结保留，等自己的迁移和观察门槛完成后再处理。

升级用户注意：安装器只检测旧的 `Codex QA Memory Hourly Maintenance` 任务，不会替用户停用。若旧任务仍启用，它会继续生成候选；确认不再使用后，需要由用户明确停用。

---

## 数据都在本机

不需要数据库、向量库或云端记忆服务。QA 日记使用本地 Markdown 和 JSONL 文件，能看、能迁移、能审查。

仓库和发布内容不包含任何用户的真实日记、会话、账号文件或凭据。

---

## 最快安装方式

把这个 GitHub 仓库交给 Codex，让它运行 `scripts/install_codex_qa_memory.ps1`。为了兼容旧地址，安装脚本仍保留原文件名；当前版本只安装 `codex-qa-diary-recall`，不会创建 `qa-memory`，也不会碰已有冻结档案。

手动安装：

```powershell
$repo = "$env:USERPROFILE\.codex\tools\codex-qa-memory"
git clone https://github.com/haoyun18881-beep/codex-qa-memory.git $repo
powershell -ExecutionPolicy Bypass -File "$repo\scripts\install_codex_qa_memory.ps1"
```

首次生成 QA 日记：

```powershell
cd "$env:USERPROFILE\.codex\tools\codex-qa-memory"
$env:PYTHONPATH="$PWD\qa-logger\src"
python -m qa_logger scan-sessions --dry-run
python -m qa_logger scan-sessions
```

默认读取 `%USERPROFILE%\.codex\sessions`，写入 `%USERPROFILE%\.codex\qa-diary`。

核心安装不会自动扫描会话、注册 MCP 或创建后台任务。

---

## 怎么召回

安装 [Personal Knowledge Recall](https://github.com/haoyun18881-beep/personal-knowledge-recall) 后，可以直接这样问：

- 你还记得我们之前怎么处理这个问题吗？
- 查一下以前关于这个项目的决定。
- 找出当时的日期和证据位置。
- 我要当时的原话和 Session 编号。

Obsidian 已经能回答时就停止；只有知识不足或需要精确证据时，才调用 `codex-qa-diary-recall`。

---

## Windows 后台记录（可选）

需要持续整理新增会话时，可以安装隐藏的 QA Diary Watcher 和健康检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_diary_watcher_task.ps1
```

后台任务只负责 QA 日记的增量记录、检查和恢复，不维护 Obsidian，也不生成 QA memory 候选节点。

Obsidian 的每日/每周整理需要另行配置，不会因为安装 Codex QA 自动出现。参考流程见 [Personal Knowledge Recall 的自动化说明](https://github.com/haoyun18881-beep/personal-knowledge-recall/blob/main/references/automation-workflow.md)。

---

## MCP 当前状态

仓库暂时保留旧版只读 MCP 和安装脚本，供已有安装审计与兼容。它仍带有旧 QA memory 工具，因此不属于当前推荐的新安装路径。

新的默认流程直接使用 `codex-qa-diary-recall`。等兼容观察完成后，再把 MCP 收缩成独立的 diary search/health 服务；本轮不会强行改名或删除，避免现有 MCP 注册断链。

详细边界见 [MCP 兼容说明](mcp/README.md)。

---

## 默认保护隐私

QA 正文写入本地前，会对常见凭据做基础脱敏。本地 manifest 会保留定位所需的 Session 路径和项目目录，所以整个 QA 目录都应只留在本机。

不要把以下内容提交到仓库：

- 真实 QA 日记和冻结 QA memory 档案
- 原始 Session 与存档 Session
- 监视器日志、心跳、manifest 或本机路径清单
- Token、Cookie、API Key、账号文件或私有导出

---

## 开发者验证

```powershell
npm test
npm run test:python
npm run test:powershell
npm run test:mcp:legacy
npm pack --dry-run
```

当前 GitHub 主线是 `0.2.0-dev.0`，暂不发布 npm。npm 上的 `0.1.1` 仍是旧候选记忆架构，不作为当前推荐安装来源。

---

## 联系作者

添加我时请备注：**codex使用心得交流**

<img src="./assets/wechat-contact-qr.png" alt="微信二维码" width="320">

---

## License

BUSL-1.1，详见 [LICENSE](LICENSE)。
