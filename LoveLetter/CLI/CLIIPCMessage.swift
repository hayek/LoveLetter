#if os(macOS)
import Foundation

enum CLIRequestKind: String, Codable {
    case refresh
    case createTask
    case linkTask
    case unlinkTask
    case respond
    case deleteAppStoreResponse
    case markRead
    case triage
    case updateTask
    case deleteTask
    case addProduct
    case updateProduct
    case removeProduct
    case configureAppStore
    case configureEmail
    case removeEmail
    case createVersion
    case updateVersion
    case deleteVersion
    case releaseVersion
    case createTemplate
    case updateTemplate
    case deleteTemplate
}

/// Payload values are strings so the envelope stays trivially Codable across the process
/// boundary; numeric fields are parsed by the responder.
struct CLIRequest: Codable {
    let id: UUID
    let kind: CLIRequestKind
    var payload: [String: String]

    init(id: UUID = UUID(), kind: CLIRequestKind, payload: [String: String]) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

struct CLIResponse: Codable {
    let id: UUID
    let ok: Bool
    var errorCode: String?
    var errorMessage: String?
    var errorHint: String?
    /// The app already knows exactly which `CLIError` it hit, so it sends the exit code
    /// rather than leaving the CLI to infer one by sniffing `errorCode` strings.
    var errorExitCode: Int32?
    var warnings: [String] = []
    /// A not-found failure's valid alternatives (products, versions, accounts…). Optional so a
    /// reply from an older app build still decodes.
    var errorCandidates: [String]?
    /// The successful result, already JSON-encoded by the app side.
    var json: String?

    init(id: UUID, ok: Bool, errorCode: String? = nil, errorMessage: String? = nil,
         errorHint: String? = nil, errorExitCode: Int32? = nil,
         warnings: [String] = [], errorCandidates: [String]? = nil, json: String? = nil) {
        self.id = id
        self.ok = ok
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorHint = errorHint
        self.errorExitCode = errorExitCode
        self.warnings = warnings
        self.errorCandidates = errorCandidates
        self.json = json
    }
}
#endif
