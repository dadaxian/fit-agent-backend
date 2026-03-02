import SwiftUI

/// 渲染 Markdown 文本，支持 **粗体**、*斜体*、`代码`、链接等
struct MarkdownText: View {
    let text: String

    var body: some View {
        if let attr = try? AttributedString(markdown: text) {
            Text(attr)
        } else {
            Text(text)
        }
    }
}
