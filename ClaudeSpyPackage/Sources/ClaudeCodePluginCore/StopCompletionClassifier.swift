import Dependencies
import DependenciesMacros
import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

// MARK: - StopCompletion

/// Verdict on whether a `Stop` hook's last assistant message reads like the agent
/// genuinely finished, or like it is still waiting on background work to finish.
public enum StopCompletion: Sendable, Equatable {
    /// The message reads like a genuine wrap-up → honor the Stop (`.doneWorking`).
    case finished
    /// The message reads like the agent is still waiting on something → suppress
    /// the premature "Done" and keep the session working.
    case stillWaiting
}

// MARK: - StopCompletionClassifier

/// Classifies a `Stop`-hook message with the on-device Apple Intelligence model to
/// decide whether a Stop that arrived *with in-flight background work* is a genuine
/// finish or a premature stop (issue #644).
///
/// Injected as a dependency so `ClaudeCodePluginCore` stays testable without real
/// inference. The default (and `testValue`) returns `.finished`, so any environment
/// without an override — or any Mac without Apple Intelligence — preserves the
/// pre-existing "a message-bearing Stop means doneWorking" behavior. Fail-safe: the
/// classifier can only ever *suppress* a Done; it never strands a session.
@DependencyClient
public struct StopCompletionClassifier: Sendable {
    /// Judge whether `message` reads like a final message. Returns `.finished` when
    /// it cannot decide (model unavailable, inference error) so the caller falls
    /// back to honoring the Stop.
    public var classify: @Sendable (_ message: String) async -> StopCompletion = { _ in .finished }
}

extension StopCompletionClassifier: DependencyKey {
    public static let liveValue = StopCompletionClassifier(
        classify: { message in
            await FoundationModelsStopClassifier.classify(message: message)
        }
    )

    /// Tests honor the Stop unless they override with a stub (see the core tests).
    public static let testValue = StopCompletionClassifier()
}

// MARK: - Foundation Models implementation

#if canImport(FoundationModels)

    /// The real Apple-Intelligence-backed classifier. Isolated in its own type so the
    /// framework + availability guards live in exactly one place.
    private enum FoundationModelsStopClassifier {
        static func classify(message: String) async -> StopCompletion {
            // Foundation Models is macOS/iOS 26+. The app product ships at 26, but the
            // package floor is macOS 15 / iOS 18, so this must runtime-guard; anything
            // older falls back to honoring the Stop.
            guard #available(macOS 26, iOS 26, *) else { return .finished }

            // Availability also depends on device eligibility, region, Apple
            // Intelligence being enabled, and the model having finished downloading.
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return .finished }

            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: prompt(for: message),
                    generating: Verdict.self
                )
                return response.content.stillWaiting ? .stillWaiting : .finished
            } catch {
                // Guardrail violations, context overflow, decode errors → honor the Stop.
                return .finished
            }
        }

        /// Static developer guidance (never interpolate the untrusted message here —
        /// that goes in the prompt as data).
        private static let instructions = """
        You classify a coding assistant's final chat message. The assistant just \
        stopped, but a background task or scheduled job it started is still running. \
        Decide whether the message means the assistant has genuinely FINISHED its \
        work and handed control back to the user (a summary, a conclusion, a \
        question, or a request for input), or whether it means the assistant is \
        STILL WAITING for that background work to finish before it can continue. \
        Base the decision only on the wording of the message.
        """

        /// The untrusted assistant message goes here, as data — not in `instructions`.
        private static func prompt(for message: String) -> String {
            """
            The assistant's last message was:
            \"\"\"
            \(message)
            \"\"\"
            Set stillWaiting to true only if this message clearly implies the \
            assistant is not finished and expects the background work to complete first.
            """
        }

        /// Not `private`: `@Generable` emits a file-scope conformance extension that
        /// must be able to reference the type.
        @available(macOS 26, iOS 26, *)
        @Generable
        fileprivate struct Verdict {
            @Guide(
                description: "true only when the assistant is clearly NOT done and is "
                    + "waiting for a background task, build, or process to finish before it continues"
            )
            var stillWaiting: Bool
        }
    }

#else

    /// Platforms without the framework (e.g. the Linux relay) always honor the Stop.
    private enum FoundationModelsStopClassifier {
        static func classify(message _: String) async -> StopCompletion {
            .finished
        }
    }

#endif
