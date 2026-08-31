# Codex QA Memory MCP（旧版兼容）

这份本地只读 MCP 暂时保留给已经注册的旧安装，避免现有 `codex-qa-memory` MCP 配置突然断链。它不是当前推荐的新安装路径，也不会随 `0.2.0-dev.0` 的默认包内容分发。

旧服务仍提供：

- `qa_memory_recall`
- `qa_diary_search`
- `qa_memory_health`

其中 QA memory 候选层已经退出推荐架构。新流程使用：

`Obsidian → codex-qa-diary-recall → 原始 Session 最后兜底`

## 边界

- 服务只读，不创建、修改或删除文件。
- 不读取原始 Session JSONL。
- 不允许调用方指定任意本机路径。
- 不返回 manifest 中的本机私密路径。
- 当前用户指令和当前项目文件始终优先。

已有注册可以在观察期内继续用于审计冻结档案。新安装不要运行 `scripts/install_codex_qa_memory_mcp.ps1`；后续会另行提供只包含 diary search/health 的 MCP。

## 旧版验证

```powershell
python -m py_compile .\mcp\codex_qa_memory_mcp.py
python -m unittest discover -s .\mcp\tests -v
python .\mcp\codex_qa_memory_mcp.py health
```
