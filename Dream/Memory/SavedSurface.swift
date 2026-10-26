import Foundation
import SwiftData

/// One generated surface on the user's shelf, and the start of the memory layer.
///
/// The template (`surface`) is stored apart from what's personal (`values`, `photoData`), so the
/// template can later be shared without it. `intent`, `editRequests` and the open counts record
/// what it's actually used for.
@Model
final class SavedSurface {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var lastOpenedAt: Date?
    var openCount = 0
    /// What the user asked for, in their words.
    var intent = ""
    /// Changes the user asked for afterwards.
    var editRequests: [String] = []
    var modelName = ""
    var generationLog: [String] = []
    var templateData = Data()
    /// The user's own numbers.
    var valuesData = Data()
    /// The user's photo, if they started from one.
    @Attribute(.externalStorage) var photoData: Data?
    /// The link it was opened from, when someone else shared it. Nil for the user's own.
    var sharedFrom: String?

    init(intent: String, surface: Surface, modelName: String, log: [String]) {
        self.intent = intent
        self.modelName = modelName
        self.generationLog = log
        self.surface = surface
    }

    var surface: Surface {
        get { (try? Self.decoder.decode(Surface.self, from: templateData)) ?? .empty }
        set {
            templateData = (try? Self.encoder.encode(newValue)) ?? Data()
            updatedAt = Date()
        }
    }

    var values: [String: Double] {
        get { (try? Self.decoder.decode([String: Double].self, from: valuesData)) ?? [:] }
        set { valuesData = (try? Self.encoder.encode(newValue)) ?? Data() }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }()
}
