# Responses API 流式输出流程

本文档描述了 Codex 系统中 LLM 模型、Codex 实例和 App-Server 在 Responses API 流式输出中的分工和配合机制。

## 概述

Codex 使用 OpenAI Responses API 协议与 LLM 模型通信，支持流式输出。整个流程采用**逐块推送**的方式，不会集中收集后一次性发送，确保客户端能够实时看到模型的响应。

## 架构组件

### 1. LLM 模型（Provider）
- **角色**：流式数据的源头
- **协议**：OpenAI Responses API（SSE 格式）
- **输出**：通过 Server-Sent Events (SSE) 发送增量 delta 事件

### 2. Codex 实例（Core）
- **角色**：接收、解析和处理流式数据
- **位置**：`codex-rs/core/src/`
- **职责**：
  - 接收 SSE 流式事件
  - 解析和转换事件格式
  - 提取可见文本
  - 立即发送事件到 app-server

### 3. App-Server
- **角色**：事件转发和协议转换
- **位置**：`codex-rs/app-server/src/`
- **职责**：
  - 接收 Codex 事件
  - 转换为 JSON-RPC 通知
  - 立即写入到客户端（stdout/websocket）

## 流式处理流程

### 阶段 1: LLM 模型发送流式数据

模型通过 SSE 发送增量事件：

```
event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"你","item_id":"msg_...","content_index":0}

event: response.output_text.delta
data: {"type":"response.output_text.delta","delta":"好","item_id":"msg_...","content_index":0}
```

**关键事件类型**：
- `response.output_text.delta` - 助手消息的文本增量
- `response.reasoning_summary_text.delta` - 推理摘要的文本增量
- `response.reasoning_text.delta` - 原始推理文本增量

### 阶段 2: Codex 接收和解析

#### 2.1 SSE 事件接收

位置：`codex-rs/codex-api/src/sse/responses.rs`

```rust
pub fn process_responses_event(
    event: ResponsesStreamEvent,
) -> Result<Option<ResponseEvent>, ResponsesEventError> {
    match event.kind.as_str() {
        "response.output_text.delta" => {
            if let Some(delta) = event.delta {
                return Ok(Some(ResponseEvent::OutputTextDelta {
                    delta,
                    item_id: event.item_id.clone(),
                }));
            }
        }
        // ... 其他事件类型
    }
}
```

#### 2.2 流式事件处理

位置：`codex-rs/core/src/codex.rs`

当收到 `ResponseEvent::OutputTextDelta` 时：

1. **立即解析文本**：
   ```rust
   let parsed = assistant_message_stream_parsers.parse_delta(&item_id, &delta);
   ```

2. **提取可见文本**：
   - 使用 `AssistantTextStreamParser` 解析
   - 提取 `visible_text`（去除引用、计划标记等）
   - 处理前导空白字符

3. **立即发送事件**：
   ```rust
   let event = AgentMessageContentDeltaEvent {
       thread_id: sess.conversation_id.to_string(),
       turn_id: turn_context.sub_id.clone(),
       item_id: item_id.to_string(),
       delta: parsed.visible_text,
   };
   sess.send_event(turn_context, EventMsg::AgentMessageContentDelta(event))
       .await;
   ```

**关键点**：
- ✅ **立即处理**：每个 delta 到达后立即处理，不等待
- ✅ **异步发送**：通过 `tx_event.send(event).await` 发送到 channel
- ✅ **无缓冲**：不会收集多个 delta 后批量发送

### 阶段 3: Codex 事件发送到 App-Server

位置：`codex-rs/core/src/codex.rs`

```rust
pub(crate) async fn send_event_raw(&self, event: Event) {
    // 记录状态
    if let Some(status) = agent_status_from_event(&event.msg) {
        self.agent_status.send_replace(status);
    }
    // 持久化到 rollout 文件
    let rollout_items = vec![RolloutItem::EventMsg(event.msg.clone())];
    self.persist_rollout_items(&rollout_items).await;
    // 立即发送到 channel
    if let Err(e) = self.tx_event.send(event).await {
        debug!("dropping event because channel is closed: {e}");
    }
}
```

**机制**：
- 使用异步 channel (`mpsc::channel`) 通信
- 事件立即放入 channel，不阻塞
- App-server 从 channel 另一端接收

### 阶段 4: App-Server 接收和转换

位置：`codex-rs/app-server/src/bespoke_event_handling.rs`

#### 4.1 事件监听

App-server 持续监听 Codex 事件：

