---
marp: true
theme: default
paginate: true
backgroundColor: #fff
backgroundImage: url('https://marp.app/assets/hero-background.svg')
style: |
  section {
    font-size: 28px;
  }
  h1 {
    color: #2563eb;
  }
  h2 {
    color: #3b82f6;
  }
  code {
    background: #f1f5f9;
    padding: 2px 6px;
    border-radius: 4px;
  }
  pre {
    background: #1e293b;
    color: #e2e8f0;
    padding: 16px;
    border-radius: 8px;
  }
  table {
    font-size: 24px;
  }
---

<!-- _class: lead -->

# **App-Server 架构深度解析**

## Codex-RS 项目的协议适配层

**深入理解设计理念与实现细节**

---

# 目录

1. 📝 概述与背景
2. 🏗️ 整体架构设计
3. 💡 核心概念模型
4. 🔄 主要执行流程
5. 📨 消息处理机制

---

<!-- _class: lead -->

# 第 1 章
## 📝 概述与背景

---

# 1.1 什么是 App-Server？

**App-Server** 是 Codex-RS 项目中的协议适配层，负责：

- 🔌 连接 VS Code Extension 和 Codex Core
- 📡 实现 JSON-RPC 2.0 over stdio 通信协议
- 🔄 转换协议层类型与 Core 层类型
- 📤 管理事件流和实时推送

**定位**：不包含业务逻辑，专注于协议适配和消息路由

---

# 1.2 为什么需要 App-Server？

```
┌─────────────────────────────────────────────┐
│  VS Code Extension (TypeScript/JavaScript) │
│  - 用户界面                                 │
│  - 交互逻辑                                 │
└─────────────────────────────────────────────┘
                    ↕
         需要一个"翻译官"
                    ↕
┌─────────────────────────────────────────────┐
│  App-Server (Rust)                          │
│  - 协议转换                                 │
│  - 进程隔离                                 │
└─────────────────────────────────────────────┘
                    ↕
┌─────────────────────────────────────────────┐
│  Codex Core (Rust)                          │
│  - 业务逻辑                                 │
│  - Agent 循环                               │
└─────────────────────────────────────────────┘
```

---

# 1.3 关键特性

| 特性 | 说明 | 优势 |
|-----|------|------|
| **进程隔离** | 独立进程运行 | 崩溃不影响 VS Code |
| **类型安全** | Rust 类型系统 | 编译时捕获错误 |
| **异步架构** | Tokio 运行时 | 高并发、低延迟 |
| **事件驱动** | 实时事件流 | 流式响应体验 |
| **标准协议** | JSON-RPC 2.0 | 工具链完善 |

---

<!-- _class: lead -->

# 第 2 章
## 🏗️ 整体架构设计

---

# 2.1 完整架构图

```
┌─────────────────────────────────────────────────┐
│         VS Code Extension (客户端)              │
│         - 前端 UI                                │
│         - 用户交互                               │
└─────────────────────────────────────────────────┘
                    ↕ JSON-RPC over stdio
┌─────────────────────────────────────────────────┐
│         App-Server (协议适配层) ← 我们在这里    │
│         - 协议解析                               │
│         - 类型转换                               │
│         - 事件管理                               │
└─────────────────────────────────────────────────┘
                    ↕ Rust API 调用
┌─────────────────────────────────────────────────┐
│         Codex Core (业务逻辑层)                 │
│         - ConversationManager                   │
│         - Codex (Agent 状态机)                  │
│         - ModelClient                           │
└─────────────────────────────────────────────────┘
                    ↕ HTTP/SSE
┌─────────────────────────────────────────────────┐
│         Backend API (LLM 服务)                  │
│         - OpenAI / Claude / 其他模型            │
└─────────────────────────────────────────────────┘
```

---

# 2.2 通信方式：为什么选择 stdin/stdout？

