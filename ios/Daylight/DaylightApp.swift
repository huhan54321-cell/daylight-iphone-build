import SwiftUI

@main
struct DaylightApp: App {
    @StateObject private var store = AssistantStore.shared
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(store) }
    }
}
