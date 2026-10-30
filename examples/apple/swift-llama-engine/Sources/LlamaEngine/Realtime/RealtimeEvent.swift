import Foundation

/// One server event of a ``RealtimeSession``.
///
/// The event keeps its raw JSON, so events this type does not know stay
/// usable. The fields below are read once, on the session's reader thread:
/// the base64 audio of `response.output_audio.delta` is decoded there, never
/// on the consumer's actor.
public struct RealtimeEvent: Sendable {
    /// The `type` field, e.g. `session.created` or `response.output_text.delta`.
    public let type: String

    /// The event as sent by the engine.
    public let json: String

    /// The `delta` text of `response.output_text.delta`,
    /// `response.output_audio_transcript.delta` and
    /// `conversation.item.input_audio_transcription.delta`.
    public let textDelta: String?

    /// The samples of `response.output_audio.delta`, mono, in -1...1, at
    /// ``RealtimeSession/outputSampleRate``.
    public let audio: [Float]?

    /// The response the event belongs to: its `response_id`, or the
    /// `response.id` of `response.created` and `response.done`.
    public let responseID: String?

    /// The `response.status` of `response.done`, e.g. `completed` or `cancelled`.
    public let responseStatus: String?

    /// The `error` object of an `error` event.
    public let error: RealtimeEventError?

    /// The tool call of a `response.output_item.done` event whose item is a
    /// `function_call`: its arguments are complete.
    public let functionCall: RealtimeFunctionCall?

    /// The parsed event, for fields this type does not expose.
    public var object: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// Reads an event from its JSON text, e.g. to replay a recorded session.
    public init(json: String) {
        self.json = json
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let type = object["type"] as? String ?? ""
        self.type = type

        switch type {
        case "response.output_text.delta",
             "response.output_audio_transcript.delta",
             "conversation.item.input_audio_transcription.delta":
            textDelta = object["delta"] as? String
            audio = nil
        case "response.output_audio.delta":
            textDelta = nil
            audio = (object["delta"] as? String).flatMap(RealtimePCM16.decodeBase64)
        default:
            textDelta = nil
            audio = nil
        }

        let response = object["response"] as? [String: Any]
        responseID = object["response_id"] as? String ?? response?["id"] as? String
        responseStatus = type == "response.done" ? response?["status"] as? String : nil

        if type == "error", let e = object["error"] as? [String: Any] {
            error = RealtimeEventError(type: e["type"] as? String ?? "",
                                       code: e["code"] as? String,
                                       message: e["message"] as? String ?? "",
                                       eventID: e["event_id"] as? String)
        } else {
            error = nil
        }

        if type == "response.output_item.done", let item = object["item"] as? [String: Any],
           item["type"] as? String == "function_call" {
            functionCall = RealtimeFunctionCall(responseID: responseID ?? "",
                                                itemID: item["id"] as? String ?? "",
                                                callID: item["call_id"] as? String ?? "",
                                                name: item["name"] as? String ?? "",
                                                arguments: item["arguments"] as? String ?? "{}")
        } else {
            functionCall = nil
        }
    }
}

/// A tool call of a response. Run it, then send its result with
/// ``RealtimeSession/sendFunctionCallOutput(callID:output:)`` and ask for the
/// next response.
public struct RealtimeFunctionCall: Sendable, Hashable {
    public let responseID: String
    public let itemID: String
    public let callID: String
    public let name: String
    /// The arguments as JSON text.
    public let arguments: String
}

/// The `error` object of an `error` event.
///
/// Protocol errors (`invalid_request_error`) leave the session open. The
/// codes below are always the last event of the session:
/// - `session_terminated`: the engine was paused, unloaded or destroyed.
/// - `input_queue_full`, `output_queue_full`: a queue reached its budget.
public struct RealtimeEventError: Sendable, Hashable {
    public let type: String
    public let code: String?
    public let message: String
    /// The `event_id` of the client event that caused the error, if it had one.
    public let eventID: String?

    /// True for the codes that end the session.
    public var isTerminal: Bool {
        switch code {
        case "session_terminated", "input_queue_full", "output_queue_full", "binary_not_supported":
            return true
        default:
            return false
        }
    }
}
