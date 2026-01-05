# Build stage
FROM swift:6.0-jammy AS builder

WORKDIR /build

# Copy package files first for better caching
COPY Package.swift Package.resolved ./
COPY Sources ./Sources

# Create empty test directories to satisfy package structure
# (tests are not needed for the release build)
RUN mkdir -p Tests/ClaudeSpyNetworkingTests Tests/ClaudeSpyCommonTests Tests/ClaudeSpyFeatureTests Tests/ClaudeSpyServerFeatureTests Tests/ClaudeSpyExternalServerTests && \
    touch Tests/ClaudeSpyNetworkingTests/.gitkeep Tests/ClaudeSpyCommonTests/.gitkeep Tests/ClaudeSpyFeatureTests/.gitkeep Tests/ClaudeSpyServerFeatureTests/.gitkeep Tests/ClaudeSpyExternalServerTests/.gitkeep

# Build release binary (--product links the executable, --target only compiles)
RUN swift build -c release --product ClaudeSpyExternalServer \
    -Xswiftc -cross-module-optimization

# Runtime stage - use slim image
FROM swift:6.0-jammy-slim

WORKDIR /app

# Copy the built binary
COPY --from=builder /build/.build/release/ClaudeSpyExternalServer ./

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser
USER appuser

# Expose the default port
EXPOSE 8080

# Set environment
ENV ENVIRONMENT=production

# Run the server
ENTRYPOINT ["./ClaudeSpyExternalServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
