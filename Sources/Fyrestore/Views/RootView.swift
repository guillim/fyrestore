import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        Group {
            if session.isSignedIn {
                MainView(session: session)
            } else {
                LoginView()
            }
        }
        .background(Theme.bg)
    }
}
