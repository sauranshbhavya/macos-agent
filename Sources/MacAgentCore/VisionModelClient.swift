import Foundation

/// Which iteration of which session one `decide` call is (SONNY-131).
///
/// **On the wire because `docs/sonny-backend-api-contract.md` §4.5 puts it there, and known only
/// here because only the runner counts iterations.** The gateway holds no session state at all —
/// §4.5 rule 5: "one request is one iteration", continuity lives in `VisionSessionRunner.history`,
/// and there is no server-side session to resume. So these two fields are not a handle on anything;
/// they are what lets metering price a session rather than a request, and what lets a support lookup
/// put a `Sonny-Request-Id` back into the sequence it came from.
///
/// That absence of server-side state is also an *input* to this ticket's mid-loop failure decision,
/// which is recorded where it is implemented — `VisionSessionRunner.runLoop`.
public struct VisionSessionRequestContext: Equatable, Sendable {
    /// The session's own journal id — the same string ``VisionSessionInteracting/visionSessionDidStart(id:)``
    /// hands the view model, so a request on the wire and a row in the task history name the same run.
    public let sessionID: String
    /// 1-based, and the same number the HUD is showing.
    public let iteration: Int

    public init(sessionID: String, iteration: Int) {
        self.sessionID = sessionID
        self.iteration = iteration
    }
}

/// The vision model, as a seam.
///
/// **The parameter type is the security property.** `payload` is a ``RedactedPayload``, whose
/// initializer is `fileprivate` to `LocalRedactionService.swift` — so the only way any conformer of
/// this protocol can be handed something to send is for `LocalRedactionService` to have produced it,
/// and there is no overload taking raw bytes to reach for instead. An unredacted screenshot leaving
/// this device does not fail a review; it fails to compile. (SONNY-89's structural non-bypass,
/// consumed exactly as it was designed to be.)
///
/// **That property survived the move behind the gateway untouched, and here is how** (SONNY-131).
/// Sending the payload now means building §4.5's JSON body from it, which is a serialisation problem
/// — and the obvious answer, making `RedactedPayload` `Codable`, would have dissolved the guarantee:
/// a `Decodable` conformance is a public initializer in disguise, so anything anywhere could mint a
/// payload out of a JSON literal. It is not conformed to either half. What the body is built from
/// instead is the payload's own `public let` properties, read inside `SonnyVisionModelClient.decide`
/// — *reading* a payload was always allowed and is what the preview panel and the old direct-to-
/// provider client already did; *constructing* one is what the `fileprivate` initializer forbids, and
/// nothing here constructs one. The wire shape lives in the consumer, which is also where it belongs:
/// §4.5 is the gateway's contract, and `LocalRedactionService` should not know a gateway exists.
public protocol VisionModelDeciding: Sendable {
    /// A short description of the model and route, for the run transcript.
    var transcriptDescription: String { get }

    func decide(
        prompt: String,
        payload: RedactedPayload,
        session: VisionSessionRequestContext
    ) async throws -> String
}

public enum VisionModelClientError: Error, Equatable, LocalizedError, CarriesBackendError {
    /// **Three cases are gone** (SONNY-136), all three unreachable and all three kept by SONNY-131
    /// only until the ticket owning the environment-variable surface could remove the sentence that
    /// named a variable. `missingAPIKey(String)` interpolated a variable's name into
    /// *"Sonny needs … set to use screen control."*, which was the last user-facing string in the
    /// tree naming one; `badResponse(status:body:)` read an HTTP status no client here reads any
    /// more; and `unreadableReply(String)` described a body without `output_text`, which §4.5 makes
    /// a required field, so such a body fails to decode and arrives as
    /// `SonnyBackendError.undecodableResponse` inside ``backend(_:)``.
    ///
    /// **`payloadCarriedNoImage` and `payloadTooLarge` stay because both are live** — SONNY-114's
    /// ceiling refuses before anything is sent, and neither has ever been about a credential.
    case payloadCarriedNoImage
    case payloadTooLarge(bytes: Int, limit: Int)
    /// A call to Sonny's backend failed. The user sees ``SonnyBackendCopy``'s sentence for it, never
    /// the server's own `message` (§7.1).
    case backend(SonnyBackendError)

    /// ``CarriesBackendError``: so a cancellation raised inside the shared client is still
    /// recognisable after this type wraps it. Without it, a user pressing stop mid-send is told
    /// something went wrong.
    public var backendError: SonnyBackendError? {
        guard case .backend(let error) = self else { return nil }
        return error
    }

    public var errorDescription: String? {
        switch self {
        case .payloadCarriedNoImage:
            return "The redacted capture carried no image to send."
        case .payloadTooLarge(let bytes, let limit):
            return "The window screenshot is \(bytes) bytes, over the \(limit)-byte limit for one request."
        case .backend(let error):
            return SonnyBackendCopy.sentence(for: error)
        }
    }
}

