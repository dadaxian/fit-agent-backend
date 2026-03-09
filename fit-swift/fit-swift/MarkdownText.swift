import SwiftUI

import SwiftUI
import MarkdownUI

/// 使用 MarkdownUI 渲染 Markdown 文本，自定义样式以移除背景和边框
struct MarkdownText: View {
    let text: String

    var body: some View {
        // 预处理换行符，确保兼容性
        let processedText = text.replacingOccurrences(of: "\\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "")
        
        Markdown(processedText)
            .markdownTheme(.customTheme)
            .textSelection(.enabled)
            // 确保 Markdown 渲染层本身不带背景色（只由外层容器决定气泡/卡片背景）
            .background(Color.clear)
    }
}

// MARK: - 自定义 Markdown 主题
extension Theme {
    static let customTheme = Theme()
        .text {
            ForegroundColor(.primary)
        }
        .paragraph { configuration in
            configuration.label
                .background(Color.clear)
        }
        .link {
            ForegroundColor(.blue)
        }
        .heading1 { configuration in
            configuration.label
                .font(.title.bold())
                .padding(.vertical, 4)
        }
        .heading2 { configuration in
            configuration.label
                .font(.title2.bold())
                .padding(.vertical, 3)
        }
        .heading3 { configuration in
            configuration.label
                .font(.title3.bold())
                .padding(.vertical, 2)
        }
        .table { configuration in
            configuration.label
        }
        .tableCell { configuration in
            configuration.label
                .padding(8)
        }
        .thematicBreak {
            Divider()
                .overlay(Color.gray.opacity(0.3))
                .padding(.vertical, 8)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 10)
                .overlay(
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2),
                    alignment: .leading
                )
                .background(Color.clear)
        }
        .codeBlock { configuration in
            configuration.label
                .background(Color.clear)
        }
}
