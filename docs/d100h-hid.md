# D100H: 解析の出典と、この実装で確認した範囲

以前のメモにあった「ベンダーにはボタンが載らない」「マウスホイールがノブと思われる」などの
記述は撤回。標準／オフラインの観測と、ベンダーモードを分けて扱う。

## 出典

最初に指定された [brendanwelsh/ulanzi-d100h-homebrew](https://github.com/brendanwelsh/ulanzi-d100h-homebrew)
の README と docs 一式を読み、commit `139bdac92a78607135f9c61296f0417b7d601369` を参照した。
特に [hardware.md](https://github.com/brendanwelsh/ulanzi-d100h-homebrew/blob/main/docs/hardware.md)、
[offline-protocol.md](https://github.com/brendanwelsh/ulanzi-d100h-homebrew/blob/main/docs/offline-protocol.md)、
[issue #2](https://github.com/brendanwelsh/ulanzi-d100h-homebrew/issues/2) を参照。
Windows のコレクション制約や既定状態の観測は macOS の限界を示すものではない。

issue #2 から参照される [ftl/hamdial protocol.md](https://github.com/ftl/hamdial/blob/master/doc/protocol.md)
と [event.go](https://github.com/ftl/hamdial/blob/master/event.go) に、ベンダーモードの keepalive・
ボタン別押下／解放・回転コードがある。本実装のコード表の根拠はこの2ファイル。
デバイス図とプロトコル番号の対応は固定せず、GUI の校正でユーザーが記録する。

## ベンダーモード

Report ID 0xFB。64バイトのペイロードはコード8バイト、トークン8バイト、残り48バイト。
本 Mac の IOHID 出力には Report ID を先頭に加えた65バイトを渡す。

- keepalive: `24 56 9E F2 28 E1 45 A1`
- token: `38 90 C4 99 A3 60 AA AD`
- 応答コード: `21 F4 5E B7 1C 35 87 AB`
- 右回転: `3E DD 5F 9E 87 6A F4 2C`
- 左回転: `B0 6B E5 36 DB E9 2E 9D`

2026-10-26、この Mac と実機 D100H の一般ユーザー権限で
`ulanzid watch --vendor --seconds 8` を実行。トークン一致の keepalive 応答を継続受信した。
終了時は HID を閉じ、keepalive を停止した。

公開仕様上、7ボタンには個別の押下・解放イベントがある。ノブ押下は離した時に
押下と解放が続けて出るため、ノブそのものを押したままのコンビネーションは保証しない。
実機の全ボタン操作、物理配置、OS 標準動作が回転時に発火しないことは別途実操作で確認が必要。
接続応答の成功だけを、これらの検証完了とは扱わない。

## 標準／オフライン入力

この個体は VID 0xFFF1 / PID 0x0082、Bluetooth Low Energy。

| ID | ペイロード（IDを除く） | 内容 |
|---|---|---|
| 1 | 8 bytes | modifier、reserved、6 keycodes |
| 2 | 2 bytes | Consumer usage (little endian) |
| 3 | 5 bytes | buttons、X、Y、wheel、AC Pan |
| 0xFB / 0xFC | 64 bytes | Vendor |

ユーザー提供ログには ID が先頭に含まれる9/3/6バイトの標準入力がある。
`02 E9 00`、`02 CD 00`、`02 B6 00`、`02 B5 00`、Ctrl+V/C/Y/Z と全ゼロの解除を確認。
ログだけから 0xCD を「ノブ押下」と断定できない。ノブと上段中央の区別もこのログだけでは確定しない。
Mouse の全ゼロはノブ押下と解釈しない。

標準接続の物理マッピングは互換用の仮定を含み、推奨経路はベンダーモード＋校正。
標準入力の排他オープン自体はユーザーの root helper 実行ログで成功を確認済み。
新しい GUI 用 root helper の起動・切断連携は一般権限テストのみであり、管理者認証での実機試験は未実施。

## Logic の MIDI

ジョグは CC 0x3C、相対値の方向ビット0x40・大きさ1〜63。pitch bend はフェーダー用途。
参照: [Control Surface MCU CC definitions](https://tttapa.github.io/Control-Surface/Doxygen/d0/d7e/group__MCU__CC.html)、
[TouchMCU protocol](https://github.com/NicoG60/TouchMCU/blob/main/doc/mackie_control_protocol.md)。
