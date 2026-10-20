import SwiftUI
import SafariServices
import UIKit

struct CareerSourceActions: View {
    let url: String
    let sourceID: String
    var noteID = ""
    var title = ""
    var compact = false
    @State private var showWeb = false
    @State private var feedback: String?
    private var destination: CareerSourceLink? { CareerSourceLink(urlString: url, sourceID: sourceID, noteID: noteID) }

    var body: some View {
        if let destination {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button { open(destination) } label: { Label("去\(destination.appName)查看", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("career-open-source-" + (noteID.isEmpty ? sourceID : noteID))
                    Menu {
                        Button("用网页查看") { showWeb = true }
                        Button("复制原链接") { UIPasteboard.general.url = destination.webURL; feedback = "原链接已复制" }
                        if !title.isEmpty { Button("复制标题搜索") { UIPasteboard.general.string = title; feedback = "标题已复制" } }
                    } label: { Image(systemName: "ellipsis.circle").padding(5) }
                        .accessibilityLabel("更多打开方式").buttonStyle(.borderless)
                }
                if !compact { Text("若 App 未进入对应内容，可在右侧选择网页查看或复制标题搜索。").font(.caption).foregroundStyle(.secondary) }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }.sheet(isPresented: $showWeb) { CareerSourceBrowser(url: destination.webURL).ignoresSafeArea() }
        }
    }

    private func open(_ destination: CareerSourceLink) {
        guard let appURL = destination.appURL else { showWeb = true; return }
        let options: [UIApplication.OpenExternalURLOptionsKey: Any] = destination.universalOnly ? [.universalLinksOnly: true] : [:]
        UIApplication.shared.open(appURL, options: options) { opened in
            // The callback means the OS handled the URL, not that a post exists.
            Task { @MainActor in if !opened { showWeb = true } }
        }
    }
}

private struct CareerSourceBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
