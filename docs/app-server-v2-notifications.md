# Codex App-Server v2 通知面（JSON-RPC Notifications）整理

本文档将 **app-server v2** 的事件流（server-initiated **JSON-RPC notifications**）按 `method` 进行归类说明，并给出与 legacy `codex/event/*` 的对照关系，便于客户端实现统一的事件处理与 UI 渲染。

> 术语约定
>
> - **v2 通知面**：以 `thread/*`、`turn/*`、`item/*` 等为主的通知方法名。
> - **legacy 通知面**：以 `codex/event/*` 为前缀的通知方法名（历史兼容层）。
> - **item**：turn 内部的工作单元（消息、工具调用、命令执行、文件改动等），通过 `item/started` → 若干增量事件 → `item/completed` 表达生命周期。

---

## v2：通知方法（method）清单与说明

### 1) 线程（Thread）生命周期与状态

- **`thread/started`**
  - **何时发送**：`thread/start` 或 `thread/fork` 成功后。
  - **用途**：告知客户端线程已就绪并可订阅后续 turn/item 通知。

- **`thread/archived`**
  - **何时发送**：`thread/archive` 成功后。
  - **用途**：线程归档状态变化，便于 UI 更新列表。

- **`thread/unarchived`**
  - **何时发送**：`thread/unarchive` 成功后。
  - **用途**：线程取消归档，便于 UI 更新列表。

- **`thread/closed`**
  - **何时发送**：`thread/unsubscribe` 后，如果该连接是最后一个订阅者，服务端卸载 thread 并关闭。
  - **用途**：告知客户端 thread 已不再可用/已被卸载。

- **`thread/status/changed`**
  - **载荷**：`{ threadId, status }`
  - **用途**：loaded thread 的状态更新（例如是否正在运行 turn、是否可交互等）。

- **`thread/tokenUsage/updated`**
  - **用途**：token 用量/计费相关的增量更新（与 turn 运行并行独立流出）。

- **`thread/name/updated`**
  - **载荷**：`{ threadId, threadName? }`
  - **用途**：线程名称更新（用户重命名/自动命名等）。

---

### 2) Turn（一次生成/执行）生命周期与派生事件

- **`turn/started`**
  - **载荷**：`{ turn }`（`turn.status` 通常为 `"inProgress"`）
  - **用途**：标记 turn 开始；UI 可创建“当前回合”容器。

- **`turn/completed`**
  - **载荷**：`{ turn }`（`turn.status` 为 `"completed" | "interrupted" | "failed"`）
  - **用途**：turn 结束的权威信号；客户端应以此作为清理/收尾的时机。

- **`turn/diff/updated`**
  - **载荷**：`{ threadId, turnId, diff }`
  - **用途**：每次 `fileChange` item 产生后，推送“当前 turn 的聚合 unified diff 快照”，客户端无需自己拼接多段 diff。

- **`turn/plan/updated`**
  - **载荷**：`{ turnId, explanation?, plan }`，其中 `plan[]` 每项含 `{ step, status: "pending" | "inProgress" | "completed" }`
  - **用途**：代理计划（plan）整体更新，用于渲染计划面板。

- **`model/rerouted`**
  - **载荷**：`{ threadId, turnId, fromModel, toModel, reason }`
  - **用途**：后端出于安全/可用性等原因将请求路由到不同模型时通知客户端。

---

### 3) Item（turn 内工作单元）通用生命周期

所有 item 都遵循统一生命周期：

- **`item/started`**：发送完整 `item`（包含 `item.id`、`item.type`、初始字段与 `status`）
- **`item/completed`**：发送最终 `item`（包含最终 `status` 与结果字段）

当前支持的主要 `item.type`（用于理解后续 delta/工具进度）：

- `userMessage`
- `agentMessage`
- `plan`
- `reasoning`
- `commandExecution`
- `fileChange`
- `mcpToolCall`
- `collabToolCall`
- `webSearch`
- `imageView`
- `enteredReviewMode`
- `exitedReviewMode`
- `contextCompaction`（推荐；`compacted` 已标记 deprecated）

---

### 4) Item：增量/子事件（delta 等）

#### 4.1 agentMessage
- **`item/agentMessage/delta`**
  - **载荷要点**：同一 `itemId` 的 `delta` 需按序拼接。
  - **用途**：流式输出助手文本。

