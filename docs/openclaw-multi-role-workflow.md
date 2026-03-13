# OpenClaw 多角色工作流系统

## 概述

OpenClaw 多角色工作流系统模拟真实软件工程团队的分工协作，通过定义明确的角色、职责和交互规则，确保 AI 代理能够按照标准化流程完成软件项目开发。

## 核心设计理念

### 1. 角色分离原则

每个角色专注于自己的职责范围，避免职责重叠和混乱：

- **需求管理者**：负责需求收集、整理、冲突检测和优先级排序
- **需求设计者**：负责将确定的需求转化为详细的技术设计
- **开发者**：负责按照设计进行编码实现
- **测试管理者**：负责测试策略制定和测试计划管理
- **测试设计者**：负责设计测试用例和测试场景
- **测试执行者**：负责执行测试并报告结果

### 2. 严格的工作流控制

由于所有角色都由 AI 扮演，需要更严格的规则来确保：

- **Git 分支管理**：每个角色在独立分支工作，通过 PR 合并
- **Skills 固化**：将工作流规则固化为 Skills，确保一致性
- **检查点机制**：每个阶段完成后创建检查点，支持回滚
- **验证机制**：每个角色的输出必须经过验证才能进入下一阶段

### 3. 角色交互协议

定义明确的角色间交互协议：

- **输入输出规范**：每个角色必须遵循标准的输入输出格式
- **交接检查清单**：角色交接时必须完成检查清单
- **冲突解决机制**：当角色间出现冲突时的解决流程
- **反馈循环**：支持角色间的反馈和迭代

## 角色定义

### 开发端角色

#### 1. 需求管理者 (Requirement Manager)

**职责：**
- 收集和整理用户需求
- 识别需求冲突和依赖关系
- 确定需求优先级
- 生成需求文档和需求追踪矩阵

**输入：**
- 用户原始需求描述
- 历史需求文档（如果有）

**输出：**
- 需求分析文档 (`docs/requirements/requirements-analysis.md`)
- 需求追踪矩阵 (`docs/requirements/requirements-traceability-matrix.md`)
- 需求优先级列表 (`docs/requirements/requirements-priority.md`)
- 需求冲突报告 (`docs/requirements/requirements-conflicts.md`)

**验证标准：**
- 所有需求都有唯一标识符
- 需求之间没有逻辑冲突
- 优先级已明确标注
- 需求可测试、可验证

**Git 规则：**
- 工作分支：`feature/requirements-analysis`
- 提交前缀：`req-mgr:`
- 必须创建 PR 到 `main` 分支
- PR 标题格式：`[需求管理] 需求分析 v<version>`

**Skills 依赖：**
- `requirement-analysis` (scope: always)
- `git-workflow` (scope: always)

#### 2. 需求设计者 (Requirement Designer)

**职责：**
- 将需求转化为详细的技术设计
- 设计系统架构和模块划分
- 定义接口和数据模型
- 制定技术选型方案

**输入：**
- 需求分析文档（来自需求管理者）
- 技术约束和偏好

**输出：**
- 系统设计文档 (`docs/design/system-design.md`)
- 架构设计文档 (`docs/design/architecture.md`)
- 接口设计文档 (`docs/design/interfaces.md`)
- 数据模型设计 (`docs/design/data-models.md`)
- 技术选型文档 (`docs/design/tech-stack.md`)

**验证标准：**
- 设计覆盖所有需求
- 架构清晰、模块化
- 接口定义完整
- 技术选型合理

**Git 规则：**
- 工作分支：`feature/design-<version>`
- 提交前缀：`designer:`
- 必须从 `feature/requirements-analysis` 分支创建
- 必须创建 PR 到 `feature/requirements-analysis` 分支
- PR 标题格式：`[设计] 系统设计 v<version>`

**Skills 依赖：**
- `system-design` (scope: always)
- `architecture-patterns` (scope: contextual)
- `git-workflow` (scope: always)

