// ENSO ad-hoc local override: synthetic harness for the approved VoiceInk Companion API v1.
// It assumes CompanionHTTPServer's internal contract; revalidate when the HTTP transport,
// authentication scheme, or request limits change upstream.

import Foundation

@main
struct CompanionHTTPHarness {
    static func main() throws {
        try verifyContractCoding()
        let environment = ProcessInfo.processInfo.environment
        guard let rawPort = environment["VOICEINK_COMPANION_PORT"], let port = UInt16(rawPort) else {
            throw CompanionAPIError(status: "invalid_configuration", message: "Missing harness port")
        }
        let server = try CompanionHTTPServer(port: port) { request in
            guard request.headers["authorization"] == "Bearer synthetic-token" else {
                return response(401, ["status": "unauthorized"])
            }
            guard request.target == "/v1/probe" else {
                return response(404, ["status": "not_found"])
            }
            return response(200, ["status": "ok", "method": request.method])
        }
        server.start()
        dispatchMain()
    }

    private static func verifyContractCoding() throws {
        let operation = CompanionDictionaryOperation(
            kind: "replacement",
            action: "upsert",
            id: "00000000-0000-0000-0000-000000000001",
            word: nil,
            originalText: "Ni\u{00F1}o | uno, dos\nl\u{00ED}nea",
            replacementText: "ni\u{00F1}o",
            isEnabled: false
        )
        let request = CompanionDictionaryMutationRequest(expectedRevision: "synthetic", operations: [operation])
        let data = try JSONEncoder.companion.encode(request)
        let roundTrip = try JSONDecoder.companion.decode(CompanionDictionaryMutationRequest.self, from: data)
        guard roundTrip.operations.count == 1,
            roundTrip.operations[0].originalText == operation.originalText,
            roundTrip.operations[0].replacementText == operation.replacementText,
            roundTrip.operations[0].isEnabled == false
        else {
            throw CompanionAPIError(status: "roundtrip_failed", message: "Contract JSON roundtrip lost data")
        }
    }

    private static func response(_ statusCode: Int, _ object: [String: String]) -> CompanionHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return CompanionHTTPResponse(statusCode: statusCode, body: body)
    }
}
