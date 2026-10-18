import SwiftUI

struct ModelReasoningEditor: View {
    let model: String
    @Binding var options: [String]?
    var body: some View {
        Form {
            Section {
                Toggle("自动识别", isOn: Binding(get: { options == nil }, set: { automatic in
                    options = automatic ? nil : []
                })).tint(Palette.switchTint)
            } footer: { Text("根据此服务商的模型能力设置。自定义未勾选任何档位时，只使用默认设置。") }
            if options != nil {
                Section("支持的强度") {
                    ForEach(ReasoningEffort.allCases.filter { $0 != .automatic }) { effort in
                        Toggle(effort.title + " · " + effort.rawValue, isOn: Binding(
                            get: { options?.contains(effort.rawValue) == true }, set: { selected in
                                var values = options ?? []
                                if selected { if !values.contains(effort.rawValue) { values.append(effort.rawValue) } }
                                else { values.removeAll { $0 == effort.rawValue } }
                                options = values
                            })).tint(Palette.switchTint)
                    }
                }
            }
        }.navigationTitle(model).navigationBarTitleDisplayMode(.inline)
    }
}