#### 4.2 plan
- **`item/plan/delta`**（实验性）
  - **用途**：plan 文本的流式增量（对应 `<proposed_plan>` 片段）。

#### 4.3 reasoning
- **`item/reasoning/summaryTextDelta`**：可读推理摘要的文本增量（按 `summaryIndex` 分组）。
- **`item/reasoning/summaryPartAdded`**：推理摘要分段边界（推进 `summaryIndex`）。
- **`item/reasoning/textDelta`**：原始推理文本增量（按 `contentIndex` 分组；常见于部分开源模型/不同后端）。

#### 4.4 commandExecution
- **`item/commandExecution/outputDelta`**
  - **用途**：命令 stdout/stderr 的流式输出片段；最终 `commandExecution` item 会带汇总字段（`exitCode`、`durationMs`、`commandActions`、`aggregatedOutput` 等）。

- **`item/commandExecution/terminalInteraction`**
  - **用途**：终端交互事件（例如向子进程写入 stdin）。若需要复现“交互式命令”的细节，可监听该事件并与 `outputDelta`/最终 item 结合渲染。

#### 4.5 fileChange
- **`item/fileChange/outputDelta`**
  - **用途**：底层 `apply_patch` 工具调用的响应流（用于 debug 或展示详细执行过程）。

---

### 5) 线程级 Realtime（独立于 ThreadItem 的通知流，实验性）

Realtime 通知不属于 `ThreadItem`，不会出现在 `thread/read` 等返回里（“纯传输/媒体流”）。

- **`thread/realtime/started`** — `{ threadId, sessionId }`
- **`thread/realtime/itemAdded`** — `{ threadId, item }`（非音频 item，`item` 以原始 JSON 转发）
- **`thread/realtime/outputAudio/delta`** — `{ threadId, audio }`（音频 chunk；字段 camelCase）
- **`thread/realtime/error`** — `{ threadId, message }`
- **`thread/realtime/closed`** — `{ threadId, reason }`

---

### 6) 其他独立通知

- **`fuzzyFileSearch/sessionUpdated`** — `{ sessionId, query, files }`（实验性）
- **`fuzzyFileSearch/sessionCompleted`** — `{ sessionId, query }`（实验性）
- **`windowsSandbox/setupCompleted`** — `{ mode, success, error }`
- **`windows/worldWritableWarning`** — `{ samplePaths, extraCount, failedScan }`（Windows：提示存在“全局可写目录”，沙箱无法可靠保护）
- **`mcpServer/oauthLogin/completed`** — OAuth 浏览器流程完成后的通知（与 `mcpServer/oauth/login` 配套）
- **`app/list/updated`** — app 列表更新通知（当可访问 apps 或目录 apps 加载完成并合并后）
- **`account/updated`** — 账号基础状态更新（例如 `authMode`、`planType`）
- **`account/rateLimits/updated`** — 账号限流/额度快照更新
- **`account/login/completed`** — 登录流程完成通知（新推荐）
- **`configWarning`** — 配置告警（例如配置解析失败/被忽略项等）
- **`deprecationNotice`** — 弃用提示（客户端/用户应迁移）
- **`error`** — turn 运行中途错误事件（可能早于 `turn/completed(status="failed")`）
- **`rawResponseItem/completed`** — 原始 Responses item 完成通知（**internal-only**；一般客户端可忽略）
- **`thread/compacted`** — 线程 compact 完成通知（**deprecated**：优先通过 `contextCompaction` item 渲染）

---

## v2：服务端请求（不是通知，但经常与通知一起处理）

严格来说以下属于 **server-initiated JSON-RPC request**（带 `id`，客户端需要回复），不是 notification；但它们与 turn/item UI 强耦合，客户端通常要在同一事件管线里处理：

- **`item/commandExecution/requestApproval`**：命令执行审批请求
- **`item/fileChange/requestApproval`**：文件改动审批请求
- **`item/tool/call`**：动态工具调用请求（实验性，需要 `initialize.capabilities.experimentalApi = true`）

以及对应的清理/收敛通知：

- **`serverRequest/resolved`** — `{ threadId, requestId }`
  - **含义**：上述“待处理请求”已被用户响应，或被 turn 生命周期（start/complete/interrupt）清理。