| 方案 | 优点 | 缺点 | 适用场景 |
|-----|------|------|---------|
| **stdin/stdout** | 简单、跨平台、进程隔离 | 只能本地通信 | ✅ IDE 插件 |
| HTTP/WebSocket | 网络通信、浏览器友好 | 需要端口管理 | Web 应用 |
| gRPC | 高性能、类型安全 | 需要 protobuf | 微服务 |
| Unix Socket | 高性能、本地通信 | Windows 不友好 | 本地服务 |

**选择理由**：
- ✅ 零配置（无需端口、无需网络）
- ✅ 天然权限控制
- ✅ 调试友好

---

# 2.3 协议选择：为什么是 JSON-RPC 2.0？

**JSON-RPC 2.0 的关键特性**：

```json
// Request（客户端 → 服务端）
{"id": 1, "method": "thread/start", "params": {...}}

// Response（服务端 → 客户端）
{"id": 1, "result": {"thread_id": "abc123"}}

// Notification（单向通知，无需响应）
{"method": "turn/started", "params": {...}}

// Error（错误响应）
{"id": 1, "error": {"code": -32600, "message": "Invalid request"}}
```

**优势**：标准化、双向通信、人类可读、工具支持好

---

# 2.4 App-Server 内部架构

```
┌──────────────────────────────────────────────────────┐
│                   App-Server 进程                     │
├──────────────────────────────────────────────────────┤
│                                                       │
│  📥 Task 1: stdin_reader                             │
│     - 读取 stdin                                     │
│     - 解析 JSON-RPC                                  │
│          ↓ [incoming channel]                        │
│                                                       │
│  ⚙️ Task 2: message_processor                        │
│     - 分发请求                                       │
│     - 调用 Core API                                  │
│     - 管理会话                                       │
│          ↓ [outgoing channel]                        │
│                                                       │
│  📤 Task 3: stdout_writer                            │
│     - 序列化 JSON                                    │
│     - 写入 stdout                                    │
│                                                       │
└──────────────────────────────────────────────────────┘
```

---

# 2.5 三任务流水线架构

**核心设计思想**：通过 **MPSC 通道** 连接三个异步任务

```rust
// 创建通道
let (incoming_tx, incoming_rx) = mpsc::channel(128);
let (outgoing_tx, outgoing_rx) = mpsc::channel(128);

// 启动三个任务
tokio::spawn(stdin_reader);     // 读取 stdin → incoming_tx
tokio::spawn(message_processor); // incoming_rx → 处理 → outgoing_tx
tokio::spawn(stdout_writer);     // outgoing_rx → 写入 stdout
```

**优势**：
- ✅ 解耦：每个任务职责单一
- ✅ 非阻塞：I/O 操作互不影响
- ✅ 背压：自动流量控制
- ✅ 优雅关闭：通道生命周期协调

---

# 2.6 核心组件

| 组件 | 文件 | 职责 |
|-----|------|------|
| **MessageProcessor** | `message_processor.rs` | 顶层路由，处理初始化和配置 |
| **CodexMessageProcessor** | `codex_message_processor.rs` | 业务处理，调用 Core API |
| **OutgoingMessageSender** | `outgoing_message.rs` | 消息发送封装 |
| **ConfigApi** | `config_api.rs` | 配置读写 |

---

<!-- _class: lead -->

# 第 3 章
## 💡 核心概念模型

---

# 3.1 Thread（会话/线程）

**定义**：用户与 Codex Agent 之间的长期对话

```
Thread
├── 唯一标识：thread_id (如 "abc123")
├── 配置：model, cwd, approval_policy
├── 历史：所有 Turn 的记录
└── 状态：active / archived
```

**类比**：微信聊天窗口
- 一个 Thread = 一个聊天窗口
- 可以暂停后恢复
- 保留完整历史记录

---

# 3.2 Turn（对话轮次）

**定义**：一次完整的交互（用户输入 → Agent 响应）

```
Turn
├── 唯一标识：turn_id (如 "turn-001")
├── 输入：UserInput (文本、图片、文件等)
├── 输出：多个 Item (消息、工具调用、推理等)
└── 状态：running / completed / error
```

