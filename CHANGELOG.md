# 更新日志

## v1.0.7 (2026-08-07)：新增全局签与多语言支持

### 界面优化

* 优化设置页面样式。
* 优化首页更多列表样式，移除冗余悬浮提示信息。
* 完善官网使用文档。

### 功能新增

* 新增全局签功能，AI 自动将日报中的待办与问题整理为常驻清单，支持完成、取消、修改和删除，变更可写回当日日报。([#88](https://github.com/Radiant303/XiaoYuNote/issues/88)；感谢 [Radiant303](https://github.com/Radiant303))
* 新增界面多语言支持。
* 新增回忆书对话历史导航。
* 新增周报整理提示词自定义。
* 首页智能生成的 AI 请求改为异步执行，提升响应速度。


## v1.0.6 (2026-07-31)：新增思维导图问答模式

### 界面优化

* 优化回忆书输入框。
* 优化官网样式，完善使用文档。

### 功能新增

* 新增思维导图问答模式，在回忆书输入框的“+”菜单中插入“思维导图”标签后，AI 回答将以放射状思维导图呈现，便签页 Markdown 预览同步支持该格式。
* 新增发送消息快捷键选项，首页和回忆书输入框支持 Enter 发送或 Ctrl/Cmd+Enter 发送。
* 优化便签页编辑与预览切换体验，大文档切换更流畅。
* 优化 Markdown 图片解码方式，按显示尺寸加载以降低内存占用。
* 优化周报、月报生成提示词，统一标题格式。

### 问题修复

* 修复思维导图内存异常驻留的问题。
* 修复回忆书页面存在点击死区的问题。
* 修复移动端首页无法打开官方文档的问题。


## v1.0.5 (2026-07-24)：新增日报周报月报再生成功能

### 界面优化

* 优化便签页编辑器工具栏图标样式和悬停效果。
* 优化便签页提示信息显示，成功类提示改为绿色高亮。
* 优化便签页各类分隔线和标题下方线条样式。
* 优化协议选择下拉框样式。

### 功能新增

* 新增日报、周报和月报再生成功能。([#84](https://github.com/Radiant303/XiaoYuNote/issues/84)；感谢 [Radiant303](https://github.com/Radiant303))
* 回忆书问答新增支持 Gemini 和 Claude 供应商。
* 编辑模型信息新增“补全协议”选项，并适配 Qwen 补全格式。
* 回忆书部分工具结果增加截断字段，模型可判断返回内容是否完整。

### 问题修复

* 修复便签页提示信息未被新消息覆盖的问题。


## v1.0.4 (2026-07-17)：新增首页三栏自定义功能

### 界面优化

* 优化主应用侧边栏、便签类型菜单和便签搜索列表的切换与选中效果。
* 优化首页三栏详情弹窗和模型供应商页面样式。
* 优化部分按钮悬浮提示的显示时机。
* 优化快捷键设置页面，移除与开关功能重复的清除按钮。
* 优化更新图标，完善中文和英文[用户手册](https://radiant303.github.io/XiaoYuNote)。
* 优化项目开发规范，完善开发说明和代码检查规则。([#83](https://github.com/Radiant303/XiaoYuNote/pull/83)；感谢 [liuwanwan1](https://github.com/liuwanwan1))

### 功能新增

* 新增首页三栏自定义功能，支持修改栏目标题和 AI 说明，并可点击栏目查看完整内容。
* 新增回忆书日报、周报和月报关键词搜索工具，优化查询时间工具返回结果。
* AI 回复期间支持继续编辑输入框内容。([#81](https://github.com/Radiant303/XiaoYuNote/issues/81)；感谢 [Radiant303](https://github.com/Radiant303))
* 模型供应商列表支持按供应商名称搜索。
* 优化便签搜索功能，提升关键词检索速度。

### 问题修复

* 修复 Windows 下启动时数据目录可能恢复为默认位置的问题。
* 修复便签搜索结果列表项闪烁的问题。
* 修复添加模型信息页面残留“全局”文本的问题。
* 修复回忆书页面存在冗余提示词的问题。
* 修复windows缺失dll导致无法启动应用的问题。


## v1.0.3 (2026-07-10)：新增深色模式、壁纸与 Markdown 编辑增强

### 界面优化

* 优化便签编辑右上角“已保存”和编辑预测提示的切换显示。([#71](https://github.com/Radiant303/XiaoYuNote/issues/71)；感谢 [Radiant303](https://github.com/Radiant303))
* 优化 Markdown 渲染样式，优化标题、表格、公式、任务列表等内容的显示效果。
* 优化官网样式，完善配置教程。


### 功能新增

* 新增深色模式支持，并适配 Windows/macOS 桌面组件。([#72](https://github.com/Radiant303/XiaoYuNote/pull/72)、[#73](https://github.com/Radiant303/XiaoYuNote/pull/73)；感谢 [jinnian0703](https://github.com/jinnian0703))
* 新增应用和桌面组件壁纸功能，支持默认背景、透明度、模糊和蒙版等配置。([#76](https://github.com/Radiant303/XiaoYuNote/pull/76)；感谢 [lovewanting](https://github.com/lovewanting))
* 新增便签页编辑、分栏和预览模式。
* 新增 Markdown 编辑器语法高亮，支持在设置中开关，默认启用。
* Markdown 渲染中的链接支持点击后使用浏览器打开。
* 快捷键设置支持直接录入组合键，并可重置或清除全局快捷键。
* 新增存储管理功能，可扫描 `notes/images` 中未被便签引用的图片并在确认后清理。

### 问题修复

* 修复便签页自动同步时上传对象漏传的问题。
* 修复回忆书本地降级检索中的工具调用上下文格式不兼容，导致部分模型请求返回 400 的问题。
* 修复 Markdown 渲染中的表格、嵌套方括号和部分链接解析异常。
* 修复桌面组件高频拖动时状态循环、纯色切换异常以及字体缩放下三态控件边界异常的问题。


## v1.0.2 (2026-07-03)：新增WebDav同步功能

### 界面优化

* 优化快捷键设置页面结构，移除重复标题([#54](https://github.com/Radiant303/XiaoYuNote/pull/54); 感谢[jinnian0703](https://github.com/jinnian0703)))
* 优化设置页面样式，增加了对删除提供商的弹窗二次确认。

### 功能新增

* 新增首页图片解析功能，支持 AI 识别图片内容。([#60](https://github.com/Radiant303/XiaoYuNote/pull/60); 感谢 [lxfight](https://github.com/lxfight))
* 新增WebDav同步功能。([#56](https://github.com/Radiant303/XiaoYuNote/pull/56); 感谢[jinnian0703](https://github.com/jinnian0703))
* 新增首页与回忆书快速提交快捷键([#39](https://github.com/Radiant303/XiaoYuNote/pull/39); 感谢[jinnian0703](https://github.com/jinnian0703))
* 支持便签页面插入和预览图片([#41](https://github.com/Radiant303/XiaoYuNote/pull/41); 感谢[jinnian0703](https://github.com/jinnian0703))
* 新增 Windows/macOS 应用内自动更新功能，新增手动更新选项。([#63](https://github.com/Radiant303/XiaoYuNote/pull/63); 感谢 [lxfight](https://github.com/lxfight))
* 为 Windows 桌面小组件增加跨重启位置持久化功能。([#47](https://github.com/Radiant303/XiaoYuNote/issues/47); 感谢 [lxfight](https://github.com/lxfight))
* 新增回忆书页面AI能力配置功能。

### 问题修复

* 修复 Windows 下多次启动未复用已有窗口的问题。([#52](https://github.com/Radiant303/XiaoYuNote/pull/52)；感谢 [jinnian0703](https://github.com/jinnian0703))
* 修复便签页搜索无法匹配完整内容的问题。([#57](https://github.com/Radiant303/XiaoYuNote/issues/57)；感谢 [Radiant303](https://github.com/Radiant303))
* 修复百炼官方 DeepSeek 无法调用工具的问题。([#46](https://github.com/Radiant303/XiaoYuNote/issues/46)；感谢 [Radiant303](https://github.com/Radiant303))
* 修复 AI 调用统计写入可能不完整的问题。([#49](https://github.com/Radiant303/XiaoYuNote/pull/49)；感谢 [lxfight](https://github.com/lxfight))
* 修复启动时配置文件损坏导致应用崩溃的问题。([#51](https://github.com/Radiant303/XiaoYuNote/pull/51)；感谢 [jinnian0703](https://github.com/jinnian0703))
* 修复桌面组件球形模式快速移动时显示异常的问题。([#38](https://github.com/Radiant303/XiaoYuNote/pull/38)；感谢 [lxfight](https://github.com/lxfight))
* 修复跨平台网络权限声明不一致问题。([#62](https://github.com/Radiant303/XiaoYuNote/pull/62)；感谢 [lxfight](https://github.com/lxfight))

## v1.0.1 (2026-06-26)

### 界面优化

* 将设置图标更换为轮廓风格齿轮图标。
* 优化模型选择页面; 支持按提供商分组展示模型。([#17](https://github.com/Radiant303/XiaoYuNote/pull/17); 感谢 [lxfight](https://github.com/lxfight))
* 设置关于页面新增QQ群联系方式。([#20](https://github.com/Radiant303/XiaoYuNote/issues/20); 感谢 [Radiant303](https://github.com/Radiant303))


### 功能新增

* 支持自定义日报整理提示词。([#7](https://github.com/Radiant303/XiaoYuNote/issues/7); 感谢 [Radiant303](https://github.com/Radiant303))
* 支持 OpenAI /responses API。([#15](https://github.com/Radiant303/XiaoYuNote/pull/15); 感谢 [jinnian0703](https://github.com/jinnian0703))
* 支持自定义配置文件存储目录。([#15](https://github.com/Radiant303/XiaoYuNote/pull/15); 感谢 [jinnian0703](https://github.com/jinnian0703))
* 新增默认模型配置功能。([#17](https://github.com/Radiant303/XiaoYuNote/pull/17); 感谢 [lxfight](https://github.com/lxfight))
* 新增附件的文件路径上传功能。([#21](https://github.com/Radiant303/XiaoYuNote/pull/21); 感谢 [lxfight](https://github.com/lxfight))
* 新增组件圆球化样式及记忆组件位置功能。([#27](https://github.com/Radiant303/XiaoYuNote/pull/27); 感谢 [lxfight](https://github.com/lxfight))
* 新增回忆书检索结果最大字符数配置([#29](https://github.com/Radiant303/XiaoYuNote/issues/29); 感谢 [Radiant303](https://github.com/Radiant303))

### 问题修复

* 修复切换日期时日期选择器按钮闪烁的问题。([#6](https://github.com/Radiant303/XiaoYuNote/issues/6); 感谢 [Radiant303](https://github.com/Radiant303))
* 修复日报内容底部显示被截断的问题。([#12](https://github.com/Radiant303/XiaoYuNote/issues/12); 感谢 [Radiant303](https://github.com/Radiant303))
* 修复启用 max 推理强度参数后 GPT 请求异常的问题。([#15](https://github.com/Radiant303/XiaoYuNote/pull/15); 感谢 [jinnian0703](https://github.com/jinnian0703))
* 修复模型选择列表中的冲突问题。([#17](https://github.com/Radiant303/XiaoYuNote/pull/17); 感谢 [lxfight](https://github.com/lxfight))
* 修复打开便签日报页面无法自动生成日报的问题([#28](https://github.com/Radiant303/XiaoYuNote/issues/28); [Radiant303](https://github.com/Radiant303))

### 平台支持

* 新增Mac端支持。([#21](https://github.com/Radiant303/XiaoYuNote/issues/21); 感谢 [lxfight](https://github.com/lxfight))

## v1.0.0 (2026-06-21)

- 实现了更新功能
- 优化了软件默认图标
- 正式版发布
