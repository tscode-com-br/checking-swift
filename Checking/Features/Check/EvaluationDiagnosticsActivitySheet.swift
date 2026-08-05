#if DEBUG
import SwiftUI
import UIKit

/// Ponte de share UIKit exclusiva da tela de validação. A conclusão — inclusive cancelamento — volta para a
/// tela para que o arquivo temporário seja removido; não há upload nem comportamento automático.
@MainActor
struct EvaluationDiagnosticsActivitySheet: UIViewControllerRepresentable {
    let exportURL: URL
    let onCompletion: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [exportURL], applicationActivities: nil)
        controller.completionWithItemsHandler = { [onCompletion] _, _, _, _ in
            Task { @MainActor in onCompletion() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