#### 3. 开发者 (Developer)

**职责：**
- 按照设计文档进行编码实现
- 实现核心功能模块
- 编写单元测试
- 确保代码质量和规范

**输入：**
- 系统设计文档（来自需求设计者）
- 架构设计文档
- 接口设计文档

**输出：**
- 源代码文件
- 单元测试代码
- 代码文档（docstrings/comments）
- 实现报告 (`docs/implementation/implementation-report.md`)

**验证标准：**
- 代码通过编译/语法检查
- 单元测试覆盖率 > 80%
- 代码符合项目规范
- 实现符合设计文档

**Git 规则：**
- 工作分支：`feature/implementation-<module>`
- 提交前缀：`dev:`
- 必须从 `feature/design-<version>` 分支创建
- 每个模块独立分支
- 必须创建 PR 到 `feature/design-<version>` 分支
- PR 标题格式：`[实现] <module-name> v<version>`
- 提交消息必须遵循 Conventional Commits

**Skills 依赖：**
- `code-implementation` (scope: always)
- `testing-unit` (scope: always)
- `git-workflow` (scope: always)
- `code-review` (scope: contextual)

### 测试端角色

#### 4. 测试管理者 (Test Manager)

**职责：**
- 制定测试策略和测试计划
- 分配测试资源
- 管理测试进度
- 协调测试活动

**输入：**
- 需求分析文档
- 系统设计文档
- 实现报告

**输出：**
- 测试策略文档 (`docs/testing/test-strategy.md`)
- 测试计划文档 (`docs/testing/test-plan.md`)
- 测试资源分配 (`docs/testing/test-resources.md`)
- 测试进度报告 (`docs/testing/test-progress.md`)

**验证标准：**
- 测试策略覆盖所有需求
- 测试计划详细可执行
- 资源分配合理
- 进度可追踪

**Git 规则：**
- 工作分支：`feature/test-management`
- 提交前缀：`test-mgr:`
- 必须从 `main` 分支创建
- 必须创建 PR 到 `main` 分支
- PR 标题格式：`[测试管理] 测试策略 v<version>`

**Skills 依赖：**
- `test-management` (scope: always)
- `test-strategy` (scope: always)
- `git-workflow` (scope: always)

#### 5. 测试设计者 (Test Designer)

**职责：**
- 设计测试用例和测试场景
- 编写测试脚本
- 设计测试数据
- 定义测试环境配置

**输入：**
- 测试策略文档（来自测试管理者）
- 系统设计文档
- 接口设计文档

**输出：**
- 测试用例文档 (`docs/testing/test-cases.md`)
- 测试场景文档 (`docs/testing/test-scenarios.md`)
- 测试脚本 (`tests/integration/`)
- 测试数据 (`tests/fixtures/`)
- 测试环境配置 (`tests/config/`)

**验证标准：**
- 测试用例覆盖所有功能点
- 测试场景完整
- 测试脚本可执行
- 测试数据充分

**Git 规则：**
- 工作分支：`feature/test-design-<version>`
- 提交前缀：`test-designer:`
- 必须从 `feature/test-management` 分支创建
- 必须创建 PR 到 `feature/test-management` 分支
- PR 标题格式：`[测试设计] 测试用例 v<version>`

**Skills 依赖：**
- `test-design` (scope: always)
- `test-case-writing` (scope: always)
- `git-workflow` (scope: always)

#### 6. 测试执行者 (Test Executor)

**职责：**
- 执行测试用例
- 记录测试结果
- 报告缺陷
- 验证修复

**输入：**
- 测试用例文档（来自测试设计者）
- 测试脚本
- 待测代码（来自开发者）

**输出：**
- 测试执行报告 (`docs/testing/test-execution-report.md`)
- 缺陷报告 (`docs/testing/bug-reports.md`)
- 测试覆盖率报告 (`docs/testing/coverage-report.md`)
- 测试总结 (`docs/testing/test-summary.md`)

