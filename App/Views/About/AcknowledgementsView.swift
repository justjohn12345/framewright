import SwiftUI

/// The third-party notices shipped in the application bundle (`Acknowledgements.md`: FFmpeg with
/// the LGPL source offer, dav1d, SVT-AV1 and the AOM patent licence, nlohmann/json, doctest; and
/// `COPYING.LGPLv2.1`, the full GNU LGPL 2.1). Shown from VidEdit > Acknowledgements….
struct AcknowledgementsView: View {
    static let windowID = "acknowledgements"
    /// Bundle resources shown, in order.
    static let resourceNames = ["Acknowledgements.md", "COPYING.LGPLv2.1"]

    /// The notices and the licence text from `bundle` (a line saying so for a missing file).
    static func text(bundle: Bundle = .main) -> String {
        resourceNames.map { name in
            guard let url = bundle.url(forResource: name, withExtension: nil),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return "(\(name) is missing from the application bundle.)"
            }
            return contents
        }
        .joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            Text(Self.text())
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}
