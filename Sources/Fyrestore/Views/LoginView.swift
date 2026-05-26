import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Text("Fyrestore")
                    .font(.system(size: 36, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.textPrimary)
                Text("A read-only browser for Google Firestore")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textMuted)
            }

            Button {
                Task { await session.signIn() }
            } label: {
                HStack(spacing: 10) {
                    if session.isAuthenticating {
                        ProgressView().controlSize(.small)
                    }
                    Text(session.isAuthenticating ? "Waiting for browser…" : "Sign in with Google")
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(minWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isAuthenticating)

            if let err = session.authError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
            }
            Spacer()
            Text("Read-only · Tokens stored in macOS Keychain")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
