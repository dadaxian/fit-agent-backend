# FitFlow 私教 · 原生 Swift iOS App

纯 SwiftUI 原生 iOS 应用，对接 fit-agent 后端（Aegra + LangGraph）。

## 功能

- **AI 私教**：与 AI 对话，支持文本输入、语音输入、TTS 朗读
- **首页 / 训练 / 评估 / 饮食 / 我的**：占位页，待扩展

## 环境要求

- Xcode 15+
- iOS 17+
- macOS（用于运行后端）

## 快速开始

### 1. 打开项目

```bash
cd fit-swift
open fit-swift.xcodeproj
```

### 2. 配置签名

在 Xcode 中：**Signing & Capabilities** → 选择你的 **Team**。

### 3. 启动后端

在项目根目录：

```bash
uv run aegra dev
```

### 4. 配置 API 地址

- **默认**：`http://139.196.181.42:8000`（可在「我的」中修改）

### 5. 运行

选择模拟器或真机，点击 Run (⌘R)。

## 项目结构

```
fit-swift/
├── fit-swift.xcodeproj
├── fit-swift/
│   ├── fit-swiftApp.swift      # App 入口
│   ├── ContentView.swift       # Tab 导航
│   ├── ChatView.swift          # AI 私教聊天页
│   ├── ChatViewModel.swift     # 聊天逻辑
│   ├── APIClient.swift         # LangGraph API 客户端
│   ├── VoiceService.swift      # ASR / TTS
│   ├── AudioRecorder.swift     # 麦克风录音
│   ├── DashboardView.swift      # 首页
│   ├── SettingsView.swift      # 设置（API 地址）
│   └── *PlaceholderView.swift  # 占位页
└── README.md
```

## 使用 XcodeGen（可选）

若已安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
cd fit-swift
xcodegen generate
open fit-swift.xcodeproj
```

## 与 fitter（Capacitor）的区别

| 项目 | 技术栈 | 特点 |
|------|--------|------|
| fitter | React + Vite + Capacitor | 跨平台，Web 技术 |
| fit-swift | 原生 Swift + SwiftUI | 原生交互，无 WebView |
