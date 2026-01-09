# syntax=docker/dockerfile:1.4

# Build stage
FROM swift:6.0-jammy AS builder

WORKDIR /build

# Step 1: Copy ONLY dependency manifest files
COPY Package.swift Package.resolved ./

# Step 2: Create minimal directory structure for package resolution
# This allows swift package resolve to work without the actual source code
RUN mkdir -p Sources/ClaudeSpyNetworking Sources/ClaudeSpyExternalServer && \
    echo 'public struct Placeholder {}' > Sources/ClaudeSpyNetworking/Placeholder.swift && \
    echo '@main struct Main { static func main() {} }' > Sources/ClaudeSpyExternalServer/main.swift

# Step 3: Resolve and fetch dependencies (CACHED unless Package.swift/resolved changes)
RUN swift package resolve

# Step 4: Copy the actual source code (changes here only invalidate build, not dependency fetch)
COPY Sources ./Sources

# Step 5: Create empty test directories to satisfy package structure
# (tests are not needed for the release build)
RUN mkdir -p Tests/ClaudeSpyNetworkingTests Tests/ClaudeSpyCommonTests Tests/ClaudeSpyFeatureTests Tests/ClaudeSpyServerFeatureTests Tests/ClaudeSpyExternalServerTests Tests/ClaudeSpyEncryptionTests && \
    touch Tests/ClaudeSpyNetworkingTests/.gitkeep Tests/ClaudeSpyCommonTests/.gitkeep Tests/ClaudeSpyFeatureTests/.gitkeep Tests/ClaudeSpyServerFeatureTests/.gitkeep Tests/ClaudeSpyExternalServerTests/.gitkeep Tests/ClaudeSpyEncryptionTests/.gitkeep

# Step 6: Build release binary with BuildKit cache mount for incremental builds
# The cache mount persists .build across builds but isn't included in the layer,
# so we copy the binary to /tmp/ within the same RUN instruction
RUN --mount=type=cache,target=/build/.build \
    swift build -c release --product ClaudeSpyExternalServer \
    -Xswiftc -cross-module-optimization && \
    cp .build/release/ClaudeSpyExternalServer /tmp/

# Runtime stage - use slim image
FROM swift:6.0-jammy-slim

WORKDIR /app

# Copy the built binary (from /tmp/ where we placed it after build due to cache mount)
COPY --from=builder /tmp/ClaudeSpyExternalServer ./

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser && \
    mkdir -p /data && \
    chown appuser:appuser /data
USER appuser

# Expose the default port
EXPOSE 8080

# Set environment
ENV ENVIRONMENT=production

# Run the server
ENTRYPOINT ["./ClaudeSpyExternalServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
