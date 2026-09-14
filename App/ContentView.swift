import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            SendView()
                .tabItem { Label("Send", systemImage: "arrow.up.forward.app") }
            ViewerView()
                .tabItem { Label("Watch", systemImage: "play.rectangle") }
        }
    }
}
