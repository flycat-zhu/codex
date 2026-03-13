# OpenClaw Git 和 Skills 管理规范

## 概述

本文档定义了 OpenClaw 多角色工作流系统中 Git 分支管理和 Skills 固化的严格规则，确保 AI 代理能够按照标准化流程工作。

## Git 分支管理规范

### 分支命名规范

#### 主分支

- `main`: 主分支，只接受合并，不允许直接推送
- `master`: 兼容性主分支（如果项目使用 master）

#### 功能分支

所有功能分支必须以 `feature/` 前缀开头：

```
feature/requirements-analysis    # 需求分析分支
feature/design-{version}        # 设计分支，版本号如 v1, v2
feature/implementation-{module} # 实现分支，模块名如 core, api
feature/test-management         # 测试管理分支
feature/test-design-{version}   # 测试设计分支
feature/test-execution-{version} # 测试执行分支
```

#### 修复分支

紧急修复使用 `hotfix/` 前缀：

```
hotfix/{issue-id}  # 紧急修复分支，如 hotfix/REQ-001
```

### 分支工作流

#### 开发端分支流

```
main
  └── feature/requirements-analysis
        └── feature/design-v1
              ├── feature/implementation-core
              ├── feature/implementation-api
              └── feature/implementation-ui
```

#### 测试端分支流

```
main
  └── feature/test-management
        └── feature/test-design-v1
              └── feature/test-execution-v1
```

#### 完整分支流

```
main
  ├── feature/requirements-analysis
  │     └── feature/design-v1
  │           ├── feature/implementation-core
  │           ├── feature/implementation-api
  │           └── feature/implementation-ui
  │
  └── feature/test-management
        └── feature/test-design-v1
              └── feature/test-execution-v1
```

### Git 操作规则

#### 1. 禁止直接推送到 main

**规则：**
- 所有更改必须通过 Pull Request
- 禁止使用 `git push origin main`
- 禁止使用 `--force` 推送到 main

**检查：**
```bash
# 工作流系统应检查
if [ "$(git branch --show-current)" = "main" ]; then
  echo "ERROR: Cannot push directly to main"
  exit 1
fi
```

#### 2. 分支创建规则

**从 main 创建：**
- 需求分析分支：`feature/requirements-analysis`
- 测试管理分支：`feature/test-management`

**从功能分支创建：**
- 设计分支从需求分析分支创建
- 实现分支从设计分支创建
- 测试设计分支从测试管理分支创建
- 测试执行分支从测试设计分支创建

**创建命令：**
```bash
# 从 main 创建需求分析分支
git checkout main
git pull origin main
git checkout -b feature/requirements-analysis

# 从需求分析分支创建设计分支
git checkout feature/requirements-analysis
git pull origin feature/requirements-analysis
git checkout -b feature/design-v1
```

#### 3. 提交消息规范

遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范：

**格式：**
```
<role>: <type>(<scope>): <subject>

<body>

<footer>
```

**角色前缀：**
- `req-mgr:` - 需求管理者
- `designer:` - 需求设计者
- `dev:` - 开发者
- `test-mgr:` - 测试管理者
- `test-designer:` - 测试设计者
- `test-executor:` - 测试执行者

**类型：**
- `feat`: 新功能
- `fix`: 修复缺陷
- `docs`: 文档更新
- `style`: 代码格式（不影响功能）
- `refactor`: 重构
- `test`: 测试相关
- `chore`: 构建/工具相关

**示例：**
```
req-mgr: docs(requirements): add user authentication requirements

- Add login/logout requirements (REQ-001)
- Add password reset requirements (REQ-002)
- Update requirements traceability matrix

Closes #REQ-001
```

```
designer: feat(architecture): design microservices architecture

- Design API gateway
- Design user service
- Design auth service
- Define service interfaces

Related to REQ-001, REQ-002
```

```
dev: feat(core): implement user authentication module

- Implement login functionality
- Implement logout functionality
- Add unit tests
- Update documentation

Implements REQ-001
Tests: 95% coverage
```

#### 4. Pull Request 规范

**PR 标题格式：**
```
[角色] <描述> v<版本>
```

**示例：**
- `[需求管理] 需求分析 v1.0`
- `[设计] 系统设计 v1.0`
- `[实现] 核心模块 v1.0`
- `[测试管理] 测试策略 v1.0`
- `[测试设计] 测试用例 v1.0`
- `[测试执行] 测试报告 v1.0`

**PR 描述模板：**
```markdown
## 概述
[简要描述本次 PR 的内容]

## 变更内容
- [ ] 变更项 1
- [ ] 变更项 2
- [ ] 变更项 3

## 关联需求
- REQ-001: [需求描述]
- REQ-002: [需求描述]

## 测试
- [ ] 单元测试已通过
- [ ] 集成测试已通过
- [ ] 代码覆盖率: XX%

## 检查清单
- [ ] 代码已通过 linter 检查
- [ ] 文档已更新
- [ ] 提交消息符合规范
- [ ] 分支命名符合规范
```