/// The shipped vision client, **talking to Sonny's own backend rather than to a provider**
/// (SONNY-131).
///
/// **What moved.** A model identifier, a vendor endpoint and an `OPENCODE_API_KEY` read out of the
/// user's own environment. All three now live in `server/src/model/vision.ts` and `server/src/config.ts`,
/// which is what turns SONNY-110's move to a paid zero-retention route into a redeploy rather than an
/// app release — and SONNY-110's requirement widened on 2026-08-16 to *no retention and no training
/// rights*, so making that a configuration change is the point rather than a tidiness.
///
/// **What did not move, and must not.** Redaction, the egress encoder, the prompt builder, the
/// coordinate space, the containment layer and the whole risk engine. §1.3 draws that line and gives
/// the reason for the half that bites here: `VisionSessionPromptBuilder` is a prompt-injection
/// boundary, and a server that rebuilt the prompt would be a second copy of a security boundary,
/// maintained by whoever edits the server. So the prompt arrives here assembled, and this type does
/// nothing to it but put it in a field.
///
/// **The type is named for Sonny and not for a vendor**, unlike the four text clients SONNY-130
/// re-pointed. Those kept their names because `CerebrasPlanner`, on that ticket's never-touch list,
/// calls `OpenAIPlanner.systemPrompt(toolRegistry:)` — a rename would have been an edit to a
/// forbidden file. Nothing depends on this one's old name, so `OpenCodeVisionModelClient` is gone
/// rather than renamed-in-place with a note.
///
/// **Screen captures still reach a retention-bearing store** — Sonny's own, for 30–90 days (founder,
/// 2026-08-16). Moving the route behind this gateway changed which retention windows exist, not
/// whether any does, and nothing in this file should be read as saying otherwise.
public struct SonnyVisionModelClient: VisionModelDeciding {
    /// The request-size ceiling, on the image alone.
    ///
    /// **Re-derived by SONNY-114, not inherited.** The old 9,000,000 came from the experiment branch
    /// as the observed practical limit for one request on the direct provider route, and it was a
    /// number sized for an uncompressed full-resolution PNG: base64 turns an image at that ceiling
    /// into a request body of about 12 MB, which was ruling out every serverless host with a body
    /// limit before anyone had asked whether the payload needed to be that big. It did not.
    ///
    /// This is the same budget the egress ladder encodes down to
    /// (``VisionCaptureEgressPolicy/default``), so the two cannot drift: the encoder aims at exactly
    /// the number this refuses above. A payload at the ceiling produces a request body of
    /// `ceil(3_000_000 / 3) * 4` = 4,000,000 bytes of base64 plus the prompt (4,673 characters on a
    /// six-entry history) and about 120 bytes of JSON envelope — call it 4.01 MB, measured.
    ///
    /// **And it is now the same number on both sides of the network** (SONNY-131).
    /// `MAXIMUM_IMAGE_BYTES` in `server/src/model/limits.ts` is 3,000,000, and §6.1's 4,200,000 body
    /// limit is *derived* from it there rather than written as a second literal — which is what §6.1
    /// means by "this number and SONNY-114's are one number". This client refuses first, so a user
    /// meets this message rather than a `413`; the server's copy is the backstop for a client that is
    /// not ours, or is out of date.
    ///
    /// The refusal itself is unchanged and still deliberate: a capture that exceeds this fails the
    /// whole iteration with a clear message rather than becoming a truncated upload with an obscure
    /// one. What changed is what has to happen first. The ladder returns the **first** rung whose
    /// encoding fits, so most captures never leave the top one; reaching this refusal means every
    /// rung was tried and every one came back over budget, and the encoder then hands back the
    /// smallest it managed rather than throwing, precisely so the message a user sees is this one.
    ///
    /// **How much headroom that leaves, measured rather than estimated.** The seeded uniform-noise
    /// fixture at a 27-inch 5K display's point resolution — the encoder's worst case among the
    /// reproducible ones, since noise is the content no encoder can compress — encodes to
    /// **2,781,667 bytes at its full 2560x1440, without the ladder resampling at all**, at
    /// `6201e45`. `theShippingPolicyKeepsEvenItsWorstCaseUnderTheCeiling` prints that figure on
    /// every run, so it is regenerable rather than a number frozen into a comment.
    ///
    /// Larger point resolutions than 5K do reach the resampling rungs on noise, and no figure is
    /// quoted for them here: the ones SONNY-114 measured came from a one-off random image nobody can
    /// reproduce, and an unreproducible number in a comment is worth less than the absence of one.
    /// What holds regardless is the shape — this is a backstop rather than a path users meet, since
    /// no real screen produces incompressible content and every real capture measured for SONNY-114
    /// fitted the top rung with room to spare.
    public static let maximumImageBytes = VisionCaptureEgressPolicy.default.maximumImageBytes

