#if os(iOS)
    import ClaudeSpyCommon

    /// Backward-compatible typealiases for the shared viewer types.
    /// These allow existing consumers (ConnectionManager, views) to continue using
    /// the original type names without modification.

    public typealias MacConnection = ViewerConnection<PairedMac>
    public typealias RelayClient = ViewerRelayClient
    public typealias RelayClientError = ViewerRelayClientError
#endif