**类比**：一次对话
- 用户："帮我写个快速排序"
- Agent："好的，我来写...【代码】...完成了！"

**一个 Turn = 一个完整的问答**

---

# 3.3 Item（元素）

**定义**：Turn 中的最小粒度单元

| Item 类型 | 说明 | 示例 |
|----------|------|------|
| **UserMessage** | 用户消息 | "帮我写个快速排序" |
| **AgentMessage** | Agent 回复 | "好的，我来写..." |
| **ToolCall** | 工具调用 | `read_file("sort.py")` |
| **Reasoning** | 内部推理 | "我需要先了解需求..." |
| **FileEdit** | 文件编辑 | 创建 `quicksort.py` |

**类比**：对话中的每一个"动作"

---

# 3.4 层次关系

```
Thread "帮我优化代码"
│
├── Turn 1 (turn-001)
│   ├── Item 1: UserMessage "帮我分析这段代码"
│   ├── Item 2: ToolCall read_file("code.py")
│   ├── Item 3: Reasoning "这段代码有性能问题..."
│   └── Item 4: AgentMessage "我发现了以下问题..."
│
├── Turn 2 (turn-002)
│   ├── Item 1: UserMessage "如何优化？"
│   ├── Item 2: Reasoning "可以用缓存..."
│   ├── Item 3: FileEdit 修改 code.py
│   └── Item 4: AgentMessage "已优化完成"
│
└── Turn 3 (turn-003)
    └── ...
```

---

# 3.5 Task vs Turn（重要区分）

| 概念 | 层次 | 用户可见 | 说明 |
|-----|------|---------|------|
| **Turn** | 用户视角 | ✅ 可见 | 一次完整的问答 |
| **Task** | Core 内部 | ❌ 不可见 | 执行 Turn 的内部单元 |

**关系**：
- **1 Turn = 1 Task**（通常情况）
- Task 内部可能包含**多次 run_turn**（Agent 循环）

```
用户发起 Turn
    ↓
Core 创建 Task
    ↓
run_turn #1: 调用 LLM → 需要工具调用
    ↓
执行工具
    ↓
run_turn #2: 再次调用 LLM → 返回最终答案
    ↓
Turn 完成
```

---

# 3.6 Op（操作）与 Event（事件）

**CQRS 模式**：命令与查询分离

### Op（Command）：修改状态

```rust
// App-Server → Core
conversation.submit(Op::UserInput { items: [...] })
conversation.submit(Op::Interrupt)
conversation.submit(Op::OverrideTurnContext { ... })
```

### Event（Query）：读取状态

```rust
// Core → App-Server
let event = conversation.next_event().await;
// TurnStarted, ItemStarted, AgentMessageDelta, ...
```

**单向数据流**，易于理解和调试

---

<!-- _class: lead -->

# 第 4 章
## 🔄 主要执行流程

---

# 4.1 完整流程概览

```
用户在 VS Code 中输入
    ↓
VS Code Extension 发送 JSON-RPC 请求
    ↓
App-Server stdin_reader 接收
    ↓
解析 → incoming 通道
    ↓
MessageProcessor 分发
    ↓
CodexMessageProcessor 处理
    ↓
调用 Core API (ConversationManager)
    ↓
Core 执行 Agent 循环 (run_task)
    ↓
生成事件 → 事件监听器
    ↓
outgoing 通道
    ↓
stdout_writer 写入
    ↓
VS Code Extension 接收响应/通知
    ↓
更新 UI
```

---

# 4.2 场景 1：创建新会话

### 步骤详解

**1. 客户端发起请求**
```json
{"id": 1, "method": "thread/start", "params": {
  "model": "claude-sonnet-4",
  "cwd": "/workspace"
}}
```

**2. stdin_reader 接收并解析**
```rust
let msg = serde_json::from_str(&line)?;
incoming_tx.send(msg).await;
```

---

