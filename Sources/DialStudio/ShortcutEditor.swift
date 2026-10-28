import AppKit
import SwiftUI
import UlanziKit

struct ShortcutEditor: View {
    @Binding var value: String
    @State private var recording = false
    @State private var unsupported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                TextField("cmd+shift+p", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .disabled(recording)
                Button(recording ? L("キャンセル") : L("キーを記録")) {
                    recording.toggle()
                    unsupported = false
                }
                .controlSize(.small)
            }
            if recording {
                Text(unsupported ? L("このキーは登録できません。別のキーを押してください。") : L("登録するキーの組み合わせを押してください。"))
                    .font(.caption).foregroundStyle(.secondary)
                ShortcutCapture { result in
                    if let result {
                        value = result
                        recording = false
                    } else {
                        unsupported = true
                    }
                }
                .frame(width: 1, height: 1)
            }
        }
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let onKey: (String?) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
    }

    final class CaptureView: NSView {
        var onKey: ((String?) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
            onKey?(InputMonitor.KeySpec.recorded(keyCode: event.keyCode, flags: flags))
        }
    }
}
