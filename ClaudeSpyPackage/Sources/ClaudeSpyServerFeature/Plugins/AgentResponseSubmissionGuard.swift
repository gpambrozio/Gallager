#if os(macOS)
    import ClaudeSpyNetworking

    /// Staleness gate for inbound viewer response submissions (issue #710).
    ///
    /// Actionable push notifications let a viewer answer a permission/question
    /// form long after it was posed — the notification can sit on the lock
    /// screen while the user answers in the terminal and the agent moves on.
    /// Delivering such a stale answer would inject keystrokes ("1", Escape,
    /// arrow-nav) into a pane that is no longer showing that prompt. So a
    /// *blocking* response (permission / question / plan) is delivered only
    /// while the pane's open form still matches the submission's `requestId`.
    ///
    /// Non-blocking responses (prompt / reply-after-stop) are typed input the
    /// user sends at will — they never had an open-form precondition and pass
    /// through untouched.
    enum AgentResponseSubmissionGuard {
        /// Whether `response` for `submittedRequestID` should reach the owning
        /// core's `deliverResponse`. `openFormRequestID` is the request id of
        /// the target pane's currently open form, `nil` when none (or the pane
        /// is unknown — a blocking answer for a vanished session is stale by
        /// definition).
        static func shouldDeliver(
            response: AgentResponse,
            openFormRequestID: String?,
            submittedRequestID: String
        ) -> Bool {
            switch response {
            case .prompt,
                 .replyAfterStop:
                return true
            case .permission,
                 .askUserQuestion,
                 .approvePlan:
                return openFormRequestID == submittedRequestID
            }
        }
    }
#endif