# 4.2 场景 1：创建新会话（续）

**3. MessageProcessor 路由**
```rust
match request {
    ClientRequest::ThreadStart { request_id, params } => {
        self.codex_message_processor.thread_start(request_id, params).await;
    }
}
```

**4. CodexMessageProcessor 处理**
```rust
async fn thread_start(...) {
    // 1. 构建配置
    let config = build_config(params);
    
    // 2. 调用 Core API
    let conversation = conversation_manager.new_conversation(config).await;
    
    // 3. 自动附加事件监听器
    self.attach_conversation_listener(conversation_id).await;
    
    // 4. 返回响应
    self.outgoing.send_response(ThreadStartResponse { thread_id }).await;
}
```

---

# 4.2 场景 1：创建新会话（续）

**5. 自动附加事件监听器**
```rust
async fn attach_conversation_listener(...) {
    let outgoing = self.outgoing.clone();  // 克隆发送端
    
    tokio::spawn(async move {
        loop {
            // 监听 Core 事件
            let event = conversation.next_event().await?;
            
            // 转换并发送通知
            let notification = convert_event(event);
            outgoing.send_notification(notification).await;
        }
    });
}
```

**关键**：每个会话都有独立的监听器任务，并发监听多个会话的事件

---

# 4.3 场景 2：发送消息

### 时间线

| 时间 | App-Server | Codex Core |
|-----|-----------|-----------|
| t0 | 收到 `turn/start` 请求 | - |
| t1 | 调用 `conversation.submit()` | 启动 `run_task` |
| t2 | **立即返回** `turn_id` | run_turn #1: 调用 LLM |
| t3 | 继续处理下一个请求 | (等待 LLM 响应) |
| t4 | - | LLM 返回：需要工具调用 |
| t5 | - | 执行工具调用 |
| t6 | - | run_turn #2: 再次调用 LLM |
| t7 | - | LLM 返回：最终答案 |
| t8 | - | Task 完成 |

**关键**：App-Server 提交请求后**不等待**，Core 异步执行

---

# 4.4 Agent 循环（ReAct 模式）

```
run_task() {
    loop {
        // 1. 调用 LLM (run_turn)
        result = run_turn().await;
        
        match result {
            ToolCalls(calls) => {
                // 2. 执行工具调用
                execute_tools(calls).await;
                // 3. 继续下一轮
                continue;
            }
            Completed => {
                // 4. 任务完成
                break;
            }
        }
    }
}
```

**ReAct** = **Re**asoning + **Act**ing
- Reasoning：LLM 推理
- Acting：工具调用
- 循环直到任务完成

---

# 4.5 事件流示例

用户输入："帮我写个快速排序"

```
→ Event: TurnStarted { turn_id: "turn-001" }
→ Event: ItemStarted { type: "agentMessage" }
→ Event: AgentMessageDelta { delta: "好" }
→ Event: AgentMessageDelta { delta: "的" }
→ Event: AgentMessageDelta { delta: "，" }
→ Event: AgentMessageDelta { delta: "我" }
→ Event: AgentMessageDelta { delta: "来" }
→ Event: AgentMessageDelta { delta: "写" }
→ Event: AgentMessageDelta { delta: "..." }
→ Event: ItemCompleted
→ Event: ItemStarted { type: "toolCall", tool: "write_file" }
→ Event: ToolCallCompleted
→ Event: TurnCompleted { status: "completed" }
```

**流式推送**，实时更新 UI

---

# 4.6 并发处理多个会话

```
用户同时有 3 个会话在运行：

会话 A (thread-A):
├─ Turn 1 正在执行
└─ 监听器持有 outgoing_tx_2

会话 B (thread-B):
├─ Turn 2 正在执行
└─ 监听器持有 outgoing_tx_3

会话 C (thread-C):
├─ Turn 3 正在执行
└─ 监听器持有 outgoing_tx_4

所有监听器同时往 outgoing 通道发送事件
    ↓
stdout_writer 按到达顺序写入 stdout
    ↓
客户端根据 thread_id 路由到正确的 UI
```

