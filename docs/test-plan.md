# XiaoYuNote 测试计划

> 版本：基于重构后的三栏结构（便签 / 知识库 / 设置），Python sidecar 已移除，
> 知识库检索改为 Rust 内置实现。

## 1. 测试概览

| 层级 | 工具 | 现状 | 说明 |
| --- | --- | --- | --- |
| Flutter 单元与 widget 测试 | `flutter test` | 164 项全绿 | lib/ 与 test/ 覆盖便签编辑、设置、知识库面板、文件树 |
| Rust 单元测试 | `cargo test --lib` | 185 项全绿 | 含 kb 模块 30+ 新增测试（store/scanner/parser/chunker/retriever/generator/exact） |
| CI 检查 | GitHub Actions | `flutter-checks`（analyze + Flutter test + Rust test） | `.github/workflows/ci.yml` |
| 手工验证 | 人工 | 见 §5 | 安装包启动、AI 配置、笔记编辑、知识库索引与问答 |

## 2. Flutter 测试（164 项）

### 2.1 运行方式

```bash
cd spring_note
flutter pub get
flutter test
```

### 2.2 覆盖范围

| 测试文件 | 覆盖内容 |
| --- | --- |
| `widget_test.dart` | App 主题动效关闭 + 三栏导航显示 + 切换到设置 Section |
| `notes_page_test.dart` | Markdown 编辑/预览/保存、文件树展开点击、编辑器焦点与快捷键、粘贴图片 |
| `settings_page_test.dart` | 偏好设置持久化、供应商/模型管理、默认模型选择 |
| `local_data_service_test.dart` | AppConfig 序列化/反序列化、数据目录迁移、加密存储 |
| `kb_page_test.dart` | KbPage 渲染文件树、索引状态栏、SSE 流式问答 |
| `ai_client_service_test.dart` | AI 供应商请求与错误处理 |
| 其他（~15 个文件） | 笔记服务、Markdown 高亮、剪贴板图片、安全存储等 |

### 2.3 已删除的测试

重构中以下不再适用的测试已移除：

- `desktop_widget_window_bridge_test.dart`（桌面组件）
- `memory_page_test.dart` / `memory_services_test.dart` / `memory_input_modes_test.dart`（回忆书）
- `cloud_sync_service_test.dart`（云同步）
- `wallpaper_service_test.dart`（壁纸）
- `update_dialog_test.dart`（更新检查）
- `level_progress_service_test.dart`（牛马等级）
- `home_kb_card_test.dart` / `home_overview_service_test.dart` / `global_sign_service_test.dart`（首页工作台）
- `spring_tree_widget_test.dart`（树图组件）
- `note_upload_queue_test.dart`（云同步上传队列）

### 2.4 后续需补的测试

| 优先级 | 测试内容 |
| --- | --- |
| 高 | KbRustClient 集成测试（文件树构建、md/xlsx 读写、文件管理 CRUD） |
| 高 | kb_file_tree_panel 交互测试（新建文件/文件夹、右键删除、目录切换） |
| 中 | 知识库问答端到端（检索 + LLM 生成，待 Rust 层接入 LLM 后） |
| 低 | 设置页 kb 数据目录选择器测试 |

## 3. Rust 测试（185 项）

### 3.1 运行方式

```bash
cd spring_note/rust
cargo test --lib
```

### 3.2 新增 kb 模块测试（30+ 项）

