# Claude Scientific Skills 医疗科研场景整合清单

本文档面向**医疗垂类 AI 服务**（医生、医学生）：科研文档生成与写作、文献处理、学术级数据可视化。用于从 [K-Dense-AI/claude-scientific-skills](https://github.com/K-Dense-AI/claude-scientific-skills/tree/main) 中**筛选、分级、合规评估**，并复制到 Codex 镜像可用的技能目录（如 `.codex/skills/` 或构建时 `COPY` 到镜像内技能路径）。

**上游说明**：上游仓库技能名称与目录以 `scientific-skills/` 下各子文件夹为准；集成前请阅读各技能 `SKILL.md` 中的 `license` 与依赖说明。上游安全提示见仓库 [Security Disclaimer](https://github.com/K-Dense-AI/claude-scientific-skills#-security-disclaimer)。

---

## 1. 与当前 Codex 镜像的衔接

| 已有能力（本仓库） | 说明 |
|-------------------|------|
| `docx` / `pdf` / `pptx` / `xlsx` | 文档与表格交付链路已覆盖 |
| 通用 Codex Skills | 见 [skills.md](./skills.md) |

**整合原则**：优先补齐**文献 → 证据 → 写作 → 图表**的医学科研专用技能；避免与现有 `docx/pdf/pptx/xlsx` 重复装包。

### 1.1 当前部署策略（本项目）

以下策略用于与上游 K-Dense 技能并存时的**产品级取舍**，避免 Agent 与镜像行为不一致：

| 维度 | 策略 |
|------|------|
| **独立文献数据源 skill** | **暂不引入** `pubmed` / `openalex` / `biorxiv` 等独立目录；文献与引用以已内置的 **`citation-management`**（含 PubMed 检索脚本等）、**`literature-review`**、模型能力为主。需要时再按课题补拷上游目录。 |
| **Google Scholar** | **不使用**；不安装 `scholarly`，不依赖 `search_google_scholar.py` 路径。 |
| **Python 依赖版本** | 科研可视化相关包（如 `numpy` / `seaborn` / `statsmodels` / `plotly`）在 `requirements.txt` 中**不固定小版本**，便于跟随安全更新；其余核心依赖仍可按镜像稳定性需要保持 pin。 |
| **学术图 vs 创意图** | **学术类、数据驱动**图表使用 **Matplotlib / Seaborn**（及必要时 **statsmodels** + **scientific-visualization**）。**创意类、概念类**配图使用 **豆包 Seedream**（见根目录 `AGENTS.md`）。镜像内**不包含**依赖 OpenRouter 的 `scientific-schematics`。 |
| **外部查证 skill** | **`research-lookup`** 已从本仓库 `skills/` 移除（Parallel/OpenRouter 付费）；文献与引用以 **`citation-management`**、**`literature-review`** 与模型能力为主。 |

---

## 2. 字段说明

| 列 | 含义 |
|----|------|
| **一句话用途** | 对用户/产品的价值摘要 |
| **外部依赖** | 网络 API、可选/必选密钥、速率限制等（以各 `SKILL.md` 为准） |
| **合规风险** | **低**：公开数据与本地计算为主；**中**：需注意引用准确性、第三方条款与患者隐私边界；**高**：接近诊疗建议或受监管输出，需流程与法务评估 |
| **镜像默认** | **开**：建议默认打入镜像或默认启用；**关**：默认不启用，按租户/版本灰度；**许可后开**：依赖机构订阅或许可证 |

---

## 3. P0：建议第一批集成（高收益、通用）

| Skill（上游目录名） | 一句话用途 | 外部依赖 | 合规风险 | 镜像默认 |
|---------------------|------------|----------|----------|----------|
| `pubmed` | 检索与引用生物医学文献（摘要/全文策略依实现） | 需网络；NCBI E-utilities 建议配置联系邮箱，部分场景可选 API Key | 低 | 开 |
| `openalex` | 开放学术图谱检索与计量辅助 | 需网络；通常无需密钥 | 低 | 开 |
| `biorxiv` | 预印本检索与跟踪 | 需网络 | 低 | 开 |
| `literature-review` | 结构化文献综述工作流（与检索类技能组合使用） | 依赖所启用数据源与模型 | 中 | 开 |
| `citation-management` | 引用格式、参考文献组织（与写作链路衔接） | 若对接 Zotero 等需按该集成配置 | 低 | 开 |
| `scientific-writing` | 论文/标书式结构与学术表达 | 主要依赖模型与本地编辑 | 低 | 开 |
| `peer-review` | 同行评审视角自查（方法、偏倚、报告规范） | 主要依赖模型 | 低 | 开 |
| `matplotlib` | 发表级静态图（误差线、多面板等） | 本地 Python 包 | 低 | 开 |
| `seaborn` | 统计图形与风格化可视化 | 本地 Python 包 | 低 | 开 |
| `plotly` | 交互图/探索性图表（按需用于内部分析） | 本地 Python 包 | 低 | 开 |
| `scientific-visualization` | 科学可视化规范与组合实践 | 依赖所选绘图栈 | 低 | 开 |
| `statsmodels` | 经典统计与计量模型（回归、检验等） | 本地 Python 包 | 低 | 开 |

---

## 4. P1：第二批（医疗科研差异化）

| Skill（上游目录名） | 一句话用途 | 外部依赖 | 合规风险 | 镜像默认 |
|---------------------|------------|----------|----------|----------|
| `clinicaltrials-gov` | 检索临床试验设计与入组信息 | 公开 API；需网络 | 低 | 开 |
| `ncbi-gene` | 基因注释与 ID 解析 | 需网络；注意 NCBI 访问频率策略 | 低 | 开 |
| `ensembl` | 基因组坐标、转录本与变异上下文 | 需网络；Ensembl REST 速率限制 | 低 | 开 |
| `uniprot` | 蛋白序列与功能注释 | 需网络 | 低 | 开 |
| `clinvar` | 临床意义变异与证据汇总（科研解读辅助） | 需网络 | 中 | 开 |
| `clinpgx` | 药物基因组学与用药相关注释（科研向） | 需网络；注意数据使用条款 | 中 | 关 |
| `cosmic` | 肿瘤突变与癌症基因组上下文 | **常需注册/学术或商业许可** | 中 | 许可后开 |
| `fda-databases` | 药物安全、标签与监管信息检索 | 需网络 | 中 | 开 |
| `string` | 蛋白互作与网络分析 | 需网络 | 低 | 开 |
| `reactome` | 通路富集与机制路径 | 需网络 | 低 | 开 |
| `kegg` | 通路数据库（医学讨论常用） | **商业/学术许可政策严格** | 中 | 许可后开 |
| `open-targets` | 靶点与疾病关联、可药性线索 | 需网络 | 低 | 开 |

---

## 5. P2：按产品与合规策略可选

| Skill（上游目录名） | 一句话用途 | 外部依赖 | 合规风险 | 镜像默认 |
|---------------------|------------|----------|----------|----------|
| `bgpt-paper-search` | 更结构化的全文级论文字段检索 | 可能依赖第三方检索后端 | 中 | 关 |
| `perplexity-search` | AI 联网检索与摘要 | **需 Perplexity API** | 中 | 关 |
| `parallel-web` | 多源网页综合与引用 | **需服务/API** | 中 | 关 |
| `clinical-reports` | 临床文书类生成辅助 | 模型 + 可能模板/知识库 | **高** | 关 |
| `treatment-plans` | 治疗方案类结构化输出 | 模型 + 外部知识 | **高** | 关 |
| `clinical-decision-support` | 临床决策支持向能力 | 模型 + 数据与规则 | **高** | 关 |

> **说明**：P2 中「临床报告 / 治疗计划 / 决策支持」类技能与诊疗边界接近，建议仅在**明确产品定位、免责声明、人工审核流程**通过后再以「增值模块」形式开启。

---

## 6. 明确暂不优先（与当前主线偏离或过重）

以下在上游集合中质量高，但对「文献 + 写作 + 学术可视化」主线的短期 ROI 较低，或依赖 GPU/重型环境：

- 大规模 **分子动力学 / 量子化学 / 虚拟筛选** 全链路（如 OpenMM、DiffDock、DeepChem 等按项目单开）
- **实验室自动化与 LIMS**（除非产品线包含实验场景）
- **金融/SEC** 类技能（与医疗科研主线无关）

需要时再按课题单点引入对应子目录即可。

---

## 7. 镜像与工程落地检查项

1. **目录**：将选定技能从上游 `scientific-skills/<name>/` 复制到镜像构建上下文中的 `.codex/skills/<name>/`（或你们统一的 skills 路径），保证每个技能含 `SKILL.md`。
2. **依赖**：在镜像 `requirements.txt` 或分阶段 `uv pip install` 中仅加入**已启用技能**声明的 Python 依赖，避免镜像体积与攻击面膨胀。
3. **密钥**：对「关」默认项通过环境变量注入（如 `PERPLEXITY_API_KEY`），未配置时代理层不注册相关工具或技能描述中注明不可用。
4. **合规**：所有生成内容要求**可追溯引用**（PMID、DOI、数据库版本日期）；禁止将可识别患者信息送入未评估的外部 API。
5. **许可**：逐个核对 `SKILL.md` 内 `license` 字段；COSMIC、KEGG 等需机构合规确认后再打包分发。

---

## 8. 版本与维护

| 项目 | 说明 |
|------|------|
| 上游仓库 | [claude-scientific-skills](https://github.com/K-Dense-AI/claude-scientific-skills) |
| 本文档 | 随产品选件更新；技能名以实际拷贝的上游文件夹名为准 |

如需将本文档与英文版 `docs/skills.md` 关联，可在 `skills.md` 末尾增加一行指向本文件的链接（可选）。

---

## 9. P0 表与「当前未纳入」项的对应关系

整合清单第 3 节中的 `pubmed` / `openalex` / `biorxiv` 行表示**上游可选能力**；**当前仓库策略为暂不拷贝这三类独立 skill**（见 §1.1）。已拷贝的 **`literature-review`**、**`citation-management`** 等与文献流程相关的技能继续保留；图表与配图路由以 §1.1 为准。
