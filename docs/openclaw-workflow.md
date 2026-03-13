# OpenClaw 通用代码工程工作流

## 概述

OpenClaw 工作流系统允许用户通过定义结构化的 YAML 工作流文件，指导 AI 代理按照标准化的流程完成软件项目开发。工作流定义了从需求分析到项目交付的完整生命周期。

## 工作流文件格式

工作流文件使用 YAML 格式，包含以下主要部分：

### 基本结构

```yaml
workflow:
  name: string          # 工作流名称
  version: string       # 工作流版本
  description: string   # 工作流描述
  
  phases:              # 阶段列表
    - phase: PhaseName
      description: string
      tasks: [...]
      validation: {...}
      next_phase: string | null
```

### 阶段（Phase）定义

每个阶段包含：

- **phase**: 阶段标识符（唯一）
- **description**: 阶段描述
- **tasks**: 任务列表
- **validation**: 验证规则
- **next_phase**: 下一阶段（null 表示结束）
- **parallel**: 是否允许并行执行（可选，默认 false）

### 任务（Task）定义

每个任务包含：

- **id**: 任务唯一标识
- **name**: 任务名称
- **description**: 任务描述
- **prompt**: 发送给 AI 的提示词模板
- **inputs**: 输入要求
- **outputs**: 输出要求
- **validation**: 任务级验证规则
- **dependencies**: 依赖的任务 ID 列表（可选）
- **tools**: 允许使用的工具列表（可选）

### 验证（Validation）定义

验证规则包含：

- **files**: 必须生成的文件列表
- **commands**: 必须成功执行的命令列表
- **checks**: 自定义检查项
- **manual_review**: 是否需要人工审核

## 工作流执行流程

1. **加载工作流文件**：解析 YAML 并验证格式
2. **初始化项目**：创建工作目录和基础结构
3. **按阶段执行**：
   - 对于每个阶段，按顺序执行任务
   - 执行任务验证
   - 如果验证失败，允许重试或人工介入
   - 完成阶段验证
4. **生成项目报告**：汇总所有阶段的输出和状态

## 示例

参见 `openclaw-workflow-example.yaml` 文件。

## 集成到 Codex

工作流可以通过以下方式集成：

1. **作为 Skill**：将工作流定义为 Codex Skill，通过 `codex skills` 命令加载
2. **作为 Agent**：将工作流定义为 Agent 配置，通过 Agent 系统执行
3. **直接执行**：通过 `codex workflow run <workflow-file>` 命令执行

## 最佳实践

1. **阶段划分清晰**：每个阶段应该有明确的输入和输出
2. **验证充分**：为每个阶段定义明确的验证标准
3. **错误处理**：定义失败时的回退策略
4. **可扩展性**：使用模板变量支持不同项目类型
5. **文档完善**：为每个任务提供清晰的描述和示例