**验证标准：**
- 所有测试用例已执行
- 测试结果准确记录
- 缺陷已分类和优先级排序
- 覆盖率达标

**Git 规则：**
- 工作分支：`feature/test-execution-<version>`
- 提交前缀：`test-executor:`
- 必须从 `feature/test-design-<version>` 分支创建
- 必须创建 PR 到 `feature/test-design-<version>` 分支
- PR 标题格式：`[测试执行] 测试报告 v<version>`

**Skills 依赖：**
- `test-execution` (scope: always)
- `bug-tracking` (scope: always)
- `git-workflow` (scope: always)

## 角色交互规则

### 1. 交接检查清单

每个角色在完成工作后，必须完成以下检查清单才能交接给下一个角色：

**需求管理者 → 需求设计者：**
- [ ] 需求分析文档已生成
- [ ] 所有需求都有唯一 ID
- [ ] 需求优先级已确定
- [ ] 需求冲突已解决
- [ ] PR 已创建并审核通过
- [ ] 文档已合并到目标分支

**需求设计者 → 开发者：**
- [ ] 系统设计文档已生成
- [ ] 架构设计已完成
- [ ] 接口定义清晰
- [ ] 技术选型已确定
- [ ] PR 已创建并审核通过
- [ ] 设计评审已完成

**开发者 → 测试执行者：**
- [ ] 代码实现已完成
- [ ] 单元测试已编写
- [ ] 代码覆盖率达标
- [ ] 代码审查已通过
- [ ] PR 已合并
- [ ] 实现报告已生成

**测试管理者 → 测试设计者：**
- [ ] 测试策略已制定
- [ ] 测试计划已确定
- [ ] 资源已分配
- [ ] PR 已创建并审核通过

**测试设计者 → 测试执行者：**
- [ ] 测试用例已设计
- [ ] 测试脚本已编写
- [ ] 测试数据已准备
- [ ] PR 已创建并审核通过

### 2. 反馈循环

支持角色间的反馈和迭代：

**设计反馈：**
- 开发者发现问题 → 反馈给需求设计者 → 更新设计 → 重新实现

**测试反馈：**
- 测试执行者发现缺陷 → 反馈给开发者 → 修复 → 重新测试

**需求变更：**
- 任何角色发现需求问题 → 反馈给需求管理者 → 更新需求 → 通知相关角色

### 3. 冲突解决机制

当角色间出现冲突时：

1. **识别冲突**：明确冲突的类型和影响范围
2. **升级处理**：将冲突升级到工作流协调器
3. **协商解决**：相关角色协商解决方案
4. **更新文档**：解决后更新相关文档
5. **通知影响**：通知受影响的角色

## Git 分支管理规范

### 分支命名规范

```
main                          # 主分支，只接受合并
feature/requirements-analysis # 需求分析分支
feature/design-<version>      # 设计分支
feature/implementation-<module> # 实现分支
feature/test-management      # 测试管理分支
feature/test-design-<version> # 测试设计分支
feature/test-execution-<version> # 测试执行分支
hotfix/<issue-id>            # 紧急修复分支
```

### 分支工作流

```
main
  ├── feature/requirements-analysis
  │     ├── feature/design-v1
  │     │     ├── feature/implementation-module-a
  │     │     ├── feature/implementation-module-b
  │     │     └── feature/implementation-module-c
  │     └── feature/design-v2 (如果设计需要迭代)
  │
  └── feature/test-management
        ├── feature/test-design-v1
        │     └── feature/test-execution-v1
        └── feature/test-design-v2 (如果需要迭代)
```

### Git 操作规则

1. **禁止直接推送到 main 分支**
2. **所有更改必须通过 PR**
3. **PR 必须经过代码审查**
4. **使用 Conventional Commits 格式**
5. **每个 PR 必须关联需求或任务 ID**
6. **合并前必须通过所有检查**

### 提交消息格式

遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范：

```
<role>: <type>(<scope>): <subject>

<body>

<footer>
```