    private let client: SonnyBackendClient
    private let taskContext: BackendTaskContext
    private let usageRecorder: any TaskUsageRecording

    /// **What the run transcript says now, and why it is not a model name.**
    ///
    /// It used to be `opencode/gpt-5.6-luna`, read off the two things this client no longer knows.
    /// The route's own name is what is left and it is the honest answer: the transcript records which
    /// of Sonny's routes ran, and which provider served it is a server-side fact that can change
    /// between two iterations of one session without the app noticing — which is exactly the property
    /// SONNY-110 needs.
    public var transcriptDescription: String { SonnyModelRoute.screenAnalyze.usageModelName }

    /// **`client` and `taskContext` have no defaults**, for the two reasons this repository already
    /// records for parameters of this kind. A defaulted client would be a second construction of the
    /// shared one, which defeats the single-flight refresh guard §3.3 depends on — ten concurrent
    /// 401s must cause one rotation, and two clients means two. A defaulted `taskContext` would be a
    /// defaulted `retention`, which §2.4.2 forbids on the wire for exactly the reason it should be
    /// forbidden here: a privacy field nobody chose.
    ///
    /// `usageRecorder` keeps the default the four text clients use, because `NoopTaskUsageRecorder`
    /// is a real answer — a build with no per-task summary records nothing — rather than a location
    /// on this Mac that a fixture could write to by accident.
    public init(
        client: SonnyBackendClient,
        taskContext: BackendTaskContext,
        usageRecorder: any TaskUsageRecording = NoopTaskUsageRecorder.shared
    ) {
        self.client = client
        self.taskContext = taskContext
        self.usageRecorder = usageRecorder
    }

    public func decide(
        prompt: String,
        payload: RedactedPayload,
        session: VisionSessionRequestContext
    ) async throws -> String {
        // Four fields, read together, because `redactCapture` sets all four or none — and §4.5 makes
        // the dimensions required, since vision token cost is driven by pixel dimensions rather than
        // bytes and metering cannot price the call without them.
        guard let imageData = payload.redactedImageData,
              let mediaType = payload.imageMediaType,
              let pixelWidth = payload.imagePixelWidth,
              let pixelHeight = payload.imagePixelHeight else {
            throw VisionModelClientError.payloadCarriedNoImage
        }
        guard imageData.count <= Self.maximumImageBytes else {
            throw VisionModelClientError.payloadTooLarge(bytes: imageData.count, limit: Self.maximumImageBytes)
        }

        var body = taskContext.wireFields
        body["session_id"] = session.sessionID
        body["session_iteration"] = session.iteration
        body["prompt"] = prompt
        body["image"] = [
            // The media type comes off the payload rather than being a literal: since SONNY-114 the
            // encoder picks PNG or JPEG per capture, and a hardcoded "image/png" would label roughly
            // half of real captures as a format they are not. §4.5 rule 2 says the same thing to the
            // server, which reads this field rather than assuming either.
            "media_type": mediaType.rawValue,
            "encoding": "base64",
            "data": imageData.base64EncodedString(),
            // The dimensions of the image **as encoded**, which since SONNY-114 may be smaller than
            // the capture's own — the same `SentImageSize` the prompt declares and every returned
            // coordinate is scaled by. §4.5 rule 1 forbids the server from resampling, so these stay
            // true of the bytes beside them.
            "pixel_width": pixelWidth,
            "pixel_height": pixelHeight,
        ]

        let decoded: SonnyTextRouteResponse
        do {
            decoded = try await client.modelRouteResponse(
                SonnyTextRouteResponse.self,
                route: .screenAnalyze,
                body: try JSONSerialization.data(withJSONObject: body)
            )
        } catch let error as SonnyBackendError {
            throw VisionModelClientError.backend(error)
        }

        // **Recorded before the reply is used, which is the order the four text clients use and the
        // order that is right.** An iteration whose decision the parser then rejects still cost what
        // it cost, and a summary that silently omitted exactly the failed iterations would understate
        // the sessions a user is most likely to ask about.
        //
        // **A reply with no `usage` block still produces a record**, with no token counts. That is
        // §4.5's own shape rather than an omission: `server/src/model/vision.ts` deliberately sends
        // nothing when the provider reported nothing, because the only estimate this gateway could
        // make is from the text — and on this route the text is the small part of a request whose
        // dominant term is an image. So the count of screen-control calls is always right, and a
        // token figure appears only when a provider measured one.
        usageRecorder.record(
            decoded.usage?.record(kind: .screenControl, route: .screenAnalyze)
                ?? AIUsageRecord(kind: .screenControl, model: SonnyModelRoute.screenAnalyze.usageModelName)
        )
        // Parsing stays client-side (§1.3): what comes back is the model's own string, and
        // `VisionDecisionParser` in the runner is what turns it into an action.
        return decoded.output_text
    }
}
