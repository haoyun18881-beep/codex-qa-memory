# Codex QA Memory MCP

这是 Codex QA Memory 的本地只读 MCP（Model Context Protocol，模型上下文协议）入口。它让 Codex 通过本地 stdio MCP 直接调用 QA 记忆，而不需要自己拼接 PowerShell 命令。当前验证目标是 Codex 本地客户端；其他 Agent 客户端尚未逐一做兼容性承诺。

## 三个工具

- `qa_memory_recall`：自然回忆的默认入口，按 `quick`、`project`、`deep` 三档预算读取结构化记忆。
- `qa_diary_search`：需要原话、日期、证据位置或 Session/Thread ID 时，窄查整理后的 QA 日记。
- `qa_memory_health`：只读检查记忆索引、日记目录及最近 manifest/anchor 是否完整。

## 安全边界

- 三个工具全部声明为只读，不创建、修改或删除文件。
- MCP 调用参数不能指定任意本机根目录；读取范围由服务启动配置固定。
- 不读取 `%USERPROFILE%\.codex\sessions` 或 `archived_sessions` 原始 JSONL。
- 不返回 manifest 中的 `session.path`、`cwd` 等本机私密路径。
- 候选记忆默认隔离，只有显式传入 `include_candidates=true` 才返回，并标记为候选线索。
- 当前用户指令和当前项目文件始终高于召回记忆。

## 安装到 Codex

先运行仓库根目录的核心安装器，安装两个 Skill 并初始化 QA Memory：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_memory.ps1
```

再按需注册 MCP：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install_codex_qa_memory_mcp.ps1
```

安装脚本只注册 MCP，不运行记忆查询。安装成功后重启 Codex，再用 `/mcp` 查看连接状态。

注册项会保存当前仓库中 MCP 服务脚本的绝对路径。建议把仓库放在固定工具目录；如果位置改变，先运行 `codex mcp remove codex-qa-memory`，再从新位置重新安装。

如果同名配置已经指向当前服务，脚本会直接报告已安装；如果同名配置指向别处，脚本会停止，不会静默覆盖或删除。只预览、不写配置时使用 `-DryRun`。

也可以手动注册：

```powershell
codex mcp add codex-qa-memory -- python "C:\path\to\codex-qa-memory\mcp\codex_qa_memory_mcp.py"
```

## 自定义数据位置

默认读取：

- `%USERPROFILE%\.codex\qa-memory`
- `%USERPROFILE%\.codex\qa-diary`

需要改变位置时，在启动 MCP 服务的配置中设置 `CODEX_QA_MEMORY_ROOT` 和 `CODEX_QA_DIARY_ROOT` 环境变量。工具调用本身不接受路径参数。

## 开发验证

```powershell
python -m py_compile .\mcp\codex_qa_memory_mcp.py
python -m unittest discover -s .\mcp\tests -v
python .\mcp\codex_qa_memory_mcp.py health
```

服务无参数运行或使用 `serve` 子命令时进入 stdio MCP 模式。
