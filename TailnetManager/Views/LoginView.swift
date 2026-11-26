import SwiftUI
import LocalAuthentication

/// The login screen on every launch (and after Lock): the saved API token
/// is only used once the admin confirms it's them with Touch ID / Face ID or
/// their device password — or signs in with a token.
struct LoginView: View {
    @Environment(AppState.self) private var app
    @State private var unlocking = false
    @State private var message: String?
    @State private var showTokenEntry = false
    @State private var token = ""
    @State private var validating = false
    @State private var triedOnce = false

    private var biometry: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    private var unlockTitle: String {
        switch biometry {
        case .touchID: return "Unlock with Touch ID"
        case .faceID: return "Unlock with Face ID"
        default: return "Unlock"
        }
    }

    private var unlockIcon: String {
        switch biometry {
        case .touchID: return "touchid"
        case .faceID: return "faceid"
        default: return "lock.open"
        }
    }

    /// "tskey-api-k1AbC…" — the key's ID only, never the secret part.
    private var tokenLabel: String {
        app.api?.keyID.map { "tskey-api-\($0)…" } ?? "your saved API token"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                OnboardingMark()

                VStack(spacing: 14) {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.title3.weight(.semibold))
                    Text("Signed in with \(tokenLabel). Confirm it's you to open your network.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(action: unlock) {
                        Group {
                            if unlocking {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(unlockTitle, systemImage: unlockIcon).fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(unlocking || validating)
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))

                DisclosureGroup("Sign in with a token instead", isExpanded: $showTokenEntry) {
                    VStack(spacing: 10) {
                        SecureField("tskey-api-…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                            .onSubmit(signIn)
                        Button(action: signIn) {
                            Group {
                                if validating { ProgressView().controlSize(.small) } else { Text("Sign in").fontWeight(.semibold) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validating)
                        Text("The token is checked with Tailscale, then replaces the saved one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                Button("Sign out and forget the saved token", role: .destructive) { app.signOut() }
                    .buttonStyle(.borderless)
                    .font(.footnote)
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        // Ask right away once; the button stays for a retry.
        .task {
            guard !triedOnce else { return }
            triedOnce = true
            unlock()
        }
    }

    private func unlock() {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            // No Touch ID / password set up: the token itself is the key.
            message = "This device can't confirm it's you. Sign in with your token below."
            showTokenEntry = true
            return
        }
        unlocking = true
        message = nil
        Task {
            do {
                try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                 localizedReason: "open your Tailscale network")
                app.unlock()
            } catch let error as LAError where [.userCancel, .systemCancel, .appCancel].contains(error.code) {
                message = nil
            } catch {
                message = error.localizedDescription
            }
            unlocking = false
        }
    }

    private func signIn() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !validating else { return }
        if !trimmed.hasPrefix("tskey-api-") {
            message = "That isn't an API access token (they start with tskey-api-)."
            return
        }
        validating = true
        Task {
            if await app.signIn(token: trimmed) { token = "" }
            validating = false
        }
    }
}
