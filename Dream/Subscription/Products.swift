import Foundation

/// Dream Plus in the App Store: one subscription group with a monthly and a yearly product, at
/// the same level, since they're the same plan for different lengths. The same ids are in App
/// Store Connect, in Config/Dream.storekit for trying purchases in Xcode, and on the server
/// (Server/src/appstore.ts), which counts only these.
enum Products {
    /// The subscription group's reference name in App Store Connect.
    static let group = "Dream Plus"
    static let monthly = "xyz.onlychan.dream.plus.monthly"
    static let yearly = "xyz.onlychan.dream.plus.yearly"
    static let all = [yearly, monthly]

    /// Apple's standard licence agreement, which App Store Connect applies unless Dream adds its own.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    /// Dream's privacy policy, served by its own server.
    static var privacy: URL? { ServerAddress.dream?.appending(path: "privacy") }
}
