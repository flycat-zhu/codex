# Codex × 豆包（doubao-seed-2-0-pro-260215）兼容性分析

> 基于 Codex 源码 commit `ad162f637`，分析 Codex 向豆包 Responses API 发送的请求结构与豆包实际支持情况。

## 豆包 Responses API 说明

豆包（Doubao / 火山引擎）实现了与 OpenAI Responses API 兼容的接口，但存在若干差异。
- Base URL：`https://ark.cn-beijing.volces.com/api/v3`
- Path：`/responses`
- 认证：`Authorization: Bearer <VOLC_API_KEY>`

---

## 请求字段兼容性

| 字段 | Codex 发送值 | 豆包支持情况 | 处理方式 |
|------|-------------|-------------|---------|
| `model` | `doubao-seed-2-0-pro-260215` | ✅ 支持 | 无需处理 |
| `instructions` | 系统 prompt 字符串 | ✅ 支持（等价于 system message）| 无需处理 |
| `input` | `ResponseItem[]`（含 message/reasoning/function_call 等）| ✅ 支持（Responses API 格式）| 部分 item type 需确认 |
| `tools` | `function[]` JSON 数组 | ✅ 支持 | 无需处理 |
| `tool_choice` | `"auto"` | ✅ 支持 | 无需处理 |
| `parallel_tool_calls` | `true/false` | ⚠️ 待确认 | 已有 `supports_parallel_tool_calls` 标志位控制，若豆包不支持需在 ModelInfo 中设为 false |
| `reasoning` | `{effort: "medium", summary: "auto"}` | ✅ 支持（doubao-seed 系列）| 无需处理 |
| `store` | `false`（非 Azure）| ✅（不发送或发 false 均可）| 无需处理 |
| `stream` | `true` | ✅ 支持 | 无需处理 |
| `include` | `[]`（非 OpenAI 时为空）| ✅ 修复后已正确处理 | **已修复** |
| `prompt_cache_key` | `None`（跳过序列化）| N/A | 无需处理 |
| `text`（verbosity/format）| `None`（`support_verbosity=false` 时跳过）| ❌ 豆包不支持 | 需确保 ModelInfo 中 `support_verbosity=false` |

---

## 流式响应事件兼容性

| 事件类型 | OpenAI 标准 | 豆包差异 | 处理方式 |
|---------|------------|---------|---------|
| `response.created` | ✅ | ✅ | 无需处理 |
| `response.output_item.added` | ✅ | ⚠️ 豆包的 Reasoning item 在 added 时 summary 为空 | 已加 `#[serde(default)]` |
| `response.output_item.done` | ✅ | ✅ | 无需处理 |
| `response.output_text.delta` | ✅ | ✅ | 无需处理 |
| `response.reasoning_summary_part.added` | 含 `item_id` at top level | ✅（豆包在顶层带 item_id）| **已修复**（合成占位 item）|
| `response.reasoning_summary_text.delta` | ✅ | ✅ | 无需处理 |
| `response.completed` | ✅ | 豆包可能用 `response.done` | 代码已同时处理两者 |
| `response.failed` | ✅ | ✅ | 无需处理 |

---

## 已知问题与修复

### 问题 1：`include` 字段包含豆包不识别的值
- **根因**：Codex 在有 reasoning 时发送 `include: ["reasoning.encrypted_content"]`，豆包不支持此字段值
- **修复方案**：在 `build_responses_request()` 中，仅当 `provider.is_openai()` 时才填充 include
- **文件**：`codex-rs/core/src/client.rs` 第 543 行
- **状态**：✅ 已修复（commit `ad162f637`）

### 问题 2：`ReasoningSummaryPartAdded` without active item panic
- **根因**：豆包的 SSE 事件顺序与 OpenAI 不同——`reasoning_summary_part.added` 在 `output_item.added` 之前到达，导致 `active_item` 为 `None` 时程序 panic
- **修复方案**：
  1. 在 `ReasoningSummaryPartAdded` 事件处理中，若 `active_item` 为空且事件携带 `item_id`，合成一个占位 `TurnItem::Reasoning`
  2. 其他 reasoning 相关的无 active_item 情况降级为 `warn!` 而非 panic
- **文件**：`codex-rs/core/src/codex.rs` 第 6401-6435 行；`codex-rs/codex-api/src/common.rs`（添加 `item_id` 字段）；`codex-rs/codex-api/src/sse/responses.rs`（解析 `item_id`）
- **状态**：✅ 已修复（commit `ad162f637`）

### 问题 3：Reasoning item 中 `content`/`encrypted_content` 字段导致 BadRequest
- **错误信息**：`unknown field "content"` in `input` parameter
- **根因**：`ResponseItem::Reasoning` 变体的 `content` 字段（`skip_serializing_if = should_serialize_reasoning_content`）在值为 `None` 时，该函数返回 `false`（不跳过），导致 serde 将其序列化为 `"content": null` 发送给豆包。豆包的 reasoning item 不接受 `content` 字段，报 `unknown field` 错误。同样 `encrypted_content: Option<String>` 也缺少 `skip_serializing_if` 保护。
- **修复方案**：
  1. `should_serialize_reasoning_content`：`None` 分支从 `false` 改为 `true`（None 时跳过序列化）
  2. `encrypted_content` 字段添加 `#[serde(skip_serializing_if = "Option::is_none")]`
