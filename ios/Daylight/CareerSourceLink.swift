import Foundation

struct CareerSourceLink {
    let webURL: URL
    let appURL: URL?
    let appName: String
    let universalOnly: Bool

    init?(urlString: String, sourceID: String, noteID: String = "") {
        guard let url = URL(string: urlString), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        webURL = url // Keep the original note access parameters for web fallback.
        if sourceID == "xiaohongshu" {
            let parts = url.pathComponents.filter { $0 != "/" }
            guard host == "www.xiaohongshu.com",
                  (parts.count == 2 && parts[0] == "explore") || (parts.count == 3 && parts[0] == "discovery" && parts[1] == "item"),
                  let id = parts.last, id.range(of: "^[a-fA-F0-9]{24}$", options: .regularExpression) != nil,
                  noteID.isEmpty || noteID.lowercased() == id.lowercased() else { return nil }
            // Official routing contract: https://pages.xiaohongshu.com/activity/deeplink
            appURL = URL(string: "xhsdiscover://item/" + id.lowercased())
            appName = "小红书"; universalOnly = false
        } else if sourceID == "boss" {
            guard ["www.zhipin.com", "zhipin.com"].contains(host),
                  url.path.range(of: "^/job_detail/[A-Za-z0-9_-]+\\.html$", options: .regularExpression) != nil else { return nil }
            // Let iOS use the platform's own Universal Link association.
            appURL = url; appName = "BOSS"; universalOnly = true
        } else {
            appURL = nil; appName = "原平台"; universalOnly = false
        }
    }
}
