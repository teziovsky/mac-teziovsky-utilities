import SwiftUI

/// Placeholder for the Move to External Drive workflow; the real screens land with the UI task.
struct ExternalDriveModeView: View {
    @ObservedObject var service: ExternalDriveTransferService

    var body: some View {
        VStack(spacing: 8) {
            Text(AppBranding.externalDriveModeTitle)
                .font(.title)
            Text("Step: \(String(describing: service.step))")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
