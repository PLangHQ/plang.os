# os bot — branch `os/v1-container`

## v1 — First container image ([details](v1/summary.md))

Bootstrap iteration. Delivered `container/Containerfile`, `container/build.sh`,
`container/README.md`, and bot docs (plan/lockdown/attack-surface/tradeoffs/
measurements). Multi-arch (amd64 + arm64) Alpine-musl image, tini as PID 1,
no shell / no apk / no setuid in final image, digest-pinned bases, reproducible
build, SBOM + trivy hooks, cosign-ready. Measurements and trivy counts pending
the first real local build.
