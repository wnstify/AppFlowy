# AppFlowy Cloud - Security-Hardened Docker Compose

A production-ready, security-hardened self-hosted [AppFlowy Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud) deployment with Docker Compose.

## What is this?

This project wraps the official AppFlowy Cloud Docker images with comprehensive security hardening, network isolation, non-root container execution, and supply chain protections. It is designed to sit behind a reverse proxy (such as [Pangolin](https://github.com/fosrl/pangolin), Traefik, Caddy, or nginx) that handles TLS termination.

The official AppFlowy Cloud compose file runs all containers as root, uses a single flat network, exposes ports to all interfaces, runs Redis without a password, applies no resource limits, and uses mutable `:latest` tags. This project fixes all of that.

## Architecture

```
Internet -> Reverse Proxy (TLS) -> 127.0.0.1:8025 -> Angie -> AppFlowy Services
```

**Single exposed port:** `127.0.0.1:8025` (localhost only — invisible to the network)

[Angie](https://angie.software/en/) (nginx-compatible reverse proxy) handles internal routing across all services through a single entry point:

| Path | Service | Description |
|------|---------|-------------|
| `/` | appflowy_web | Web UI (static + SSR) |
| `/api` | appflowy_cloud | Backend REST API |
| `/ws` | appflowy_cloud | WebSocket (realtime collaboration) |
| `/gotrue/` | gotrue | Authentication (signup, login, OAuth) |
| `/console` | admin_frontend | Admin dashboard |
| `/minio-api/` | minio | S3 API (presigned URL downloads) |

## Services (9 containers)

| Service | Image | Version | Purpose |
|---------|-------|---------|---------|
| **postgres** | `pgvector/pgvector` | pg18 | Database with vector search (AI features) |
| **dragonfly** | `dragonflydb/dragonfly` | v1.36.0 | Redis-compatible cache (password-protected) |
| **minio** | `minio/minio` | 2025-09-07 | S3-compatible object storage |
| **gotrue** | `appflowyinc/gotrue` | 0.12.0 | Authentication (signup disabled by default) |
| **appflowy_cloud** | `appflowyinc/appflowy_cloud` | 0.12.0 | Backend API + WebSocket server |
| **appflowy_worker** | `appflowyinc/appflowy_worker` | 0.12.0 | Background tasks (imports, jobs) |
| **appflowy_web** | `appflowyinc/appflowy_web` | 0.10.5 | Web UI (nginx + Node.js SSR) |
| **admin_frontend** | `appflowyinc/admin_frontend` | 0.12.0 | Admin dashboard (Node.js) |
| **angie** | `angie` | 1.11.3-alpine | Internal reverse proxy |

All images are pinned to exact versions with SHA256 digest verification. See [SECURITY.md](SECURITY.md#pinned-image-versions-with-sha256-digest-verification) for why this matters.

## Quick Start

```bash
git clone <repo-url> && cd appflowy
bash setup.sh
docker compose up -d
```

The interactive setup script handles everything automatically:
- Prompts for your domain, admin email, and optional SMTP
- Generates cryptographically strong passwords for all services
- Detects your UID/GID and updates the compose file
- Creates data directories with correct ownership
- Pulls images and extracts container assets for non-root operation
- Generates a complete `.env` file

See [INSTALLATION.md](INSTALLATION.md) for manual setup, upgrading, backups, and OAuth configuration.

## Security Highlights

This project applies defense-in-depth across every layer. See [SECURITY.md](SECURITY.md) for the full documentation with detailed explanations of every measure.

- **Zero root containers** — all 9 services run as your host UID/GID, preventing container-escape-to-root attacks
- **Network segmentation** — 4 isolated Docker networks (3 internal, no internet access), preventing lateral movement between services
- **Capability dropping** — `cap_drop: ALL` on every container with only minimal re-adds, removing ~40 Linux kernel capabilities
- **No-new-privileges** — `no-new-privileges:true` on every container, preventing SUID/SGID exploitation
- **Pinned images with SHA256** — every image uses `tag@sha256:digest` format, preventing supply chain attacks via tag mutation
- **Dragonfly with auth** — replaces the official passwordless Redis with password-protected Dragonfly
- **Resource limits** — memory, CPU, and PID limits on every container, preventing resource exhaustion and fork bombs
- **Localhost-only port** — `127.0.0.1:8025` is invisible to external networks
- **Read-only filesystems** — immutable root filesystem on the reverse proxy
- **IPC isolation** — `ipc: private` on every container, preventing shared memory attacks
- **Log rotation** — `json-file` driver with 10MB x 3 rotation, preventing disk exhaustion
- **tmpfs mounts** — RAM-backed `/tmp` on every container, sensitive temp data never touches disk
- **Security headers** — `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` on all responses
- **Signup disabled** — closed by default, must be explicitly enabled

## Why Dragonfly Instead of Redis?

The official AppFlowy Cloud deployment uses Redis as its cache layer. This project replaces Redis with [Dragonfly](https://www.dragonflydb.io/) for several reasons:

1. **Multi-threaded architecture** — Redis is single-threaded by design. Dragonfly uses a shared-nothing multi-threaded architecture that delivers up to 25x higher throughput on the same hardware. For a collaboration platform handling real-time WebSocket sessions, this matters.

2. **Memory efficiency** — Dragonfly uses significantly less memory than Redis for the same dataset. It achieves this through a novel dashtable data structure and efficient memory allocation. In testing, Dragonfly uses roughly 30-40% less memory than Redis for equivalent workloads.

3. **Drop-in compatible** — Dragonfly speaks the Redis protocol (RESP2/RESP3) natively. AppFlowy Cloud services connect to it via standard `redis://` URIs. No code changes needed — it's a transparent drop-in replacement.

4. **Built-in snapshotting** — Dragonfly handles persistence natively without the fork-based RDB snapshots that cause Redis memory spikes (Redis temporarily doubles its memory during snapshots due to copy-on-write).

5. **Better for containers** — Redis was designed for bare-metal servers. Dragonfly was designed from the ground up for modern infrastructure, handling resource constraints (memory limits, CPU pinning) more gracefully.

6. **Active development** — Dragonfly is actively developed with modern C++ and has a growing community. It supports all Redis data structures and commands that AppFlowy uses.

The official Redis deployment also runs without authentication, which is a security risk even on internal networks. This project configures Dragonfly with `--requirepass`, and the password is auto-generated during setup.

## Why Angie Instead of nginx?

The internal reverse proxy uses [Angie](https://angie.software/en/) instead of nginx:

1. **Active open-source fork** — Angie is a fork of nginx maintained by former nginx core developers. After F5's acquisition of nginx and the subsequent departure of key developers, Angie was created as a community-driven alternative with active development.

2. **Full nginx compatibility** — Angie is configuration-compatible with nginx. The `angie.conf` file uses standard nginx directives. Modules, syntax, and behavior are identical, making it a zero-effort swap.

3. **Enhanced features** — Angie includes features that nginx only offers in the paid "nginx Plus" tier, such as dynamic upstream reconfiguration, enhanced monitoring, and improved HTTP/3 support — all in the open-source version.

4. **Better security track record** — As an actively maintained fork, Angie receives security patches independently and often faster than upstream nginx. The project has a transparent security policy.

5. **Alpine-based image** — The `angie:alpine` image is minimal (~15MB), reducing the attack surface compared to full OS-based images.

6. **Non-root friendly** — Angie handles non-root operation cleanly with tmpfs mounts for cache, logs, and PID files, making it ideal for security-hardened deployments.

## System Resource Limits

Every container has explicit memory, CPU, and PID limits to prevent resource exhaustion attacks and ensure predictable performance. The official AppFlowy Cloud compose applies no resource limits whatsoever.

| Service | Memory Limit | Memory Reserved | CPUs | PID Limit |
|---------|-------------|-----------------|------|-----------|
| postgres | 4 GB | 512 MB | 4.0 | 200 |
| dragonfly | 2 GB | 256 MB | 2.0 | 100 |
| minio | 2 GB | 256 MB | 2.0 | 150 |
| gotrue | 512 MB | 64 MB | 2.0 | 100 |
| appflowy_cloud | 4 GB | 256 MB | 4.0 | 300 |
| appflowy_worker | 2 GB | 128 MB | 2.0 | 200 |
| appflowy_web | 512 MB | 64 MB | 2.0 | 100 |
| admin_frontend | 512 MB | 64 MB | 2.0 | 100 |
| angie | 256 MB | 32 MB | 2.0 | 100 |
| **Total ceiling** | **~15.8 GB** | **~1.7 GB** | | **1,350** |

**Memory limits** prevent any single container from consuming all host RAM (e.g., a memory leak in the backend won't kill the database). **Memory reservations** guarantee a minimum allocation so critical services like PostgreSQL always have enough to operate. **CPU limits** prevent compute-heavy operations from starving other services. **PID limits** prevent fork bombs — if a compromised container tries to spawn thousands of processes, it hits a hard ceiling.

These values are tuned for a small-to-medium team deployment (5-50 users). For larger deployments, increase `postgres`, `appflowy_cloud`, and `dragonfly` limits proportionally.

## Differences from Official Compose

| Feature | Official | This Project |
|---------|----------|-------------|
| Container user | root | Non-root (your UID/GID) |
| Image tags | Mutable `:latest` | Pinned version + SHA256 digest |
| Networks | Single flat network | 4 isolated networks (3 internal) |
| Redis/Cache | Redis, no password | Dragonfly with `--requirepass` |
| Reverse proxy | nginx | Angie (nginx-compatible, actively maintained) |
| Capabilities | Default (~40 capabilities) | `cap_drop: ALL` + minimal re-adds |
| Privilege escalation | Allowed | `no-new-privileges: true` |
| Resource limits | None | Memory, CPU, PIDs per service |
| Port binding | `0.0.0.0:80` (all interfaces) | `127.0.0.1:8025` (localhost only) |
| Log rotation | None (unbounded growth) | `json-file` 10MB x 3 per container |
| IPC namespace | Default (shared) | `ipc: private` |
| Filesystem | Read-write everywhere | Read-only where possible |
| Temp files | Disk-backed | tmpfs (RAM-backed, size-limited) |
| Signup | Open to anyone | Disabled by default |
| Setup process | Manual multi-step | Interactive script with auto-generation |

## File Structure

```
appflowy/
  docker-compose.yml          # Main compose (9 services, 4 networks, pinned images)
  .env.example                # Configuration template with documentation
  setup.sh                    # Interactive setup + upgrade script
  angie/angie.conf            # Internal reverse proxy config (Angie/nginx)
  appflowy-web/nginx.conf     # Non-root nginx config for web UI container
  INSTALLATION.md             # Full installation, upgrade, and backup guide
  SECURITY.md                 # Comprehensive security documentation
  README.md                   # This file

  # Created by setup.sh at runtime (gitignored):
  .env                        # Active configuration with secrets
  postgres-data/              # PostgreSQL data (bind mount)
  dragonfly-data/             # Dragonfly cache data (bind mount)
  minio-data/                 # MinIO object storage (bind mount)
  appflowy-web-html/          # Web UI static assets (extracted from image)
  appflowy-web-dist/          # Web UI dist files (extracted from image)
  admin-frontend-app/         # Admin frontend app (extracted from image)
```

## Supporting AppFlowy

This project exists because the [AppFlowy](https://appflowy.com) team built an incredible open-source collaboration platform and made it available to everyone. AppFlowy Cloud, the backend powering real-time collaboration, is fully open-source under AGPL-3.0 — a genuine commitment to the open-source community.

If you find AppFlowy valuable, the best way to support the project and its continued development is through their official offerings:

- **[AppFlowy Cloud](https://appflowy.com/pricing)** — Managed SaaS with a generous free tier, Pro plan ($10/month) with unlimited storage and AI features, and team plans. Zero infrastructure to manage.
- **[Self-Hosted Licenses](https://appflowy.com/pricing)** — For organizations that need self-hosted deployments with official support, SLAs, and enterprise features.
- **[Star the project on GitHub](https://github.com/AppFlowy-IO/AppFlowy)** — Stars help increase visibility and attract contributors.
- **[Contribute upstream](https://github.com/AppFlowy-IO/AppFlowy-Cloud)** — Bug reports, feature requests, and pull requests to the official AppFlowy Cloud repository directly benefit everyone.

This hardened deployment wrapper is a community project. The real work — building the collaboration engine, the editor, the mobile apps, the AI features — is done by the AppFlowy team. Please support them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to this project.

## License

This project provides Docker Compose configuration for AppFlowy Cloud. AppFlowy Cloud is licensed under [AGPL-3.0](https://github.com/AppFlowy-IO/AppFlowy-Cloud/blob/main/LICENSE).