```rust
match msg {
    EventMsg::AgentMessageContentDelta(event) => {
        let notification = AgentMessageDeltaNotification {
            thread_id: conversation_id.to_string(),
            turn_id: event_turn_id.clone(),
            item_id: event.item_id,
            delta: event.delta,
        };
        outgoing
            .send_server_notification(ServerNotification::AgentMessageDelta(notification))
            .await;
    }
    // ... 其他事件类型
}
```

#### 4.2 协议转换

将内部事件转换为 JSON-RPC 通知：

- **内部格式**：`EventMsg::AgentMessageContentDelta`
- **JSON-RPC 格式**：`{"method": "item/agentMessage/delta", "params": {...}}`

位置：`codex-rs/app-server-protocol/src/protocol/common.rs`

```rust
server_notification_definitions! {
    AgentMessageDelta => "item/agentMessage/delta" (v2::AgentMessageDeltaNotification),
    // ...
}
```

### 阶段 5: App-Server 写入客户端

位置：`codex-rs/app-server/src/transport.rs`

#### 5.1 Writer Task

独立的 writer task 从 channel 接收消息并立即写入：

```rust
tokio::spawn(async move {
    let mut stdout = io::stdout();
    while let Some(outgoing_message) = writer_rx.recv().await {
        let Some(mut json) = serialize_outgoing_message(outgoing_message) else {
            continue;
        };
        json.push('\n');
        if let Err(err) = stdout.write_all(json.as_bytes()).await {
            error!("Failed to write to stdout: {err}");
            break;
        }
    }
});
```

#### 5.2 输出格式

客户端收到的 JSON-RPC 通知：

```json
{"method": "item/agentMessage/delta", "params": {"threadId": "...", "turnId": "...", "itemId": "...", "delta": "你"}}
{"method": "item/agentMessage/delta", "params": {"threadId": "...", "turnId": "...", "itemId": "...", "delta": "好"}}
```

## 数据流向图

```
┌─────────────┐
│  LLM Model  │
│  (Provider) │
└──────┬──────┘
       │ SSE Stream
       │ response.output_text.delta
       ▼
┌─────────────────┐
│  Codex Client   │
│  (codex-api)    │
│  - 接收 SSE     │
│  - 解析事件     │
└──────┬──────────┘
       │ ResponseEvent::OutputTextDelta
       ▼
┌─────────────────┐
│  Codex Core     │
│  (codex.rs)     │
│  - 解析文本     │
│  - 提取可见文本 │
│  - 发送事件     │
└──────┬──────────┘
       │ EventMsg::AgentMessageContentDelta
       │ (通过 async channel)
       ▼
┌─────────────────┐
│  App-Server     │
│  (bespoke_*)    │
│  - 接收事件     │
│  - 转换协议     │
└──────┬──────────┘
       │ ServerNotification::AgentMessageDelta
       │ (通过 async channel)
       ▼
┌─────────────────┐
│  Writer Task    │
│  (transport.rs) │
│  - 序列化 JSON  │
│  - 写入 stdout  │
└──────┬──────────┘
       │ JSON-RPC Notification
       ▼
┌─────────────┐
│   Client    │
│  (终端/IDE) │
└─────────────┘
```

## 关键特性

### 1. 真正的流式处理

- ✅ **逐块推送**：每个 delta 立即处理并转发
- ✅ **无缓冲收集**：不会等待多个 delta 后批量发送
- ✅ **低延迟**：从模型到客户端的延迟最小化

### 2. 异步非阻塞

- 使用 Rust 的 `async/await` 和 `tokio::mpsc::channel`
- 各组件通过异步 channel 通信
- 不会因为某个组件处理慢而阻塞整个流程

### 3. 错误处理

- Channel 关闭时优雅降级
- 解析失败时记录日志但不中断流
- 连接断开时清理资源

## 配置要求

### Provider 配置

在 `config.toml` 中配置 provider：

```toml
[model_providers.volcengine]
name = "火山引擎 Doubao"
base_url = "https://ark.cn-beijing.volces.com/api/v3"
env_key = "VOLC_API_KEY"
wire_api = "responses"
requires_openai_auth = false
```

### 请求构建

Codex 自动设置 `stream: true`：

位置：`codex-rs/core/src/client.rs`

```rust
let request = ResponsesApiRequest {
    model: model_info.slug.clone(),
    instructions: instructions.clone(),
    input,
    tools,
    tool_choice: "auto".to_string(),
    parallel_tool_calls: prompt.parallel_tool_calls,
    reasoning,
    store: provider.is_azure_responses_endpoint(),
    stream: true,  // 固定为 true
    include,
    prompt_cache_key,
    text,
};
```

## 支持的事件类型

### 1. `response.output_text.delta`

