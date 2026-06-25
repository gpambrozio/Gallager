# syntax=docker/dockerfile:1.4

# Build stage
# Swift 6.3+ is required so SPM resolves swift-dependencies' main Package.swift
# (which declares package traits); older toolchains fall back to its
# Package@swift-6.0.swift, which has no traits and would reject `traits:`.
FROM swift:6.3-jammy AS builder

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

# Step 5: Create an empty directory for every test target the manifest declares,
# so `swift package resolve`/`swift build` can load the package graph (the real
# Tests/ are rsync-excluded from the relay build — their sources aren't needed).
# Derived from Package.swift rather than hardcoded, so adding a test target can't
# silently break this build. Every test target name ends in "Tests" by convention
# (product refs like "VaporTesting"/"DependenciesTestSupport" don't, so they're
# correctly excluded).
RUN grep -oE 'name: "[A-Za-z0-9_]+Tests"' Package.swift | grep -oE '[A-Za-z0-9_]+Tests' | sort -u | while read -r t; do \
        mkdir -p "Tests/$t" && touch "Tests/$t/.gitkeep"; \
    done

# Step 6: Build release binary with BuildKit cache mount for incremental builds
# The cache mount persists .build across builds but isn't included in the layer,
# so we copy the binary to /tmp/ within the same RUN instruction
RUN --mount=type=cache,target=/build/.build \
    swift build -c release --product ClaudeSpyExternalServer \
    -Xswiftc -cross-module-optimization && \
    cp .build/release/ClaudeSpyExternalServer /tmp/

# Runtime stage - use slim image
FROM swift:6.3-jammy-slim

WORKDIR /app

# Install curl so the docker-compose healthcheck can call /health. The slim
# image otherwise lacks any HTTP client, so the healthcheck would always fail.
RUN apt-get update && apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

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