**MPSC 通道保证消息完整性，thread_id 保证消息路由正确**

---

<!-- _class: lead -->

# 第 6 章
## 📨 消息处理机制

---

# 6.1 四种 JSON-RPC 消息类型

```
┌────────────────────────────────────────────────┐
│            Client (VS Code Extension)          │
└────────────────────────────────────────────────┘
         ↓ Request                ↑ Response
         ↓ Notification           ↑ Notification
┌────────────────────────────────────────────────┐
│            Server (App-Server)                 │
└────────────────────────────────────────────────┘
```

| 类型 | 方向 | 有 `id` | 需要响应 |
|-----|------|---------|---------|
| **Request** | Client → Server | ✅ | ✅ |
| **Response** | Server → Client | ✅ | ❌ |
| **Notification** | 双向 | ❌ | ❌ |
| **Error** | Server → Client | ✅ | ❌ |

---

# 6.2 Request/Response 流程

```
Client                   App-Server
  │                          │
  │ {"id": 1, "method":      │
  │  "thread/start"}         │
  ├─────────────────────────>│
  │                          │ parse & validate
  │                          │ route to handler
  │                          │ call Core API
  │                          │
  │ {"id": 1, "result":      │
  │  {"thread_id": "abc"}}   │
  │<─────────────────────────┤
  │                          │
```

**关键**：通过 `id` 字段配对请求和响应

---

# 6.3 Notification（通知）流程

**特点**：
- ❌ 没有 `id` 字段
- ❌ 不需要响应
- ✅ 用于实时推送

**示例**：
```json
// App-Server 推送事件
{"method": "turn/started", "params": {"turn_id": "turn-001"}}
{"method": "item/agentMessage/delta", "params": {"delta": "你好"}}
{"method": "turn/completed", "params": {"status": "completed"}}
```

**用途**：
- 流式文本推送（Delta）
- 状态变更通知
- 工具调用进度

---

# 6.4 消息路由机制

```
incoming_rx.recv()
    ↓
JSONRPCMessage
    ├─ Request → MessageProcessor::process_request()
    │   ├─ Initialize → 处理初始化
    │   ├─ Config* → ConfigApi
    │   └─ 其他 → CodexMessageProcessor
    │       ├─ ThreadStart → thread_start()
    │       ├─ TurnStart → turn_start()
    │       ├─ LoginApiKey → login_api_key()
    │       └─ ...
    │
    ├─ Response → MessageProcessor::process_response()
    │   └─ 通过 id 找到回调
    │
    ├─ Notification → MessageProcessor::process_notification()
    │   └─ 记录日志（暂无实际处理）
    │
    └─ Error → MessageProcessor::process_error()
        └─ 记录错误日志
```

---

# 6.5 事件流监听机制

### 谁在监听？

**会话监听器任务**（`conversation_listener_task`）

### 何时启动？

创建会话时（`thread/start`）自动启动

### 做什么？

```rust
tokio::spawn(async move {
    loop {
        // 1. 从 Core 获取事件
        let event = conversation.next_event().await?;
        
        // 2. 转换为协议层通知
        let notification = convert_event_to_notification(event);
        
        // 3. 发送到 outgoing 通道
        outgoing_tx.send_notification(notification).await;
    }
});
```

---

# 6.6 多会话并发处理

```
message_processor (主任务)
    ├─ 持有 outgoing_tx_1
    │
    ├─ 会话 A 监听器 (子任务)
    │   └─ 持有 outgoing_tx_2 = outgoing_tx_1.clone()
    │
    ├─ 会话 B 监听器 (子任务)
    │   └─ 持有 outgoing_tx_3 = outgoing_tx_1.clone()
    │
    └─ 会话 C 监听器 (子任务)
        └─ 持有 outgoing_tx_4 = outgoing_tx_1.clone()

所有任务并发往 outgoing 通道发送
    ↓
MPSC 通道保证消息完整性
    ↓
客户端根据 thread_id 路由消息
```

