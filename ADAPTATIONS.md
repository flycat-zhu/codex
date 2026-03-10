# Codex 源码适配性修改记录

本文档记录针对 Codex 源码进行的适配性修改，用于兼容火山引擎等不支持某些特性的 LLM 服务。

## 修改概览

| 序号 | 修改项 | 修改时间 | 状态 | 影响范围 |
|------|--------|----------|------|----------|
| 1 | 禁用 FreeformTool (tool.type=custom) | 2026-03-04 | ✅ 已生效 | 工具过滤 |
| 2 | 禁用 WebSearch 工具 | 2026-03-04 | ✅ 已生效 | 工具过滤 |
| 3 | 禁用 prompt_cache_key 字段 | 2026-03-04 | ✅ 已生效 | API 请求参数 |
| 4 | 禁用 include 字段（空数组时） | 2026-03-04 | ✅ 已生效 | API 请求参数 |

---

## 详细修改记录

### 1. 禁用 FreeformTool (tool.type=custom)

#### 修改时间
2026-03-04

#### 修改位置
- **文件**: `codex-rs/core/src/tools/spec.rs`
- **函数**: `create_tools_json_for_responses_api`
- **行号**: 1466-1469

#### 修改内容

**修改前**:
```rust
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> crate::error::Result<Vec<serde_json::Value>> {
    let mut tools_json = Vec::new();

    for tool in tools {
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }

    Ok(tools_json)
}
```

**修改后**:
```rust
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> crate::error::Result<Vec<serde_json::Value>> {
    let mut tools_json = Vec::new();

    for tool in tools {
        // Filter out Freeform tools as they are not supported by some LLMs
        if matches!(tool, ToolSpec::Freeform(_)) {
            continue;
        }
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }

    Ok(tools_json)
}
```

#### 特性说明
**FreeformTool 的主要用途**:
- FreeformTool 是一种允许 LLM 使用自由格式文本（非 JSON）调用工具的方式
- 在 Codex 中主要用于：
  - `js_repl`: JavaScript REPL 工具，允许直接执行 JavaScript 代码
  - `apply_patch`: 补丁应用工具，支持自由格式的补丁输入
- 工具定义包含 `name`、`description` 和 `format`（包括 `type`、`syntax`、`definition` 等）
- 序列化到 API 请求时，`ToolSpec::Freeform` 会被映射为 `{"type": "custom", ...}`

**为何被屏蔽**:
- 火山引擎等部分 LLM 服务不支持 `tool.type=custom` 这种工具类型
- 当发送包含 `custom` 类型工具的消息时，会导致 API 调用失败
- 为了确保兼容性，选择在序列化工具列表时直接过滤掉所有 FreeformTool

#### 影响范围
- 禁用后，`js_repl` 和自由格式的 `apply_patch` 工具将不会出现在发送给 LLM 的工具列表中
- 如果代码中依赖这些工具，可能需要使用替代方案（如函数式工具）

#### 验证状态
✅ **已生效** - 修改后重新编译并测试，确认不再发送 `tool.type=custom` 的工具

---

### 2. 禁用 WebSearch 工具

#### 修改时间
2026-03-04

#### 修改位置
- **文件**: `codex-rs/core/src/tools/spec.rs`
- **函数**: `create_tools_json_for_responses_api`
- **行号**: 1470-1473

#### 修改内容

**修改前**:
```rust
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> crate::error::Result<Vec<serde_json::Value>> {
    let mut tools_json = Vec::new();

    for tool in tools {
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }

    Ok(tools_json)
}
```

**修改后**:
```rust
pub fn create_tools_json_for_responses_api(
    tools: &[ToolSpec],
) -> crate::error::Result<Vec<serde_json::Value>> {
    let mut tools_json = Vec::new();

    for tool in tools {
        // Filter out WebSearch tools as they are not supported by some LLMs
        if matches!(tool, ToolSpec::WebSearch { .. }) {
            continue;
        }
        let json = serde_json::to_value(tool)?;
        tools_json.push(json);
    }

    Ok(tools_json)
}
```

#### 配置方式
除了代码层面的过滤，**配置文件也进行了禁用**：
- **配置文件**: `~/.codex/config.toml` 或 `.codex/config.toml`
- **配置项**: 
  ```toml
  web_search = "disabled"
  ```

