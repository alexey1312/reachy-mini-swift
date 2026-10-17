#if os(visionOS)
    import AVFoundation
    import CoreMedia
    @preconcurrency import LiveKitWebRTC
    import UIKit

    /// The camera's renderer on visionOS, where LiveKit's WebRTC slice has neither view
    /// the other platforms draw with: it ships no `RTCMTLVideoView`, and its
    /// `RTCEAGLVideoView` needs OpenGL ES, which visionOS does not have.
    ///
    /// Each frame goes to an `AVSampleBufferDisplayLayer` as a sample buffer marked for
    /// immediate display, so the layer neither queues nor times anything — WebRTC's
    /// jitter buffer already did. It letterboxes like `RTCMTLVideoView` in
    /// `.scaleAspectFit` and stays transparent until the first frame, which is what
    /// `CameraViewport` expects of a renderer.
    ///
    /// **Rotation is not applied.** The robot's camera sends upright frames with no
    /// rotation extension, so `RTCVideoFrame.rotation` is always 0 from it. A peer that
    /// rotates would show here on its side; that is where to start if one does.
    public final class SampleBufferVideoView: UIView, LKRTCVideoRenderer {
        private let displayLayer = AVSampleBufferDisplayLayer()
        private let sink: FrameSink

        override public init(frame: CGRect) {
            displayLayer.videoGravity = .resizeAspect
            sink = FrameSink(renderer: displayLayer.sampleBufferRenderer)
            super.init(frame: frame)
            layer.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            // A standalone sublayer animates its frame implicitly; a resize must not.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }

        // `LKRTCVideoRenderer` is called on WebRTC's decoding thread, one frame at a time.

        public nonisolated func setSize(_: CGSize) {}

        public nonisolated func renderFrame(_ frame: LKRTCVideoFrame?) {
            guard let frame else { return }
            sink.enqueue(frame.buffer)
        }
    }

    /// The part of the view that runs off the main actor: it turns a WebRTC buffer into a
    /// sample buffer and hands it to the layer's renderer.
    ///
    /// `@unchecked Sendable` because WebRTC calls a renderer from one thread at a time, so
    /// the cached format description and pool are never touched concurrently, and
    /// `AVSampleBufferVideoRenderer` accepts a buffer from any thread.
    private final class FrameSink: @unchecked Sendable {
        private let renderer: AVSampleBufferVideoRenderer
        private var format: CMVideoFormatDescription?
        private var pool: CVPixelBufferPool?
        private var poolSize = CGSize.zero

        init(renderer: AVSampleBufferVideoRenderer) {
            self.renderer = renderer
        }

        func enqueue(_ buffer: any LKRTCVideoFrameBuffer) {
            guard let pixelBuffer = pixelBuffer(for: buffer),
                  let sample = sampleBuffer(for: pixelBuffer)
            else { return }
            // A failed renderer, or one the system stopped while the app was in the
            // background, shows nothing until it is flushed.
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
            }
            renderer.enqueue(sample)
        }

        /// The hardware decoder's output as it is, and anything else (a software VP8
        /// decode, a buffer that needs cropping) through I420 into a pooled NV12 buffer.
        private func pixelBuffer(for buffer: any LKRTCVideoFrameBuffer) -> CVPixelBuffer? {
            if let native = buffer as? LKRTCCVPixelBuffer, !native.requiresCropping() {
                return native.pixelBuffer
            }
            return nv12(from: buffer.toI420())
        }

        private func nv12(from i420: any LKRTCI420BufferProtocol) -> CVPixelBuffer? {
            let width = Int(i420.width)
            let height = Int(i420.height)
            guard let pool = pool(width: width, height: height) else { return nil }
            var output: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
                  let output
            else { return nil }
            CVPixelBufferLockBaseAddress(output, [])
            defer { CVPixelBufferUnlockBaseAddress(output, []) }
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(output, 0)?.assumingMemoryBound(to: UInt8.self),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(output, 1)?.assumingMemoryBound(to: UInt8.self)
            else { return nil }
            let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
            for row in 0 ..< height {
                (luma + row * lumaStride).update(from: i420.dataY + row * Int(i420.strideY), count: width)
            }
            let chromaWidth = Int(i420.chromaWidth)
            for row in 0 ..< Int(i420.chromaHeight) {
                let u = i420.dataU + row * Int(i420.strideU)
                let v = i420.dataV + row * Int(i420.strideV)
                let line = chroma + row * chromaStride
                for column in 0 ..< chromaWidth {
                    line[2 * column] = u[column]
                    line[2 * column + 1] = v[column]
                }
            }
            return output
        }

        private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
            let size = CGSize(width: width, height: height)
            if let pool, poolSize == size {
                return pool
            }
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
            return created
        }

        private func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
            if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
                format = try? CMVideoFormatDescription(imageBuffer: pixelBuffer)
            }
            guard let format else { return nil }
            let timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid
            )
            guard let sample = try? CMSampleBuffer(
                imageBuffer: pixelBuffer,
                formatDescription: format,
                sampleTiming: timing
            ) else { return nil }
            // The collection wraps the buffer's own attachment dictionaries, so writing
            // through a copy of it writes to the buffer.
            var attachments = sample.sampleAttachments
            if !attachments.isEmpty {
                attachments[0][.displayImmediately] = true
            }
            return sample
        }
    }
#endif
