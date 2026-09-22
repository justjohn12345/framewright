import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A VidEdit project file (.videdit), declared in Info.plist.
    static let videditProject = UTType(exportedAs: "com.justjohn12345.videdit.project")
    /// A reference to an asset of the open project, dragged from the media bin to the timeline
    /// (declared in Info.plist).
    static let videditAssetReference = UTType(exportedAs: "com.justjohn12345.videdit.asset-reference")
}

/// Drag payload for an asset of the open project. Only meaningful inside this app process.
struct AssetReference: Codable, Transferable, Hashable {
    let assetID: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .videditAssetReference)
    }
}