#### 特性说明
**WebSearch 工具的主要用途**:
- WebSearch 工具允许 LLM 执行网络搜索操作
- 支持两种模式：
  - `Cached`: 使用缓存的搜索结果
  - `Live`: 实时网络搜索（需要 `external_web_access: true`）
- 工具定义包含 `external_web_access` 字段，用于控制是否允许实时网络访问

**为何被屏蔽**:
- 火山引擎等部分 LLM 服务不支持 `web_search` 工具类型
- 即使通过配置设置 `web_search = "disabled"`，在某些情况下仍可能被发送（如 feature flags 覆盖）
- 为了确保兼容性，选择在代码层面直接过滤掉所有 WebSearch 工具

#### 影响范围
- 禁用后，LLM 将无法使用网络搜索功能
- 如果需要搜索功能，可能需要通过其他方式实现（如通过 MCP 服务器）

#### 验证状态
✅ **已生效** - 修改后重新编译并测试，确认不再发送 `web_search` 工具

---

### 3. 禁用 prompt_cache_key 字段

#### 修改时间
2026-03-04

#### 修改位置
- **文件**: `codex-rs/core/src/client.rs`
- **函数**: `build_responses_api_request`
- **行号**: 560

#### 修改内容

**修改前**:
```rust
let text = create_text_param_for_request(verbosity, &prompt.output_schema);
let prompt_cache_key = Some(self.client.state.conversation_id.to_string());
let request = ResponsesApiRequest {
    model: model_info.slug.clone(),
    instructions: instructions.clone(),
    input,
    tools,
    tool_choice: "auto".to_string(),
    parallel_tool_calls: prompt.parallel_tool_calls,
    reasoning,
    store: provider.is_azure_responses_endpoint(),
    stream: true,
    include,
    prompt_cache_key,
    text,
};
```

**修改后**:
```rust
let text = create_text_param_for_request(verbosity, &prompt.output_schema);
let prompt_cache_key = None;
let request = ResponsesApiRequest {
    model: model_info.slug.clone(),
    instructions: instructions.clone(),
    input,
    tools,
    tool_choice: "auto".to_string(),
    parallel_tool_calls: prompt.parallel_tool_calls,
    reasoning,
    store: provider.is_azure_responses_endpoint(),
    stream: true,
    include,
    prompt_cache_key,
    text,
};
```

#### 特性说明
**prompt_cache_key 的主要用途**:
- `prompt_cache_key` 是 OpenAI Responses API 的一个可选参数
- 用于 prompt caching 功能，允许 LLM 服务缓存相同的 prompt 前缀
- 使用 `conversation_id` 作为缓存 key，使得同一对话的重复请求可以复用缓存
- 可以显著减少重复 prompt 的 token 消耗和响应时间

**为何被屏蔽**:
- 火山引擎等部分 LLM 服务不支持 `prompt_cache_key` 参数
- 当请求中包含该字段时，会返回错误：
  ```
  "json: unknown field \"prompt_cache_key\""
  ```
- 为了确保兼容性，选择直接将该字段设置为 `None`
- 由于 `ResponsesApiRequest` 结构体中该字段有 `#[serde(skip_serializing_if = "Option::is_none")]` 属性，设置为 `None` 后不会被序列化到请求中

#### 影响范围
- 禁用后，将无法使用 prompt caching 功能
- 可能导致重复 prompt 的 token 消耗增加
- 对功能影响较小，主要是性能优化特性的缺失

#### 验证状态
✅ **已生效** - 修改后重新编译并测试，确认不再发送 `prompt_cache_key` 字段，API 调用成功

---

### 4. 禁用 include 字段（空数组时）

#### 修改时间
2026-03-04

#### 修改位置
- **文件**: `codex-rs/codex-api/src/common.rs`
- **结构体**: `ResponsesApiRequest` 和 `ResponseCreateWsRequest`
- **行号**: 156, 198

#### 修改内容

**修改前**:
```rust
#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct ResponsesApiRequest {
    pub model: String,
    pub instructions: String,
    pub input: Vec<ResponseItem>,
    pub tools: Vec<serde_json::Value>,
    pub tool_choice: String,
    pub parallel_tool_calls: bool,
    pub reasoning: Option<Reasoning>,
    pub store: bool,
    pub stream: bool,
    pub include: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_cache_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<TextControls>,
}
```

