import SwiftUI

struct TextTemplateRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let template: TextTemplate
    let workspaceID: String
    @Binding var selectedID: String?
    @Binding var selectedText: String
    var onDelete: () -> Void
    @Binding var expanded: Bool
    @State private var draft: String
    @State private var hovering = false

    init(template: TextTemplate, workspaceID: String, selectedID: Binding<String?>, selectedText: Binding<String>, onDelete: @escaping () -> Void = {}, expanded: Binding<Bool>) {
        self.template = template; self.workspaceID = workspaceID; _selectedID = selectedID; _selectedText = selectedText; self.onDelete = onDelete; _expanded = expanded
        _draft = State(initialValue:template.text)
    }
    private var selected: Bool { selectedID == template.id }
    private var firstLine: String { TextTemplate(text:draft).title }

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:12) {
                Button {
                    selectedID = template.id; selectedText = draft
                    store.settings.savedText = draft; store.saveSettings()
                } label: {
                    HStack(spacing:11) {
                        Image(systemName:selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(selected ? Theme.indigo : Color.secondary)
                        Text(firstLine.isEmpty ? "未命名文案" : firstLine)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.86))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("选用：\(firstLine.isEmpty ? "未命名文案" : firstLine)")

                CopyButton("复制文案") { try ClipboardCopy.text(draft) }.disabled(draft.isEmpty)
                if !expanded && hovering {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                        .help("删除这条文案")
                }
                Button {
                    if expanded { save() }
                    withAnimation(reduceMotion ? nil : .spring(response:0.3,dampingFraction:1)) { expanded.toggle() }
                } label: { Image(systemName:expanded ? "chevron.up" : "chevron.down").frame(width:24,height:24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(expanded ? "收起文案" : "展开文案")
            }.padding(13)

            if expanded {
                Divider().opacity(0.6).padding(.horizontal,13)
                TextEditor(text:$draft).font(.system(size: 12.5)).scrollContentBackground(.hidden).frame(height:180).padding(11)
                    .background(Surface(scheme).inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 13).padding(.top, 11)
                    .accessibilityLabel("文案正文")
                HStack(spacing: 8) {
                    Text("\(draft.count) 字 · \(draft == template.text ? "已保存" : "待保存")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDelete) { Label("删除", systemImage: "trash") }
                        .buttonStyle(SoftButtonStyle(tint: Theme.rose))
                    Button("另存一份") { store.perform { _ = try store.saveTextTemplate(text:draft) } }
                        .buttonStyle(SoftButtonStyle(tint: Theme.indigo))
                    Button("保存") { save() }
                        .buttonStyle(DepthButtonStyle(compact: true))
                }.padding([.horizontal,.bottom],13).padding(.top,9)
            }
        }
        .background {
            RoundedRectangle(cornerRadius:17, style:.continuous)
                .fill(selected ? Theme.indigo.opacity(scheme == .dark ? 0.14 : 0.06) : Surface(scheme).inset.opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius:17, style:.continuous)
                .strokeBorder(selected ? Theme.indigo.opacity(0.26) : Surface(scheme).hairline.opacity(0.7), lineWidth: selected ? 1.2 : 0.9)
        }
        .shadow(color: selected ? Theme.indigo.opacity(0.16) : .clear, radius: 8, y: 4)
        .onHover { hovering = $0 }
        .onChange(of:draft) { _,value in if selected { selectedText = value } }
        .onDisappear { if draft != template.text { save() } }
    }

    private func save() {
        guard draft != template.text else { return }
        store.perform {
            _ = try store.saveTextTemplate(id:template.id,text:draft,workspaceID:workspaceID)
            if selected && store.workspaceID == workspaceID { store.settings.savedText = draft; store.saveSettings() }
        }
    }
}
