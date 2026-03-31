# 内置 Skills（LinkMed / Codex 镜像）

本目录随 `Dockerfile` 烘焙进 `CODEX_HOME/skills`。说明见 **`docs/claude-scientific-skills-integration-zh.md`**。

## 维护要点

- **文献**：不单独引入上游 PubMed/OpenAlex/bioRxiv skill；以 **`citation-management`**、**`literature-review`** 等为主。不使用 Google Scholar（不装 `scholarly`）。
- **图**：数据/统计图用 **Matplotlib / Seaborn**（及 **statsmodels** / **scientific-visualization**）；概念示意、流程图等用 **豆包**（根目录 `AGENTS.md`）。
- **已移除**：`research-lookup`（Parallel/OpenRouter）、`scientific-schematics`（OpenRouter 示意图），与当前产品策略一致。
