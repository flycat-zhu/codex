# OpenClaw 工作流执行指南

## 简介

本指南说明如何使用 OpenClaw 工作流系统来执行标准化的软件项目开发流程。

## 快速开始

### 1. 准备工作流文件

使用提供的示例工作流文件，或根据项目需求自定义：

```bash
# 使用示例工作流
cp openclaw-workflow-example.yaml my-project-workflow.yaml

# 编辑工作流文件，根据项目需求调整
vim my-project-workflow.yaml
```

### 2. 准备用户需求

创建一个需求文件或直接在命令行提供：

```bash
# 方式 1: 使用文件
echo "我需要一个 Python CLI 工具，用于批量重命名文件，支持正则表达式" > requirements.txt

# 方式 2: 直接在命令中提供
codex workflow run my-project-workflow.yaml --requirement "我需要一个 Python CLI 工具..."
```

### 3. 执行工作流

```bash
# 基本执行
codex workflow run my-project-workflow.yaml --requirement "你的项目需求"

# 指定项目目录
codex workflow run my-project-workflow.yaml \
  --requirement "你的项目需求" \
  --output-dir ./my-project

# 从检查点恢复
codex workflow run my-project-workflow.yaml \
  --resume-from-checkpoint .openclaw/checkpoints/phase_3
```

## 工作流文件自定义

### 模板变量

工作流文件支持以下模板变量，这些变量会在执行时被替换：

- `${PROJECT_NAME}`: 项目名称（从需求中提取或用户指定）
- `${PROJECT_TYPE}`: 项目类型（web, cli, library, api 等）
- `${LANGUAGE}`: 编程语言（python, rust, typescript 等）
- `${PROJECT_DESCRIPTION}`: 项目描述
- `${USER_REQUIREMENT}`: 用户原始需求

### 自定义阶段

你可以添加、删除或修改阶段：

```yaml
phases:
  - phase: "custom_phase"
    description: "自定义阶段"
    tasks:
      - id: "custom_task"
        name: "自定义任务"
        prompt: "执行自定义任务..."
```

### 调整验证规则

为每个阶段或任务定义验证规则：

```yaml
validation:
  files:
    - "required-file.txt"
  commands:
    - "test -f required-file.txt"
  checks:
    - "文件应包含特定内容"
  manual_review: true
```

## 执行模式

### 1. 自动模式

完全自动执行，只在需要人工审核时暂停：

```bash
codex workflow run workflow.yaml --auto
```

### 2. 交互模式（默认）

在每个阶段完成后暂停，等待用户确认：

```bash
codex workflow run workflow.yaml
```

### 3. 检查点模式

定期保存检查点，支持中断后恢复：

```bash
codex workflow run workflow.yaml --checkpoint-interval 1
```

## 监控和调试

### 查看执行日志

```bash
# 实时查看日志
codex workflow run workflow.yaml --verbose

# 查看历史日志
cat .openclaw/logs/workflow-*.log
```

### 检查执行状态

```bash
# 查看当前阶段
codex workflow status

# 查看检查点
ls .openclaw/checkpoints/
```

### 调试特定任务

如果某个任务失败，可以单独重新执行：

```bash
codex workflow run-task workflow.yaml --task-id "req_1" --phase "requirements_analysis"
```

## 最佳实践

### 1. 需求描述

提供清晰、详细的需求描述：

**好的需求：**
```
我需要一个 Python CLI 工具，用于批量重命名文件。
功能要求：
- 支持正则表达式匹配和替换
- 支持预览模式（不实际重命名）
- 支持递归处理子目录
- 支持备份原文件
- 提供详细的日志输出

技术偏好：
- Python 3.10+
- 使用 click 库处理命令行参数
- 支持 Windows、macOS 和 Linux
```

**不好的需求：**
```
做一个文件重命名工具
```

### 2. 工作流定制

根据项目类型选择或定制工作流：

- **简单 CLI 工具**：可以跳过架构设计阶段，直接实现
- **复杂 Web 应用**：需要完整的架构设计和多个实现阶段
- **库项目**：重点关注 API 设计和文档

### 3. 验证规则

为关键阶段设置严格的验证规则：

```yaml
validation:
  files:
    - "src/main.py"
    - "tests/test_main.py"
  commands:
    - "python -m pytest"
  checks:
    - "所有测试应通过"
    - "代码覆盖率 > 80%"
  manual_review: true
```

### 4. 错误处理

工作流支持自动重试，但建议：

- 设置合理的 `max_retries`
- 在关键阶段启用 `manual_review`
- 定期保存检查点

## 集成到 CI/CD

工作流可以集成到 CI/CD 流程中：

```yaml
# .github/workflows/openclaw.yml
name: OpenClaw Workflow
on:
  workflow_dispatch:
    inputs:
      requirement:
        description: 'Project requirement'
        required: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run OpenClaw Workflow
        run: |
          codex workflow run openclaw-workflow-example.yaml \
            --requirement "${{ inputs.requirement }}" \
            --auto
```

## 故障排除

### 问题：任务执行失败

**解决方案：**
1. 查看详细日志：`--verbose`
2. 检查任务依赖是否正确
3. 手动执行失败的任务
4. 调整验证规则

### 问题：验证不通过

**解决方案：**
1. 检查验证规则是否合理
2. 查看生成的输出文件
3. 手动修复问题后继续

### 问题：工作流中断

**解决方案：**
1. 从最近的检查点恢复
2. 使用 `--resume-from-checkpoint` 参数
3. 检查 `.openclaw/checkpoints/` 目录

## 示例场景

### 场景 1: 创建简单的 CLI 工具

```bash
codex workflow run openclaw-workflow-example.yaml \
  --requirement "创建一个 Python CLI 工具，用于计算文件的 MD5 哈希值" \
  --skip-phases "architecture_design,deployment_preparation"
```

### 场景 2: 创建 Web API

```bash
codex workflow run openclaw-workflow-example.yaml \
  --requirement "创建一个 REST API，用于管理待办事项，使用 FastAPI 框架" \
  --output-dir ./todo-api
```

### 场景 3: 创建库项目

```bash
codex workflow run openclaw-workflow-example.yaml \
  --requirement "创建一个 Rust 库，提供通用的数据结构操作函数" \
  --focus-phases "core_implementation,testing,documentation"
```

## 扩展工作流

### 添加自定义阶段

```yaml
phases:
  - phase: "custom_optimization"
    description: "自定义优化阶段"
    tasks:
      - id: "opt_1"
        name: "性能分析"
        prompt: "分析代码性能..."
```

### 添加自定义工具

如果 Codex 支持自定义工具，可以在任务中指定：

```yaml
tasks:
  - id: "task_1"
    tools:
      - "custom_tool"
      - "shell"
```

## 参考资源

- [工作流格式文档](./openclaw-workflow.md)
- [示例工作流文件](../openclaw-workflow-example.yaml)
- [Codex 核心概念](./codex-core-concepts.md)
