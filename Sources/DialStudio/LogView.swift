import SwiftUI
import UlanziKit

struct LogView: View {
    let model: StudioModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("実行ログ")).font(.headline)
                Spacer()
                Button(L("閉じる")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            Table(model.activities) {
                TableColumn(L("時刻")) { Text($0.time, style: .time).foregroundStyle(.secondary) }.width(64)
                TableColumn(L("種類")) { Text($0.category).foregroundStyle($0.category == "error" ? Color.red : .secondary) }.width(76)
                TableColumn(L("内容")) { Text($0.text).textSelection(.enabled) }
            }
        }
        .frame(width: 760, height: 420)
    }
}
