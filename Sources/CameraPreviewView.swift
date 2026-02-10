import Cocoa
import AVFoundation

class CameraPreviewView: NSView {
    private var session: CameraCaptureSession?
    private var completion: ((ToolResult) -> Void)?

    /// Called when the session is ready and preview layer is attached (before countdown).
    /// The parent can use this to drive a reveal animation.
    var onReadyForReveal: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Start the full capture flow: permission → preview → countdown → capture → completion
    func startCapture(completion: @escaping (ToolResult) -> Void) {
        self.completion = completion

        let capture = CameraCaptureSession()
        self.session = capture

        capture.requestAccessAndPrepare { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.attachPreview(capture: capture)
                case .failure(let error):
                    completion(.error(error.localizedDescription))
                    self.session = nil
                }
            }
        }
    }

    func teardown() {
        session?.stopSession()
        session = nil
        completion = nil
    }

    // MARK: - Preview

    private var previewLayer: AVCaptureVideoPreviewLayer?

    private func attachPreview(capture: CameraCaptureSession) {
        // Create preview layer at target size (view may be 0-height during visor)
        let targetBounds = NSRect(x: 0, y: 0, width: bounds.width > 0 ? bounds.width : 380,
                                  height: targetHeight)
        let preview = capture.makePreviewLayer(fitting: targetBounds)
        self.previewLayer = preview
        layer?.addSublayer(preview)

        capture.startSession()

        // Let the parent drive the visor reveal, then start countdown
        if let onReady = onReadyForReveal {
            onReady()
        } else {
            runCountdown(from: 3)
        }
    }

    /// Call after the visor animation completes to fix the preview layer frame.
    func beginCountdown() {
        // Reset preview layer to actual bounds now that the view is full-size
        previewLayer?.frame = bounds
        runCountdown(from: 3)
    }

    /// The full height this view wants to be when fully revealed.
    var targetHeight: CGFloat = 285

    // MARK: - Countdown

    private func runCountdown(from number: Int) {
        let label = makeCountdownLabel()
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        animateNumber(label: label, current: number) { [weak self] in
            label.removeFromSuperview()
            self?.captureAndFinish()
        }
    }

    private func animateNumber(label: NSTextField, current: Int, done: @escaping () -> Void) {
        label.stringValue = "\(current)"
        label.alphaValue = 0
        label.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.3, y: 1.3))

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 1
            label.layer?.setAffineTransform(.identity)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let fadeOut = { (onDone: @escaping () -> Void) in
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.2
                        label.animator().alphaValue = 0
                    }, completionHandler: onDone)
                }

                if current > 1 {
                    fadeOut { self?.animateNumber(label: label, current: current - 1, done: done) }
                } else {
                    fadeOut(done)
                }
            }
        })
    }

    // MARK: - Capture

    private func captureAndFinish() {
        guard let session = self.session else {
            completion?(.error("Camera session lost"))
            return
        }

        session.capturePhoto { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let jpegData):
                    self.showFlashAndStill(jpegData: jpegData)
                case .failure(let error):
                    self.finish(with: .error("Capture failed: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func showFlashAndStill(jpegData: Data) {
        // Flash
        let flash = NSView(frame: bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        flash.alphaValue = 0
        flash.autoresizingMask = [.width, .height]
        addSubview(flash)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            flash.animator().alphaValue = 0.6
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                flash.animator().alphaValue = 0
            }, completionHandler: {
                flash.removeFromSuperview()
            })
        })

        // Still image
        if let image = NSImage(data: jpegData) {
            let imageView = NSImageView(frame: bounds)
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        // Hold briefly, then finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.finish(with: .image(data: jpegData, mediaType: "image/jpeg"))
        }
    }

    private func finish(with result: ToolResult) {
        session?.stopSession()
        session = nil

        // Fade out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
            self?.completion?(result)
            self?.completion = nil
        })
    }

    // MARK: - Factory

    private func makeCountdownLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 48, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.wantsLayer = true
        label.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.7)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        return label
    }
}

// MARK: - Camera Capture Session (AVFoundation)

class CameraCaptureSession {
    private var session: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var captureHandler: PhotoCaptureHandler?

    func requestAccessAndPrepare(completion: @escaping (Result<Void, Error>) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                let error = NSError(domain: "CameraTool", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Camera access denied. Please enable in System Settings > Privacy & Security > Camera."])
                completion(.failure(error))
                return
            }

            let session = AVCaptureSession()
            session.sessionPreset = .photo

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                let error = NSError(domain: "CameraTool", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not access camera"])
                completion(.failure(error))
                return
            }

            session.addInput(input)

            let output = AVCapturePhotoOutput()
            session.addOutput(output)

            self.session = session
            self.photoOutput = output
            completion(.success(()))
        }
    }

    func makePreviewLayer(fitting bounds: NSRect) -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session!)
        layer.videoGravity = .resizeAspectFill
        layer.cornerRadius = 12
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        return layer
    }

    func startSession() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session?.startRunning()
        }
    }

    func stopSession() {
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
        self.session = nil
        self.photoOutput = nil
        self.captureHandler = nil
    }

    func capturePhoto(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let photoOutput = self.photoOutput else {
            completion(.failure(NSError(domain: "CameraTool", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Photo output not available"])))
            return
        }

        let handler = PhotoCaptureHandler(completion: completion)
        self.captureHandler = handler
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: handler)
    }
}

// MARK: - Photo Capture Delegate

private class PhotoCaptureHandler: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            completion(.failure(error))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            completion(.failure(NSError(domain: "CameraTool", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No image data"])))
            return
        }

        guard let image = NSImage(data: data) else {
            completion(.failure(NSError(domain: "CameraTool", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid image data"])))
            return
        }

        // Scale down and compress (matches ScreenshotTool)
        let scaledSize = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        let scaledImage = NSImage(size: scaledSize)
        scaledImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: scaledSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        scaledImage.unlockFocus()

        guard let tiffData = scaledImage.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else {
            completion(.failure(NSError(domain: "CameraTool", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Failed to compress photo"])))
            return
        }

        completion(.success(jpegData))
    }
}
