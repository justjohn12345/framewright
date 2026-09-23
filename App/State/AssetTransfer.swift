import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// A Framewright project file (.framewright), declared in Info.plist.
    static let framewrightProject = UTType(exportedAs: "com.justjohn12345.framewright.project")
    /// A reference to an asset of the open project, dragged from the media bin to the timeline
    /// (declared in Info.plist).
    static let framewrightAssetReference = UTType(exportedAs: "com.justjohn12345.framewright.asset-reference")
}

/// Drag payload for an asset of the open project. Only meaningful inside this app process.
struct AssetReference: Codable, Transferable, Hashable {
    let assetID: Int64

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .framewrightAssetReference)
    }
}
