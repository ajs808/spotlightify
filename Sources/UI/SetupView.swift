import SwiftUI

/// First-launch form for pasting the user's own Spotify Client ID.
struct SetupView<ClientIDField: View>: View {
    @ObservedObject var viewModel: SearchViewModel
    /// Supplied by the parent so it can own focus for the text field.
    @ViewBuilder let clientIDField: () -> ClientIDField

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bring your own Spotify app")
                        .font(.system(size: 23, weight: .black, design: .rounded))
                        .foregroundStyle(Color.ink)

                    Text("Create a Spotify developer app, add the redirect below, then paste its Client ID here. The value stays local to this Mac.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SetupStep(number: "1", title: "Spotify redirect URI", detail: viewModel.redirectURI, emphasis: true)
                    SetupStep(number: "2", title: "Allowed API", detail: "Enable Spotify Web API for the app.")
                    SetupStep(number: "3", title: "Paste Client ID", detail: "Client secret is not used and should never be stored here.")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Spotify Client ID")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(Color.inkSecondary)
                        .textCase(.uppercase)
                        .tracking(1.3)

                    clientIDField()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .modifier(NativeGlassBackground(cornerRadius: 18))
                }

                HStack(spacing: 12) {
                    Button("Save Client ID") {
                        viewModel.saveClientID()
                    }
                    .modifier(NativeGlassButtonStyle(prominent: true))
                    .controlSize(.large)
                    .font(.system(size: 14, weight: .bold))

                    if viewModel.hasSavedClientID {
                        Button("Clear Saved Setup") {
                            viewModel.clearConfiguration()
                        }
                        .modifier(NativeGlassButtonStyle())
                        .controlSize(.large)
                        .font(.system(size: 14, weight: .bold))
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let detail: String
    var emphasis = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Color.overlayInk.opacity(0.055))
                )
                .overlay(
                    Circle()
                        .stroke(Color.separator, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(Color.inkSecondary)

                Text(detail)
                    .font(.system(size: emphasis ? 13 : 14, weight: emphasis ? .bold : .medium, design: emphasis ? .monospaced : .default))
                    .foregroundStyle(emphasis ? Color.inkSecondary : Color.inkMuted)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.overlayInk.opacity(0.026))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.overlayInk.opacity(0.065), lineWidth: 1)
        )
    }
}

struct AuthenticationPrompt: View {
    @ObservedObject var viewModel: SearchViewModel
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelEmptyState(title: "Connect Spotify", subtitle: message)

            Button(viewModel.loginInProgress ? "Waiting For Spotify..." : "Login / Reconnect") {
                viewModel.requestLogin()
            }
            .modifier(NativeGlassButtonStyle(prominent: true))
            .disabled(viewModel.loginInProgress)
            .controlSize(.large)
            .font(.system(size: 14, weight: .bold))
        }
    }
}