- **影响评估**：**不影响任何 Codex 功能**。`content` 和 `encrypted_content` 有值时依然正常序列化发送，仅阻止 `null` 值出现在请求 JSON 中。OpenAI 侧行为不变（原本发 null 被忽略，现在不发，语义等价）。
- **文件**：`codex-rs/protocol/src/models.rs`（`should_serialize_reasoning_content` 函数，约第 628 行；`Reasoning` variant 第 226 行）
- **状态**：✅ 已修复（commit `db8b89dbc`）

### 问题 4：第二轮对话 `FunctionCall` item 缺少 `status` 字段导致 MissingParameter
- **错误信息**：`missing input.status parameter`（第二轮及后续对话）
- **根因**：`ResponseItem::FunctionCall` 结构体没有 `status` 字段。OpenAI 在 `output_item.done` 事件中会带上 `status: "completed"`，但 Codex 反序列化时直接丢弃了该字段（结构体无对应字段）。第二轮对话把第一轮的 `FunctionCall` 历史放入 `input` 时，豆包要求 `status` 必须存在，于是报 `MissingParameter`。
- **修复方案**：给 `FunctionCall` 添加 `status: String` 字段，使用 `#[serde(default = "default_status_completed")]` 保证反序列化缺失时默认为 `"completed"`，从而在下一轮 input 中正确携带该字段。
- **影响评估**：**不影响任何 Codex 功能**。OpenAI 本就会在此字段发送 `"completed"`，补全后行为与 OpenAI 侧完全一致。
- **文件**：`codex-rs/protocol/src/models.rs`（`FunctionCall` variant；`default_status_completed` 函数）
- **状态**：✅ 已修复（commit `b3113e84e`）

### 问题 5：第二轮对话 `Reasoning` item 缺少 `status` 字段导致 MissingParameter
- **错误信息**：`missing input.status parameter`（第二轮及后续对话，与问题 4 相同表现）
- **根因**：`ResponseItem::Reasoning` 结构体同样缺少 `status` 字段。当模型在第一轮返回推理 item（reasoning），第二轮把它带入 input 历史时，豆包要求该 item 必须携带 `status`。
- **修复方案**：给 `Reasoning` 添加 `status: String` 字段，`#[serde(default = "default_status_completed")]`，默认 `"completed"`。
- **影响评估**：与问题 4 修复相同，不影响 Codex 功能，与 OpenAI 行为一致。
- **文件**：`codex-rs/protocol/src/models.rs`（`Reasoning` variant）
- **状态**：✅ 已修复（commit `b907ae7ab`），镜像 `4.5` 构建中

### 问题 6：ModelInfo 中豆包模型配置缺失（待验证）
- **根因**：`doubao-seed-2-0-pro-260215` 是推理模型，需要正确的 ModelInfo（`supports_reasoning_summaries=true`，`parallel_tool_calls` 等）
- **修复方案**：在用户 `config.toml` 的 `[model_providers.volcengine]` 下，或通过 Codex 的 models.json 注入正确的 ModelInfo
- **状态**：🔍 待验证（取决于运行时 models.json 返回值）

---

## 构建与测试历史

| 时间 | 操作 | 镜像 tag | 结果 |
|------|-----|---------|-----|
| 2026-03-10 之前 | include 字段修复 + 首次构建 | `3.1` | ✅ 编译成功，已构建 |
| 2026-03-10 09:x | OutputTextDelta without active item 修复 | `4.1` | ✅ 编译成功 |
| 2026-03-10 19:43 | config.toml TOML 顺序修复 + 重建 | `4.2` | ✅ 镜像构建完成 |
| 2026-03-11 10:48 | Reasoning content/encrypted_content null 字段修复 | `4.3` | ✅ 镜像构建完成，测试通过（豆包正常推理响应）|
| 2026-03-11 12:24 | FunctionCall 缺失 status 字段修复 | `4.4` | ✅ 构建完成，但测试发现 Reasoning item 同样缺 status |
| 2026-03-11 13:3x | Reasoning 缺失 status 字段修复 | `4.5`（构建中）| 🔧 进行中 |

---

## 后续待检查项

1. **`parallel_tool_calls` 字段**：豆包是否支持？如不支持，应在 volcengine provider 对应 ModelInfo 中标记 `supports_parallel_tool_calls: false`
2. **`tool_choice` 枚举值**：豆包是否接受 `"auto"` / `"none"` / `"required"`？
3. **`Reasoning.effort` 值域**：豆包接受 `"low"/"medium"/"high"` 还是其他？
4. **工具 JSON 中 `strict` 字段**：豆包对 function tool 的 JSON Schema strict mode 支持情况
5. **WebSocket 推理路径**：豆包不支持 Responses WebSocket，Codex 应走 SSE 路径（需确认 `disable_websockets` 逻辑正确）

---

*文件由 Claw 自动维护，每次修复后更新。*
