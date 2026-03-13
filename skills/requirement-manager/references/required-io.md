# 强制参考与输入输出件

## 1. 强制参考文件

AI 在处理需求管理任务时，必须优先参考以下 4 份 canonical 文档：

1. `docs/requirement-management/01-requirement-intake.md`
2. `docs/requirement-management/02-requirement-evaluation.md`
3. `docs/requirement-management/03-requirement-handoff.md`
4. `docs/requirement-management/04-acceptance-confirmation.md`

这 4 份文档是标准结构，不允许在未得到用户明确要求的情况下重命名、改造主结构或用自由格式替代。

## 2. 推荐参考样例

当 AI 需要生成实例化文档、补全字段、演示流程时，应参考以下样例：

- `docs/requirement-management/01-requirement-intake-example.md`
- `docs/requirement-management/02-requirement-evaluation-example.md`
- `docs/requirement-management/03-requirement-handoff-example.md`
- `docs/requirement-management/04-acceptance-confirmation-example.md`

## 3. 输入件定义

### 3.1 最小输入件

处理任一需求管理任务时，至少应识别以下输入：

- `TAPD` 中当前新增需求、需求变更单或待处理任务
- 用户原始需求描述或用户补充说明
- 当前所处阶段：登记 / 评估 / 交接 / 验收
- 需求来源
- 目标用户或业务对象

说明：

- `TAPD` 是默认主输入源。
- 人负责在 `TAPD` 中完成需求登记或补充登记信息。
- 若 AI 无法直接访问 `TAPD`，则必须向用户索取等效输入，包括导出表格、截图、复制文本、接口返回或结构化摘要。

### 3.2 分阶段输入件

#### 需求登记阶段

输入件：

- `TAPD` 新增任务列表或单条任务信息
- 用户原始需求
- 客户/业务方补充说明
- 截图、日志、录屏、聊天记录中的任意可用信息

#### 需求评估阶段

输入件：

- 已完成的需求登记信息
- `TAPD` 中任务优先级、状态、关联需求或补充备注
- 业务背景和时间要求
- 人补充的限制条件、目标版本、业务上下文

说明：

- 该阶段默认由 AI 主导完成，不要求真人会议参与。
- 若输入不足，AI 的首要输出应是`待澄清问题清单`，而不是直接给出完整评估。

#### 需求交接阶段

输入件：

- 已完成的需求评估结论
- `TAPD` 中已确认的目标版本、处理人、状态或关联任务
- 业务目标
- 规则说明
- 风险与依赖
- 测试管理者补充的可测性和边界场景

#### 验收确认阶段

输入件：

- 测试结果
- 业务验收结果
- `TAPD` 中的完成状态、验收状态、遗留缺陷或关联缺陷单
- 遗留问题列表
- 上线建议

## 4. 输出件定义

### 4.1 阶段输出件

#### 需求登记阶段输出

- `01-requirement-intake.md` 对应的需求登记内容

#### 需求评估阶段输出

- `02-requirement-evaluation.md` 对应的需求评估内容
- 必要时附加`待澄清问题清单`
- 必要时附加`建议排期说明`

#### 需求交接阶段输出

- `03-requirement-handoff.md` 对应的需求交接内容

#### 验收确认阶段输出

- `04-acceptance-confirmation.md` 对应的验收确认内容

### 4.2 附加输出

按需补充：

- 缺失信息清单
- 下一步动作建议
- 需要测试管理者确认的事项
- 需求变更影响说明

## 5. 输出完成判定

AI 只有在满足以下条件时，才可判定当前阶段输出完成：

- 已使用对应 canonical 文档的结构
- 必填字段均有值或明确标记待确认
- 当前阶段结论明确
- 责任人明确
- 下一步动作明确
- 若为评估阶段，已明确说明复杂度、风险、优先级和排期建议

## 6. 禁止事项

- 不得在未读取 `TAPD` 或未取得用户提供的等效输入时，声称“已获取当前新增需求”
- 不得跳过 canonical 文档直接生成随意格式的需求说明
- 不得把缺失信息伪造成已确认结论
- 不得省略`本次不做`、`验收标准`、`遗留问题`等关键字段
- 不得把测试结论与业务验收结论混写成一个字段
