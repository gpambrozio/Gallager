# Security Policy

Gallager is an end-to-end-encrypted remote-monitoring tool, so security reports
get priority attention.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting:
https://github.com/gpambrozio/Gallager/security/advisories/new

Please don't open public issues for security reports.

## Supported versions

Only the latest released version receives security fixes.

## Scope notes

- The relay server never sees plaintext terminal content — pairing and session
  traffic are end-to-end encrypted between the Mac and iOS apps (see
  [docs/e2ee-encryption-plan.md](docs/e2ee-encryption-plan.md)). Reports that
  break that property are the highest severity.
- Self-hosted relay deployments are configured by their operators; issues in
  the deployment recipes ([docs/self-hosting.md](docs/self-hosting.md)) are in
  scope, issues in an individual operator's server hygiene are not.
