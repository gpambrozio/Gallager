import ClaudeSpyCommon

/// Backward-compatible typealiases for the shared viewer types.
/// These allow existing consumers (HostConnectionManager, views) to continue using
/// the original type names without modification.

public typealias HostConnection = ViewerConnection<PairedHost>
public typealias HostRelayClient = ViewerRelayClient
public typealias HostRelayClientError = ViewerRelayClientError