**关键**：MPSC（Multi-Producer, Single-Consumer）通道的价值

---

# 6.7 背压机制

```
Client 疯狂发送请求
    ↓
stdin_reader 快速读取
    ↓
incoming 通道（容量 128）
    ↓ (通道满了！)
stdin_reader.send() 阻塞
    ↓
stdin 缓冲区满
    ↓
Client 感知到延迟，停止发送
```

**自动流量控制，防止内存溢出**

---

# 6.8 优雅关闭流程

```
1. stdin 到达 EOF (用户关闭 VS Code)
    ↓
2. stdin_reader 任务退出
    ↓ (dropping incoming_tx)
3. incoming_rx 通道关闭
    ↓
4. message_processor 任务退出
    ↓ (dropping 所有 outgoing_tx)
5. outgoing_rx 通道关闭
    ↓
6. stdout_writer 任务退出
    ↓
7. 程序优雅退出 ✅
```

**无需手动信号，通道生命周期自动协调**

---

# 6.9 错误处理

### 标准错误码

| 错误码 | 含义 | 常见原因 |
|--------|------|---------|
| `-32600` | Invalid Request | 请求格式错误 |
| `-32601` | Method Not Found | API 不存在 |
| `-32602` | Invalid Params | 参数类型错误 |
| `-32603` | Internal Error | 服务端内部错误 |

### 错误响应示例

```json
{
  "id": 1,
  "error": {
    "code": -32600,
    "message": "Not initialized",
    "data": null
  }
}
```

---

<!-- _class: lead -->

# 总结

---

# 核心要点回顾

### 1. 分层架构
✅ **Extension → App-Server → Core → Backend**
✅ 职责分离，易于维护和扩展

### 2. 三任务流水线
✅ **stdin_reader → message_processor → stdout_writer**
✅ 通过 MPSC 通道连接，非阻塞、自动背压

### 3. 核心概念
✅ **Thread（会话）→ Turn（轮次）→ Item（元素）**
✅ 清晰的抽象层次，易于理解

---

# 核心要点回顾（续）

### 4. Agent 循环
✅ **ReAct 模式**：Reasoning + Acting
✅ run_task 内部多次 run_turn，直到任务完成

### 5. 事件驱动
✅ **CQRS 模式**：Op（命令）与 Event（查询）分离
✅ 实时事件流，流式推送体验

### 6. 消息处理
✅ **JSON-RPC 2.0**：标准化、双向通信
✅ MPSC 通道保证并发安全

---

# 设计亮点

| 设计 | 价值 |
|-----|------|
| **进程隔离** | 崩溃不影响 VS Code |
| **类型安全** | 编译时捕获错误 |
| **异步架构** | 高并发、低延迟 |
| **事件驱动** | 实时响应体验 |
| **通道通信** | 无锁、线程安全 |
| **优雅关闭** | 自动协调生命周期 |

---

# 适用场景

**这种架构适合**：

- ✅ IDE/编辑器插件开发（LSP、DAP）
- ✅ 命令行工具（CLI、REPL）
- ✅ 微服务架构（事件驱动）
- ✅ Agent 系统开发（AI Agent）
- ✅ 实时通信系统（流式处理）

**核心价值**：**简单而不简陋，安全而不牺牲性能**

---

<!-- _class: lead -->

# Q&A

## 欢迎提问！

**GitHub**: [codex-rs](https://github.com/cursor/codex)
**文档**: 完整分析文档请参考 `app-server-analysis.md`

---

<!-- _class: lead -->

# 谢谢！

**App-Server 是一个优秀的协议适配层实现**

展示了如何用 Rust 构建：
- 🎯 高性能、类型安全的服务
- 🔄 清晰的分层架构
- 🚀 优雅的异步编程
- 📡 稳定的进程间通信

**值得深入研究的优秀开源项目！** 🎉