**修改后**:
```rust
#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct ResponsesApiRequest {
    pub model: String,
    pub instructions: String,
    pub input: Vec<ResponseItem>,
    pub tools: Vec<serde_json::Value>,
    pub tool_choice: String,
    pub parallel_tool_calls: bool,
    pub reasoning: Option<Reasoning>,
    pub store: bool,
    pub stream: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub include: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_cache_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<TextControls>,
}
```

同样的修改也应用于 `ResponseCreateWsRequest` 结构体。

#### 特性说明
**include 字段的主要用途**:
- `include` 是 OpenAI Responses API 的一个可选参数
- 用于指定响应中需要包含的额外字段
- 当使用 `reasoning` 功能时，需要设置 `include: ["reasoning.encrypted_content"]` 以在响应中包含加密的推理内容
- 代码中会根据是否有 `reasoning` 来决定是否设置 `include`：
  ```rust
  let include = if reasoning.is_some() {
      vec!["reasoning.encrypted_content".to_string()]
  } else {
      Vec::new()
  };
  ```

**为何被屏蔽**:
- 火山引擎等部分 LLM 服务不支持 `include` 参数
- 即使 `include` 是空数组 `[]`，也会被序列化到 JSON 请求中
- 当请求中包含该字段时（即使是空数组），会返回错误：
  ```
  "The parameter `include` specified in the request are not valid: include is not supported"
  ```
- 为了确保兼容性，添加 `#[serde(skip_serializing_if = "Vec::is_empty")]` 属性，使得当 `include` 为空向量时不会被序列化到请求中
- 这样既保持了功能的完整性（当需要 `reasoning` 时仍可使用），又避免了空数组导致的兼容性问题

#### 影响范围
- 当 `include` 为空数组时，不会被序列化到请求中，避免火山引擎报错
- 当需要使用 `reasoning` 功能时，`include` 仍会正常包含 `["reasoning.encrypted_content"]`，功能不受影响
- 对功能影响较小，主要是修复了兼容性问题

#### 验证状态
✅ **已生效** - 修改后重新编译并测试，确认空数组时不再发送 `include` 字段，API 调用成功

---

## 测试验证

### 验证方法
1. 重新编译 Codex 项目
2. 使用火山引擎作为 model provider 进行测试
3. 检查发送给 LLM 的请求，确认：
   - 不包含 `tool.type=custom` 的工具
   - 不包含 `web_search` 工具
   - 不包含 `prompt_cache_key` 字段
   - 当 `include` 为空数组时，不包含 `include` 字段

### 测试命令
```bash
# 编译项目
cd codex-rs
cargo build --release

# 运行测试
cargo test -p codex-core
```

---

## 后续维护

### 添加新适配项
当需要进行新的适配性修改时，请按照以下格式添加到本文档：

```markdown
### N. [修改项名称]

#### 修改时间
YYYY-MM-DD

#### 修改位置
- **文件**: `文件路径`
- **函数/类**: `函数或类名`
- **行号**: `行号范围`

#### 修改内容
[代码片段或说明]

#### 特性说明
[详细说明该特性的用途和为何被屏蔽]

#### 影响范围
[说明修改的影响]

#### 验证状态
[ ] 待验证 / ✅ 已生效 / ❌ 未生效
```

### 更新记录
- 每次修改后，更新对应条目的"验证状态"
- 如果发现问题，在对应条目下添加"问题记录"部分
- 定期检查已修改的代码是否因上游更新而失效

---

## 相关资源

- Codex 官方文档: https://developers.openai.com/codex
- 火山引擎 API 文档: [相关链接]
- Codex GitHub: [相关链接]

---

## 注意事项

1. **上游更新风险**: 当 Codex 上游代码更新时，需要检查这些适配性修改是否仍然有效
2. **功能影响**: 禁用某些特性可能会影响 Codex 的完整功能，需要评估是否可接受
3. **测试覆盖**: 每次修改后都应该进行充分测试，确保不会引入新的问题
4. **文档同步**: 如果修改了代码逻辑，需要同步更新本文档

---

**文档维护者**: [您的名字]  
**最后更新**: 2026-03-04
