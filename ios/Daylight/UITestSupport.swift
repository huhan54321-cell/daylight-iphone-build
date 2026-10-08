import Foundation

// UI tests use the real repository and save paths, but in a separate simulator
// directory. This entire hook is absent from physical-device and Release builds.
enum UITestSupport {
    static func recordURL(applicationSupport: URL) -> URL {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            guard let index = arguments.firstIndex(of: "--ui-test-run"),
                  arguments.indices.contains(index + 1),
                  let runID = UUID(uuidString: arguments[index + 1]) else {
                fatalError("Simulator UI tests require a valid isolated run UUID")
            }
            // A new UUID starts an empty scenario; reusing it checks persistence.
            // No deletion or alteration of the ordinary Daylight directory.
            return applicationSupport.appendingPathComponent("DaylightUITests", isDirectory: true)
                .appendingPathComponent(runID.uuidString, isDirectory: true)
                .appendingPathComponent("records.json")
        }
        #endif
        return applicationSupport.appendingPathComponent("Daylight", isDirectory: true)
            .appendingPathComponent("records.json")
    }
}
