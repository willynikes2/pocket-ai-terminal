import SwiftUI
import SwiftTerm

struct TerminalModeView: UIViewRepresentable {
    let terminalStream: TerminalStream

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        tv.terminalDelegate = context.coordinator
        return tv
    }

    func updateUIView(_ tv: TerminalView, context: Context) {
        // Wire output callback each update to keep reference current
        context.coordinator.terminalView = tv
        context.coordinator.stream = terminalStream

        terminalStream.onRawOutput = { data in
            DispatchQueue.main.async {
                tv.feed(byteArray: [UInt8](data))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(stream: terminalStream)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        weak var terminalView: TerminalView?
        var stream: TerminalStream

        init(stream: TerminalStream) {
            self.stream = stream
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            stream.sendResize(cols: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            stream.sendInput(Data(data))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Could update navigation title in the future
        }

        func scrolled(source: TerminalView, position: Double) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
    }
}
