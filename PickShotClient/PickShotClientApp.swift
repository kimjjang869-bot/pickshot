import SwiftUI

@main
struct PickShotClientApp: App {
    @StateObject private var store = PhotoStore()

    var body: some Scene {
        WindowGroup("PickShot Client") {
            ClientView()
                .environmentObject(store)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
    }
}
