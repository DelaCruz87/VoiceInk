import Foundation

// Ad-hoc local override: the GPL app id is com.prakashjoshipax.VoiceInk.GPL, and an
// embedded XPC CFBundleIdentifier must be prefixed by the host app id. Upstream's
// com.prakashjoshipax.VoiceInk.RefineXPC is valid for the App Store bundle, not for GPL.
// Revalidate this if the local app bundle id or upstream XPC service name changes.
#if LOCAL_BUILD
let voiceInkRefineXPCServiceName = "com.prakashjoshipax.VoiceInk.GPL.RefineXPC"
let voiceInkRefineXPCErrorDomain = "com.prakashjoshipax.VoiceInk.GPL.RefineXPC"
#else
let voiceInkRefineXPCServiceName = "com.prakashjoshipax.VoiceInk.RefineXPC"
let voiceInkRefineXPCErrorDomain = "com.prakashjoshipax.VoiceInk.RefineXPC"
#endif

struct VoiceInkRefinePrepareRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
}

struct VoiceInkRefineEnhanceRequest: Codable, Sendable {
    let requestID: UUID
    let modelDirectoryPath: String
    let systemPrompt: String
    let transcript: String
}

struct VoiceInkRefineEnhanceResponse: Codable, Sendable {
    let requestID: UUID
    let output: String
}

enum VoiceInkRefineXPCErrorCode: Int {
    case invalidRequest = 1
    case inferenceFailed = 2
    case invalidResponse = 3
    case connectionFailed = 4
}

@objc protocol VoiceInkRefineXPCProtocol {
    func prepare(
        _ requestData: NSData,
        withReply reply: @escaping (NSError?) -> Void
    )

    func enhance(
        _ requestData: NSData,
        withReply reply: @escaping (NSData?, NSError?) -> Void
    )

    func shutdown(withReply reply: @escaping () -> Void)
}

func makeVoiceInkRefineXPCError(
    _ code: VoiceInkRefineXPCErrorCode,
    description: String
) -> NSError {
    NSError(
        domain: voiceInkRefineXPCErrorDomain,
        code: code.rawValue,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}