示例：
```
req-mgr: docs(requirements): add user authentication requirements

- Add login/logout requirements
- Add password reset requirements
- Update requirements traceability matrix

Closes #REQ-001
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
    │       ├── roles.md            # 角色定义
    │       ├── git-workflow.md     # Git 工作流
    │       └── interaction-rules.md # 交互规则
    │
    ├── requirement-analysis/       # 需求分析 Skill
    ├── system-design/              # 系统设计 Skill
    ├── code-implementation/        # 代码实现 Skill
    ├── test-management/            # 测试管理 Skill
    ├── test-design/                # 测试设计 Skill
    └── test-execution/             # 测试执行 Skill
```

### Skill 固化规则

1. **每个角色对应一个 Skill**
2. **Skill 必须包含角色职责和规则**
3. **Skill scope 设置为 `always` 以确保始终生效**
4. **工作流规则必须固化在 Skill 中**
5. **Git 操作规则必须固化在 Skill 中**

### Skill 更新机制

1. **版本控制**：每个 Skill 都有版本号
2. **变更通知**：Skill 更新时通知相关角色
3. **向后兼容**：确保 Skill 更新不影响已有工作流
4. **验证机制**：更新后必须验证工作流仍能正常运行

## 工作流执行流程

### 阶段 1: 初始化

1. 创建工作流目录结构
2. 初始化 Git 仓库
3. 加载工作流 Skills
4. 创建初始分支

### 阶段 2: 需求管理

1. 需求管理者分析需求
2. 生成需求文档
3. 创建 PR 并审核
4. 合并到 main 分支

### 阶段 3: 需求设计

1. 需求设计者从 main 分支创建设计分支
2. 进行系统设计
3. 创建 PR 并审核
4. 合并到设计分支

### 阶段 4: 开发实现

1. 开发者从设计分支创建实现分支
2. 进行编码实现
3. 编写单元测试
4. 创建 PR 并审核
5. 合并到设计分支

### 阶段 5: 测试管理（并行）

1. 测试管理者从 main 分支创建测试管理分支
2. 制定测试策略
3. 创建 PR 并审核
4. 合并到测试管理分支

### 阶段 6: 测试设计

1. 测试设计者从测试管理分支创建测试设计分支
2. 设计测试用例
3. 创建 PR 并审核
4. 合并到测试设计分支

### 阶段 7: 测试执行

1. 测试执行者从测试设计分支创建测试执行分支
2. 执行测试用例
3. 报告缺陷
4. 验证修复
5. 生成测试报告

### 阶段 8: 集成和交付

1. 合并所有功能分支到 main
2. 执行集成测试
3. 生成项目报告
4. 准备交付

## 检查点和恢复机制

### 检查点创建时机

- 每个阶段完成后
- 每个角色交接时
- 重大决策点
- 错误恢复点

### 检查点内容

- Git 分支状态
- 文档版本
- Skills 版本
- 工作流状态

### 恢复流程

1. 识别需要恢复的检查点
2. 恢复 Git 分支状态
3. 恢复文档版本
4. 重新加载 Skills
5. 继续工作流执行

## 质量保证

### 代码质量

- 代码审查必须通过
- 单元测试覆盖率 > 80%
- 集成测试必须通过
- 代码规范检查必须通过

### 文档质量

- 文档必须完整
- 文档必须可读
- 文档必须可维护
- 文档必须版本控制

### 流程质量

- 所有角色必须遵循规则
- 所有交接必须完成检查清单
- 所有 PR 必须经过审查
- 所有冲突必须解决

## 扩展性

### 添加新角色

1. 定义角色职责
2. 创建对应 Skill
3. 定义交互规则
4. 更新工作流文档

### 添加新阶段

1. 定义阶段目标
2. 定义输入输出
3. 定义验证标准
4. 更新工作流流程

### 自定义规则

1. 在 Skill 中定义规则
2. 更新工作流文档
3. 通知相关角色
4. 验证规则生效
