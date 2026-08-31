# Codex QA Memory · 永不失忆的 AI 长期记忆外挂

[npm 发布包：codex-qa-memory](https://www.npmjs.com/package/codex-qa-memory)

给 Codex 一个不会随着窗口关闭一起消失、随时能找回来的本地记忆库。

推荐和 Obsidian、每日/每周自动化、[知识库召回 Skill](https://github.com/haoyun18881-beep/personal-knowledge-recall) 一起用。平时排查故障、做规划、继续项目，或者问“这件事以前聊过吗”，召回 Skill 会先去 Obsidian 找已经整理好的经验。需要当时的原话、日期或会话编号，再交给 Codex QA 精准取证。

Codex QA 负责持续记录新对话，并整理成可以召回的记忆线索；Obsidian 负责把经验、项目和主题放进一套看得见的结构里；每日和每周自动化负责补充、提炼和检查遗漏；召回 Skill 负责在合适的任务里打开知识库。

换窗口、跨项目，哪怕隔了一年，之前定过的规则、说过的话、个人偏好和踩过的坑，也不用重新解释。

- 🧠 **永不失忆**：完整 QA 日记和结构化记忆要点双层保存
- ⚡ **先快后准**：先查小记忆，需要原话时再精准取证
- 🔐 **有据可查**：每条记忆保留时间、来源和证据位置

---

## 它解决了什么问题

长期记忆会受到多种不确定因素影响，存在误判和错误引导风险。AI 一换窗口又很容易失忆；如果直接把整段旧对话重新塞进上下文，一旦找错内容，就容易引发幻觉和误判。不仅慢、费 Token，还可能挤爆上下文。

Codex QA Memory 不走大而全的路线。它把记忆分成两层：

- **记忆前门**：保存短小、结构化、能快速召回的记忆节点。
- **证据室**：保存完整 QA 日记。需要原话、日期或会话编号时，再根据准确位置精准取证。

平时问“你还记得吗”，先走记忆前门，尽量减少 Token 消耗；只有需要证明时，才打开证据室，以较小的上下文完成更精准的记忆召回。

---

## 为什么它真的轻

- 不需要数据库。
- 不需要向量库。
- 不需要云端记忆服务。
- 核心数据就是本地 Markdown 和 JSONL 文件，能看、能迁移、能审查。
- 默认只把当前任务需要的少量记忆交给 Codex，不把整本日记重新塞进上下文。

它不是靠堆组件解决问题，而是用最短的路径，把真正有用的记忆找回来。

---

## 完整的召回顺序

推荐的顺序是：

`Obsidian 知识库 → codex-qa-memory → codex-qa-diary-recall`

- **[personal-knowledge-recall](https://github.com/haoyun18881-beep/personal-knowledge-recall)**：先按当前任务查 Obsidian。知识库已经能回答，就不再扩大召回。
- **codex-qa-memory**：知识库信息不够时，补充长期偏好、规则、失败经验、项目历史和候选记忆。
- **codex-qa-diary-recall**：需要原话、日期、Session ID、Thread ID 或证据位置时，再窄查完整 QA 日记。

`personal-knowledge-recall` 是推荐搭配的独立 Skill，不包含在当前 npm 包中；没有 Obsidian 时，Codex QA 自带的两个 Skill 仍可单独使用。

你可以直接这样说：

- 你还记得我们之前怎么处理这个问题吗？
- 查一下以前关于这个项目的决定。
- 找出当时的日期和证据位置。
- 我要当时的原话和 Session 编号。

---

## MCP：让 Codex 直接调用记忆

仓库现在还提供一个本地只读 MCP 服务。Skill 负责告诉 Agent 什么时候该查；MCP 负责把三个稳定工具直接交给 Agent：结构化记忆召回、QA 日记取证和健康检查。

它不会读取原始 Session JSONL，不允许工具调用方指定任意本机路径，也不会把候选记忆偷偷提升成长期规则。

MCP 当前从 GitHub 仓库安装。在仓库根目录执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_memory_mcp.ps1
```

安装成功后重启 Codex，再用 `/mcp` 查看连接。详细边界和手动配置见 [MCP 说明](mcp/README.md)。

安装器会登记当前仓库的绝对路径，因此安装后不要移动或删除仓库；换位置时需要重新注册。

---

## 它是怎么工作的

1. Codex QA 的日志记录器把新会话整理成按日期归档的 QA 日记。
2. Codex QA 的记忆维护脚本从日记索引中生成可审查的候选记忆节点。
3. 如果另外配置了 Obsidian 每日/每周工作流，可以把候选经验继续整理到项目和主题入口。
4. `personal-knowledge-recall` 在合适的任务里先查 Obsidian，信息不够时再查 QA 记忆。
5. 需要原始证据时，最后根据来源指针窄查对应日记或会话。

完整记录不会因为生成了小节点就被丢掉。小节点负责快，原始日记负责准。

前两步属于 Codex QA 自带能力；Obsidian 整理流程需要用户另行配置，不会因为安装 Codex QA 自动出现。知识库召回 Skill 也需要从它的 [独立仓库](https://github.com/haoyun18881-beep/personal-knowledge-recall)安装。

---

## 记忆不会偷偷变成规则

所有长期记忆分成三种状态：

- **candidate（候选）**：自动整理出来的线索，默认不生效。
- **soft-active（软生效）**：低风险、来源完整、范围明确，只作参考。
- **active（长期有效）**：经过人工复核或用户明确确认后才能提升。

当前用户指令和当前项目文件永远优先。旧记忆不能盖过现在的事实。

---

## 三档召回预算

- **quick**：最多 6 个节点，目标字符预算 1200。适合新窗口和轻量恢复。
- **project**：最多 15 个节点，目标字符预算 3000。适合继续项目和恢复边界。
- **deep**：最多 40 个节点，目标字符预算 8000。适合冲突审查和方案复盘。

够回答就停，不无限扩大上下文。

---

## 默认保护隐私

常见的 key、token、cookie、Authorization、密码和私密配置，会在持久化前替换成脱敏标记；记忆校验还会再做一次敏感内容扫描。

仓库和发布包不包含任何用户的真实日记、会话、记忆节点、账号文件或凭据。

---

## 最快安装方式

把上面的 npm 发布包或这个 GitHub 仓库交给 Codex，让它完成下面三件事：

1. 把 `codex-qa-memory` 和 `codex-qa-diary-recall` 复制到 Codex Skills 目录。
2. 首次安装时，把 `qa-memory-template` 初始化为本机 QA Memory 目录。
3. 先执行一次只读试运行，确认范围后再开始写入本地日记。

需要手动安装时，只保留这几条命令：

```powershell
git clone https://github.com/haoyun18881-beep/codex-qa-memory.git
cd codex-qa-memory
$env:PYTHONPATH="$PWD\qa-logger\src"
python -m qa_logger scan-sessions --dry-run
python -m qa_logger scan-sessions
```

默认读取 `%USERPROFILE%\.codex\sessions`，写入 `%USERPROFILE%\.codex\qa-diary`；结构化记忆默认位于 `%USERPROFILE%\.codex\qa-memory`。

如果还想让 Codex 先查 Obsidian，再单独安装 [personal-knowledge-recall](https://github.com/haoyun18881-beep/personal-knowledge-recall)，并为它配置自己的 vault。这个额外 Skill 和 Obsidian 每日/每周自动化都不在 Codex QA 的 npm 包里。

---

## Windows 后台维护（可选）

仓库附带 Codex QA 的隐藏后台监视、周期恢复和健康检查。安装后，它可以持续整理新增会话，并在后台任务中断时自动恢复。

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_diary_watcher_task.ps1
```

这套后台任务只负责 QA 会话记录、检查和恢复，不会维护 Obsidian，也不会把候选记忆自动提升成长期规则。Obsidian 的每日/每周整理需要单独配置，可以参考 [personal-knowledge-recall 的维护流程](https://github.com/haoyun18881-beep/personal-knowledge-recall/blob/main/references/automation-workflow.md)。

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

## 包里故意不放什么

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
