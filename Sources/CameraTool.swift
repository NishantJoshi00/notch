import Foundation
import AVFoundation

class CameraTool: NotchTool {
    let name = "camera"
    let description = "Look through the camera. See them, see what they're showing you."
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [:],
        "required": []
    ]

    /// Optional UI capture handler (conversation mode).
    /// Return `true` if the handler took over (shows preview, countdown, etc.).
    /// Return `false` to fall back to direct capture (mind mode).
    var uiCaptureHandler: ((@escaping (ToolResult) -> Void) -> Bool)?

    func execute(input: [String: Any], completion: @escaping (ToolResult) -> Void) {
        DispatchQueue.main.async { [self] in
            if let handler = uiCaptureHandler, handler(completion) {
                return
            }
            captureDirectly(completion: completion)
        }
    }

    // MARK: - Direct Capture (no UI)

    /// Keep a strong reference so the session stays alive through the async flow.
    private var activeSession: CameraCaptureSession?

    private func captureDirectly(completion: @escaping (ToolResult) -> Void) {
        let session = CameraCaptureSession()
        self.activeSession = session

        session.requestAccessAndPrepare { [weak self] result in
            switch result {
            case .success:
                session.startSession()
                // Brief warmup so the camera auto-adjusts exposure
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                    session.capturePhoto { captureResult in
                        session.stopSession()
                        self?.activeSession = nil
                        switch captureResult {
                        case .success(let data):
                            completion(.image(data: data, mediaType: "image/jpeg"))
                        case .failure(let error):
                            completion(.error("Capture failed: \(error.localizedDescription)"))
                        }
                    }
                }
            case .failure(let error):
                self?.activeSession = nil
                completion(.error(error.localizedDescription))
            }
        }
    }
}
