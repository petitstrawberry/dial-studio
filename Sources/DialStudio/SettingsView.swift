import SwiftUI
import AppKit
import IOKit.hidsystem
import UlanziKit

struct SettingsView: View {
    @Bindable var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("接続")) {
                    LabeledContent(L("状態"), value: model.state.connected == true ? L("D100H 接続中") : L("未接続"))
                    Picker(L("接続方式"), selection: $model.configuration.mode) { ForEach(InputMode.allCases) { Text($0.title).tag($0) } }
                    HStack {
                        Button(L("保存して反映"), action: model.save)
                        Button(model.running ? L("サービスを停止") : L("サービスを起動")) { model.running ? model.stopService() : model.startService() }
                    }
                    if model.configuration.mode.usesHelper {
                        Button(model.helperBusy ? L("認証待ち…") : L("管理者認証で HID ヘルパーを起動"), action: model.startHelper).disabled(model.helperBusy)
                    }
                    Text(L("ベンダーモードは応答を確認してから有効になります。接続に失敗した場合はログに理由を表示します。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("一般")) {
                    HStack { Text(L("長押しの判定")); Spacer(); TextField("", value: $model.configuration.holdMilliseconds, format: .number).frame(width: 65); Text(L("ミリ秒")).foregroundStyle(.secondary) }
                    Toggle(L("メニューバーに常駐（Dockに表示しない）"), isOn: Binding(get: { model.configuration.menuBarOnly }, set: {
                        model.configuration.menuBarOnly = $0
                        model.onMenuBarModeChange?($0)
                    }))
                    Toggle(L("ログイン時に起動する"), isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Button(L("設定ファイルを Finder で表示")) { NSWorkspace.shared.activateFileViewerSelecting([model.configURL]) }
                }
                Section(L("レイヤー切り替えの表示")) {
                    Toggle(L("バナーを表示"), isOn: $model.configuration.showHUD)
                    Picker(L("位置"), selection: $model.configuration.hudPosition) {
                        ForEach(HUDPosition.allCases) { Text($0.title).tag($0) }
                    }.disabled(!model.configuration.showHUD)
                    Button(L("表示を確認")) { model.onLayerChange?(L("YouTube  /  再生")) }.disabled(!model.configuration.showHUD)
                }
                Section(L("ボタンの校正")) {
                    if [.vendor, .exclusiveVendor].contains(model.configuration.mode) && model.configuration.vendorLayout.count < 7 {
                        Text(L("未校正のボタンは、信号を受信しても割り当てが動作しません。校正後に保存・反映してください。"))
                            .foregroundStyle(.orange)
                    }
                    Text(L("位置を選び、その位置の実機ボタンを1回押してください。校正中はアクションを実行しません。")).font(.callout)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        ForEach(Control.buttons.filter { $0 != .knob }) { control in
                            GridRow {
                                Text(control.title)
                                Text(model.configuration.vendorLayout.first { $0.value == control }.map { LF("ボタン %@", $0.key) } ?? L("未設定")).foregroundStyle(.secondary)
                                Button(model.calibrating == control ? L("押してください…") : L("校正")) { model.send(ServiceCommand("calibrate")); model.calibrating = control }
                            }
                        }
                    }.disabled(![InputMode.vendor, .exclusiveVendor].contains(model.configuration.mode) || !model.running)
                    HStack {
                        Text(LF("最終受信: %@", model.lastVendorButton.map { LF("ボタン %@", String($0)) } ?? L("なし"))).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("校正を終了して反映")) { model.save(); model.calibrating = nil; model.send(ServiceCommand("endCalibration")) }
                    }
                    Text(L("ノブの長押し・押し回しは実機検証が必要です。ボタンを押したままの操作には側面ボタンを推奨します。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("アプリ連携")) {
                    HStack {
                        Text(LF("入力監視: %@", inputMonitoringStatus))
                        Spacer()
                        Button(L("入力監視を許可…")) {
                            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                            openSettings("Privacy_ListenEvent")
                        }
                    }
                    HStack { Button(L("アクセシビリティ設定を開く")) { openSettings("Privacy_Accessibility") }; Button(L("オートメーション設定を開く")) { openSettings("Privacy_Automation") } }
                    Text(L("Chrome: 表示 → 開発 / デベロッパー → Apple Events からの JavaScript を許可。\nLogic: Mackie Control の入出力を Dial Studio MCU に設定。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("プラグイン")) {
                    HStack {
                        Button(L("プラグインを追加…"), action: model.installPlugin)
                        Button(L("フォルダを開く"), action: model.openPluginsFolder)
                        Button(L("再読み込み"), action: model.refreshPlugins)
                    }
                    ForEach(model.plugins, id: \.manifest.id) { plugin in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(plugin.manifest.name).font(.headline)
                            LabeledContent(L("作者"), value: plugin.manifest.author.map(L) ?? L("未記載"))
                            LabeledContent(L("説明"), value: plugin.manifest.description.map(L) ?? L("未記載"))
                            LabeledContent(L("ライセンス"), value: plugin.manifest.license ?? L("未記載"))
                            LabeledContent(L("バージョン"), value: plugin.manifest.version)
                            if plugin.directory.deletingLastPathComponent().standardizedFileURL == PluginRegistry.directory.standardizedFileURL {
                                Button(L("削除")) { model.removePlugin(plugin) }
                            }
                        }
                    }
                    ForEach(model.pluginErrors, id: \.self) { message in
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack { Button(L("保存して反映"), action: model.save); Spacer(); Button(L("閉じる")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(16)
        }.frame(width: 620, height: 700)
        .onDisappear { model.calibrating = nil; model.send(ServiceCommand("endCalibration")) }
    }
    private var inputMonitoringStatus: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return L("許可済み")
        case kIOHIDAccessTypeDenied: return L("拒否")
        default: return L("未確認")
        }
    }
    private func openSettings(_ pane: String) { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) } }
}