#### 5. 合并策略

**默认策略：** Squash and Merge

- 保持主分支历史清晰
- 每个 PR 合并为一个提交
- 提交消息使用 PR 标题

**特殊情况：**
- 大型功能开发：使用 Merge Commit
- 需要保留详细历史：使用 Rebase and Merge

#### 6. 代码审查要求

**必须审查：**
- 所有 PR 必须经过代码审查
- 至少一个审查者批准
- 所有 CI 检查必须通过

**审查检查清单：**
- [ ] 代码符合规范
- [ ] 功能实现正确
- [ ] 测试充分
- [ ] 文档完整
- [ ] 无安全漏洞
- [ ] 性能可接受

### Git 安全检查

#### 1. 提交前检查

**预提交钩子：**
```bash
#!/bin/bash
# .git/hooks/pre-commit

# 检查提交消息格式
commit_msg=$(git log -1 --pretty=format:"%s")
if ! echo "$commit_msg" | grep -qE "^(req-mgr|designer|dev|test-mgr|test-designer|test-executor):"; then
  echo "ERROR: Commit message must start with role prefix"
  exit 1
fi

# 检查是否在 main 分支提交
current_branch=$(git branch --show-current)
if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
  echo "ERROR: Cannot commit directly to main/master"
  exit 1
fi
```

#### 2. 推送前检查

**预推送钩子：**
```bash
#!/bin/bash
# .git/hooks/pre-push

# 检查是否推送到 main
while read local_ref local_sha remote_ref remote_sha; do
  if [[ "$remote_ref" == "refs/heads/main" ]] || [[ "$remote_ref" == "refs/heads/master" ]]; then
    echo "ERROR: Cannot push directly to main/master"
    exit 1
  fi
done
```

## Skills 固化规范

### Skills 目录结构

```
.codex/
└── skills/
    ├── openclaw-workflow/          # 工作流主 Skill
    │   ├── SKILL.md
    │   ├── agents/
    │   │   └── openai.yaml
    │   └── references/
    │       ├── roles.md
    │       ├── git-workflow.md
    │       └── interaction-rules.md
    │
    ├── requirement-analysis/       # 需求分析 Skill
    │   ├── SKILL.md
    │   ├── agents/
    │   │   └── openai.yaml
    │   └── references/
    │       └── requirement-templates.md
    │
    ├── system-design/               # 系统设计 Skill
    │   ├── SKILL.md
    │   ├── agents/
    │   │   └── openai.yaml
    │   └── references/
    │       ├── architecture-patterns.md
    │       └── design-templates.md
    │
    ├── code-implementation/        # 代码实现 Skill
    │   ├── SKILL.md
    │   ├── agents/
    │   │   └── openai.yaml
    │   └── references/
    │       └── coding-standards.md
    │
    ├── test-management/            # 测试管理 Skill
    │   ├── SKILL.md
    │   └── agents/
    │       └── openai.yaml
    │
    ├── test-design/                # 测试设计 Skill
    │   ├── SKILL.md
    │   └── agents/
    │       └── openai.yaml
    │
    ├── test-execution/             # 测试执行 Skill
    │   ├── SKILL.md
    │   └── agents/
    │       └── openai.yaml
    │
    └── git-workflow/               # Git 工作流 Skill
        ├── SKILL.md
        └── agents/
            └── openai.yaml
```

### Skill 定义规范

#### 1. SKILL.md 格式

**Frontmatter：**
```yaml
---
name: skill-name
description: Comprehensive description of when and how to use this skill. Include all "when to use" information here, not in the body.
---
```

**Body：**
- 使用命令式/不定式形式
- 保持简洁，避免冗余
- 包含必要的操作步骤
- 引用参考文档而非重复内容

#### 2. Scope 设置

**Always Scope：**
- 工作流相关 Skills：`openclaw-workflow`, `git-workflow`
- 角色核心 Skills：每个角色的主要 Skill

**Contextual Scope：**
- 特定场景使用的 Skills
- 可选功能相关的 Skills

#### 3. Skill 内容要求

**必须包含：**
1. 角色职责说明
2. 工作流程
3. Git 操作规则
4. 输出格式要求
5. 验证标准

**示例：需求分析 Skill**

