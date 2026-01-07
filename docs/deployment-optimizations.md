# Deployment Optimizations

This document describes the deployment optimizations implemented and potential further improvements.

## Implemented Optimizations

### 1. Removed `--no-cache` Flag
**File:** `deploy.sh`

Previously, the deploy script used `docker compose build --no-cache`, which forced Docker to rebuild every layer from scratch on every deployment. This has been removed to allow proper layer caching.

### 2. Restructured Dockerfile for Layer Caching
**File:** `Dockerfile`

The Dockerfile now follows a proper caching strategy:

1. Copy only `Package.swift` and `Package.resolved`
2. Create minimal placeholder source structure
3. Run `swift package resolve` (cached unless manifests change)
4. Copy actual source code
5. Build the binary

This ensures dependency resolution (~3 minutes) is cached for code-only changes.

## Results

| Scenario | Before | After |
|----------|--------|-------|
| No changes | ~12 min | ~2 sec |
| Code-only change | ~12 min | ~8-10 min |
| Dependency change | ~12 min | ~12 min |

## Potential Further Improvements

### ~~1. BuildKit Cache Mounts (Medium Effort, High Impact)~~ ✅ IMPLEMENTED

~~Use BuildKit's cache mounts to persist Swift build artifacts across builds:~~

```dockerfile
# syntax=docker/dockerfile:1.4

RUN --mount=type=cache,target=/build/.build \
    swift build -c release --product ClaudeSpyExternalServer \
    -Xswiftc -cross-module-optimization && \
    cp .build/release/ClaudeSpyExternalServer /tmp/
```

~~Enable with: `DOCKER_BUILDKIT=1 docker compose build`~~

**Expected improvement:** Incremental compilation for code changes could reduce build time from ~8-10 minutes to ~2-3 minutes.

**Status:** Implemented in Dockerfile and deploy.sh. BuildKit is now enabled by default.

### 2. Pre-built Dependencies Image (High Effort, Very High Impact)

Create a separate base image with pre-resolved and pre-compiled dependencies:

```dockerfile
# deps.Dockerfile - rebuild only when Package.swift changes
FROM swift:6.0-jammy AS deps
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN mkdir -p Sources/ClaudeSpyNetworking Sources/ClaudeSpyExternalServer && \
    echo 'public struct Placeholder {}' > Sources/ClaudeSpyNetworking/Placeholder.swift && \
    echo '@main struct Main { static func main() {} }' > Sources/ClaudeSpyExternalServer/main.swift
RUN swift build -c release 2>/dev/null || true
```

Push to a registry and use as base:

```dockerfile
FROM your-registry/claudespy-deps:latest AS builder
COPY Sources ./Sources
RUN swift build -c release --product ClaudeSpyExternalServer
```

**Expected improvement:** Code-only deployments could drop to ~1-2 minutes.

### 3. Parallel rsync with Compression (Low Effort, Low Impact)

Add compression to rsync for faster file transfer:

```bash
rsync -avz --compress-level=9 --delete \
    --exclude='.build' \
    --exclude='.git' \
    ...
```

**Expected improvement:** Marginal, files are already small.

### 4. Remote Build Cache (High Effort, Very High Impact)

Use a remote Docker build cache (e.g., registry cache or S3):

```bash
docker buildx build \
    --cache-from type=registry,ref=your-registry/claudespy:cache \
    --cache-to type=registry,ref=your-registry/claudespy:cache,mode=max \
    .
```

**Expected improvement:** Shared cache across CI/CD and local builds.

### 5. Multi-stage Parallel Builds (Medium Effort, Medium Impact)

If the project grows to have multiple independent targets, use parallel multi-stage builds:

```dockerfile
FROM swift:6.0-jammy AS deps
# ... resolve dependencies

FROM deps AS build-server
COPY Sources/ClaudeSpyExternalServer ./Sources/ClaudeSpyExternalServer
RUN swift build -c release --product ClaudeSpyExternalServer

FROM deps AS build-other
COPY Sources/OtherTarget ./Sources/OtherTarget
RUN swift build -c release --product OtherTarget
```

### 6. Slim Down Dependencies (Medium Effort, High Impact)

Review `Package.swift` to ensure only necessary dependencies are included. Current dependencies include:

- SwiftFormat (dev tool, not needed for server build)
- SFSymbolsMacro (iOS/macOS only, not needed for Linux server)
- SwiftTerm (iOS/macOS only, not needed for Linux server)

Consider conditional compilation or separate packages for server-only builds.

### 7. Use Static Linking (Low Effort, Medium Impact)

Build a fully static binary to use a smaller runtime image:

```dockerfile
RUN swift build -c release --product ClaudeSpyExternalServer \
    --static-swift-stdlib \
    -Xswiftc -cross-module-optimization

FROM ubuntu:22.04  # or even alpine/scratch
```

**Expected improvement:** Smaller image size, faster pulls.

## Monitoring Deployment Times

To track deployment performance, add timing to the deploy script:

```bash
SECONDS=0
# ... deployment steps ...
echo "Deployment completed in ${SECONDS} seconds"
```

## Priority Recommendations

1. **Quick wins:** ✅ Already implemented (layer caching)
2. **Next step:** ✅ BuildKit cache mounts for incremental builds (DONE)
3. **Long term:** Pre-built dependencies image + remote cache
