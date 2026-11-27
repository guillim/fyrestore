import SwiftUI

struct LoginView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 28) {
                VStack(spacing: 18) {
                    LogoTile()
                    VStack(spacing: 6) {
                        Text("Fyrestore")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("A read-only browser for Google Firestore")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                VStack(spacing: 14) {
                    if let message = session.authError {
                        AuthNotice(message: message, isExpiry: session.sessionExpired)
                    }

                    Button {
                        Task { await session.signIn() }
                    } label: {
                        HStack(spacing: 8) {
                            if session.isAuthenticating {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(session.isAuthenticating ? "Waiting for browser…" : "Sign in with Google")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.isAuthenticating)
                    .keyboardShortcut(.defaultAction)

                    Text(session.isAuthenticating
                         ? "Finish signing in in your browser, then come back here."
                         : "Opens your browser. You'll see every project your Google account can read.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 320)

            Spacer(minLength: 24)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                Text("Read-only · Tokens stored in macOS Keychain")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// The app icon's white tile with the Fyrestore mark, drawn in code so it looks the
/// same in every build (the SwiftPM build ships no asset catalog).
private struct LogoTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white)
            .frame(width: 96, height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 6)
            .overlay(LogoMark().frame(height: 60))
            .accessibilityHidden(true)
    }
}

/// The folded-ribbon "F". Coordinates are those of the original artwork, in a
/// 251 × 395 box.
struct LogoMark: View {
    private static let size = CGSize(width: 251, height: 395)
    private static let parts: [(color: Color, points: [CGPoint])] = [
        (rgb(218, 105, 51), [p(0, 226), p(92, 226), p(92, 359), p(0, 395)]),    // lower stem
        (rgb(221, 114, 54), [p(0, 80), p(92, 80), p(92, 226), p(0, 226)]),      // upper stem
        (rgb(211, 97, 50), [p(81, 0), p(92, 0), p(92, 80), p(0, 80)]),          // folded corner
        (rgb(232, 154, 60), [p(92, 0), p(251, 0), p(173, 80), p(92, 80)]),      // top bar
        (rgb(224, 131, 55), [p(92, 148), p(231, 148), p(151, 226), p(92, 226)]) // middle bar
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / Self.size.width, canvasSize.height / Self.size.height)
            for part in Self.parts {
                var path = Path()
                path.addLines(part.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                path.closeSubpath()
                context.fill(path, with: .color(part.color))
            }
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }
}

/// Why the user is on this screen again: a calm note when Google ended the session,
/// a red one when sign-in actually failed.
private struct AuthNotice: View {
    let message: String
    let isExpiry: Bool

    private var tint: Color {
        isExpiry
            ? Color(.sRGB, red: 0.60, green: 0.38, blue: 0.08, opacity: 1)
            : Color(.sRGB, red: 0.72, green: 0.16, blue: 0.14, opacity: 1)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isExpiry ? "clock.arrow.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

/// Full-width button in the logo's deep orange.
private struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.sRGB, red: 0.79, green: 0.33, blue: 0.16, opacity: 1))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
