# Codex QA Memory · 永不失忆的 AI 长期记忆外挂

[npm 发布包：codex-qa-memory](https://www.npmjs.com/package/codex-qa-memory)

给 Codex 一个不会随着窗口关闭一起消失、随时能找回来的本地记忆库。

推荐和 Obsidian、每日/每周自动化、[知识库召回 Skill](https://github.com/haoyun18881-beep/personal-knowledge-recall) 一起用。平时排查故障、做规划、继续项目，或者问“这件事以前聊过吗”，召回 Skill 会先去 Obsidian 找已经整理好的经验。需要当时的原话、日期或会话编号，再交给 Codex QA 精准取证。

Codex QA 持续记录新对话，整理成方便召回的记忆线索。Obsidian 用来归纳经验、项目和主题；每日和每周自动化负责补充、提炼和查漏，需要时再由召回 Skill 打开知识库。

换窗口、跨项目，哪怕隔了一年，之前定过的规则、说过的话、个人偏好和踩过的坑，也不用重新解释。

- 🧠 **永不失忆**：完整 QA 日记和结构化记忆要点双层保存
- ⚡ **先快后准**：先查小记忆，需要原话时再精准取证
- 🔐 **有据可查**：每条记忆保留时间、来源和证据位置

---

## 它解决了什么问题

AI 一换窗口，很容易忘掉之前做过什么。直接把整段旧对话重新塞进上下文，又慢、费 Token，还可能因为找错内容产生误判。

Codex QA 把记忆分成两层：

- **记忆前门**：保存短小、结构化、能快速召回的记忆节点。
- **证据室**：保存完整 QA 日记。需要原话、日期或会话编号时，再按准确位置取证。

平时先查记忆节点；只有需要证明或补充细节时，才打开对应日记。

---

## 数据都在本机

不需要数据库、向量库或云端记忆服务。核心数据是本地 Markdown 和 JSONL 文件，能看、能迁移、能审查；默认只把当前任务需要的少量记忆交给 Codex。

---

## 完整的召回顺序

推荐顺序：

`Obsidian 知识库 → codex-qa-memory → codex-qa-diary-recall`

- **[personal-knowledge-recall](https://github.com/haoyun18881-beep/personal-knowledge-recall)**：先按当前任务查 Obsidian，找到够用的信息就停止。
- **codex-qa-memory**：知识库信息不够时，补充长期偏好、规则、失败经验和项目历史。
- **codex-qa-diary-recall**：需要原话、日期、Session ID、Thread ID 或证据位置时，再窄查完整 QA 日记。

`personal-knowledge-recall` 是推荐搭配的独立 Skill，不包含在当前 npm 包中。没有 Obsidian 时，Codex QA 自带的两个 Skill 仍可单独使用。

你可以直接这样问：

- 你还记得我们之前怎么处理这个问题吗？
- 查一下以前关于这个项目的决定。
- 找出当时的日期和证据位置。
- 我要当时的原话和 Session 编号。

---

## 最快安装方式

把这个 GitHub 仓库交给 Codex，让它运行 `scripts/install_codex_qa_memory.ps1`。安装器会：

1. 安装 `codex-qa-memory` 和 `codex-qa-diary-recall` 两个 Skill。
2. 初始化本机 QA Memory 目录和必要子目录。
3. 保留已有记忆；遇到有差异的已安装 Skill 时停止，不会静默覆盖。

手动安装：

```powershell
$repo = "$env:USERPROFILE\.codex\tools\codex-qa-memory"
git clone https://github.com/haoyun18881-beep/codex-qa-memory.git $repo
powershell -ExecutionPolicy Bypass -File "$repo\scripts\install_codex_qa_memory.ps1"
```

核心安装不会自动扫描会话、注册 MCP 或创建后台任务。首次生成 QA 日记时，在仓库目录运行：

```powershell
cd "$env:USERPROFILE\.codex\tools\codex-qa-memory"
$env:PYTHONPATH="$PWD\qa-logger\src"
python -m qa_logger scan-sessions --dry-run
python -m qa_logger scan-sessions
```

默认读取 `%USERPROFILE%\.codex\sessions`，写入 `%USERPROFILE%\.codex\qa-diary`；结构化记忆默认位于 `%USERPROFILE%\.codex\qa-memory`。

---

## MCP：让 Codex 直接调用记忆

仓库提供本地只读 MCP 服务。Skill 负责判断什么时候该查，MCP 提供结构化记忆召回、QA 日记取证和健康检查三个工具。

它不会读取原始 Session JSONL，不允许调用方指定任意本机路径，也不会把候选记忆提升成长期规则。

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_memory_mcp.ps1
```

安装成功后重启 Codex，再用 `/mcp` 查看连接。详细边界和手动配置见 [MCP 说明](mcp/README.md)。

---

## 它是怎么工作的

扫描器把会话整理成 QA 日记，维护脚本再从日记生成候选记忆。需要历史时，先取小节点；需要原始证据时，再按来源位置读取对应日记。

Obsidian 工作流和知识库召回 Skill 都需要另行配置，不会随 Codex QA 自动安装。每日/每周整理可以参考 [personal-knowledge-recall 的维护流程](https://github.com/haoyun18881-beep/personal-knowledge-recall/blob/main/references/automation-workflow.md)。

---

## 记忆不会偷偷变成规则

长期记忆分成三种状态：

- **candidate（候选）**：自动整理出来的线索，默认不生效。
- **soft-active（软生效）**：低风险、来源完整、范围明确，只作参考。
- **active（长期有效）**：经过用户明确确认或主任务复核后才能提升。

当前用户指令和当前项目文件永远优先。旧记忆不能盖过现在的事实。

---

## 三档召回预算

- **quick**：最多 6 个节点，目标字符预算 1200。适合新窗口和轻量恢复。
- **project**：最多 15 个节点，目标字符预算 3000。适合继续项目和恢复边界。
- **deep**：最多 40 个节点，目标字符预算 8000。适合冲突审查和方案复盘。

够回答就停，不无限扩大上下文。

---

## 默认保护隐私

QA 正文写入本地前，会对常见凭据做基础脱敏；MCP 返回结果前还会过滤凭据和本机绝对路径。本地 manifest 会保留用于定位的 Session 路径和项目目录，因此整个 QA 目录都应只留在本机。

仓库和发布包不包含任何用户的真实日记、会话、记忆节点、账号文件或凭据。

---

## Windows 后台维护（可选）

需要持续整理新增会话时，可以安装隐藏后台监视、周期恢复和健康检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_diary_watcher_task.ps1
```

后台任务只负责 QA 会话记录、检查和恢复，不维护 Obsidian，也不会把候选记忆自动提升成长期规则。

---

## 开发者验证

```powershell
npm test
npm run test:python
npm run test:mcp
npm run memory:validate
npm pack --dry-run
```

---

## 包里不包含

- 真实 QA 日记和记忆节点
- 原始会话和存档会话
- 向量索引、数据库、监视器日志和心跳文件
- token、cookie、API key、账户文件或私有导出

---

## 联系作者

添加我时请备注：**codex使用心得交流**

<img src="./assets/wechat-contact-qr.png" alt="微信二维码" width="320">

---

## License

BUSL-1.1，详见 [LICENSE](LICENSE)。

---

**Codex QA Memory：记住你说过的，不瞎编你没说的。**