| 模块 | 测试项 | 说明 |
| --- | --- | --- |
| `kb::store` | — | SQLite 建表/CRUD 目前通过集成测试间接覆盖 |
| `kb::scanner::tests` | 3 项 | 增量判重（新文件/跳过/变更/删除）、黑名单目录排除 |
| `kb::parser::tests` | 2 项 | Markdown 按二级标题分段、纯文本解析、列字母 A→AA |
| `kb::chunker::tests` | 5 项 | 短文档整块、min_size 过滤、结构化块豁免、长文档滑动窗口、敏感文档跳过 |
| `kb::utils::tests` | 6 项 | 日期提取（文件名/目录名/中文格式）、时间词解析（上周/上月）、脱敏、sha256 稳定 |
| `kb::exact::tests` | 4 项 | 单号/金额/中文 token 提取 |
| `kb::generator::tests` | 4 项 | Prompt 组装、上下文预算裁剪、引用构建、脱敏 |
| `kb::retriever::tests` | 1 项 | 空库返回空（完整检索需 embedding API，暂未接入） |
| `kb::kb::tests` | 5 项 | base64 往返、路径安全、文件树构建、文本读写、索引冒烟 |
| `kb::embedder::tests` | 2 项 | L2 归一化、未配置检测 |

### 3.3 后续需补的测试

| 优先级 | 测试内容 |
| --- | --- |
| 高 | Retriever 集成测试（需要 embedding API mock） |
| 高 | Generator 端到端（检索 → Prompt 组装 → 引用） |
| 中 | Embedder batch 维度校验错误路径 |

## 4. CI 流水线

### 4.1 当前 Job

| Job | 触发条件 | 内容 |
| --- | --- | --- |
| `Flutter Analyze & Test` | push main/master | flutter pub get → flutter analyze → flutter test → cargo test |
| `Windows Release Build` | flutter-checks 通过 | flutter build windows → npm build Univer → Inno Setup 打包 |
| `macOS Release Build` | flutter-checks 通过 | flutter build macos → xcodebuild test → DMG 打包 |

### 4.2 已移除的 Job

- `Sidecar Python Tests`（Python sidecar 已删除）

### 4.3 CI 验证命令

```bash
# 本地模拟 CI 检查
cd spring_note
flutter analyze
flutter test
cd rust
cargo test --lib
```

## 5. 手工验证清单

### 5.1 基础功能

- [ ] 应用启动 → 默认进入便签页，导航显示便签/知识库/设置三项
- [ ] 设置页 → 配置 AI 供应商（供应商/模型/默认模型），验证连接
- [ ] 便签页 → 新建日报、输入内容、保存成功
- [ ] 便签页 → 在笔记目录中创建 md 文件，文件树可展开并打开编辑
- [ ] 知识库页 → 文件树显示笔记目录结构，可展开/选中文件

### 5.2 知识库索引

- [ ] 在数据目录中放入新的 md/txt 文件
- [ ] 知识库页点击「立即索引」→ 看到新文件被统计
- [ ] 修改文件后再次索引 → 统计为变更

### 5.3 配置持久化

- [ ] 修改字体/语言/深色模式 → 重启后保持不变
- [ ] 添加 AI 供应商 → 重启后仍然存在

### 5.4 边界与错误处理

- [ ] 未配置 AI 时打开知识库问答 → 显示「请先配置 AI 供应商」
- [ ] 数据目录不存在时启动 → App 创建默认目录
- [ ] 打开不存在的文件 → 文件树不显示（不崩溃）

## 6. 性能验证

重构后的关键性能改进：

| 操作 | 重构前（sidecar HTTP） | 重构后（Rust 直读） |
| --- | --- | --- |
| 文件树加载 | HTTP GET → Python iterdir → JSON 序列化 | Rust 本地递归 iterdir |
| 打开 md 文件 | HTTP GET → read_text → JSON | Rust 本地 fs::read_to_string |
| 打开 xlsx 文件 | HTTP GET → calamine → base64 → JSON | Rust 本地 calamine → base64 |
| KbFileTreePanel 初始化 | dirs() + filesTreeRoot() 两次 HTTP + 1500ms 重试 | 单次 Rust 调用（~0ms 无网络延迟） |

> 验证方法：在数据目录中放入 100+ 个文件，启动 App 进入知识库页，观察文件树加载速度应显著快于 sidecar 版本。
