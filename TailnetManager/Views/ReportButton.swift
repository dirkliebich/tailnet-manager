import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// "Report" in every section's toolbar: the section as one HTML page —
/// open it in the browser or keep a copy in Downloads (Mac), or share it
/// (iPhone).
struct ReportButton: View {
    // Passed in, not read from the environment: toolbar content can be
    // built outside the view that has it.
    let app: AppState
    let section: AppSection

    var body: some View {
        #if os(macOS)
        Menu {
            Button {
                run { try ReportFiles.openInBrowser(app.report(for: section)) }
            } label: {
                Label("Open in browser", systemImage: "safari")
            }
            Button {
                run { try ReportFiles.download(app.report(for: section)) }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        } label: {
            Label("Report", systemImage: "doc.richtext")
        }
        .help("A page with everything in \(section.title): search, filters, grouping, light and dark")
        #else
        ShareLink(item: ReportFile(report: app.report(for: section)),
                  preview: SharePreview("\(section.title) report")) {
            Label("Report", systemImage: "doc.richtext")
        }
        #endif
    }

    private func run(_ work: () throws -> Void) {
        do { try work() } catch {
            app.errorMessage = "The report couldn't be saved: \(error.localizedDescription)"
        }
    }
}

#if os(macOS)
enum ReportFiles {
    /// Writes to the app's temporary folder and opens it with the default browser.
    static func openInBrowser(_ report: ReportDocument) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ReportHTML.fileName(for: report))
        try Data(ReportHTML.render(report).utf8).write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }

    /// Saves to Downloads (never overwriting) and shows it in Finder.
    static func download(_ report: ReportDocument) throws {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let name = ReportHTML.fileName(for: report)
        let base = (name as NSString).deletingPathExtension
        var url = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(base) (\(n)).html")
            n += 1
        }
        try Data(ReportHTML.render(report).utf8).write(to: url, options: .withoutOverwriting)
        NSWorkspace.shared.activateFileViewerSelecting([url.resolvingSymlinksInPath()])
    }
}
#endif

/// The report as an .html file for the share sheet.
struct ReportFile: Transferable {
    let report: ReportDocument

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { Data(ReportHTML.render($0.report).utf8) }
            .suggestedFileName { ReportHTML.fileName(for: $0.report) }
    }
}
