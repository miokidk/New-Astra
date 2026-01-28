import SwiftUI
import UIKit

struct InlineTextView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onCommit: () -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InlineTextView
        init(_ parent: InlineTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            if replacement == "\n" {
                parent.onCommit()
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.textColor = .white
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        tv.delegate = context.coordinator
        tv.keyboardDismissMode = .interactive
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        tv.font = UIFont.systemFont(ofSize: max(10, fontSize))
        if !tv.isFirstResponder {
            tv.becomeFirstResponder()
        }
    }
}