```markdown
---
name: requirement-analysis
description: Analyze and manage software requirements. Use when acting as a requirement manager to collect, organize, prioritize requirements, detect conflicts, and generate requirement documents.
---

# Requirement Analysis

## Role: Requirement Manager

As a requirement manager, you are responsible for:
- Collecting and organizing user requirements
- Identifying requirement conflicts and dependencies
- Determining requirement priorities
- Generating requirement documents

## Workflow

1. Extract all functional and non-functional requirements
2. Assign unique identifiers (REQ-001, REQ-002, ...)
3. Identify requirement types and dependencies
4. Detect conflicts and propose solutions
5. Determine priorities using MoSCoW method
6. Generate requirement documents

## Git Rules

- Branch: `feature/requirements-analysis`
- Commit prefix: `req-mgr:`
- PR title format: `[需求管理] 需求分析 v<version>`
- Target branch: `main`

## Output Documents

- `docs/requirements/requirements-analysis.md`
- `docs/requirements/requirements-priority.md`
- `docs/requirements/requirements-traceability-matrix.md`
- `docs/requirements/requirements-conflicts.md`

## Validation

- All requirements have unique identifiers
- No logical conflicts
- Priorities are clearly marked
- Requirements are testable and verifiable
```

### Skill 版本管理

#### 1. 版本号规则

使用语义化版本号：`MAJOR.MINOR.PATCH`

- **MAJOR**: 重大变更，不向后兼容
- **MINOR**: 新功能，向后兼容
- **PATCH**: 修复，向后兼容

#### 2. 版本更新流程

1. **识别需要更新的 Skill**
2. **更新 Skill 内容**
3. **更新版本号**
4. **更新 CHANGELOG**
5. **通知相关角色**
6. **验证工作流仍能正常运行**

#### 3. 向后兼容性

- 尽量保持向后兼容
- 重大变更需要迁移指南
- 提供版本兼容性矩阵

### Skill 加载机制

#### 1. 自动加载

工作流系统自动加载：

```yaml
required_skills:
  - openclaw-workflow  # scope: always
  - git-workflow      # scope: always
```

#### 2. 角色特定加载

根据当前角色加载：

```yaml
role_specific_skills:
  requirement_manager:
    - requirement-analysis  # scope: always
  requirement_designer:
    - system-design         # scope: always
    - architecture-patterns # scope: contextual
```

#### 3. 动态加载

根据上下文动态加载：

```yaml
contextual_skills:
  - architecture-patterns  # 仅在需要时加载
  - code-review           # 仅在代码审查时加载
```

### Skill 验证

#### 1. 格式验证

```bash
# 验证 Skill 格式
codex skill validate .codex/skills/skill-name/
```

**检查项：**
- Frontmatter 格式正确
- 必需字段存在
- 文件结构正确
- 引用文件存在

#### 2. 内容验证

- 角色职责清晰
- 工作流程完整
- Git 规则明确
- 输出格式规范

#### 3. 集成验证

- Skill 与工作流兼容
- 角色切换正常
- 输出符合预期

## 工作流集成

### 1. 初始化时加载 Skills

```yaml
phases:
  - phase: "project_initialization"
    tasks:
      - id: "load_skills"
        prompt: |
          加载工作流 Skills：
          1. 检查 .codex/skills/openclaw-workflow/ 是否存在
          2. 如果不存在，创建工作流 Skill
          3. 检查其他必需的 Skills
          4. 验证 Skill 格式
```

### 2. 角色切换时加载 Skills

```yaml
- phase: "requirements_management"
  role: "requirement_manager"
  skills:
    - requirement-analysis
    - git-workflow
    - openclaw-workflow
```

### 3. 任务执行时应用 Skills

每个任务的 prompt 应引用相关 Skill：

```yaml
tasks:
  - id: "req_mgr_1"
    prompt: |
      作为需求管理者，分析用户需求...
      
      遵循需求分析 Skill 的规范。
      参考：.codex/skills/requirement-analysis/SKILL.md
```

## 最佳实践

### Git 最佳实践

1. **保持分支清晰**
   - 一个功能一个分支
   - 及时合并和清理
   - 避免长期分支

2. **提交频率**
   - 小步提交，频繁提交
   - 每个提交完成一个逻辑单元
   - 提交前确保测试通过

3. **PR 管理**
   - PR 保持小而专注
   - 及时响应审查意见
   - 合并后及时删除分支

### Skills 最佳实践

1. **保持简洁**
   - 只包含必要信息
   - 避免冗余内容
   - 使用引用而非重复

2. **及时更新**
   - 发现问题及时更新
   - 保持版本同步
   - 记录变更历史

3. **充分测试**
   - 更新后验证工作流
   - 测试角色切换
   - 验证输出格式

## 故障处理

### Git 问题

1. **合并冲突**
   - 识别冲突文件
   - 分析冲突原因
   - 协商解决方案
   - 手动解决冲突

2. **分支混乱**
   - 清理无用分支
   - 重新组织分支结构
   - 更新文档

### Skills 问题

1. **Skill 加载失败**
   - 检查 Skill 格式
   - 验证文件路径
   - 查看错误日志

2. **Skill 版本冲突**
   - 检查版本兼容性
   - 更新到兼容版本
   - 提供迁移指南
