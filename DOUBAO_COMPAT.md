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

### 问题 3：ModelInfo 中豆包模型配置缺失（待验证）
- **根因**：`doubao-seed-2-0-pro-260215` 是推理模型，需要正确的 ModelInfo（`supports_reasoning_summaries=true`，`parallel_tool_calls` 等）
- **修复方案**：在用户 `config.toml` 的 `[model_providers.volcengine]` 下，或通过 Codex 的 models.json 注入正确的 ModelInfo
- **状态**：🔍 待验证（取决于运行时 models.json 返回值）

---

## 构建与测试历史

| 时间 | 操作 | 镜像 tag | 结果 |
|------|-----|---------|-----|
| 2026-03-10 之前 | include 字段修复 + 首次构建 | `3.1` | ✅ 编译成功，已构建 |
| 2026-03-10 | ReasoningSummaryPartAdded 修复，编译中 | `4.0`（目标）| 🔧 进行中 |

---

## 后续待检查项

1. **`parallel_tool_calls` 字段**：豆包是否支持？如不支持，应在 volcengine provider 对应 ModelInfo 中标记 `supports_parallel_tool_calls: false`
2. **`tool_choice` 枚举值**：豆包是否接受 `"auto"` / `"none"` / `"required"`？
3. **`Reasoning.effort` 值域**：豆包接受 `"low"/"medium"/"high"` 还是其他？
4. **工具 JSON 中 `strict` 字段**：豆包对 function tool 的 JSON Schema strict mode 支持情况
5. **WebSocket 推理路径**：豆包不支持 Responses WebSocket，Codex 应走 SSE 路径（需确认 `disable_websockets` 逻辑正确）

---

*文件由 Claw 自动维护，每次修复后更新。*
