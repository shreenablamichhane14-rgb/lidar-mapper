import SwiftUI

/// The pre-permission screen shown before iOS asks for the camera (UX_COPY section 16):
/// `Copy.Permissions.cameraTitle`, `cameraBody` and a Continue button at the bottom (one-hand
/// reach) that makes the scan flow call `AVCaptureDevice.requestAccess`. Cancel ends the flow.
/// Forced dark by `RoomScanScreen`.
struct ScanPermissionScreen: View {
    /// True while the iOS prompt is up (Continue disabled).
    let isRequesting: Bool
    /// Continue: ask iOS for the camera.
    let onContinue: () -> Void
    /// Cancel: end the flow.
    let onCancel: () -> Void

    /// Scaled icon size.
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

    /// Creates the screen.
    init(isRequesting: Bool, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.isRequesting = isRequesting
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    /// Cancel at the top, the explanation in the middle, Continue at the bottom.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(Copy.Scanning.cancel, action: onCancel)
                    .font(.body.weight(.semibold))
                    .padding(.vertical, 12)
                Spacer()
            }
            .padding(.horizontal, 16)
            Spacer(minLength: 16)
            VStack(spacing: 20) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: iconSize, weight: .light))
                    .foregroundStyle(Color.white)
                    .accessibilityHidden(true)
                Text(Copy.Permissions.cameraTitle)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                Text(Copy.Permissions.cameraBody)
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer(minLength: 16)
            Button(action: onContinue) {
                HStack(spacing: 10) {
                    if isRequesting {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                    Text(Copy.Permissions.cameraContinue)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
