import SwiftUI

// MARK: - Onboarding

/// Full-window first-run screen shown until a valid API token is stored.
struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var token = ""
    @State private var isValidating = false
    @State private var inlineHint: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                OnboardingMark()

                if app.needsReplacementToken {
                    Label("Tailscale rejected your saved API token. Create a new API access token and connect again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                OnboardingStepsCard()

                tokenEntry

                Text("Your token is stored only in your Keychain and is sent only to api.tailscale.com.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Token entry

    private var tokenEntry: some View {
        VStack(spacing: 12) {
            SecureField("tskey-api-…", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                #endif
                .onSubmit(connect)

            if let inlineHint {
                Label(inlineHint, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: connect) {
                Group {
                    if isValidating {
                        ProgressView()
                            #if os(macOS)
                            .controlSize(.small)
                            #endif
                    } else {
                        Text("Connect")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
        }
    }

    private func connect() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isValidating else { return }
        // Client-side pre-check: catch the common wrong-key-type mistakes
        // without a round trip to the API.
        if trimmed.hasPrefix("tskey-auth-") {
            inlineHint = "That’s an auth key — you need an API access token (it starts with tskey-api-)."
            return
        }
        if trimmed.hasPrefix("tskey-client-") {
            inlineHint = "That’s an OAuth client secret — you need an API access token (it starts with tskey-api-)."
            return
        }
        inlineHint = nil
        isValidating = true
        Task {
            _ = await app.signIn(token: trimmed)
            isValidating = false
        }
    }
}

// MARK: - App mark

struct OnboardingMark: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("Tailnet Manager")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))

            Text("Manage devices, users and access in your Tailscale network — without ever touching the policy file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Steps card

private struct OnboardingStepsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepRow(number: 1) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open the Tailscale admin console keys page.")
                    Link("Open Keys page", destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!)
                        .font(.callout.weight(.medium))
                }
            }
            OnboardingStepRow(number: 2) {
                Text("Under “API access tokens” click “Generate access token…” and pick an expiry (1–90 days).")
            }
            OnboardingStepRow(number: 3) {
                Text("Copy the token (starts with tskey-api-) and paste it below.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct OnboardingStepRow<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())

            content
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
