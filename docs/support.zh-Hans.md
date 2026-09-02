# PrivateAI 帮助中心

## 当前状态

PrivateAI 是一个持续开发中的原生 macOS 助手。已签名和公证的开发版本可从 GitHub Releases 下载。

应用需要本机安装 Ollama 和兼容的对话模型。目前支持持久对话、模型选择、Markdown 渲染、内置 Tool 和受管文档附件。可搜索 PDF 与文本格式支持有界精读；整篇文档任务使用可恢复的本地分层摘要。

## 文档分析

使用回形针按钮或从 Finder 拖放受支持文档，然后提出总结或分析请求。长任务会把私有 checkpoint 保存在 `~/.privateAI/jobs/document-summaries`；停止后以相同文档、目标和模型重试，会继续利用已经完成的结果。当前不支持没有可提取文本层的扫描 PDF。

如果文档分析失败，请在私密报告中提供错误信息和应用版本。不要把文档上传到公开 issue。

## 开发构建

请使用兼容版本的 Xcode 打开 `Private AI/Private AI.xcodeproj`，并构建 `Private AI` target。当前部署目标和 SDK 要求以 Xcode 项目配置为准，在重建期间可能变化。

## 下载版本

请从同一个 GitHub Release 下载 `PrivateAI.dmg` 和 `PrivateAI.dmg.sha256`，并在打开 DMG 前验证校验值。每个发布版本都会在 CI 中使用 Developer ID 签名、提交 Apple 公证并通过 Gatekeeper 检查。

## 联系方式

请创建 GitHub issue，并附上 commit、macOS 版本、Xcode 版本和准确的构建或运行错误。请勿在公开 issue 中提交敏感文档、私人数据、API 密钥或其他凭据。安全漏洞请按照 `SECURITY.md` 通过私密渠道报告。