---

## legacy `codex/event/*` → v2 的对照整理（核心迁移指南）

> 说明：legacy 层的事件更“细碎”，v2 将大量细节统一收敛为 **item 生命周期 + item-specific delta**。因此有些 legacy 事件在 v2 不再有 1:1 的 method，而是体现在某个 item 的字段变化或增量通知中。

### 1) Turn 生命周期

- `codex/event/task_started` → **`turn/started`**
- `codex/event/task_complete` → **`turn/completed`**
- `codex/event/turn_aborted` → 通常用 **`turn/completed`（status="interrupted"）** 表达；客户端应以 `turn/completed` 作为“清理完成”的权威信号

### 2) 文本输出

- `codex/event/agent_message` → `item/started`（`item.type="agentMessage"`）+（可能直接在 item 内给完整 text）+ `item/completed`
- `codex/event/agent_message_delta` / `codex/event/agent_message_content_delta` → **`item/agentMessage/delta`**

### 3) 推理（reasoning）

- legacy 的 `agent_reasoning*` / `reasoning*_delta` / `agent_reasoning_section_break` → 归并到 `item.type="reasoning"`，对应：
  - **`item/reasoning/summaryTextDelta`**
  - **`item/reasoning/summaryPartAdded`**
  - **`item/reasoning/textDelta`**
  - 以及最终 `item/completed`

### 4) 命令执行（exec_command_* / terminal_interaction）

- `codex/event/exec_command_begin` → `item/started`（`item.type="commandExecution"`）
- `codex/event/exec_command_output_delta` → **`item/commandExecution/outputDelta`**
- `codex/event/exec_command_end` → `item/completed`（`commandExecution.status` + `exitCode` 等）
- `codex/event/terminal_interaction` → **`item/commandExecution/terminalInteraction`**

### 5) 文件改动/补丁

- legacy 的 `patch_apply_begin` / `patch_apply_end` / `turn_diff` → v2 推荐使用：
  - `item/started` / `item/completed`（`item.type="fileChange"`）
  - **`turn/diff/updated`**（聚合 diff 快照）
  - `item/fileChange/outputDelta`（底层 apply_patch 输出）

### 6) Web 搜索

- `codex/event/web_search_begin` / `codex/event/web_search_end` → `item/started` / `item/completed`（`item.type="webSearch"`）

### 7) MCP / 工具调用

- legacy 的 `mcp_*`、`dynamic_tool_call_*` → v2 推荐使用：
  - `item/started` / `item/completed`（`item.type="mcpToolCall"` 或 `dynamicToolCall`）
  - 动态工具仍需处理 server-initiated request：`item/tool/call`

### 8) 会话配置/弃用/错误等“系统事件”

- `codex/event/session_configured` → **v2 没有直接等价的通知 method**；通常由 thread/turn 的正常通知流覆盖。若客户端依赖它做一次性初始化，可迁移到：
  - `thread/started`（thread 建立完成）
  - 或首次 `turn/started`（开始产生事件流）

- `codex/event/error` → v2：可能以 `turn/completed`（status="failed" + error）终止，也可能在中途有独立的 **`error`** 事件（README 的 Errors 小节）。
- `codex/event/warning` / `codex/event/deprecation_notice` / `codex/event/stream_error` / `codex/event/shutdown_complete` / `codex/event/background_event`
  - v2 有些会体现在 `turn.status`/`error` 事件/系统通知中；具体实现建议以 README 的 Errors/Auth/其他章节为准。

---

## 客户端实现建议（面向 v2 的最小事件处理器）

1. 以 `turn/started` 创建 turn 容器；以 `turn/completed` 作为收尾/清理的权威信号。
2. 以 `item/started` 立即渲染一个“进行中的 item”；以 `item/completed` 覆盖为最终状态。
3. 对 delta 类通知按 `itemId` 聚合：
   - 文本：`item/agentMessage/delta`
   - 命令输出：`item/commandExecution/outputDelta`
   - 推理：`item/reasoning/*`
4. diff/UI 统一视图优先用 `turn/diff/updated`，不要自行拼接多个 `fileChange` 的 diff。
5. 审批与动态工具：把 server-initiated request（带 `id`）与 `serverRequest/resolved` 一起纳入同一条“turn 内交互”状态机。

