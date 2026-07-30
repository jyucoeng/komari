# Komari Multi-Arch Support Status

Generated at: 2026-07-30 09:16:14 (北京时间)

## Column Description

| Column | Meaning |
|--------|---------|
| `Version` | Upstream release version tag |
| `Upstream Image` | Whether `ghcr.io/komari-monitor/komari:{version}` Docker image exists upstream |
| `Upstream Binary Support` | Which architecture binaries are available in the upstream GitHub Release |
| `Our Image` | Whether `ghcr.io/{{repo}}:{version}` has been built and pushed |
| `Our Build Platforms` | Which platform images are included in our multi-arch manifest |

## Status Table

| Version | Upstream Image | Upstream Binary Support | Our Image | Our Build Platforms |
|---------|:--------------:|-------------------------|:---------:|---------------------|
| 1.3.1 | ✅ | `amd64`, `arm64`, `386`, `riscv64`, `loong64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.3.0 | ✅ | `amd64`, `arm64`, `386`, `riscv64`, `loong64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.3.0-pre1 | ✅ | `amd64`, `arm64`, `386`, `riscv64`, `loong64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.7 | ✅ | `amd64`, `arm64`, `386`, `riscv64`, `loong64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.6 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.5-fix2 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.5-fix1 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.5 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.3 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.2 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.1 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.2.0 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.9 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.8 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.7 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.6 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.5a | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.5 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.4 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.3 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.2a | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.2 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.1b | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.1a | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.1.0 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.9 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.8-fix2 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.7 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.6 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.5-fix1 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 1.0.4-fix3 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 1.0.3-fix1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 1.0.2 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 1.0.1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 1.0.0 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.6-fix1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.6 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.5 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.5-fix1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.5-pre1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.4 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.3 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.2-fix2 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.2-fix3 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.2 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.1 | ❌ | `amd64`, `arm64`, `386`, `riscv64` | ❌ | — |
| 0.1.0-fix1 | ✅ | `amd64`, `arm64`, `386`, `riscv64` | ✅ | `amd64`, `arm64`, `386`, `riscv64` |
| 0.1.0 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.1.0-pre3 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.1.0-prerelease | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.9 | ✅ | `amd64`, `arm64` | ✅ | `amd64`, `arm64` |
| 0.0.8 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.7 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.6 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.5a | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.5 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.4 | ❌ | `amd64`, `arm64` | ❌ | — |
| 0.0.3 | ❌ | `amd64`, `arm64` | ❌ | — |
