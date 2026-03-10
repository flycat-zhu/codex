# Codex Core 核心概念与实现

> 本文档旨在梳理 Codex 系统的核心概念和架构设计，聚焦于"为什么这样设计"和"组件如何协作"，而非具体实现细节。

---

## 目录

1. [系统架构概览](#1-系统架构概览)
2. [核心数据结构](#2-核心数据结构)
3. [核心工作流程](#3-核心工作流程)
4. [关键机制](#4-关键机制)
5. [扩展机制](#5-扩展机制)
6. [关键文件位置与作用](#6-关键文件位置与作用)
7. [最佳实践与设计模式](#7-最佳实践与设计模式)

---

## 1. 系统架构概览

### 1.1 Codex 的定位

Codex 是一个 AI 代理系统的核心引擎，作为**高层接口**，采用**队列对模型**：
- 用户通过队列提交操作（Operations）
- 系统通过队列返回事件（Events）

### 1.2 核心组件关系

```
┌─────────────────────────────────────────────────┐
│                    Codex                        │  ← 用户接口层
│  (tx_sub: 提交通道, rx_event: 事件通道)         │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│                   Session                       │  ← 会话管理层
│  ├─ SessionState (可变状态)                     │
│  ├─ SessionServices (共享服务)                  │
│  └─ active_turn (当前任务)                      │
└────────────────┬────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────┐
│                TurnContext                      │  ← 单轮上下文
│  (模型客户端、工具配置、策略设置)                │
└─────────────────────────────────────────────────┘
                 │
                 ▼
         ┌──────┴──────┐
         │   run_task   │  ← 任务执行
         └──────┬───────┘
                │
         ┌──────┴──────┐
         │   run_turn   │  ← 单轮执行
         └──────────────┘
```

---

## 2. 核心数据结构

### 2.1 Codex - 对外接口层

**核心职责：** 作为用户与系统交互的唯一入口

```rust
pub struct Codex {
    next_id: AtomicU64,           // 提交ID生成器
    tx_sub: Sender<Submission>,   // 提交通道（输入）
    rx_event: Receiver<Event>,    // 事件通道（输出）
}
```

**关键特性：**
- **队列对模型**：用户通过 `submit(Op)` 发送操作，通过 `next_event()` 接收事件
- **生命周期**：`spawn()` 创建后，后台运行 `submission_loop`，直到收到 `Op::Shutdown`
- **线程安全**：通道天然支持多线程，ID 用原子操作生成

**设计意图：** 隔离用户代码与内部实现，提供异步、非阻塞的接口

---

##### 📘 补充说明 2.1.1：通道架构详解

**Q: `tx_sub` 和 `rx_event` 是干什么的？**

A: 它们构成了 Codex 的**双向通信机制**：

```
用户代码                    Codex 系统内部
   │                            │
   │  submit(Op::UserInput)     │
   ├──────────────────────────→ │ tx_sub → rx_sub → submission_loop
   │                            │               ↓
   │                            │          处理操作...
   │                            │               ↓
   │  next_event()              │          生成事件
   │ ←──────────────────────────┤ tx_event → rx_event
   │  Event::TaskStarted        │
   │                            │
```

**通道说明：**
```rust
// 在 Codex::spawn() 中创建：
let (tx_sub, rx_sub) = async_channel::bounded(64);     // 提交通道（有界）
let (tx_event, rx_event) = async_channel::unbounded(); // 事件通道（无界）

// 分配给不同组件：
Codex {
    tx_sub,      // 用户持有发送端
    rx_event,    // 用户持有接收端
}

Session {
    tx_event,    // Session 持有发送端
}

// rx_sub 传给后台任务
tokio::spawn(submission_loop(session, config, rx_sub));
```

---

**Q: 这两个通道是全局唯一的，还是每个 Session 一个？**

A: **每个 Codex 实例（= 每个 Session）都有独立的通道对**

```rust
// 架构关系：
1 个 Codex 实例 = 1 对通道 (tx_sub/rx_event) 
                = 1 个 Session
                = 1 个 conversation_id
                = 1 个后台 submission_loop 任务
```

**具体来说：**

```rust
// 场景 1: 单个会话
let codex1 = Codex::spawn(config).await?;
codex1.submit(Op::UserInput { ... }).await?;
codex1.next_event().await?;
// ✅ codex1 有自己的通道对

// 场景 2: 多个会话（并行）
let codex1 = Codex::spawn(config1).await?;  // 独立通道对
let codex2 = Codex::spawn(config2).await?;  // 独立通道对

codex1.submit(Op::UserInput { ... }).await?;
codex2.submit(Op::UserInput { ... }).await?;
// ✅ 两个会话完全隔离，互不干扰
```

---

**通道的"所有权分布"：**

```
创建时（Codex::spawn）:
  ┌──────────────────────────────────────────┐
  │  let (tx_sub, rx_sub) = channel::bounded  │
  │  let (tx_event, rx_event) = channel::unbounded │
  └───────────┬──────────────────────────────┘
              │
      ┌───────┴───────┐
      │               │
      ▼               ▼
  Codex             Session
  ├─ tx_sub         ├─ tx_event (clone)
  └─ rx_event       │
                    └─ 传递 rx_sub 给 submission_loop
                       （后台任务独占接收端）
```

**关键设计洞察：**

1. **单向流动**
   ```
   用户 → tx_sub → [submission_loop] → Session 处理
   Session 生成事件 → tx_event → rx_event → 用户
   ```

2. **解耦合**
   - 用户只需要 `Codex` 句柄，不需要知道 `Session` 的存在
   - `submission_loop` 和 `Session` 都是内部实现细节

3. **异步非阻塞**
   ```rust
   // 用户代码可以这样写：
   let id = codex.submit(Op::UserInput { ... }).await?;  // 发送立即返回
   
   loop {
       let event = codex.next_event().await?;  // 异步等待事件
       match event.msg {
           EventMsg::TaskStarted { ... } => println!("任务开始"),
           EventMsg::AgentMessage { ... } => println!("AI 回复"),
           // ...
       }
   }
   ```

4. **容量设计**
   ```rust
   tx_sub:   bounded(64)    // 有界，防止用户提交过快
   tx_event: unbounded()    // 无界，保证事件不丢失
   ```

---

**实际使用示例（app-server 中）：**

```rust
// 创建 Codex 会话
let CodexSpawnOk { codex, conversation_id } = 
    Codex::spawn(config, ...).await?;

// 在一个任务中处理用户输入
tokio::spawn(async move {
    codex.submit(Op::UserInput { items }).await?;
});

// 在另一个任务中处理事件流
tokio::spawn(async move {
    while let Ok(event) = codex.next_event().await {
        // 通过 WebSocket 发送给客户端
        websocket.send(event).await?;
    }
});
```

---

##### 📘 补充说明 2.1.2：App-Server 与 Codex Core 的四通道架构

**完整数据流：从 VS Code 到 LLM 再回来**

当我们把 App-Server 和 Codex Core 结合起来看，会发现一个精妙的**四通道架构**：

```
┌─────────────────────────────────────────────────────────────────┐
│                    VS Code Extension (客户端)                    │
└───────────────────────┬─────────────────────────────────────────┘
                        │
                        │ JSON-RPC over stdin/stdout
                        │
┌───────────────────────┴─────────────────────────────────────────┐
│                      App-Server (协议层)                         │
│                                                                  │
│  MessageProcessor {                                              │
│    incoming_rx: Receiver<IncomingMessage>,    ← 通道 ①          │
│    outgoing_tx: Sender<OutgoingMessage>,      ← 通道 ②          │
│                                                                  │
│    conversation_manager: ConversationManager  ← 会话管理器       │
│  }                                                               │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       │ Rust API 调用
                       │
┌──────────────────────┴───────────────────────────────────────────┐
│                    Codex Core (业务逻辑层)                        │
│                                                                   │
│  CodexConversation {                                              │
│    codex: Codex {                                                 │
│      tx_sub: Sender<Submission>,      ← 通道 ③                   │
│      rx_event: Receiver<Event>,       ← 通道 ④                   │
│    }                                                              │
│  }                                                                │
│                                                                   │
│  Session {                                                        │
│    tx_event: Sender<Event>,           ← 通道 ④ 的发送端          │
│  }                                                                │
│                                                                   │
│  submission_loop(rx_sub) ← 后台任务,处理通道 ③                  │
└───────────────────────┬───────────────────────────────────────────┘
                        │
                        │ HTTP/SSE
                        │
┌───────────────────────┴───────────────────────────────────────────┐
│                  Backend API (OpenAI/Claude/...)                  │
└───────────────────────────────────────────────────────────────────┘
```

---

**四个通道的详细说明：**

### 通道 ① `incoming_rx` - 客户端请求接收通道

**作用：** App-Server 接收来自 VS Code 的 JSON-RPC 请求

**数据流向：** VS Code → stdio → App-Server

**通道类型：** `Receiver<IncomingMessage>`

**典型消息：**
```rust
IncomingMessage::Request {
    id: "1",
    method: "sendUserMessage",
    params: {
        conversation_id: "abc123",
        items: [{ text: "帮我写个 Hello World" }]
    }
}
```

**创建位置：**
```rust
// app-server/src/main.rs
let (incoming_tx, incoming_rx) = async_channel::bounded(128);

// stdio_reader 任务将消息写入 incoming_tx
tokio::spawn(stdio_reader(incoming_tx));

// MessageProcessor 持有 incoming_rx
let processor = MessageProcessor::new(incoming_rx, ...);
```

---

### 通道 ② `outgoing_tx` - 客户端响应发送通道

**作用：** App-Server 向 VS Code 发送 JSON-RPC 响应和通知

**数据流向：** App-Server → stdio → VS Code

**通道类型：** `Sender<OutgoingMessage>`

**典型消息：**
```rust
OutgoingMessage::Response {
    id: "1",
    result: SendUserMessageResponse {}
}

OutgoingMessage::Notification {
    method: "agentMessageDelta",
    params: { delta: "Hello " }
}
```

**创建位置：**
```rust
// app-server/src/main.rs
let (outgoing_tx, outgoing_rx) = async_channel::unbounded();

// MessageProcessor 持有 outgoing_tx
let processor = MessageProcessor::new(..., outgoing_tx);

// stdio_writer 任务从 outgoing_rx 读取并写入 stdout
tokio::spawn(stdio_writer(outgoing_rx));
```

---

### 通道 ③ `tx_sub` - Codex 提交通道

**作用：** 用户代码向 Codex Core 提交操作（Op）

**数据流向：** CodexConversation → submission_loop → Session

**通道类型：** `Sender<Submission>`

**典型消息：**
```rust
Submission {
    id: "turn-1",
    op: Op::UserInput {
        items: vec![
            UserInput::Text { text: "帮我写个 Hello World" }
        ]
    }
}
```

**创建位置：**
```rust
// core/src/codex.rs - Codex::spawn()
let (tx_sub, rx_sub) = async_channel::bounded(64);

// 用户持有发送端
let codex = Codex { tx_sub, ... };

// 后台任务持有接收端
tokio::spawn(submission_loop(session, rx_sub));
```

---

### 通道 ④ `rx_event` - Codex 事件通道

**作用：** Codex Core 向用户代码发送事件（Event）

**数据流向：** Session → CodexConversation → App-Server

**通道类型：** `Receiver<Event>`

**典型消息：**
```rust
Event {
    id: "turn-1",
    msg: EventMsg::AgentMessageDelta(
        AgentMessageDeltaEvent { delta: "Hello " }
    )
}
```

**创建位置：**
```rust
// core/src/codex.rs - Codex::spawn()
let (tx_event, rx_event) = async_channel::unbounded();

// Session 持有发送端
let session = Session { tx_event, ... };

// 用户持有接收端
let codex = Codex { rx_event, ... };
```

---

**完整数据流示例：用户发送 "Hello World" 请求**

```
步骤 1: 客户端发起请求
   VS Code Extension
      ↓ JSON-RPC
   {"method": "sendUserMessage", "params": {"items": [{"text": "写 Hello"}]}}
      ↓ stdin
   通道 ① incoming_rx.recv()
      ↓
   MessageProcessor.handle_message()

步骤 2: App-Server 协议转换
   MessageProcessor
      ├─ 解析 JSON-RPC
      ├─ 转换类型: WireInputItem → CoreInputItem
      └─ 获取会话
            conversation = conversation_manager.get_conversation(id)

步骤 3: 提交到 Codex Core
   conversation.submit(Op::UserInput { items })
      ↓
   通道 ③ tx_sub.send(Submission)
      ↓
   submission_loop 接收
      ↓
   handlers::user_input_or_turn()
      ↓
   Session.spawn_task()
      ↓
   run_task() → run_turn() → try_run_turn()
      ↓
   ModelClient.stream(prompt)  ← HTTP 请求到 OpenAI

步骤 4: LLM 流式响应
   OpenAI API
      ↓ SSE 流
   ModelClient 解析响应
      ↓
   ResponseEvent::OutputTextDelta { delta: "Hello" }
      ↓
   Session.send_event()
      ↓
   通道 ④ tx_event.send(Event)

步骤 5: 事件转发到客户端
   CodexConversation.next_event()
      ↓
   通道 ④ rx_event.recv()
      ↓ 返回给 App-Server 的监听任务
   MessageProcessor 事件循环
      ├─ 转换类型: CoreEvent → WireEvent
      └─ 发送通知
            ↓
   通道 ② outgoing_tx.send(Notification)
      ↓ stdout
   JSON-RPC Notification
      ↓
   VS Code Extension 更新 UI
```

---

**关键设计洞察：**

### 1. 双层异步架构

```
外层 (App-Server):
  incoming_rx ──→ MessageProcessor ──→ outgoing_tx
  (JSON-RPC)                         (JSON-RPC)

内层 (Codex Core):
  tx_sub ──→ submission_loop → Session ──→ tx_event
  (Rust Op)                              (Rust Event)
```

**优势：**
- 协议层和业务层完全解耦
- 每层都是异步非阻塞
- 可以独立替换协议（WebSocket、gRPC）

### 2. 通道容量设计

```rust
incoming_rx:  bounded(128)   // 限流，防止客户端请求过快
outgoing_tx:  unbounded()    // 响应不能丢失
tx_sub:       bounded(64)    // 限流，防止提交过快
tx_event:     unbounded()    // 事件不能丢失
```

**设计原则：**
- **输入通道有界** - 背压（backpressure）机制
- **输出通道无界** - 保证不丢消息

### 3. 事件流监听机制

```rust
// App-Server 为每个会话启动一个监听任务
tokio::spawn(async move {
    loop {
        // 从 Codex Core 读取事件
        let event = conversation.next_event().await?;
        
        // 转换格式
        let wire_event = convert_to_wire(event);
        
        // 通过 outgoing_tx 发送给客户端
        outgoing_tx.send(Notification { ... }).await?;
    }
});
```

**关键点：**
- 每个会话有独立的监听任务
- 事件实时转发，延迟低
- 任务失败时会自动清理

### 4. 多会话隔离

```
VS Code 同时打开 3 个 Agent 面板:

┌─────────────────────┐
│  Conversation A     │ ─→ CodexConversation A ─→ Codex A ─→ 独立通道 ③④
├─────────────────────┤
│  Conversation B     │ ─→ CodexConversation B ─→ Codex B ─→ 独立通道 ③④
├─────────────────────┤
│  Conversation C     │ ─→ CodexConversation C ─→ Codex C ─→ 独立通道 ③④
└─────────────────────┘
         │
         └─────→ 共享通道 ①② (但请求中带 conversation_id 区分)
```

**关键点：**
- 通道 ①② 是共享的（所有会话共用一个 App-Server 进程）
- 通道 ③④ 是每个会话独立的（每个 Codex 实例一对）
- 通过 `conversation_id` 路由到正确的 Codex 实例

---

**类比理解：餐厅的通信系统**

```
通道 ①  = 顾客按铃叫服务员（所有桌共用）
通道 ②  = 广播通知顾客（所有桌共用）

通道 ③  = 服务员向后厨下单（每桌独立）
通道 ④  = 后厨出餐通知（每桌独立）
```

---

##### 📘 补充说明 2.1.3：通道所有权详解

**回答常见疑问：谁持有哪些通道？**

### 疑问 1: `outgoing_tx` 由谁持有？

**答案：** `MessageProcessor` 持有，**不是** Codex 实例持有

```rust
// app-server/src/main.rs - 创建时
let (outgoing_tx, outgoing_rx) = async_channel::unbounded();

// MessageProcessor 持有发送端
struct MessageProcessor {
    outgoing: Arc<OutgoingMessageSender>,  // ← 持有 outgoing_tx
    conversation_manager: Arc<ConversationManager>,
    // ...
}

// stdout_writer 持有接收端
tokio::spawn(async move {
    while let Ok(msg) = outgoing_rx.recv().await {
        println!("{}", serde_json::to_string(&msg)?);
    }
});
```

**关键点：**
- `outgoing_tx` 被包装成 `Arc<OutgoingMessageSender>`
- 多个事件监听任务共享这个 `Arc`
- 所有 conversation 的事件都写入同一个 `outgoing_tx`

---

### 疑问 2: `tx_sub` 和 `rx_sub` 由谁持有？

**答案：** 
- `tx_sub` 由 **Codex 实例** 持有
- `rx_sub` 由 **submission_loop 后台任务** 持有

```rust
// core/src/codex.rs - Codex::spawn()
pub async fn spawn(...) -> CodexResult<CodexSpawnOk> {
    // 1. 创建通道对
    let (tx_sub, rx_sub) = async_channel::bounded(64);
    let (tx_event, rx_event) = async_channel::unbounded();
    
    // 2. 创建 Session
    let session = Session::new(..., tx_event.clone(), ...).await?;
    
    // 3. 启动后台任务，传入 rx_sub
    tokio::spawn(submission_loop(session, config, rx_sub));
    //                                              ^^^^^^
    //                                   后台任务持有接收端
    
    // 4. 返回 Codex 实例，持有 tx_sub
    let codex = Codex {
        next_id: AtomicU64::new(0),
        tx_sub,      // ← Codex 持有发送端
        rx_event,    // ← Codex 持有接收端
    };
    
    Ok(CodexSpawnOk { codex, conversation_id })
}
```

**所有权转移：**
```
创建时:
  let (tx_sub, rx_sub) = channel::bounded(64);
       ^^^^^^  ^^^^^^
         │       │
  ┌──────┘       └──────┐
  │                     │
  ▼                     ▼
Codex               submission_loop
  (move)              (move, 独占)
```

---

### 疑问 3: `tx_event` 和 `rx_event` 由谁持有？

**答案：**
- `tx_event` 由 **Session** 持有（克隆后共享）
- `rx_event` 由 **Codex 实例** 持有

```rust
// core/src/codex.rs - Codex::spawn()
pub async fn spawn(...) -> CodexResult<CodexSpawnOk> {
    let (tx_event, rx_event) = async_channel::unbounded();
    
    // Session 持有发送端（克隆）
    let session = Session::new(
        ...,
        tx_event.clone(),  // ← Session 持有克隆
        ...
    ).await?;
    
    struct Session {
        tx_event: Sender<Event>,  // ← 在这里
        state: Mutex<SessionState>,
        // ...
    }
    
    // Codex 持有接收端
    let codex = Codex {
        tx_sub,
        rx_event,  // ← Codex 持有接收端
    };
    
    Ok(CodexSpawnOk { codex, conversation_id })
}
```

**为什么 `tx_event` 可以克隆？**
- `Sender` 类型实现了 `Clone`
- 多个发送者可以向同一个通道发送消息
- `Session` 的多个方法都可以调用 `self.tx_event.send()`

---

### 疑问 4: MessageProcessor 可以看到四个通道吗？

**答案：不能！** MessageProcessor **只能直接看到外层两个通道**（①②）

**通道可见性分析：**

```rust
// App-Server 层
struct MessageProcessor {
    // ✅ 可以直接访问
    incoming_rx: Receiver<IncomingMessage>,    // 通道 ①
    outgoing: Arc<OutgoingMessageSender>,      // 通道 ②
    
    // ❌ 不能直接访问！
    // 只能通过 CodexConversation API 间接访问
    conversation_manager: Arc<ConversationManager>,
}

// Codex Core 层
struct Codex {
    // ❌ MessageProcessor 看不到！
    tx_sub: Sender<Submission>,     // 通道 ③
    rx_event: Receiver<Event>,      // 通道 ④
}
```

**消息传递如何实现？**

通过 **API 调用** 而非直接访问通道：

```rust
// MessageProcessor 中的代码
async fn send_user_message(&self, params: SendUserMessageParams) {
    // 1. 获取 conversation（封装了 Codex 实例）
    let conversation = self.conversation_manager
        .get_conversation(params.conversation_id)
        .await?;
    
    // 2. 通过 API 提交（内部会写入 tx_sub）
    conversation.submit(Op::UserInput { items }).await?;
    //           ^^^^^^
    //    这是 API 调用，不是直接写通道！
    
    // 3. 在另一个任务中，通过 API 读取事件（内部会读 rx_event）
    loop {
        let event = conversation.next_event().await?;
        //                       ^^^^^^^^^^
        //              也是 API 调用，不是直接读通道！
        
        // 4. 转换格式并写入 outgoing_tx
        self.outgoing.send_notification(...).await?;
    }
}
```

**CodexConversation 的封装：**

```rust
// core/src/codex_conversation.rs
pub struct CodexConversation {
    codex: Codex,  // ← 内部持有 Codex
    // ...
}

impl CodexConversation {
    // API 1: 提交操作
    pub async fn submit(&self, op: Op) -> CodexResult<String> {
        // 内部调用 self.codex.submit()
        // 最终写入 tx_sub
        self.codex.submit(op).await
    }
    
    // API 2: 读取事件
    pub async fn next_event(&self) -> CodexResult<Event> {
        // 内部调用 self.codex.next_event()
        // 最终读取 rx_event
        self.codex.next_event().await
    }
}
```

---

**完整的所有权和可见性图：**

```
┌─────────────────────────────────────────────────────────────┐
│                    App-Server 进程                           │
│                                                              │
│  stdin_reader                                                │
│    ├─ 持有: incoming_tx  ────────┐                          │
│    └─ 写入: IncomingMessage      │                          │
│                                   │                          │
│  MessageProcessor                 │                          │
│    ├─ 持有: incoming_rx  ◄────────┘ (通道 ①)                │
│    ├─ 持有: outgoing_tx  ────────┐ (通道 ②)                │
│    │                              │                          │
│    ├─ 持有: conversation_manager                             │
│    │    └─ 管理多个 CodexConversation                        │
│    │                                                          │
│    └─ 启动事件监听任务 ──────┐                               │
│         for each conversation │                              │
│                               │                              │
│         tokio::spawn(async {  │                              │
│           loop {              │                              │
│             // API 调用 ↓     │                              │
│             let event = conversation.next_event().await;     │
│             self.outgoing.send(event).await; ──┐             │
│           }                                     │             │
│         })                                      │             │
│                                                 │             │
│  stdout_writer                                  │             │
│    ├─ 持有: outgoing_rx  ◄──────────────────────┴─┘         │
│    └─ 读取并输出到 stdout                                    │
│                                                              │
└───────────────────┬──────────────────────────────────────────┘
                    │
                    │ 通过 API 调用（不是直接通道访问）
                    │
┌───────────────────┴──────────────────────────────────────────┐
│                    Codex Core (库)                            │
│                                                              │
│  CodexConversation (API 层)                                  │
│    ├─ submit(Op) ───→ 调用 codex.submit()                   │
│    └─ next_event() ──→ 调用 codex.next_event()              │
│                                                              │
│  Codex (每个 conversation 一个实例)                          │
│    ├─ 持有: tx_sub ──────────────┐ (通道 ③)                 │
│    └─ 持有: rx_event ◄───────────┼─┐ (通道 ④)              │
│                                  │ │                        │
│  submission_loop (后台任务)       │ │                        │
│    └─ 持有: rx_sub ◄──────────────┘ │                        │
│                                    │                        │
│  Session                           │                        │
│    └─ 持有: tx_event ───────────────┘                        │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

**关键设计要点：**

### 1. 封装性（Encapsulation）
```
MessageProcessor 不知道通道 ③④ 的存在
         ↓
只通过 CodexConversation API 交互
         ↓
API 内部操作通道 ③④
```

**好处：**
- App-Server 可以替换协议（WebSocket、gRPC）而不影响 Core
- Core 可以改变内部实现而不影响 App-Server
- 测试时可以 mock CodexConversation

### 2. 所有权清晰（Clear Ownership）
```
每个通道的两端都有唯一所有者：

通道 ①: stdin_reader(tx) ──→ MessageProcessor(rx)
通道 ②: MessageProcessor(tx) ──→ stdout_writer(rx)
通道 ③: Codex(tx) ──→ submission_loop(rx)
通道 ④: Session(tx) ──→ Codex(rx)
```

### 3. 生命周期绑定（Lifetime Binding）
```
App-Server 进程启动:
  创建 incoming/outgoing 通道对 (①②)
  ├─ 生命周期 = 进程生命周期
  └─ 所有 conversation 共享

每创建一个 Codex 实例:
  创建 tx_sub/rx_event 通道对 (③④)
  ├─ 生命周期 = Codex 实例生命周期
  └─ 该 conversation 独占
```

---

**总结你的理解（修正版）：**

✅ **1. 分层架构** - 完全正确

✅ **2. App-Server 组件** - 完全正确

⚠️ **3. Conversation 管理** - 需要补充：
- Codex 实例**不直接持有** incoming/outgoing 通道
- 通过 **CodexConversation API** 间接交互
- MessageProcessor 为每个 conversation **启动独立的事件监听任务**

✅ **4. 消息流转** - 基本正确，补充细节：
- MessageProcessor 通过 `conversation.submit()` API 发送（**不是直接写通道**）
- MessageProcessor 通过 `conversation.next_event()` API 接收（**不是直接读通道**）

**回答你的疑问：**

1. ✅ `outgoing_tx` 由 **MessageProcessor** 持有（Arc 包装，多任务共享）
2. ✅ `tx_sub` 由 **Codex** 持有，`rx_sub` 由 **submission_loop** 持有
3. ✅ `tx_event` 由 **Session** 持有，`rx_event` 由 **Codex** 持有
4. ✅ MessageProcessor **只能直接看到外层通道 ①②**，通过 API 间接访问内层通道 ③④

---

### 2.2 Session - 会话管理层

**核心职责：** 管理一次完整的对话会话（conversation）

```rust
struct Session {
    conversation_id: ConversationId,        // 会话唯一标识
    tx_event: Sender<Event>,                // 事件发送器
    state: Mutex<SessionState>,             // 可变状态（历史记录等）
    features: Features,                     // 功能开关（不可变）
    active_turn: Mutex<Option<ActiveTurn>>, // 当前活跃的任务
    services: SessionServices,              // 共享服务
}
```

#### 2.2.1 SessionState - 会话状态

**职责：** 保存会话的**可变状态**，需要加锁访问

核心内容：
- `session_configuration: SessionConfiguration` - 当前配置
- `history: ContextManager` - 对话历史
- `token_info: Option<TokenUsageInfo>` - Token 使用情况
- `latest_rate_limits: Option<RateLimitSnapshot>` - 速率限制

#### 2.2.2 SessionConfiguration - 会话配置

**职责：** 定义会话的**配置参数**，可在运行时更新（如切换模型）

核心内容：
- `provider: ModelProviderInfo` - 模型提供商
- `model: String` - 模型名称
- `approval_policy: AskForApproval` - 审批策略
- `sandbox_policy: SandboxPolicy` - 沙箱策略
- `cwd: PathBuf` - 工作目录
- `user_instructions: Option<String>` - 用户指令

#### 2.2.3 SessionServices - 共享服务

**职责：** 提供会话运行所需的**基础设施服务**，跨多个 turn 共享

核心内容：
- `mcp_connection_manager: McpConnectionManager` - MCP 服务器连接
- `unified_exec_manager: UnifiedExecSessionManager` - 命令执行管理
- `auth_manager: AuthManager` - 认证管理
- `models_manager: ModelsManager` - 模型管理
- `rollout: RolloutRecorder` - 持久化记录器
- `exec_policy: ExecPolicyManager` - 执行策略

---

### 2.3 TurnContext - 单轮上下文

**核心职责：** 封装单次模型交互（一个 turn）所需的所有信息

```rust
struct TurnContext {
    sub_id: String,                     // 本次提交的ID
    client: ModelClient,                // 模型客户端
    cwd: PathBuf,                       // 工作目录
    
    // 指令相关
    developer_instructions: Option<String>,
    base_instructions: Option<String>,
    user_instructions: Option<String>,
    
    // 策略相关
    approval_policy: AskForApproval,
    sandbox_policy: SandboxPolicy,
    
    // 工具相关
    tools_config: ToolsConfig,
    tool_call_gate: Arc<ReadinessFlag>,  // 工具就绪信号
    
    // 其他
    truncation_policy: TruncationPolicy,  // 截断策略
    final_output_json_schema: Option<Value>, // 输出 schema
}
```

**关键特性：**
- **不可变快照**：创建后不可修改，确保单次交互的配置一致性
- **上下文隔离**：每个 turn 可以有不同的配置（如不同的工作目录）
- **工具绑定**：包含该 turn 可用的工具配置

---

### 2.4 三者关系总结

```
Codex (接口层)
  └─→ Session (会话层) ────┐
        ├─ SessionState    │ 生命周期：整个会话
        ├─ SessionServices │
        └─ active_turn ────┘
              │
              └─→ TurnContext (单轮层) ─── 生命周期：单次交互
```

**核心设计模式：**
1. **分层隔离**：Codex → Session → TurnContext，职责逐层细化
2. **不可变原则**：TurnContext 不可变，Session 中可变部分用 Mutex 隔离
3. **Arc 共享**：Session 和 TurnContext 都用 Arc 包装，支持多线程共享

---

## 3. 核心工作流程

### 3.0 总体概览：Codex 如何实现 ReAct 模式

#### 3.0.1 什么是 ReAct 模式？

ReAct（Reasoning + Acting）是一种经典的 Agent 工作模式：

```
用户问题 → [思考(Reason) → 行动(Act) → 观察(Observe)] → 循环直到得出答案
```

**具体例子：** "帮我统计项目中的 Python 文件数量"

```
Cycle 1:
  Reason: 我需要先列出项目目录
  Act:    调用 shell("ls -R")
  Observe: 看到目录结构

Cycle 2:
  Reason: 我需要过滤出 .py 文件
  Act:    调用 shell("find . -name '*.py' | wc -l")
  Observe: 得到数量 42

Cycle 3:
  Reason: 我已经得到答案
  Act:    返回文本消息 "项目中有 42 个 Python 文件"
  Observe: (结束)
```

---

#### 3.0.2 Codex 中的 ReAct 实现映射

Codex 将 ReAct 模式映射到三层抽象：

```
┌─────────────────────────────────────────────────────────────┐
│                         Task 层                              │
│  (对应完整的 ReAct 循环，直到问题解决)                        │
│                                                               │
│  run_task() {                                                │
│    loop {                                                    │
│      result = run_turn()  ← 一次 Reason-Act-Observe         │
│      if !result.needs_follow_up { break }                   │
│    }                                                         │
│  }                                                           │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                        Turn 层                               │
│  (对应一次 Reason-Act-Observe 循环)                          │
│                                                               │
│  run_turn() {                                                │
│    1. 发送 Prompt (包含历史 + 用户输入)                       │
│    2. 模型流式返回:                                          │
│       - Reasoning: 思考过程 (O1 模型可见)                    │
│       - Acting: 工具调用 OR 文本回复                         │
│    3. 执行工具调用 → 得到 Observation                        │
│    4. 将 Observation 加入历史                                │
│    5. 返回 needs_follow_up (是否需要下一轮)                  │
│  }                                                           │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                   Tool Call 层                               │
│  (对应 Act 阶段的具体执行)                                   │
│                                                               │
│  dispatch_tool_call() {                                      │
│    1. 审批检查 (如果需要)                                    │
│    2. 沙箱检查 (权限控制)                                    │
│    3. 执行工具 (shell, read_file, write, MCP, ...)          │
│    4. 返回结果 → 转换为 Observation                          │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘
```

---

#### 3.0.3 核心流程用"餐厅点餐"类比

把 Codex 想象成一个**智能餐厅系统**：

**组件映射：**
```
用户 (User)           → 顾客
Codex                 → 前台接待（接收订单，返回状态）
Session               → 餐桌（保存点餐历史、账单信息）
TurnContext           → 服务员（负责单次服务）
Task                  → 完整的用餐过程（多轮服务）
Turn                  → 单次服务（点菜、上菜、询问）
Tool                  → 后厨工具（炉灶、刀具）
```

**完整流程：**

```
1. 顾客进门 (Codex::spawn)
   ├─ 前台分配餐桌 (Session::new)
   ├─ 查看菜单历史 (record_initial_history)
   └─ 服务员就位 (submission_loop 启动)

2. 顾客点餐 (Op::UserInput)
   └─ 前台转交服务员 (user_input_or_turn)
      └─ 服务员记录 (创建 TurnContext)

3. 开始用餐 (run_task)
   └─ 循环服务 loop {
        
        ┌─────────────────────────────────┐
        │  单次服务 (run_turn - ReAct)    │
        ├─────────────────────────────────┤
        │                                 │
        │  Reason: 服务员判断             │
        │    "顾客要牛排，我需要问几分熟" │
        │                                 │
        │  Act: 调用工具                  │
        │    ask_customer("几分熟?")      │
        │                                 │
        │  Observe: 顾客回答              │
        │    "七分熟"                     │
        │                                 │
        └─────────────────────────────────┘
        
        needs_follow_up? 
        ├─ Yes → 继续下一轮 (通知后厨、上菜...)
        └─ No → 用餐结束
      }

4. 结账离开 (任务完成)
   └─ 保存账单 (rollout 持久化)
```

**关键洞察：**
- **餐桌 (Session)** 保留整个用餐的历史（点过什么菜、花了多少钱）
- **服务员 (TurnContext)** 只负责当前这一轮服务（拿着当前配置的托盘）
- **后厨工具 (Tools)** 可能需要厨师长审批（审批策略）
- **账单 (Rollout)** 记录所有操作，可以"回放"整个用餐过程

---

#### 3.0.4 ReAct 循环的核心要素

在 Codex 实现中，ReAct 的三个阶段对应：

**1. Reason（推理） - 模型内部**
```rust
// 模型收到 Prompt:
历史消息：
  User: "统计 Python 文件"
  Assistant: (之前的思考...)
  Tool Result: (之前的观察...)

可用工具：
  - shell(command)
  - read_file(path)
  - ...

// 模型思考：
我需要执行 shell 命令来统计文件
```

**2. Act（行动） - 模型输出**
```rust
// 模型返回两种可能：
Option A: 工具调用
  ResponseItem::CustomToolCall {
    name: "shell",
    input: "find . -name '*.py' | wc -l"
  }
  → needs_follow_up = true  // 需要等待工具结果

Option B: 文本回复
  ResponseItem::Message {
    role: "assistant",
    content: "项目中有 42 个 Python 文件"
  }
  → needs_follow_up = false  // 任务完成
```

**3. Observe（观察） - 工具执行结果**
```rust
// 工具执行后返回：
ResponseInputItem::FunctionCallOutput {
  call_id: "...",
  output: "42\n"
}

// 这个结果会：
1. 加入历史记录 (record_conversation_items)
2. 在下一轮 Turn 中作为 Prompt 的一部分发送给模型
```

---

#### 3.0.5 关键设计：为什么分 Task 和 Turn？

**Task = 完整问题的解决**
- 可能需要多轮交互
- 管理整体状态（Token 使用、自动压缩）
- 生命周期：用户提交问题 → 模型给出最终答案

**Turn = 单次 Reason-Act-Observe**
- 只关注一次模型交互
- 配置独立（可以中途切换模型）
- 生命周期：发送 Prompt → 处理响应 → 执行工具 → 返回

**类比：**
```
Task = 解决一道数学题（可能需要多步计算）
Turn = 单步计算（列式、计算、得到中间结果）
```

**实际例子：**
```
Task: "帮我创建一个 Python 项目并添加 README"

Turn 1:
  Reason: 需要创建项目目录
  Act: shell("mkdir my_project")
  Observe: 目录创建成功

Turn 2:
  Reason: 需要初始化 Python 环境
  Act: shell("cd my_project && python -m venv venv")
  Observe: 虚拟环境创建成功

Turn 3:
  Reason: 需要创建 README
  Act: write(path="my_project/README.md", content="# My Project")
  Observe: 文件写入成功

Turn 4:
  Reason: 任务完成
  Act: 返回 "项目已创建完成！"
  Observe: (结束)
```

### 3.1 会话初始化流程

#### 3.1.1 Codex::spawn() - 系统启动

**核心目标：** 创建并初始化一个新的 Codex 会话

**关键步骤：**

```rust
Codex::spawn(config, auth_manager, models_manager, ...) 
  │
  ├─→ 1. 加载 Skills（如果启用）
  │      └─ skills_manager.skills_for_cwd(&config.cwd)
  │
  ├─→ 2. 加载用户指令
  │      └─ get_user_instructions() [详见补充说明 3.1.1.1]
  │         ├─ Config 中的指令（--instructions 参数）
  │         ├─ 项目文档（AGENTS.md 文件链）
  │         └─ Skills 指令摘要
  │
  ├─→ 3. 加载执行策略
  │      └─ ExecPolicyManager::load()
  │
  ├─→ 4. 刷新可用模型列表（如果启用远程模型）
  │      └─ models_manager.refresh_available_models()
  │
  ├─→ 5. 创建 Session
  │      └─ Session::new()  [详见 3.1.2]
  │
  └─→ 6. 启动后台任务
         └─ tokio::spawn(submission_loop())  [详见 3.2.1]
```

**设计要点：**
- **并行初始化**：独立的异步任务（如 rollout、shell discovery、auth）并行执行
- **错误处理**：初始化失败会通过 `map_session_init_error` 转换为用户友好的错误信息

---

##### 📘 补充说明 3.1.1.1：用户指令的加载机制

**`get_user_instructions()` 的作用：为 AI 提供项目特定的指令**

这些指令会被注入到**每个会话的初始历史**中，作为系统级的"上下文知识"，指导模型如何处理该项目的任务。

**加载的三个来源（按顺序合并）：**

```rust
get_user_instructions(config, skills)
  │
  ├─→ 1. Config 指令（优先级最高）
  │      来源：命令行参数 --instructions "..." 或配置文件
  │      示例：--instructions "This is a Rust project. Use cargo commands."
  │
  ├─→ 2. 项目文档（AGENTS.md 文件链）
  │      └─ 发现机制：
  │         ├─ 从当前工作目录向上查找 Git 仓库根目录
  │         ├─ 收集从 Git 根到当前目录的所有 AGENTS.md 文件
  │         └─ 按路径顺序串联（root → intermediate → cwd）
  │
  │      文件名优先级：
  │      ├─ AGENTS.override.md（最高优先级，不会提交到 Git）
  │      ├─ AGENTS.md（标准名称）
  │      └─ 配置的 fallback 文件名（可选）
  │
  │      示例结构：
  │      my-repo/
  │      ├─ AGENTS.md              ← "This is a monorepo..."
  │      └─ packages/
  │         └─ web-app/
  │            ├─ AGENTS.md         ← "This is a React app..."
  │            └─ src/              ← 当前工作目录
  │
  │      最终拼接：
  │      """
  │      This is a monorepo...
  │      
  │      This is a React app...
  │      """
  │
  └─→ 3. Skills 指令摘要
         └─ 自动生成的 Skills 列表（名称、描述、路径）
            示例：
            """
            Available skills:
            - python-test: Run pytest with coverage
              Path: .codex/skills/python-test.md
            - git-commit: Generate conventional commits
              Path: .codex/skills/git-commit.md
            """
```

**最终组合格式：**

```
# AGENTS.md instructions for /path/to/project

<INSTRUCTIONS>
[Config 指令]

--- project-doc ---

[AGENTS.md 内容]

[Skills 摘要]
</INSTRUCTIONS>
```

**作用示例：**

假设你的 `AGENTS.md` 包含：

```markdown
# Project Instructions

- This is a TypeScript project using Bun runtime
- Always use `bun test` instead of `npm test`
- Follow our naming convention: components use PascalCase
- API endpoints are in `src/api/` directory
```

当你问 AI："帮我运行测试"，AI 会看到这些指令，知道：
1. 使用 `bun test` 而不是 `npm test`
2. 项目使用 TypeScript + Bun

**关键设计：**
- **分层覆盖**：支持 monorepo 中不同目录有不同指令
- **本地覆盖**：`AGENTS.override.md` 用于本地开发，不提交到仓库
- **自动发现**：无需手动配置，放在目录中即生效
- **大小限制**：`project_doc_max_bytes` 防止指令过大影响性能（默认通常是 50KB）

**与 base_instructions 的区别：**
```
base_instructions (系统级)
  → 定义 AI 的通用行为（如何使用工具、如何响应）
  → 所有项目共享
  → 由 Codex 系统提供

user_instructions (项目级)
  → 定义项目特定的规则和上下文
  → 每个项目不同
  → 由用户/项目维护（AGENTS.md）
```

---

#### 3.1.2 Session::new() - 会话创建

**核心目标：** 初始化会话的所有基础设施

**关键步骤：**

```rust
Session::new(...)
  │
  ├─→ 1. 生成或恢复 conversation_id
  │      ├─ New: 生成新 UUID
  │      ├─ Resumed: 从历史中读取
  │      └─ Forked: 生成新 UUID
  │
  ├─→ 2. 并行初始化基础服务（tokio::join!）
  │      ├─ RolloutRecorder::new()        // 持久化记录器
  │      ├─ history_metadata()             // 历史元数据
  │      └─ compute_auth_statuses()        // MCP 认证状态
  │
  ├─→ 3. 初始化 OtelManager（可观测性）
  │      └─ conversation_starts() 记录会话开始
  │
  ├─→ 4. 初始化 ShellSnapshot（如果启用）
  │      └─ 捕获当前 shell 环境
  │
  ├─→ 5. 初始化 MCP 连接管理器
  │      └─ mcp_connection_manager.initialize()
  │         └─ 启动所有配置的 MCP 服务器连接
  │
  ├─→ 6. 发送 SessionConfiguredEvent
  │      └─ 通知客户端会话已就绪
  │
  └─→ 7. 记录初始历史
         └─ record_initial_history()  [详见 3.1.3]
```

**设计要点：**
- **异步优化**：独立的初始化任务并行执行以减少启动延迟
- **事件驱动**：每个关键步骤都发送事件，客户端可实时感知状态

---

#### 3.1.3 历史记录初始化

**三种模式：**

**模式 1: New（新会话）**
```rust
record_initial_history(InitialHistory::New)
  │
  ├─→ build_initial_context()
  │      ├─ DeveloperInstructions（如果有）
  │      ├─ UserInstructions（如果有）
  │      └─ EnvironmentContext（cwd, 审批策略, 沙箱策略, shell 信息）
  │
  └─→ record_conversation_items()
         └─ 追加到历史并持久化到 rollout
```

**模式 2: Resumed（恢复会话）**
```rust
record_initial_history(InitialHistory::Resumed(history))
  │
  ├─→ 重建历史
  │      └─ reconstruct_history_from_rollout()
  │         ├─ 处理 ResponseItem（普通消息）
  │         └─ 处理 Compacted（压缩点）
  │            └─ 应用压缩逻辑重建历史
  │
  ├─→ 模型版本检查
  │      └─ 如果模型变更，发送 Warning 事件
  │
  └─→ 恢复 token 使用信息
         └─ 从 rollout 中提取最后的 TokenCountEvent
```

**模式 3: Forked（分叉会话）**
```rust
record_initial_history(InitialHistory::Forked(history))
  │
  ├─→ 重建历史（同 Resumed）
  │
  └─→ 持久化 rollout 副本
         └─ persist_rollout_items()  // 创建新的 rollout 文件
```

**关键设计：**
- **压缩重建**：支持从压缩后的历史中重建完整对话上下文
- **状态恢复**：恢复 token 使用、速率限制等运行时状态
- **分叉独立性**：分叉会话生成新 ID，但保留历史副本

---

### 3.2 任务执行流程

#### 3.2.1 submission_loop - 提交循环

**核心职责：** 处理用户提交的所有操作，是系统的"心脏"

```rust
submission_loop(session, config, rx_sub)
  │
  └─→ loop {
         rx_sub.recv().await  // 阻塞等待提交
           │
           ├─→ Op::Interrupt          → interrupt()
           ├─→ Op::OverrideTurnContext → override_turn_context()
           ├─→ Op::UserInput / UserTurn → user_input_or_turn()  [关键！]
           ├─→ Op::ExecApproval       → exec_approval()
           ├─→ Op::PatchApproval      → patch_approval()
           ├─→ Op::Compact            → compact()
           ├─→ Op::Undo               → undo()
           ├─→ Op::Review             → review()
           ├─→ Op::Shutdown           → shutdown() → break
           └─→ ...
      }
```

**关键特性：**
- **单线程顺序处理**：所有提交按序处理，避免竞态
- **previous_context 维护**：跟踪上一个 TurnContext，用于检测环境变化
- **阻塞式**：只有当前操作完成才处理下一个

---

#### 3.2.2 user_input_or_turn - 用户输入处理

**核心逻辑：** 用户输入可能创建新任务，也可能注入到运行中的任务

```rust
user_input_or_turn(session, sub_id, op, previous_context)
  │
  ├─→ 1. 创建 TurnContext
  │      └─ new_turn_with_sub_id()
  │         ├─ 应用 SessionSettingsUpdate（模型、策略等）
  │         └─ 构建 TurnContext 快照
  │
  ├─→ 2. 尝试注入到运行中的任务
  │      └─ inject_input(items)
  │         ├─ 成功 → 任务会在下一个 turn 处理输入
  │         └─ 失败 → 没有运行中的任务，继续
  │
  └─→ 3. 启动新任务（如果注入失败）
         ├─ 检测环境变化
         │  └─ build_environment_update_item()
         │     └─ 对比 previous_context 和 current_context
         │
         └─ spawn_task(RegularTask)  [详见 3.2.3]
```

**设计要点：**
- **输入注入**：支持在模型运行时注入新消息（取决于模型能力）
- **环境感知**：自动检测并记录工作目录、策略变更

---

#### 3.2.3 run_task - 任务执行

**核心职责：** 执行完整的任务，包含多个 turn 的循环

```rust
run_task(session, turn_context, input, cancellation_token)
  │
  ├─→ 1. 自动压缩检查
  │      └─ if total_tokens >= auto_compact_limit
  │         └─ run_auto_compact()  // 执行历史压缩
  │
  ├─→ 2. 发送 TaskStartedEvent
  │
  ├─→ 3. 处理 Skills 注入
  │      └─ build_skill_injections()
  │         └─ 根据用户输入匹配并注入相关 skill
  │
  ├─→ 4. 记录初始用户输入
  │      └─ record_response_item_and_emit_turn_item()
  │
  ├─→ 5. 启动 Ghost Snapshot 任务（后台）
  │      └─ maybe_start_ghost_snapshot()  // 如果启用
  │
  └─→ 6. 主循环：run_turn()
         │
         loop {
            ├─→ 获取待处理输入
            │   └─ get_pending_input()  // 用户注入的新消息
            │
            ├─→ 构建输入
            │   └─ clone_history().get_history_for_prompt()
            │
            ├─→ 执行单轮
            │   └─ run_turn()  [详见 3.2.4]
            │      └─ 返回 TurnRunResult { needs_follow_up, ... }
            │
            ├─→ Token 限制检查
            │   └─ if token_limit_reached && needs_follow_up
            │      └─ run_auto_compact() → continue
            │
            └─→ 任务完成判断
                └─ if !needs_follow_up → break
         }
```

**关键机制：**
- **自动压缩**：Token 使用超限时自动触发历史压缩
- **循环执行**：只要模型需要后续交互（如工具调用），就继续循环
- **并发任务**：Ghost Snapshot 等后台任务与主流程并行

---

#### 3.2.4 run_turn - 单轮执行

**核心职责：** 处理单次模型交互（发送 prompt → 接收 response → 处理工具调用）

```rust
run_turn(session, turn_context, turn_diff_tracker, input, cancellation_token)
  │
  ├─→ 1. 准备工具
  │      ├─ 获取 MCP 工具列表
  │      └─ 构建 ToolRouter
  │
  ├─→ 2. 构建 Prompt
  │      └─ Prompt {
  │            input: 历史消息,
  │            tools: 可用工具规范,
  │            parallel_tool_calls: 是否支持并行,
  │            base_instructions_override,
  │            output_schema
  │         }
  │
  ├─→ 3. 重试循环
  │      └─ loop {
  │            try_run_turn()  [详见 3.2.5]
  │              ├─ 成功 → return
  │              ├─ 流断开 → 重试（最多 max_retries 次）
  │              └─ 其他错误 → return Err
  │         }
  │
  └─→ 4. 持久化 TurnContext
         └─ persist_rollout_items(RolloutItem::TurnContext)
            └─ 记录本轮的配置快照（模型、策略等）
```

**错误处理与重试：**
```rust
Err(CodexErr::Stream(..)) → 重试
Err(CodexErr::TurnAborted) → 立即返回
Err(CodexErr::UsageLimitReached) → 更新速率限制并返回
Err(CodexErr::ContextWindowExceeded) → 标记 token 已满并返回
其他错误 → 根据 max_retries 决定
```

**设计要点：**
- **透明重试**：流断开时自动重试，用户无感知
- **指数退避**：使用 `backoff(retries)` 计算重试延迟
- **状态通知**：通过 `notify_stream_error()` 通知客户端重试进度

---

#### 3.2.5 try_run_turn - 单轮执行核心

**核心职责：** 处理模型流式响应，调度工具执行

```rust
try_run_turn(router, session, turn_context, turn_diff_tracker, prompt, cancellation_token)
  │
  ├─→ 1. 发起流式请求
  │      └─ turn_context.client.stream(prompt)
  │
  ├─→ 2. 创建工具运行时
  │      └─ ToolCallRuntime::new(router, session, turn_context, tracker)
  │
  ├─→ 3. 流式处理循环
  │      └─ loop {
  │            stream.next().await
  │              │
  │              ├─→ ResponseEvent::OutputItemAdded(item)
  │              │      └─ 发送 ItemStartedEvent
  │              │
  │              ├─→ ResponseEvent::OutputTextDelta(delta)
  │              │      └─ 发送 AgentMessageContentDeltaEvent（实时文本流）
  │              │
  │              ├─→ ResponseEvent::OutputItemDone(item)
  │              │      └─ handle_output_item_done()  [详见 3.3]
  │              │         ├─ 处理工具调用
  │              │         └─ 处理文本消息
  │              │
  │              ├─→ ResponseEvent::RateLimits(snapshot)
  │              │      └─ update_rate_limits()
  │              │
  │              ├─→ ResponseEvent::Completed { token_usage }
  │              │      ├─ update_token_usage_info()
  │              │      └─ break → 返回 TurnRunResult
  │              │
  │              └─→ ResponseEvent::ReasoningSummaryDelta { ... }
  │                     └─ 发送 ReasoningContentDeltaEvent（O1 推理过程）
  │         }
  │
  ├─→ 4. 等待所有工具调用完成
  │      └─ drain_in_flight(in_flight)
  │
  └─→ 5. 发送 TurnDiff 事件
         └─ turn_diff_tracker.get_unified_diff()
            └─ 生成本轮文件变更的统一 diff
```

**并发工具执行：**
```rust
in_flight: FuturesOrdered<BoxFuture<ResponseInputItem>>
  │
  ├─→ 工具 A 执行中...
  ├─→ 工具 B 执行中...
  └─→ 工具 C 执行中...
       │
       └─→ 完成后 → record_conversation_items()
```

**关键设计：**
- **流式响应**：实时处理模型输出，无需等待完整响应
- **并发工具执行**：多个工具调用可并行执行（如果模型支持）
- **取消支持**：通过 `cancellation_token` 可随时中止

---

### 3.3 工具调用机制

#### 3.3.1 handle_output_item_done - 输出项完成处理

**核心职责：** 处理模型返回的完整输出项（工具调用或文本消息）

```rust
handle_output_item_done(ctx, item, previously_active_item)
  │
  └─→ match item {
         │
         ├─→ ResponseItem::Message { role: "assistant", ... }
         │      ├─ 记录到历史
         │      ├─ 发送 ItemCompletedEvent
         │      └─ return { needs_follow_up: false }  // 任务完成
         │
         ├─→ ResponseItem::CustomToolCall { name, input, ... }
         │      │
         │      ├─→ 1. 构建工具调用
         │      │      └─ ToolRouter::build_tool_call()
         │      │         ├─ 解析 MCP 工具名（server::tool）
         │      │         └─ 构建 ToolCall 对象
         │      │
         │      ├─→ 2. 调度工具执行
         │      │      └─ tool_runtime.spawn_tool_call()
         │      │         ├─ 并行执行 → 加入 in_flight
         │      │         └─ 顺序执行 → 立即执行
         │      │
         │      └─→ 3. 返回 future
         │             └─ return { 
         │                   needs_follow_up: true,
         │                   tool_future: Some(future)
         │                }
         │
         └─→ 其他类型
                └─ 记录到历史
      }
```

**工具调用流程：**
```rust
spawn_tool_call(call)
  │
  ├─→ 检查并发策略
  │      ├─ 并行模式 → 直接返回 future
  │      └─ 顺序模式 → 等待前序工具完成
  │
  └─→ 执行工具
         └─ router.dispatch_tool_call()  [详见 3.3.2]
```

---

#### 3.3.2 ToolRouter::dispatch_tool_call - 工具分发

**核心职责：** 根据工具名分发到对应的处理器

```rust
dispatch_tool_call(session, turn_context, tracker, call)
  │
  ├─→ 1. 查找工具处理器
  │      └─ router.get_handler(tool_name)
  │         ├─ 内置工具（shell, read_file, write, ...）
  │         └─ MCP 工具（通过 mcp_connection_manager）
  │
  ├─→ 2. 准备调用上下文
  │      └─ ToolInvocation {
  │            session,
  │            turn: turn_context,
  │            tracker: turn_diff_tracker,
  │            call_id,
  │            tool_name,
  │            payload
  │         }
  │
  ├─→ 3. 执行工具
  │      └─ handler.handle(invocation)
  │         │
  │         └─→ 返回 Result<ToolOutput, FunctionCallError>
  │
  └─→ 4. 处理结果
         ├─ Ok(output) → 转换为 ResponseInputItem
         └─ Err(FunctionCallError) → 
            ├─ Fatal → 传播错误（终止 turn）
            ├─ RespondToModel(msg) → 包装为错误响应
            └─ ToolCallDenied → 用户拒绝审批
```

**工具执行示例（shell 工具）：**
```rust
ShellHandler::handle(invocation)
  │
  ├─→ 1. 解析参数
  │      └─ ExecParams { command, cwd, timeout, sandbox_permissions, ... }
  │
  ├─→ 2. 权限检查
  │      ├─ 检查审批策略
  │      ├─ 检查沙箱策略
  │      └─ 检查执行策略（execpolicy）
  │
  ├─→ 3. 请求审批（如果需要）
  │      └─ session.request_command_approval()
  │         ├─ 发送 ExecApprovalRequestEvent
  │         └─ 等待 ReviewDecision
  │
  ├─→ 4. 执行命令
  │      └─ exec::exec_command()
  │         ├─ 应用沙箱
  │         └─ 执行并收集输出
  │
  └─→ 5. 返回结果
         └─ ToolOutput::Function { content, success }
```

---

#### 3.3.3 工具调用的关键机制

**1. 并行执行策略**
```rust
if model_supports_parallel && enabled(ParallelToolCalls) {
    // 多个工具调用并发执行
    in_flight.push_back(future_A);
    in_flight.push_back(future_B);
} else {
    // 顺序执行
    await future_A;
    await future_B;
}
```

**2. 审批流程**
```rust
审批策略           何时触发审批
─────────────────────────────────────────
Always            所有命令
OnRequest         工具显式请求（escalated permissions）
OnFailure         命令执行失败后
Never             从不审批
```

**3. 沙箱策略**
```rust
沙箱策略              行为
─────────────────────────────────────────
DangerFullAccess     完全访问（测试用）
AllowWritesToCwd     只允许写工作目录
ReadOnlyFilesystem   只读文件系统
ForbidNetwork        禁止网络访问
```

**4. 执行策略（ExecPolicy）**
```rust
执行策略规则：
- AllowedPrefixes: 允许的命令前缀列表
- 可通过审批动态添加新前缀
- 持久化到 ~/.codex/exec-policy.toml
```

---

### 3.4 流程总结图

```
用户提交 Op::UserInput
    │
    ▼
submission_loop
    │
    ▼
user_input_or_turn
    │
    ├─→ 创建 TurnContext
    └─→ spawn_task()
           │
           ▼
       run_task
           │
           ├─→ 自动压缩检查
           ├─→ Skills 注入
           │
           └─→ loop {
                  run_turn
                    │
                    ├─→ 准备工具
                    ├─→ 构建 Prompt
                    │
                    └─→ try_run_turn
                          │
                          ├─→ stream(prompt)
                          │
                          └─→ loop {
                                 ├─ OutputTextDelta → 实时文本
                                 ├─ OutputItemDone
                                 │    └─→ CustomToolCall
                                 │         └─→ dispatch_tool_call
                                 │              ├─→ 审批检查
                                 │              ├─→ 执行工具
                                 │              └─→ 返回结果
                                 │
                                 └─ Completed
                                      └─→ needs_follow_up?
                                           ├─ true → continue (下一轮)
                                           └─ false → break (任务完成)
                              }
               }
```

---

现在第 3 章已经补充完成！你可以提出任何疑问，我会针对性地深入解释。

---

## 4. 关键机制

### 4.1 历史记录管理

历史记录是 AI Agent 的"记忆"，直接影响模型的推理能力。Codex 使用多层历史管理策略。

#### 4.1.1 ContextManager - 内存中的历史

**核心职责：** 管理会话的对话历史（存储在内存中）

```rust
// core/src/context_manager.rs
pub struct ContextManager {
    history: Vec<ResponseItem>,  // 完整的对话历史
}

impl ContextManager {
    // 添加新项到历史
    pub fn record_items(&mut self, items: impl Iterator<Item = &ResponseItem>) {
        for item in items {
            self.history.push(item.clone());
        }
    }
    
    // 获取用于发送给模型的历史
    pub fn get_history_for_prompt(&self) -> Vec<ResponseItem> {
        self.history.clone()
    }
    
    // 替换整个历史（压缩后）
    pub fn replace(&mut self, new_history: Vec<ResponseItem>) {
        self.history = new_history;
    }
}
```

**历史中包含的内容：**

```rust
Vec<ResponseItem> {
    // 1. 系统指令
    ResponseItem::Message {
        role: "user",
        content: [InputText { 
            text: "# AGENTS.md instructions...\n<INSTRUCTIONS>..." 
        }]
    },
    
    // 2. 环境上下文
    ResponseItem::Message {
        role: "user",
        content: [InputText {
            text: "<environment_context>\nCWD: /path/to/project\n..."
        }]
    },
    
    // 3. 用户消息
    ResponseItem::Message {
        role: "user",
        content: [InputText { text: "帮我写个函数" }]
    },
    
    // 4. AI 回复
    ResponseItem::Message {
        role: "assistant",
        content: [OutputText { text: "好的，我来写..." }]
    },
    
    // 5. 工具调用
    ResponseItem::CustomToolCall {
        name: "write",
        input: "{ \"path\": \"main.rs\", ... }"
    },
    
    // 6. 工具结果
    ResponseItem::Message {
        role: "user",
        content: [InputText { 
            text: "<function_result>文件已写入</function_result>" 
        }]
    },
}
```

---

#### 4.1.2 历史压缩机制（Compact）

**为什么需要压缩？**

```
问题：历史记录无限增长
  ├─ Token 成本增加（每次请求都发送完整历史）
  ├─ 超出模型上下文窗口限制
  └─ 响应变慢（处理更多 token）

解决：自动压缩历史
  └─ 用摘要替代详细对话
```

**压缩触发条件：**

```rust
// core/src/codex.rs - run_task()
let auto_compact_limit = turn_context
    .client
    .get_model_family()
    .auto_compact_token_limit()
    .unwrap_or(i64::MAX);  // 默认如 50,000 tokens

let total_usage_tokens = session.get_total_token_usage().await;

if total_usage_tokens >= auto_compact_limit {
    run_auto_compact(&session, &turn_context).await;
}
```

**压缩流程：**

```
当前历史 (10,000 tokens):
  User Instructions
  Turn 1: User → AI → Tool calls
  Turn 2: User → AI → Tool calls
  Turn 3: User → AI → Tool calls
  Turn 4: User → AI → Tool calls (当前)

        ↓ 压缩

压缩后历史 (2,000 tokens):
  User Instructions
  Compact Summary:
    "Previous conversation covered:
     - Turn 1-3: User asked X, AI did Y, results were Z"
  Turn 4: User → AI → Tool calls (保留最近)
```

**压缩实现：**

```rust
// core/src/compact.rs
pub async fn run_inline_auto_compact_task(
    session: Arc<Session>,
    turn_context: Arc<TurnContext>
) {
    // 1. 收集用户消息（保留用户意图）
    let snapshot = session.clone_history().await.get_history();
    let user_messages = collect_user_messages(&snapshot);
    
    // 2. 调用模型生成摘要
    let prompt = format!(
        "{}\n\n{}", 
        turn_context.compact_prompt(),  // 压缩指令
        format_messages_for_summarization(&user_messages)
    );
    
    let summary = turn_context.client.stream_compact(prompt).await?;
    
    // 3. 构建新历史
    let initial_context = session.build_initial_context(&turn_context);
    let compacted_history = build_compacted_history(
        initial_context,
        &user_messages,  // 保留用户消息
        &summary         // 用摘要替代详细交互
    );
    
    // 4. 替换历史
    session.replace_history(compacted_history).await;
    
    // 5. 记录到 rollout
    session.persist_rollout_items(&[
        RolloutItem::Compacted(CompactedItem {
            message: summary,
            replacement_history: Some(compacted_history),
        })
    ]).await;
}
```

**压缩策略：**

```
保留内容：
  ✅ 初始上下文（AGENTS.md、环境信息）
  ✅ 用户消息（理解用户意图）
  ✅ 压缩摘要（历史概括）
  ✅ 最近 N 轮对话（保持上下文连续性）

丢弃内容：
  ❌ 早期的详细 AI 回复
  ❌ 早期的工具调用细节
  ❌ 早期的工具输出
```

---

#### 4.1.3 Rollout - 持久化历史

**核心职责：** 将会话的所有操作持久化到文件，用于恢复和审计

```rust
// core/src/rollout.rs
pub struct RolloutRecorder {
    writer: JournalWriter,           // 文件写入器
    rollout_path: PathBuf,           // 存储路径
    conversation_id: ConversationId, // 会话 ID
}
```

**Rollout 文件格式（JSONL）：**

```jsonl
{"type":"response_item","item":{"role":"user","content":[{"text":"帮我写函数"}]}}
{"type":"response_item","item":{"role":"assistant","content":[{"text":"好的"}]}}
{"type":"tool_call","name":"write","input":"{...}"}
{"type":"tool_result","output":"文件已写入"}
{"type":"compacted","message":"Turn 1-3: ..."}
{"type":"turn_context","model":"gpt-4","cwd":"/path/to/project"}
{"type":"event","msg":{"AgentMessageDelta":{"delta":"Hello"}}}
```

**Rollout 用途：**

1. **恢复会话**
   ```rust
   // 从 rollout 文件恢复会话
   let history = read_rollout_file(path).await?;
   Codex::spawn(config, ..., InitialHistory::Resumed(history)).await?;
   ```

2. **分叉会话**
   ```rust
   // 基于现有会话创建新分支
   let history = read_rollout_file(path).await?;
   Codex::spawn(config, ..., InitialHistory::Forked(history)).await?;
   ```

3. **调试和审计**
   - 完整记录所有交互
   - 可以回放整个会话
   - 用于分析问题

**记录内容：**

```rust
pub enum RolloutItem {
    ResponseItem(ResponseItem),       // 对话项
    Compacted(CompactedItem),          // 压缩记录
    TurnContext(TurnContextItem),      // 轮次配置
    EventMsg(EventMsg),                // 事件消息
}
```

**异步写入机制：**

```rust
// 后台写入，不阻塞主流程
impl RolloutRecorder {
    pub async fn record_items(&self, items: &[RolloutItem]) -> Result<()> {
        for item in items {
            // 序列化为 JSON
            let json = serde_json::to_string(item)?;
            
            // 异步写入文件
            self.writer.write_line(&json).await?;
        }
        Ok(())
    }
    
    pub async fn flush(&self) -> Result<()> {
        // 确保写入持久化到磁盘
        self.writer.flush().await
    }
}
```

---

### 4.2 审批与沙箱

Codex 实现了多层安全机制来保护用户系统。

#### 4.2.1 审批策略（Approval Policy）

**三种审批模式：**

```rust
pub enum AskForApproval {
    Always,      // 总是询问
    OnRequest,   // 工具请求时询问（escalated permissions）
    OnFailure,   // 失败后询问
    Never,       // 从不询问（危险！）
}
```

**审批流程：**

```rust
// core/src/tools/handlers/shell.rs
async fn handle_shell_command(
    session: &Session,
    turn_context: &TurnContext,
    params: ExecParams,
) -> Result<ToolOutput> {
    // 1. 检查是否需要审批
    let needs_approval = match turn_context.approval_policy {
        AskForApproval::Always => true,
        AskForApproval::OnRequest => params.sandbox_permissions.is_escalated(),
        AskForApproval::OnFailure => false,
        AskForApproval::Never => false,
    };
    
    if needs_approval {
        // 2. 发送审批请求事件
        let decision = session.request_command_approval(
            turn_context,
            call_id,
            params.command.clone(),
            params.cwd.clone(),
            params.justification,
            proposed_execpolicy_amendment,
        ).await;
        
        // 3. 等待用户决策
        match decision {
            ReviewDecision::Approved => { /* 继续执行 */ },
            ReviewDecision::ApprovedExecpolicyAmendment { amendment } => {
                // 更新执行策略并执行
                session.persist_execpolicy_amendment(&amendment).await?;
            },
            ReviewDecision::Denied => {
                return Err(ToolCallError::ToolCallDenied);
            },
            ReviewDecision::Abort => {
                // 中止整个任务
                return Err(ToolCallError::TaskAborted);
            },
        }
    }
    
    // 4. 执行命令
    exec_command(params).await
}
```

**审批请求事件：**

```rust
EventMsg::ExecApprovalRequest(ExecApprovalRequestEvent {
    call_id: "tool-call-123",
    turn_id: "turn-1",
    command: vec!["rm", "-rf", "/important/data"],
    cwd: PathBuf::from("/project"),
    reason: Some("需要清理临时文件"),
    proposed_execpolicy_amendment: Some(ExecPolicyAmendment {
        allowed_prefix: "rm -rf /tmp/".to_string(),
    }),
    parsed_cmd: ParsedCommand { ... },
})
```

**用户响应：**

```rust
// 用户通过 UI 做出决策
Op::ExecApproval {
    id: "tool-call-123",
    decision: ReviewDecision::Approved,
}
```

---

#### 4.2.2 沙箱策略（Sandbox Policy）

**四种沙箱模式：**

```rust
pub enum SandboxPolicy {
    DangerFullAccess,      // 完全访问（仅测试用）
    AllowWritesToCwd,      // 只允许写当前目录
    ReadOnlyFilesystem,    // 只读文件系统
    ForbidNetwork,         // 禁止网络访问
}
```

**沙箱实现（Linux）：**

```rust
// core/src/sandboxing/linux.rs
pub async fn exec_with_sandbox(
    command: Vec<String>,
    cwd: PathBuf,
    sandbox_policy: &SandboxPolicy,
    sandbox_exe: &Path,
) -> Result<ExecOutput> {
    // 1. 构建沙箱参数
    let sandbox_args = match sandbox_policy {
        SandboxPolicy::AllowWritesToCwd => vec![
            "--ro-bind", "/", "/",           // 只读挂载根目录
            "--bind", &cwd, &cwd,            // 可写挂载工作目录
            "--unshare-net",                 // 隔离网络
            "--die-with-parent",             // 父进程退出时终止
        ],
        SandboxPolicy::ReadOnlyFilesystem => vec![
            "--ro-bind", "/", "/",
            "--unshare-net",
            "--die-with-parent",
        ],
        // ...
    };
    
    // 2. 使用 bubblewrap 执行
    let mut cmd = Command::new(sandbox_exe);  // /usr/bin/bwrap
    cmd.args(sandbox_args)
       .args(&["--", "sh", "-c"])
       .arg(command.join(" "))
       .current_dir(cwd);
    
    // 3. 执行并收集输出
    let output = cmd.output().await?;
    
    Ok(ExecOutput {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).to_string(),
    })
}
```

**沙箱权限升级：**

```rust
// 工具可以请求升级权限
pub enum SandboxPermissions {
    UseDefault,         // 使用策略默认权限
    RequireEscalated,   // 请求升级权限（触发审批）
}

// 示例：安装依赖需要写 /usr/local
shell_tool.call({
    command: "npm install -g typescript",
    sandbox_permissions: SandboxPermissions::RequireEscalated,
    justification: "需要安装全局依赖",
})
```

---

#### 4.2.3 执行策略（ExecPolicy）

**基于前缀的白名单：**

```toml
# ~/.codex/exec-policy.toml
[[allowed_prefixes]]
prefix = "git "
reason = "用户批准的 Git 操作"

[[allowed_prefixes]]
prefix = "npm install"
reason = "用户批准的依赖安装"

[[allowed_prefixes]]
prefix = "cargo build"
reason = "用户批准的构建命令"
```

**执行策略检查：**

```rust
// core/src/exec_policy.rs
impl ExecPolicyManager {
    pub async fn check_command(&self, command: &[String]) -> ExecPolicyResult {
        let cmd_str = command.join(" ");
        
        // 检查是否在白名单中
        for allowed in &self.allowed_prefixes {
            if cmd_str.starts_with(&allowed.prefix) {
                return ExecPolicyResult::Allowed;
            }
        }
        
        // 不在白名单，需要审批
        ExecPolicyResult::RequiresApproval {
            suggested_amendment: ExecPolicyAmendment {
                allowed_prefix: extract_prefix(&cmd_str),
            }
        }
    }
    
    // 用户批准后添加到策略
    pub async fn append_amendment(
        &self,
        codex_home: &Path,
        amendment: &ExecPolicyAmendment,
    ) -> Result<()> {
        // 1. 更新内存中的策略
        self.allowed_prefixes.push(amendment.clone());
        
        // 2. 持久化到文件
        let policy_path = codex_home.join("exec-policy.toml");
        write_policy_file(&policy_path, &self.allowed_prefixes).await?;
        
        Ok(())
    }
}
```

---

### 4.3 事件系统

事件系统是 Codex 与客户端通信的核心机制。

#### 4.3.1 事件类型

**核心事件分类：**

```rust
pub enum EventMsg {
    // 1. 会话生命周期
    SessionConfigured(SessionConfiguredEvent),  // 会话初始化完成
    ShutdownComplete,                           // 会话关闭
    
    // 2. 任务生命周期
    TaskStarted(TaskStartedEvent),              // 任务开始
    TurnAborted(TurnAbortedEvent),              // 轮次中止
    
    // 3. 流式内容
    AgentMessageContentDelta(AgentMessageContentDeltaEvent),  // AI 文本流
    ReasoningContentDelta(ReasoningContentDeltaEvent),        // 推理过程流
    
    // 4. 工具调用
    ExecApprovalRequest(ExecApprovalRequestEvent),  // 命令审批请求
    ApplyPatchApprovalRequest(...),                 // 文件修改审批
    
    // 5. 状态更新
    TokenCount(TokenCountEvent),                // Token 使用统计
    TurnDiff(TurnDiffEvent),                    // 文件变更 diff
    
    // 6. 错误和警告
    Error(ErrorEvent),                          // 错误
    Warning(WarningEvent),                      // 警告
    StreamError(StreamErrorEvent),              // 流错误
    
    // 7. 内部事件
    RawResponseItem(RawResponseItemEvent),      // 原始响应项
    BackgroundEvent(BackgroundEventEvent),      // 后台事件
}
```

---

#### 4.3.2 事件发送机制

**Session 统一发送入口：**

```rust
impl Session {
    pub async fn send_event(&self, turn_context: &TurnContext, msg: EventMsg) {
        // 1. 包装为 Event
        let event = Event {
            id: turn_context.sub_id.clone(),
            msg: msg.clone(),
        };
        
        // 2. 持久化到 rollout
        self.persist_rollout_items(&[RolloutItem::EventMsg(msg)]).await;
        
        // 3. 发送到事件通道
        if let Err(e) = self.tx_event.send(event).await {
            error!("failed to send event: {e}");
        }
        
        // 4. 发送兼容的遗留事件
        for legacy in msg.as_legacy_events() {
            let legacy_event = Event {
                id: turn_context.sub_id.clone(),
                msg: legacy,
            };
            self.tx_event.send(legacy_event).await.ok();
        }
    }
}
```

**流式事件示例：**

```rust
// 模型返回流式文本
loop {
    match stream.next().await {
        Some(ResponseEvent::OutputTextDelta(delta)) => {
            // 实时发送文本片段
            session.send_event(
                &turn_context,
                EventMsg::AgentMessageContentDelta(
                    AgentMessageContentDeltaEvent {
                        thread_id: session.conversation_id.to_string(),
                        turn_id: turn_context.sub_id.clone(),
                        item_id: active_item.id(),
                        delta: delta.clone(),
                    }
                )
            ).await;
        }
        Some(ResponseEvent::Completed { .. }) => break,
        _ => {}
    }
}
```

---

#### 4.3.3 Turn Items - 结构化事件

**TurnItem：** 对用户可见的高层事件抽象

```rust
pub enum TurnItem {
    UserMessage(UserMessageItem),      // 用户消息
    AgentMessage(AgentMessageItem),    // AI 消息
    ToolCall(ToolCallItem),            // 工具调用
    Reasoning(ReasoningItem),          // 推理过程（O1 模型）
}
```

**生命周期事件：**

```rust
// 1. 项开始
EventMsg::ItemStarted(ItemStartedEvent {
    thread_id: "conv-123",
    turn_id: "turn-1",
    item: TurnItem::ToolCall(ToolCallItem {
        id: "call-1",
        name: "shell",
        status: ToolCallStatus::InProgress,
    }),
})

// 2. 项完成
EventMsg::ItemCompleted(ItemCompletedEvent {
    thread_id: "conv-123",
    turn_id: "turn-1",
    item: TurnItem::ToolCall(ToolCallItem {
        id: "call-1",
        name: "shell",
        status: ToolCallStatus::Completed,
        output: Some("命令执行成功"),
    }),
})
```

---

### 4.4 错误处理与重试

Codex 实现了多层错误处理和自动重试机制。

#### 4.4.1 错误类型

```rust
// core/src/error.rs
pub enum CodexErr {
    // 1. 可恢复错误（会重试）
    Stream(String, Option<Duration>),  // 流断开
    
    // 2. 用户操作错误
    TurnAborted,                       // 用户中止
    Interrupted,                       // 用户中断
    
    // 3. 配额错误
    UsageLimitReached(UsageLimitError),  // 速率限制
    ContextWindowExceeded,               // 上下文超限
    QuotaExceeded,                       // 配额用尽
    
    // 4. 致命错误（不重试）
    Fatal(String),                     // 致命错误
    InvalidRequest(String),            // 无效请求
    EnvVar(String),                    // 环境变量缺失
    
    // 5. 内部错误
    InternalAgentDied,                 // 内部任务崩溃
}
```

---

#### 4.4.2 流断开重试机制

**自动重试策略：**

```rust
// core/src/codex.rs - run_turn()
let mut retries = 0;
loop {
    match try_run_turn(...).await {
        Ok(output) => return Ok(output),
        
        // 流断开 → 重试
        Err(CodexErr::Stream(msg, delay)) => {
            let max_retries = turn_context.client.get_provider().stream_max_retries();
            
            if retries < max_retries {
                retries += 1;
                let delay = delay.unwrap_or_else(|| backoff(retries));
                
                warn!("stream disconnected - retrying {retries}/{max_retries} in {delay:?}");
                
                // 通知用户正在重试
                session.notify_stream_error(
                    &turn_context,
                    format!("Reconnecting... {retries}/{max_retries}"),
                    err,
                ).await;
                
                tokio::time::sleep(delay).await;
                continue;  // 重试
            } else {
                return Err(CodexErr::Stream(msg, None));  // 超过最大重试次数
            }
        }
        
        // 其他错误 → 不重试
        Err(e) => return Err(e),
    }
}
```

**指数退避策略：**

```rust
// core/src/util.rs
pub fn backoff(attempt: usize) -> Duration {
    let base_ms = 1000;  // 1 秒
    let max_ms = 30000;  // 30 秒
    
    let delay_ms = (base_ms * 2_u64.pow(attempt as u32)).min(max_ms);
    Duration::from_millis(delay_ms)
}

// 重试延迟：1s, 2s, 4s, 8s, 16s, 30s, 30s, ...
```

---

#### 4.4.3 取消令牌（CancellationToken）

**优雅取消机制：**

```rust
// 为每个任务创建取消令牌
let cancellation_token = CancellationToken::new();

// 启动任务
tokio::spawn(async move {
    run_task(session, turn_context, input, cancellation_token.clone()).await
});

// 中止任务时
cancellation_token.cancel();  // 通知所有监听者

// 任务内部检查取消
async fn run_turn(..., cancellation_token: CancellationToken) -> Result<...> {
    let stream = client
        .stream(prompt)
        .or_cancel(&cancellation_token)  // ← 自动取消
        .await??;
    
    loop {
        let event = stream
            .next()
            .or_cancel(&cancellation_token)  // ← 自动取消
            .await?;
        
        // 处理事件...
    }
}
```

**取消传播：**

```rust
// 父任务取消会传播到子任务
let parent_token = CancellationToken::new();

// 创建子令牌
let child_token = parent_token.child_token();

// 启动子任务
tokio::spawn(async move {
    some_work(child_token).await
});

// 取消父令牌 → 自动取消所有子令牌
parent_token.cancel();
```

---

#### 4.4.4 错误恢复示例

**场景：处理 Token 超限**

```rust
async fn handle_token_limit(
    session: &Session,
    turn_context: &TurnContext,
) -> CodexResult<()> {
    // 1. 标记 token 已满
    session.set_total_tokens_full(turn_context).await;
    
    // 2. 尝试压缩历史
    if session.enabled(Feature::AutoCompact) {
        run_auto_compact(session, turn_context).await;
        
        // 3. 重新计算 token 使用
        session.recompute_token_usage(turn_context).await;
        
        let new_usage = session.get_total_token_usage().await;
        if new_usage < auto_compact_limit {
            // 压缩成功，可以继续
            return Ok(());
        }
    }
    
    // 4. 压缩后仍超限 → 返回错误
    Err(CodexErr::ContextWindowExceeded)
}
```

---

**第 4 章总结：**

1. **历史记录管理** - 内存历史、自动压缩、持久化三层体系
2. **审批与沙箱** - 多层安全机制保护用户系统
3. **事件系统** - 流式实时通信，结构化事件
4. **错误处理** - 自动重试、优雅取消、智能恢复

这些机制共同构成了 Codex 的健壮性和安全性基础。

---

## 5. 扩展机制

Codex 提供了多种扩展机制，让用户可以定制和增强系统功能。

### 5.1 MCP 服务器集成

（MCP 相关内容待补充）

---

### 5.2 Skills 技能系统

Skills 是 Codex 的可插拔扩展机制，允许用户为特定任务定义自动化流程。

#### 5.2.1 什么是 Skill？

**Skill = 一段结构化的指令 + 可选的工具绑定**

```markdown
# .codex/skills/python-test.md
---
name: python-test
description: Run pytest with coverage
scope: contextual
---

When the user asks to "run tests" in a Python project:

1. Check if pytest is installed:
   - Run `python -m pytest --version`
   - If not found, ask user to install

2. Run tests with coverage:
   - Command: `python -m pytest --cov=. --cov-report=html`
   - Working directory: project root

3. Summarize results:
   - Number of tests passed/failed
   - Coverage percentage
   - Link to HTML report
```

---

#### 5.2.2 Skill 的结构

**YAML Frontmatter（元数据）：**

```yaml
---
name: skill-name           # 唯一标识符
description: Short desc    # 简短描述
short_description: Shorter # 更短的描述（可选）
scope: contextual          # 作用域：contextual | always
---
```

**Markdown Body（指令内容）：**

```markdown
# 可以包含任何 Markdown 内容

## 使用场景
描述何时使用这个 Skill

## 操作步骤
1. 第一步
2. 第二步
3. 第三步

## 注意事项
- 注意点 1
- 注意点 2
```

---

#### 5.2.3 Skill 加载机制

**加载位置：**

```
.codex/
  └─ skills/
     ├─ python-test.md
     ├─ git-commit.md
     ├─ docker-build.md
     └─ ...
```

**加载时机：**

```rust
// core/src/codex.rs - Codex::spawn()
let loaded_skills = config
    .features
    .enabled(Feature::Skills)
    .then(|| skills_manager.skills_for_cwd(&config.cwd));

// 加载结果
struct SkillLoadOutcome {
    skills: Vec<SkillMetadata>,  // 成功加载的 Skills
    errors: Vec<SkillError>,     // 加载失败的 Skills
}
```

**注入时机：**

Skills 采用**懒注入**策略，只在需要时注入：

```rust
// core/src/codex.rs - run_task()
let SkillInjections {
    items: skill_items,
    warnings: skill_warnings,
} = build_skill_injections(&input, skills_outcome.as_ref()).await;

// 检测用户输入中是否显式提到 Skill
fn collect_explicit_skill_mentions(
    inputs: &[UserInput],
    skills: &[SkillMetadata],
) -> Vec<&SkillMetadata> {
    // 如果用户输入包含 "@skill-name"，则注入该 Skill
    inputs.iter()
        .filter_map(|input| {
            if let UserInput::Text { text } = input {
                skills.iter().find(|skill| text.contains(&format!("@{}", skill.name)))
            } else {
                None
            }
        })
        .collect()
}
```

---

#### 5.2.4 Skill 作用域

**两种作用域：**

```rust
pub enum SkillScope {
    Always,      // 总是注入到会话初始上下文
    Contextual,  // 仅在用户显式提到时注入
}
```

**示例：**

```markdown
# .codex/skills/project-conventions.md
---
name: project-conventions
scope: always  # 总是生效
---

This project follows these conventions:
- Use 2-space indentation
- Write tests in `tests/` directory
- Use conventional commits
```

```markdown
# .codex/skills/deploy.md
---
name: deploy
scope: contextual  # 仅在提到时生效
---

To deploy this project:
1. Build with `npm run build`
2. Upload to S3
3. Invalidate CloudFront cache
```

**使用方式：**

```
用户: "@deploy 帮我部署到生产环境"
      ^^^^^^^ 显式提到 skill

系统: 注入 deploy.md 的内容到上下文
```

---

#### 5.2.5 Skills 的注入格式

**注入到历史记录的格式：**

```rust
ResponseItem::Message {
    role: "user",
    content: vec![ContentItem::InputText {
        text: format!(
            "<skill name=\"{name}\" path=\"{path}\">\n{contents}\n</skill>",
            name = skill.name,
            path = skill.path.display(),
            contents = skill_contents
        )
    }]
}
```

**实际示例：**

```
<skill name="python-test" path=".codex/skills/python-test.md">
When the user asks to "run tests" in a Python project:

1. Check if pytest is installed...
2. Run tests with coverage...
3. Summarize results...
</skill>
```

---

### 5.3 自定义提示词（Custom Prompts）

自定义提示词允许用户快速调用预定义的 Prompt 模板。

#### 5.3.1 存储位置

```
~/.codex/prompts/
  ├─ review-code.md
  ├─ explain-diff.md
  ├─ write-tests.md
  └─ ...
```

#### 5.3.2 Prompt 文件格式

**简单文本：**

```markdown
# ~/.codex/prompts/review-code.md

Please review the code in the current file:
- Check for bugs
- Suggest improvements
- Verify best practices
```

**带变量的 Prompt：**

```markdown
# ~/.codex/prompts/explain-diff.md

Please explain the git diff between {{branch1}} and {{branch2}}:
- What changes were made?
- Why might these changes be important?
- Any potential issues?
```

#### 5.3.3 使用方式

**在 VS Code 中：**

1. 打开命令面板
2. 选择 "Codex: Use Custom Prompt"
3. 选择预定义的 Prompt
4. AI 根据 Prompt 执行任务

**API 调用：**

```rust
// app-server 可以支持加载自定义 Prompt
Op::ListCustomPrompts => {
    let prompts = custom_prompts::discover_prompts_in(&prompts_dir).await;
    // 返回 Prompt 列表
}
```

---

### 5.4 内置工具（Built-in Tools）

Codex 提供了丰富的内置工具供 AI 调用。

#### 5.4.0 工具定义位置

**源码位置：**

```
codex-rs/core/src/tools/
  ├── spec.rs              # 工具定义与注册
  │   ├── create_shell_tool()
  │   ├── create_exec_command_tool()
  │   ├── create_read_file_tool()
  │   ├── create_grep_files_tool()
  │   ├── create_apply_patch_*_tool()
  │   ├── create_view_image_tool()
  │   └── build_specs()    # 工具注册入口
  │
  └── handlers/            # 工具执行器
      ├── shell.rs
      ├── unified_exec.rs
      ├── read_file.rs
      ├── grep_files.rs
      ├── apply_patch.rs
      ├── view_image.rs
      ├── plan.rs
      ├── mcp.rs
      └── ...
```

**工具定义流程：**

```rust
// 1. 定义工具规格（Spec）
fn create_xxx_tool() -> ToolSpec {
    ToolSpec::Function(ResponsesApiTool {
        name: "tool_name",
        description: "What this tool does",
        parameters: JsonSchema::Object { /* ... */ },
    })
}

// 2. 实现工具处理器（Handler）
pub struct XxxHandler;

#[async_trait]
impl ToolHandler for XxxHandler {
    async fn handle(&self, invocation: ToolInvocation) -> Result<ToolOutput, Error> {
        // 实际执行逻辑
    }
}

// 3. 注册工具（在 build_specs() 中）
builder.push_spec(create_xxx_tool());
builder.register_handler("tool_name", Arc::new(XxxHandler));
```

---

#### 5.4.1 工具总览

**文件系统工具：**

| 工具名 | 描述 | 并行支持 | 定义位置 |
|--------|------|---------|---------|
| `read_file` | 读取文件内容 | ✅ | `spec.rs:create_read_file_tool()` |
| `list_dir` | 列出目录内容 | ✅ | `spec.rs:create_list_dir_tool()` |
| `grep_files` | 在文件中搜索文本 | ✅ | `spec.rs:create_grep_files_tool()` |

**命令执行工具：**

| 工具名 | 描述 | 特性 | 定义位置 |
|--------|------|------|---------|
| `shell` | 执行 shell 命令（传统） | 简单命令 | `spec.rs:create_shell_tool()` |
| `shell_command` | 执行 shell 脚本 | 支持登录 shell | `spec.rs:create_shell_command_tool()` |
| `exec_command` | PTY 会话执行 | 交互式命令 | `spec.rs:create_exec_command_tool()` |
| `write_stdin` | 向 PTY 会话写入 | 交互式输入 | `spec.rs:create_write_stdin_tool()` |

**文件修改工具：**

| 工具名 | 描述 | 格式 | 定义位置 |
|--------|------|------|---------|
| `apply_patch` | 应用代码补丁 | Freeform/Function 两种 | `spec.rs:create_apply_patch_*_tool()` |

**辅助工具：**

| 工具名 | 描述 | 用途 | 定义位置 |
|--------|------|------|---------|
| `update_plan` | 更新任务计划 | 任务规划 | `handlers/plan.rs:PLAN_TOOL` |
| `view_image` | 查看本地图片 | 多模态输入 | `spec.rs:create_view_image_tool()` |
| `web_search` | 网络搜索（特定模型） | 信息检索 | `ToolSpec::WebSearch` |

**MCP 资源工具：**

| 工具名 | 描述 | 定义位置 |
|--------|------|---------|
| `list_mcp_resources` | 列出 MCP 资源 | `spec.rs:create_list_mcp_resources_tool()` |
| `list_mcp_resource_templates` | 列出资源模板 | `spec.rs:create_list_mcp_resource_templates_tool()` |
| `read_mcp_resource` | 读取 MCP 资源 | `spec.rs:create_read_mcp_resource_tool()` |

---

#### 5.4.2 核心工具详解

##### 1. Shell 工具家族

**`shell` - 传统 Shell 工具**

```json
{
  "name": "shell",
  "parameters": {
    "command": ["bash", "-c", "ls -la"],
    "workdir": "/path/to/project",
    "timeout_ms": 30000,
    "sandbox_permissions": "use_default",
    "justification": "列出文件"
  }
}
```

**特点：**
- 命令数组形式
- 直接调用 `execvp()`
- 适合简单一次性命令

---

**`shell_command` - Shell 脚本工具**

```json
{
  "name": "shell_command",
  "parameters": {
    "command": "ls -la | grep .rs",
    "workdir": "/path/to/project",
    "login": true,
    "timeout_ms": 30000
  }
}
```

**特点：**
- 字符串形式（可用管道、重定向）
- 支持 login shell（加载 ~/.bashrc 等）
- 适合复杂 shell 脚本

---

**`exec_command` + `write_stdin` - 交互式 PTY**

```json
// 1. 启动交互式会话
{
  "name": "exec_command",
  "parameters": {
    "cmd": "python -i",
    "workdir": "/path/to/project",
    "yield_time_ms": 1000
  }
}
// 返回: { "session_id": 42, "output": ">>> " }

// 2. 向会话写入
{
  "name": "write_stdin",
  "parameters": {
    "session_id": 42,
    "chars": "print('Hello')\n",
    "yield_time_ms": 500
  }
}
// 返回: { "output": "Hello\n>>> " }
```

**特点：**
- 真正的 PTY（伪终端）
- 支持交互式程序（Python REPL、vim 等）
- 会话保持，可多次交互
- 自动管理会话生命周期

**使用场景：**
```
适合 exec_command:
  ✅ Python/Node REPL
  ✅ 数据库客户端（psql、mysql）
  ✅ 交互式调试器
  ✅ 长时间运行的进程

适合 shell/shell_command:
  ✅ 快速查询（ls、grep、find）
  ✅ 构建命令（npm build、cargo build）
  ✅ 简单脚本执行
```

---

##### 2. apply_patch - 文件修改工具

**两种格式：**

**Freeform 格式（推荐）：**

```
<<<<<<<<< path/to/file.rs
<<<<<<<<<
// 旧代码
fn old_function() {
    println!("old");
}
=========
// 新代码
fn new_function() {
    println!("new");
}
>>>>>>>>>
>>>>>>>>>
```

**Function 格式（结构化）：**

```json
{
  "name": "apply_patch",
  "parameters": {
    "changes": {
      "path/to/file.rs": {
        "old_content": "fn old_function() {\n    println!(\"old\");\n}",
        "new_content": "fn new_function() {\n    println!(\"new\");\n}"
      }
    },
    "reason": "重构函数名"
  }
}
```

**特点：**
- 批量修改多个文件
- 精确的上下文匹配
- 防止意外覆盖
- 可审批（如果启用）

---

##### 3. read_file - 文件读取工具

```json
{
  "name": "read_file",
  "parameters": {
    "path": "src/main.rs",
    "start_line": 10,
    "end_line": 50
  }
}
```

**特点：**
- 支持行范围读取
- 并行执行支持
- 自动处理编码

---

##### 4. grep_files - 文件搜索工具

```json
{
  "name": "grep_files",
  "parameters": {
    "pattern": "TODO",
    "path": "src/",
    "file_pattern": "*.rs",
    "case_sensitive": false
  }
}
```

**特点：**
- 正则表达式支持
- 文件类型过滤
- 递归搜索
- 并行执行

---

##### 5. update_plan - 任务规划工具

```json
{
  "name": "update_plan",
  "parameters": {
    "plan": {
      "tasks": [
        {
          "id": "task-1",
          "description": "实现用户登录",
          "status": "in_progress",
          "subtasks": [
            { "description": "设计数据库表", "status": "completed" },
            { "description": "实现 API", "status": "in_progress" }
          ]
        },
        {
          "id": "task-2",
          "description": "编写测试",
          "status": "pending"
        }
      ]
    }
  }
}
```

**特点：**
- 结构化任务追踪
- 支持子任务
- 状态管理
- UI 可视化展示

---

##### 6. view_image - 图片查看工具

```json
{
  "name": "view_image",
  "parameters": {
    "path": "/path/to/image.png"
  }
}
```

**功能：**
将本地图片附加到对话上下文，让 AI 可以"看到"图片内容。

**工作流程：**

```rust
// 1. AI 调用 view_image 工具
view_image({ "path": "screenshot.png" })

// 2. 处理器读取图片
let image_data = fs::read(&path).await?;

// 3. 发送 ViewImageToolCallEvent
session.emit_event(EventMsg::ViewImageToolCall {
    call_id: "call_123",
    path: PathBuf::from("screenshot.png")
});

// 4. 构建 UserInput::Image 并添加到历史
let image_input = UserInput::Image {
    image_data,
    media_type: "image/png"
};

// 5. 返回给 AI 确认消息
return ToolOutput {
    result: "Image attached to conversation context",
    events: vec![image_input]
};
```

**使用场景：**
```
用户："这张图有什么问题？"
AI：
  1. 调用 view_image("screenshot.png")
  2. 图片被添加到上下文
  3. 分析图片内容："图中的按钮位置不对齐..."
```

**特点：**
- 支持多模态输入（Vision 模型）
- 仅支持本地文件路径
- 图片数据会被编码为 Base64
- 受模型能力限制（如 GPT-4 Vision、Claude 3 等）

**事件流：**

```
Tool Call: view_image
    ↓
ViewImageToolCallEvent (app-server 处理)
    ↓
ItemStarted (ThreadItem::ImageView)
    ↓
图片添加到历史记录
    ↓
ItemCompleted (ThreadItem::ImageView)
    ↓
AI 可在后续对话中引用图片
```

**App-Server 处理：**

```rust
// bespoke_event_handling.rs
EventMsg::ViewImageToolCall(view_image_event) => {
    let item = ThreadItem::ImageView {
        id: view_image_event.call_id,
        path: view_image_event.path.to_string_lossy().into_owned(),
    };
    
    // 发送 ItemStarted 和 ItemCompleted 通知
    outgoing.send_notification(ItemStarted { item }).await;
    outgoing.send_notification(ItemCompleted { item }).await;
}
```

**注意事项：**
- 需要 `Feature::ViewImageTool` 启用
- 需要模型支持视觉能力
- 图片大小受限于上下文窗口
- 不会修改文件系统，只读取

---

#### 5.4.3 工具配置

**根据模型能力动态配置：**

```rust
// core/src/tools/spec.rs
impl ToolsConfig {
    pub fn new(params: &ToolsConfigParams) -> Self {
        let shell_type = if !features.enabled(Feature::ShellTool) {
            ConfigShellToolType::Disabled  // 禁用 shell
        } else if features.enabled(Feature::UnifiedExec) {
            ConfigShellToolType::UnifiedExec  // 使用 PTY
        } else {
            model_family.shell_type  // 模型默认
        };
        
        let apply_patch_tool_type = match model_family.apply_patch_tool_type {
            Some(ApplyPatchToolType::Freeform) => Some(Freeform),
            Some(ApplyPatchToolType::Function) => Some(Function),
            None => None,  // 不支持
        };
        
        // 实验性工具（需要显式启用）
        let experimental = model_family.experimental_supported_tools;
        
        Self {
            shell_type,
            apply_patch_tool_type,
            web_search_request: features.enabled(Feature::WebSearchRequest),
            include_view_image_tool: features.enabled(Feature::ViewImageTool),
            experimental_supported_tools: experimental,
        }
    }
}
```

**工具注册：**

```rust
// core/src/tools/spec.rs - build_specs()
let mut builder = ToolRegistryBuilder::new();

// 1. Shell 工具（根据配置）
match config.shell_type {
    ConfigShellToolType::UnifiedExec => {
        builder.push_spec(create_exec_command_tool());
        builder.push_spec(create_write_stdin_tool());
    }
    ConfigShellToolType::ShellCommand => {
        builder.push_spec(create_shell_command_tool());
    }
    ConfigShellToolType::Default => {
        builder.push_spec(create_shell_tool());
    }
    ConfigShellToolType::Disabled => {}
}

// 2. apply_patch（如果支持）
if let Some(patch_type) = config.apply_patch_tool_type {
    match patch_type {
        ApplyPatchToolType::Freeform => {
            builder.push_spec(create_apply_patch_freeform_tool());
        }
        ApplyPatchToolType::Function => {
            builder.push_spec(create_apply_patch_json_tool());
        }
    }
}

// 3. 实验性工具（显式启用）
if config.experimental_supported_tools.contains(&"read_file") {
    builder.push_spec_with_parallel_support(create_read_file_tool(), true);
}

if config.experimental_supported_tools.contains(&"grep_files") {
    builder.push_spec_with_parallel_support(create_grep_files_tool(), true);
}

// 4. 其他工具
builder.push_spec(PLAN_TOOL.clone());
if config.include_view_image_tool {
    builder.push_spec(create_view_image_tool());
}
```

---

#### 5.4.4 并行工具执行

**支持并行的工具：**

```rust
// 这些工具可以并行执行
builder.push_spec_with_parallel_support(create_read_file_tool(), true);
builder.push_spec_with_parallel_support(create_grep_files_tool(), true);
builder.push_spec_with_parallel_support(create_list_dir_tool(), true);
```

**并行执行示例：**

```
AI 请求:
  - read_file("src/main.rs")
  - read_file("src/lib.rs")  
  - grep_files("TODO", "src/")

执行:
  ┌─ read_file("src/main.rs") ───┐
  ├─ read_file("src/lib.rs") ────┤ 并行执行
  └─ grep_files("TODO", "src/") ─┘
       ↓ 全部完成
  返回结果给 AI
```

**并行策略：**

```rust
// core/src/tools/parallel.rs
pub enum ParallelStrategy {
    Parallel,    // 立即并行执行
    Sequential,  // 等待前序完成
}

// 由模型能力决定
let strategy = if model_supports_parallel && enabled(ParallelToolCalls) {
    ParallelStrategy::Parallel
} else {
    ParallelStrategy::Sequential
};
```

---

### 5.5 扩展机制总结

**三层扩展体系：**

```
1. Skills (项目级)
   └─ 为特定项目定制 AI 行为

2. Custom Prompts (用户级)
   └─ 个人常用的 Prompt 模板

3. MCP Servers (系统级)
   └─ 连接外部服务和工具
```

**工具生态：**

```
内置工具 (Built-in)
  ├─ 文件系统：read_file, list_dir, grep_files
  ├─ 命令执行：shell, exec_command, write_stdin
  ├─ 文件修改：apply_patch
  └─ 辅助工具：update_plan, view_image

MCP 工具 (External)
  └─ 通过 MCP 服务器提供的工具
```

**设计原则：**

1. **可组合性** - Skills、Prompts、Tools 可以组合使用
2. **渐进增强** - 从简单到复杂，逐步扩展
3. **安全优先** - 所有扩展都受审批和沙箱控制
4. **性能优化** - 懒加载、并行执行、智能缓存

---

## 6. 关键文件位置与作用

本章节列出 `codex-rs/core/src/` 中的关键文件及其功能，帮助快速定位代码。

### 6.1 核心入口与编排

#### 6.1.1 `codex.rs` ⭐⭐⭐⭐⭐
**最核心文件**，包含整个系统的主要逻辑。

**关键结构：**
- `Codex` - 用户接口，提供 `tx_sub` / `rx_event` 通道
- `Session` - 会话管理，维护状态和服务
- `TurnContext` - 单轮上下文
- `submission_loop()` - 核心事件循环

**主要职责：**
- Codex 生命周期管理（`spawn()`, `shutdown()`）
- Session 状态管理
- Submission → Task → Turn 的完整编排
- ReAct 循环的核心实现

**代码量：** ~3867 行

---

#### 6.1.2 `codex_conversation.rs`
**CodexConversation API** - App-Server 与 Core 交互的门面。

**关键 API：**
```rust
impl CodexConversation {
    pub async fn submit(&self, op: Op) -> Result<()>;
    pub async fn get_history(&self) -> ConversationHistory;
    pub async fn fork(&self, ...) -> Result<ConversationId>;
    pub async fn shutdown(&self) -> Result<()>;
}
```

**作用：**
- 封装 `tx_sub.send()` 为高层 API
- 提供类型安全的操作提交
- App-Server 的主要交互点

**代码量：** ~40 行（简洁的门面）

---

#### 6.1.3 `conversation_manager.rs`
**会话生命周期管理器** - 管理多个会话的创建、查找和清理。

**关键功能：**
```rust
pub struct ConversationManager {
    pub async fn spawn_conversation(...) -> CodexSpawnOk;
    pub async fn get_conversation(&self, id: ConversationId) -> Option<Arc<CodexConversation>>;
    pub async fn list_conversations(&self) -> Vec<ConversationId>;
    pub async fn shutdown_conversation(&self, id: ConversationId);
}
```

**使用场景：**
- App-Server 创建新会话
- 通过 ID 查找现有会话
- 会话清理和资源回收

**代码量：** ~412 行

---

### 6.2 任务执行（Tasks）

#### 6.2.1 `tasks/regular.rs` ⭐⭐⭐⭐
**常规任务执行** - 实现 ReAct 循环的核心。

**核心函数：**
```rust
pub(crate) async fn run_regular(
    turn: &TurnContext,
    session: &Session,
    input: InputForTurn,
) -> CodexResult<()>;
```

**主要流程：**
1. 调用 LLM 生成响应
2. 解析工具调用
3. 执行工具（通过 Orchestrator）
4. 将结果反馈给 LLM
5. 循环直到任务完成

**涉及组件：**
- `ToolOrchestrator` - 工具编排
- `ModelClient` - LLM 调用
- `ContextManager` - 上下文管理

---

#### 6.2.2 `tasks/review.rs`
**审批任务执行** - 处理需要人工审批的操作。

**使用场景：**
- 文件修改需要用户批准
- 命令执行需要确认
- 风险操作的安全检查

---

#### 6.2.3 `tasks/compact.rs`
**上下文压缩任务** - 当上下文超出限制时自动压缩。

**策略：**
- 保留最近的对话
- 删除中间历史
- 发送 `ContextCompacted` 事件

---

#### 6.2.4 `tasks/user_shell.rs`
**用户 Shell 任务** - 执行用户在 TUI 中直接输入的命令。

**特点：**
- 不经过 AI
- 直接执行 shell 命令
- 结果展示在 TUI 中

---

#### 6.2.5 `tasks/ghost_snapshot.rs`
**Ghost 快照任务** - 为 Undo 功能创建 Git 快照。

**工作流：**
1. 在每个 Turn 开始时创建 ghost commit
2. 记录文件系统状态
3. 用户执行 Undo 时恢复快照

---

#### 6.2.6 `tasks/undo.rs`
**撤销任务** - 恢复到之前的状态。

**依赖：**
- `ghost_snapshot.rs` 提供的快照
- Git 工作树操作

---

### 6.3 工具系统（Tools）

#### 6.3.1 `tools/spec.rs` ⭐⭐⭐⭐
**工具定义与注册中心**

**关键函数：**
```rust
fn create_shell_tool() -> ToolSpec;
fn create_exec_command_tool() -> ToolSpec;
fn create_read_file_tool() -> ToolSpec;
fn create_apply_patch_*_tool() -> ToolSpec;
// ... 所有内置工具的定义

pub(crate) fn build_specs(...) -> ToolRegistryBuilder;
```

**作用：**
- 定义所有内置工具的 JSON Schema
- 根据 Feature Flags 动态注册工具
- 工具配置（并行、沙箱权限等）

**代码量：** ~1100+ 行

---

#### 6.3.2 `tools/registry.rs`
**工具注册表** - 管理工具的查找和调用。

**核心结构：**
```rust
pub struct ToolRegistry {
    specs: Vec<ToolSpec>,
    handlers: HashMap<String, Arc<dyn ToolHandler>>,
}
```

**功能：**
- 工具查找
- Handler 路由
- 工具验证

---

#### 6.3.3 `tools/orchestrator.rs` ⭐⭐⭐⭐
**工具编排器** - 协调工具的并行/串行执行。

**核心逻辑：**
```rust
pub struct ToolOrchestrator;

impl ToolOrchestrator {
    pub async fn execute_tools(
        &self,
        tool_calls: Vec<ToolCall>,
        strategy: ParallelStrategy,
    ) -> Vec<ToolResult>;
}
```

**策略：**
- `Parallel` - 同时执行所有工具（如 read_file）
- `Sequential` - 顺序执行（如 apply_patch）

---

#### 6.3.4 `tools/handlers/*`
**工具处理器实现** - 每个工具的具体执行逻辑。

**文件列表：**
```
handlers/
  ├── shell.rs          # shell 工具执行
  ├── unified_exec.rs   # PTY 会话管理
  ├── read_file.rs      # 文件读取
  ├── grep_files.rs     # 文件搜索
  ├── list_dir.rs       # 目录列表
  ├── apply_patch.rs    # 文件修改
  ├── view_image.rs     # 图片加载
  ├── plan.rs           # 任务规划
  ├── mcp.rs            # MCP 工具调用
  └── mcp_resource.rs   # MCP 资源访问
```

---

#### 6.3.5 `tools/sandboxing.rs`
**工具沙箱机制** - 限制工具的文件系统和网络访问。

**功能：**
- Landlock（Linux）沙箱
- Windows Restricted Token
- 沙箱权限请求与审批

---

#### 6.3.6 `tools/router.rs`
**工具路由** - 将工具调用分发到正确的 Handler。

---

#### 6.3.7 `tools/parallel.rs`
**并行执行策略** - 决定工具是并行还是串行执行。

---

### 6.4 上下文管理（Context Manager）

#### 6.4.1 `context_manager/mod.rs` ⭐⭐⭐⭐
**上下文管理器** - 管理对话历史、工具结果和上下文窗口。

**核心结构：**
```rust
pub struct ContextManager {
    history: Vec<ResponseItem>,
    context_window: usize,
    token_counter: TokenCounter,
}
```

**功能：**
- 历史记录增删
- Token 计数
- 上下文溢出检测
- 压缩策略

---

#### 6.4.2 `context_manager/history.rs`
**历史记录操作** - 提供历史记录的增删改查。

---

#### 6.4.3 `context_manager/normalize.rs`
**历史记录规范化** - 清理和格式化历史记录。

---

### 6.5 配置系统（Config）

#### 6.5.1 `config/mod.rs` ⭐⭐⭐⭐
**配置加载与管理** - 解析 `config.toml` 和命令行参数。

**核心结构：**
```rust
pub struct Config {
    pub model: String,
    pub model_provider: String,
    pub features: Features,
    pub approval_policy: AskForApproval,
    pub sandbox_mode: SandboxMode,
    // ... 100+ 配置项
}
```

**功能：**
- 加载 TOML 配置文件
- 合并 Profile 配置
- CLI 参数覆盖
- 配置验证

**代码量：** ~2019 行

---

#### 6.5.2 `config/edit.rs`
**配置编辑器** - 运行时修改配置。

**API：**
```rust
ConfigEditor::new(codex_home)
    .set_model("gpt-4")
    .set_feature_enabled("view_image_tool", false)
    .apply().await?;
```

---

#### 6.5.3 `config/profile.rs`
**配置 Profile** - 支持多配置切换。

**使用场景：**
```toml
[profiles.gpt4]
model = "gpt-4"

[profiles.claude]
model = "claude-3-5-sonnet-20241022"
```

---

#### 6.5.4 `config/service.rs`
**配置服务** - 为多个组件提供配置访问。

---

### 6.6 特性系统（Features）

#### 6.6.1 `features.rs` ⭐⭐⭐
**Feature Flags 管理** - 动态开关功能。

**核心枚举：**
```rust
pub enum Feature {
    GhostCommit,
    ViewImageTool,
    ShellTool,
    UnifiedExec,
    ApplyPatchFreeform,
    WebSearchRequest,
    ExecPolicy,
    ParallelToolCalls,
    Skills,
    // ...
}
```

**使用方式：**
```rust
if features.enabled(Feature::ViewImageTool) {
    // 注册 view_image 工具
}
```

**代码量：** ~409 行

---

### 6.7 执行策略（Exec Policy）

#### 6.7.1 `exec_policy.rs`
**命令执行策略** - 控制哪些命令可以执行。

**策略类型：**
- Allow - 允许特定命令
- Deny - 拒绝特定命令
- Default - 默认行为

**示例：**
```toml
[exec_policy]
allow = ["git", "npm", "cargo"]
deny = ["rm -rf /"]
```

---

### 6.8 Shell 执行

#### 6.8.1 `shell.rs`
**Shell 工具执行** - 执行简单的 shell 命令。

---

#### 6.8.2 `bash.rs`
**Bash 特定逻辑** - Bash shell 的处理。

---

#### 6.8.3 `powershell.rs`
**PowerShell 特定逻辑** - Windows PowerShell 的处理。

---

#### 6.8.4 `exec.rs`
**通用命令执行** - 跨平台的命令执行抽象。

---

#### 6.8.5 `exec_env.rs`
**执行环境** - 管理命令执行的环境变量和工作目录。

---

### 6.9 持久化与历史（Rollout）

#### 6.9.1 `rollout/recorder.rs` ⭐⭐⭐
**会话录制器** - 记录会话历史到磁盘。

**功能：**
- 持久化对话历史
- 支持会话恢复
- 支持会话 Fork

**存储位置：**
```
~/.codex/rollout/
  └── {conversation_id}/
      ├── 0.json   # Turn 0
      ├── 1.json   # Turn 1
      └── ...
```

---

#### 6.9.2 `rollout/list.rs`
**会话列表** - 列出所有已保存的会话。

---

#### 6.9.3 `rollout/policy.rs`
**录制策略** - 控制哪些事件需要录制。

---

### 6.10 模型管理（Models Manager）

#### 6.10.1 `models_manager/manager.rs` ⭐⭐⭐
**模型管理器** - 管理可用的 AI 模型。

**功能：**
- 加载模型配置
- 查询模型能力
- 模型切换

---

#### 6.10.2 `models_manager/model_family.rs`
**模型家族定义** - 定义不同模型的能力。

**示例：**
```rust
pub struct ModelFamily {
    pub name: String,
    pub shell_type: ConfigShellToolType,
    pub apply_patch_tool_type: Option<ApplyPatchToolType>,
    pub supports_parallel_tool_calls: bool,
    pub supports_vision: bool,
    // ...
}
```

---

#### 6.10.3 `models_manager/model_presets.rs`
**模型预设** - 常见模型的默认配置。

---

### 6.11 客户端（Client）

#### 6.11.1 `client.rs`
**模型客户端接口** - 与 LLM API 交互的抽象。

**核心 Trait：**
```rust
pub trait ModelClient {
    async fn stream_responses(
        &self,
        history: Vec<ResponseItem>,
        tools: Vec<ToolSpec>,
    ) -> impl Stream<Item = ResponseChunk>;
}
```

---

#### 6.11.2 `default_client.rs`
**默认客户端实现** - OpenAI/ChatGPT 客户端。

---

#### 6.11.3 `client_common.rs`
**客户端公共逻辑** - 共享的客户端工具。

---

### 6.12 认证（Auth）

#### 6.12.1 `auth.rs`
**认证管理** - 管理 API Key 和 OAuth Token。

---

#### 6.12.2 `auth/storage.rs`
**认证存储** - 安全存储凭证。

---

### 6.13 MCP 集成

#### 6.13.1 `mcp_connection_manager.rs`
**MCP 连接管理器** - 管理与 MCP 服务器的连接。

**功能：**
- 启动 MCP 服务器进程
- 维护连接池
- 错误重连

---

#### 6.13.2 `mcp_tool_call.rs`
**MCP 工具调用** - 调用 MCP 服务器提供的工具。

---

### 6.14 辅助工具

#### 6.14.1 `apply_patch.rs`
**补丁应用** - 解析和应用文件补丁。

**支持格式：**
- Freeform（`<<<<<<<< ... >>>>>>>>>`）
- Function（JSON）

---

#### 6.14.2 `project_doc.rs`
**项目文档** - 读取 `AGENTS.md` 和 Skills。

**核心函数：**
```rust
pub(crate) async fn get_user_instructions(
    config: &Config,
    skills: Option<&[SkillMetadata]>,
) -> Option<String>;
```

---

#### 6.14.3 `custom_prompts.rs`
**自定义 Prompt** - 加载用户定义的 Prompt 模板。

---

#### 6.14.4 `git_info.rs`
**Git 信息** - 获取当前 Git 仓库状态。

---

#### 6.14.5 `error.rs`
**错误类型定义** - `CodexErr` 和错误处理。

---

#### 6.14.6 `util.rs`
**通用工具函数** - 杂项辅助函数。

---

### 6.15 文件结构总览

```
codex-rs/core/src/
├── codex.rs                    ⭐⭐⭐⭐⭐ 核心入口
├── codex_conversation.rs       ⭐⭐⭐⭐  API 门面
├── conversation_manager.rs     ⭐⭐⭐    会话管理
│
├── tasks/                      ⭐⭐⭐⭐  任务执行
│   ├── regular.rs              ReAct 循环
│   ├── review.rs               审批任务
│   ├── compact.rs              上下文压缩
│   ├── user_shell.rs           用户命令
│   ├── ghost_snapshot.rs       Git 快照
│   └── undo.rs                 撤销操作
│
├── tools/                      ⭐⭐⭐⭐  工具系统
│   ├── spec.rs                 工具定义
│   ├── registry.rs             工具注册
│   ├── orchestrator.rs         工具编排
│   ├── router.rs               工具路由
│   ├── parallel.rs             并行策略
│   ├── sandboxing.rs           沙箱
│   └── handlers/               工具实现
│       ├── shell.rs
│       ├── unified_exec.rs
│       ├── read_file.rs
│       ├── grep_files.rs
│       ├── apply_patch.rs
│       ├── view_image.rs
│       ├── plan.rs
│       └── mcp*.rs
│
├── context_manager/            ⭐⭐⭐⭐  上下文管理
│   ├── mod.rs
│   ├── history.rs
│   └── normalize.rs
│
├── config/                     ⭐⭐⭐⭐  配置系统
│   ├── mod.rs                  配置加载
│   ├── edit.rs                 配置编辑
│   ├── profile.rs              Profile
│   └── service.rs              配置服务
│
├── features.rs                 ⭐⭐⭐    Feature Flags
│
├── rollout/                    ⭐⭐⭐    会话持久化
│   ├── recorder.rs
│   ├── list.rs
│   └── policy.rs
│
├── models_manager/             ⭐⭐⭐    模型管理
│   ├── manager.rs
│   ├── model_family.rs
│   └── model_presets.rs
│
├── client.rs                   ⭐⭐⭐    LLM 客户端
├── default_client.rs
├── client_common.rs
│
├── auth.rs                     ⭐⭐      认证
├── auth/storage.rs
│
├── mcp_connection_manager.rs   ⭐⭐      MCP 集成
├── mcp_tool_call.rs
│
├── shell.rs                    ⭐⭐      Shell 执行
├── bash.rs
├── powershell.rs
├── exec.rs
├── exec_env.rs
├── exec_policy.rs
│
├── apply_patch.rs              ⭐⭐      文件修改
├── project_doc.rs              ⭐⭐      文档读取
├── custom_prompts.rs           ⭐        自定义 Prompt
├── git_info.rs                 ⭐        Git 工具
│
├── error.rs                    ⭐        错误类型
├── util.rs                     ⭐        工具函数
├── lib.rs                                库入口
│
└── [其他辅助文件...]
    ├── environment_context.rs
    ├── message_history.rs
    ├── token_data.rs
    ├── truncate.rs
    ├── turn_diff_tracker.rs
    ├── user_instructions.rs
    └── ...
```

---

### 6.16 快速查找指南

**想要理解核心流程？**
1. `codex.rs` - `submission_loop()` 和 `run_task()`
2. `tasks/regular.rs` - ReAct 循环实现
3. `tools/orchestrator.rs` - 工具执行编排

**想要添加新工具？**
1. `tools/spec.rs` - 定义工具 Schema
2. `tools/handlers/` - 实现工具 Handler
3. `tools/spec.rs:build_specs()` - 注册工具

**想要修改配置？**
1. `config/mod.rs` - 配置结构定义
2. `config/edit.rs` - 运行时修改配置

**想要理解审批流程？**
1. `tasks/review.rs` - 审批任务
2. `exec_policy.rs` - 命令策略
3. `tools/sandboxing.rs` - 沙箱机制

**想要理解会话管理？**
1. `conversation_manager.rs` - 会话生命周期
2. `codex_conversation.rs` - API 接口
3. `rollout/recorder.rs` - 持久化

**想要理解工具执行？**
1. `tools/spec.rs` - 工具定义
2. `tools/orchestrator.rs` - 编排器
3. `tools/handlers/` - 具体实现

---

## 7. 最佳实践与设计模式

### 6.1 异步并发设计

（待补充）

### 6.2 取消令牌（CancellationToken）模式

（待补充）

### 6.3 锁与状态管理

（待补充）

---

## 附录

### 关键类型定义速查

（待补充）

### 数据流向图

（待补充）