**模型发送**：
```json
{"type":"response.output_text.delta","delta":"文本","item_id":"msg_..."}
```

**Codex 处理**：
- 解析为 `ResponseEvent::OutputTextDelta`
- 提取可见文本
- 发送 `EventMsg::AgentMessageContentDelta`

**客户端接收**：
```json
{"method":"item/agentMessage/delta","params":{"delta":"文本",...}}
```

### 2. `response.reasoning_summary_text.delta`

**模型发送**：
```json
{"type":"response.reasoning_summary_text.delta","delta":"摘要","summary_index":0}
```

**Codex 处理**：
- 解析为 `ResponseEvent::ReasoningSummaryDelta`
- 发送 `EventMsg::ReasoningContentDelta`

**客户端接收**：
```json
{"method":"item/reasoning/summaryTextDelta","params":{"delta":"摘要",...}}
```

### 3. `response.reasoning_text.delta`

**模型发送**：
```json
{"type":"response.reasoning_text.delta","delta":"推理","content_index":0}
```

**Codex 处理**：
- 解析为 `ResponseEvent::ReasoningContentDelta`
- 发送 `EventMsg::ReasoningRawContentDelta`

**客户端接收**：
```json
{"method":"item/reasoning/textDelta","params":{"delta":"推理",...}}
```

## 调试和监控

### 启用调试日志

```bash
# 查看 API 请求和响应
RUST_LOG=codex_api=debug,codex_core::client=debug codex ...

# 查看 SSE 事件解析
RUST_LOG=codex_api::sse=debug codex ...

# 查看事件发送
RUST_LOG=codex_core=debug codex ...

# 最详细的日志
RUST_LOG=trace codex ...
```

### 日志位置

- **TUI 模式**：`~/.codex/log/codex-tui.log`
- **实时查看**：`tail -F ~/.codex/log/codex-tui.log`

### 关键日志点

1. **SSE 事件接收**：`trace!("SSE event: {}", &sse.data)`
2. **事件解析**：`debug!("failed to parse ResponseItem")`
3. **Delta 发送**：`sess.send_event()` 调用
4. **通知发送**：`outgoing.send_server_notification()` 调用

## 常见问题

### Q: 为什么没有收到 `item/agentMessage/delta` 消息？

**可能原因**：
1. **请求被拒绝**：检查日志中的 HTTP 状态码（如 400 Bad Request）
2. **模型不支持流式**：某些模型可能不发送增量 delta
3. **文本为空**：`visible_text` 为空时不会发送事件
4. **解析失败**：SSE 事件格式不匹配

**排查步骤**：
1. 启用调试日志查看实际请求和响应
2. 检查模型 API 文档确认流式支持
3. 验证 SSE 事件格式是否兼容

### Q: Delta 是否会被缓冲？

**答案**：不会。每个 delta 都会立即处理并转发，唯一的"缓冲"是异步 channel 的容量限制（用于背压控制）。

### Q: 如何确保流式输出正常工作？

**检查清单**：
- ✅ Provider 配置正确（`wire_api = "responses"`）
- ✅ `stream: true` 在请求中（自动设置）
- ✅ 模型支持流式输出
- ✅ SSE 事件格式兼容
- ✅ 网络连接稳定

## 相关代码位置

### 核心处理逻辑

- **SSE 事件解析**：`codex-rs/codex-api/src/sse/responses.rs`
- **流式事件处理**：`codex-rs/core/src/codex.rs` (约 6354-6400 行)
- **文本解析**：`codex-rs/core/src/codex.rs` (约 5911-5943 行)
- **事件发送**：`codex-rs/core/src/codex.rs` (约 2356-2367 行)

### App-Server 处理

- **事件转换**：`codex-rs/app-server/src/bespoke_event_handling.rs` (约 927-939 行)
- **协议定义**：`codex-rs/app-server-protocol/src/protocol/common.rs`
- **输出写入**：`codex-rs/app-server/src/transport.rs` (约 254-267 行)

### 请求构建

- **请求结构**：`codex-rs/codex-api/src/common.rs` (约 155-172 行)
- **请求构建**：`codex-rs/core/src/client.rs` (约 516-579 行)
- **URL 构建**：`codex-rs/codex-api/src/provider.rs` (约 53-75 行)

## 总结

Codex 的流式输出机制采用**真正的流式处理**，从模型到客户端的每个环节都是逐块推送，确保：

1. **低延迟**：客户端能够实时看到模型响应
2. **高效**：不需要等待完整响应即可开始显示
3. **可靠**：异步非阻塞设计，不会因为某个环节慢而阻塞整体

整个流程通过异步 channel 连接，各组件独立运行，实现了高效的流式数据处理。
