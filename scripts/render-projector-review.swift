import AppKit
import SwiftUI

@main
struct RenderProjector {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("ViewTheWord/Resources")
        let reference = VerseReference(book: "Esther", chapter: 8, verse: 9)!
        let primaryURL = resources.appendingPathComponent("MAL_BSI.bible")
        let secondaryURL = resources.appendingPathComponent("ENG_UKJV.bible")
        let primary = try await Bible(dbUrl: primaryURL).verses([reference])
        let secondary = try await Bible(dbUrl: secondaryURL).verses([reference])
        let pair = TranslationPair(reference: reference, primary: primary.first, secondary: secondary.first)
        let projection = PreparedProjection(pair: pair, sources: BibleSources(primary: primaryURL, secondary: secondaryURL, revision: 0), owner: .searchResult(reference))!
        let model = ProjectorViewModel()
        model.project(projection.data, owner: projection.owner)
        for (name, width, height, stacked, padding) in [("dual-1920",1920,1080,false,20), ("stacked-1024",1024,768,true,200), ("small-640",640,480,false,200)] {
            UserDefaults.standard.setVolatileDomain([
                AppDefaultsKey.fontSizeVerse: 200.0,
                AppDefaultsKey.fontSizeVerseRef: 36.0,
                AppDefaultsKey.projectorPadding: Double(padding),
                AppDefaultsKey.projectorDualLayoutVertical: stacked,
                AppDefaultsKey.projectorShowTranslationInfo: true,
                AppDefaultsKey.projectorTextAlignment: "center",
                AppDefaultsKey.projectorReadingDirection: "auto"
            ], forName: UserDefaults.argumentDomain)
            try save(model: model, name: name, width: width, height: height, root: root)

        }
        UserDefaults.standard.setVolatileDomain([
            AppDefaultsKey.fontSizeVerse: 100.0, AppDefaultsKey.fontSizeVerseRef: 36.0,
            AppDefaultsKey.projectorPadding: 20.0, AppDefaultsKey.projectorDualLayoutVertical: false,
            AppDefaultsKey.projectorShowTranslationInfo: true, AppDefaultsKey.projectorReadingDirection: "auto"
        ], forName: UserDefaults.argumentDomain)
        let genesis = VerseReference(book: "Genesis", chapter: 1, verse: 1)!
        let english = try await Bible(dbUrl: secondaryURL).verses([genesis]).first!.verse
        model.project(ProjectorViewData(title: genesis.verseQuery.title,
            primaryText: "בראשית ברא אלהים את השמים ואת הארץ.", secondaryText: english,
            primaryTranslationName: "Hebrew layout fixture", secondaryTranslationName: "English · UKJV"), owner: .searchResult(genesis))
        try save(model: model, name: "mixed-rtl-1024", width: 1024, height: 768, root: root)
        model.toggleBlank()
        try save(model: model, name: "blank-640", width: 640, height: 480, root: root)
    }

    @MainActor private static func save(model: ProjectorViewModel, name: String, width: Int, height: Int, root: URL) throws {
        let content = ProjectorView().environmentObject(model)
            .frame(width: CGFloat(width), height: CGFloat(height)).background(.black)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: CGFloat(height))
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: root.appendingPathComponent("build/review/rendered/\(name).png"))
        print("Rendered \(name)")
    }
}
