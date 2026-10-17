import SwiftUI

struct MessageEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let original: ChatMessage
    let submit: (String) -> Bool
    @State private var text: String
    @State private var failed = false
    @FocusState private var focused: Bool
    init(message: ChatMessage, submit: @escaping (String) -> Bool) {
        original = message; self.submit = submit; _text = State(initialValue: message.text)
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("修改后会创建一段新对话，原来的消息和后续回复会保留。")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $text).focused($focused).scrollContentBackground(.hidden)
                    .padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("编辑消息")
                if failed { Text("暂时无法发送，请检查连接和可用模型。").font(.caption).foregroundStyle(.secondary) }
            }.padding(20).background(Palette.paper)
                .navigationTitle("编辑消息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("发送") { if submit(text) { dismiss() } else { failed = true } }
                            .fontWeight(.semibold).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }.presentationDragIndicator(.visible)
    }
}
