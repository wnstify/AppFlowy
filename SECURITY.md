# Security Documentation

This document details every security hardening measure applied to this deployment, explains **why** each measure exists, and compares it to the official AppFlowy Cloud Docker Compose configuration.

## Summary

| Measure | Official | This Project |
|---------|----------|-------------|
| Container user | root | Non-root (your UID/GID) |
| Image tags | Mutable `:latest` | Pinned version + SHA256 digest |
| Networks | Single flat network | 4 isolated networks (3 internal) |
| Redis/Cache | Redis, no password | Dragonfly with `--requirepass` |
| Reverse proxy | nginx | Angie (actively maintained nginx fork) |
| Capabilities | Default (~40 capabilities) | `cap_drop: ALL` + minimal re-adds |
| Privilege escalation | Allowed | `no-new-privileges: true` |
| Resource limits | None | Memory, CPU, PIDs per service |
| Port binding | `0.0.0.0:80` (all interfaces) | `127.0.0.1:8025` (localhost only) |
| Log rotation | None (unbounded growth) | `json-file` 10MB x 3 per container |
| IPC namespace | Default (shared) | `ipc: private` |
| Filesystem | Read-write everywhere | Read-only where possible |
| Temp files | Disk-backed | tmpfs (RAM-backed, size-limited) |
| Signup | Open to anyone | Disabled by default |
| Health checks | Partial | All stateful services with dependency ordering |
| Secret generation | Manual | Automated with `openssl rand -hex` |

---

## Pinned Image Versions with SHA256 Digest Verification

### What we do

Every container image in `docker-compose.yml` uses the format `image:tag@sha256:digest`:

```yaml
image: appflowyinc/appflowy_cloud:0.12.0@sha256:d8c82089cc51115dea3f148278acd240a19cca5050d5868862b74a2ab04f00ec
```

### Why this matters

**Docker tags are mutable pointers.** A tag like `:latest` or even `:0.12.0` can be overwritten at any time — by the image publisher, by a compromised CI/CD pipeline, or by an attacker who gains write access to a registry. When you pull `image:latest`, you get whatever that tag happens to point to *right now*, which might not be what it pointed to yesterday.

This is a real supply chain attack vector:

1. **Tag hijacking** — an attacker pushes a malicious image under an existing tag. Your next `docker compose pull` silently replaces your known-good image with the compromised one.

2. **Registry compromise** — if Docker Hub or the publisher's account is compromised, any tag can be overwritten. SHA256 digests are content-addressed — they are a cryptographic hash of the image itself. A different image produces a different digest, period.

3. **Reproducible deployments** — with digest pinning, the exact same binary runs on every machine that uses this compose file. Two deployments from the same commit are byte-for-byte identical. Without pinning, two `docker compose pull` commands run minutes apart might pull different images.

4. **Auditability** — pinned digests create an auditable record of exactly what ran in production. If a vulnerability is discovered in a specific image version, you can verify immediately whether you were affected by comparing digests.

The version tag (e.g., `:0.12.0`) is retained for human readability. Docker resolves the `@sha256:` digest first and ignores the tag if both are present, so the digest is the actual source of truth.

### Current pinned versions

| Service | Image | Version | SHA256 |
|---------|-------|---------|--------|
| postgres | `pgvector/pgvector` | pg18 | `3c37093a...` |
| dragonfly | `dragonflydb/dragonfly` | v1.36.0 | `af221b68...` |
| minio | `minio/minio` | 2025-09-07 | `14cea493...` |
| gotrue | `appflowyinc/gotrue` | 0.12.0 | `306c5d6b...` |
| appflowy_cloud | `appflowyinc/appflowy_cloud` | 0.12.0 | `d8c82089...` |
| appflowy_worker | `appflowyinc/appflowy_worker` | 0.12.0 | `eca5db52...` |
| appflowy_web | `appflowyinc/appflowy_web` | 0.10.5 | `c519ac5b...` |
| admin_frontend | `appflowyinc/admin_frontend` | 0.12.0 | `592bd540...` |
| angie | `angie` | 1.11.3-alpine | `1dab21d9...` |

To update an image, find the new digest on Docker Hub or via `docker inspect --format='{{index .RepoDigests 0}}' <image>` after pulling, then update both the tag and digest in `docker-compose.yml`.

---

## Non-Root Containers

### What we do

All 9 containers run as your host user (set via the `user:` directive in `docker-compose.yml`). No container runs as root at any point during normal operation.

### Why this matters

Running containers as root is the single most common Docker security mistake. When a container runs as root (UID 0):

- **Container escape = host root.** If an attacker exploits a container escape vulnerability (which are discovered regularly in container runtimes), they land on the host as root — full control of the server.
- **File ownership conflicts.** Files created by root-running containers on bind mounts are owned by root on the host, requiring sudo to manage.
- **Violates least privilege.** No AppFlowy service needs root to function. Running as root grants ~40 kernel capabilities that these services never use.

The official AppFlowy Cloud compose runs all containers as root. This project eliminates that entirely.

### How it works

Most services (Go binaries, Rust binaries, Dragonfly) run directly as non-root without issues. Two services — `appflowy_web` and `admin_frontend` — have entrypoints that run `sed -i` to inject configuration at startup. Since these modify files owned by root inside the image, we extract writable content to host bind mounts before starting:

```
docker create <image> -> docker cp <files> -> host directory -> chown -> bind mount back
```

This lets the non-root user modify files that the entrypoint needs to write to. The setup script automates this extraction.

PostgreSQL's entrypoint internally handles permission setup via `CHOWN`, `SETUID`, and `SETGID` capabilities — these are the only capabilities added to any container beyond the base `ALL` drop.

### Per-service user configuration

| Service | User | Capabilities Added | Notes |
|---------|------|-------------------|-------|
| postgres | UID:GID | CHOWN, SETUID, SETGID | PG18 entrypoint manages data directory permissions internally |
| dragonfly | UID:GID | (none) | Runs entirely unprivileged |
| minio | UID:GID | (none) | Both ports >1024, no privilege needed |
| gotrue | UID:GID | (none) | Go binary, port 9999 |
| appflowy_cloud | UID:GID | (none) | Rust binary, port 8000 |
| appflowy_worker | UID:GID | (none) | Rust binary, no port |
| appflowy_web | UID:GID | NET_BIND_SERVICE | nginx binds port 80 inside container |
| admin_frontend | UID:GID | (none) | Node.js on port 3000, unprivileged |
| angie | UID:GID | NET_BIND_SERVICE | Binds port 80 inside container |

**7 of 9 services run with zero capabilities.** The remaining 2 have only the minimum needed.

---

## Capability Dropping

### What we do

Every container has `cap_drop: [ALL]`, removing all ~40 Linux kernel capabilities. Only the absolute minimum required capabilities are re-added per service.

### Why this matters

Linux capabilities are fine-grained root privileges. The full list includes dangerous abilities like:

- `CAP_SYS_ADMIN` — mount filesystems, load kernel modules, access arbitrary devices
- `CAP_NET_RAW` — send raw packets, sniff network traffic
- `CAP_SYS_PTRACE` — attach to any process, read memory of other containers
- `CAP_DAC_OVERRIDE` — bypass all file permission checks
- `CAP_FOWNER` — bypass ownership checks on any file

By default, Docker grants containers a subset of ~14 capabilities. While this is less than the full ~40, it still includes capabilities like `NET_RAW` (network sniffing), `MKNOD` (device creation), and `AUDIT_WRITE` (writing to kernel audit log) that no AppFlowy service needs.

`cap_drop: ALL` removes every capability, then we add back only what's strictly required:
- **CHOWN/SETUID/SETGID** on `postgres` — the PostgreSQL entrypoint manages data directory permissions
- **NET_BIND_SERVICE** on `appflowy_web` and `angie` — nginx/Angie bind to port 80 inside the container

If an attacker gains code execution inside a container, they have zero kernel capabilities to escalate with. They cannot sniff the network, create devices, trace processes, or bypass file permissions.

---

## Privilege Escalation Prevention

### What we do

All containers include:

```yaml
security_opt:
  - no-new-privileges:true
```

### Why this matters

The `no-new-privileges` flag sets the Linux kernel's `PR_SET_NO_NEW_PRIVS` bit on the container's init process. This prevents:

- **SUID/SGID exploitation** — setuid binaries (like `sudo`, `su`, `passwd`) inside the container cannot gain elevated privileges even if they exist in the image
- **Capability inheritance** — child processes cannot acquire more capabilities than their parent
- **Privilege escalation chains** — even if an attacker finds a local privilege escalation vulnerability, the kernel blocks the elevation

This is a defense-in-depth measure that works alongside capability dropping. Even if we missed a capability or if a new escalation technique is discovered, `no-new-privileges` provides a kernel-level backstop.

---

## Network Segmentation

### What we do

Traffic is isolated across 4 Docker networks, 3 of which are `internal: true` (no internet access, no host access).

### Why this matters

The official AppFlowy Cloud compose puts all services on a single flat network. This means every container can talk to every other container and potentially reach the internet. If any single service is compromised, the attacker has direct network access to the database, cache, object storage, and all other services.

Network segmentation applies the principle of least privilege to network access. Each service only connects to the networks it actually needs:

### Network map

```
appflowy-frontend (bridge — only network with host access)
  angie              (only service with a published port)
  appflowy_web       (serves web UI)
  appflowy_cloud     (backend API + WebSocket)
  gotrue             (authentication)
  admin_frontend     (admin dashboard)
  minio              (needed for presigned URL downloads via Angie)

appflowy-database (internal — no internet, no host access)
  postgres           (database)
  gotrue             (needs database for auth)
  appflowy_cloud     (needs database for app data)
  appflowy_worker    (needs database for background jobs)

appflowy-cache (internal — no internet, no host access)
  dragonfly          (cache)
  appflowy_cloud     (needs cache for sessions, realtime)
  appflowy_worker    (needs cache for job queues)

appflowy-storage (internal — no internet, no host access)
  minio              (object storage)
  appflowy_cloud     (needs storage for file uploads)
  appflowy_worker    (needs storage for import processing)
```

### What this prevents

- **postgres** cannot be reached from `appflowy_web`, `admin_frontend`, or `angie`. A compromised frontend cannot directly attack the database.
- **dragonfly** cannot be reached from any frontend service. Cache poisoning attacks from the frontend are impossible.
- **minio** internal S3 traffic is on a separate network from frontend traffic. The frontend network access is only for presigned URL downloads through Angie.
- **appflowy_worker** has no frontend network access at all. It processes background jobs in isolation.
- Only **angie** has a published port, and it's bound to `127.0.0.1` — not even reachable from other machines on the LAN.

### Network access matrix

| Service | frontend | database | cache | storage |
|---------|----------|----------|-------|---------|
| angie | yes | - | - | - |
| appflowy_web | yes | - | - | - |
| appflowy_cloud | yes | yes | yes | yes |
| gotrue | yes | yes | - | - |
| admin_frontend | yes | - | - | - |
| appflowy_worker | - | yes | yes | yes |
| postgres | - | yes | - | - |
| dragonfly | - | - | yes | - |
| minio | yes* | - | - | yes |

*MinIO is on the frontend network solely for presigned URL downloads through Angie. It does not serve the MinIO console or admin API publicly.

---

## Localhost-Only Port Binding

### What we do

The only published port is bound exclusively to localhost:

```yaml
ports:
  - "127.0.0.1:8025:80"
```

### Why this matters

The official compose uses `0.0.0.0:80:80`, which binds to all network interfaces — making the service directly accessible from the internet, bypassing any host firewall that uses `iptables` (Docker manipulates iptables rules directly, often bypassing `ufw` and similar tools).

Binding to `127.0.0.1`:
- **Invisible to the network** — port scanning from external machines finds nothing open
- **Requires a reverse proxy** — forces traffic through your TLS-terminating reverse proxy, ensuring all external traffic is encrypted
- **Bypasses Docker's iptables manipulation** — since the port is localhost-only, Docker doesn't create forwarding rules that bypass host firewalls

---

## Resource Limits

### What we do

Every container has explicit memory, CPU, and PID limits defined in the `deploy.resources` section.

### Why this matters

Without resource limits, a single misbehaving container can consume all host resources:

- **Memory exhaustion** — a memory leak or OOM in one service can kill the entire host, taking down all services including the database
- **CPU starvation** — a compute-heavy operation in one service can starve other services of CPU time, causing health check failures and cascading restarts
- **Fork bombs** — a compromised container can spawn thousands of processes, overwhelming the host's process table and making the server unresponsive

The official AppFlowy Cloud compose defines no resource limits at all.

### Resource allocation table

| Service | Memory Limit | Memory Reserved | CPUs | PID Limit | Rationale |
|---------|-------------|-----------------|------|-----------|-----------|
| postgres | 4 GB | 512 MB | 4.0 | 200 | Largest data service; needs memory for query buffers, shared_buffers, WAL |
| dragonfly | 2 GB | 256 MB | 2.0 | 100 | In-memory cache; also limited internally via `--maxmemory=1536mb` |
| minio | 2 GB | 256 MB | 2.0 | 150 | Object storage; memory scales with concurrent uploads |
| gotrue | 512 MB | 64 MB | 2.0 | 100 | Lightweight Go auth service; low resource needs |
| appflowy_cloud | 4 GB | 256 MB | 4.0 | 300 | Main backend; handles API + WebSocket connections |
| appflowy_worker | 2 GB | 128 MB | 2.0 | 200 | Background processing; imports can be memory-intensive |
| appflowy_web | 512 MB | 64 MB | 2.0 | 100 | Static file serving + SSR; minimal resource needs |
| admin_frontend | 512 MB | 64 MB | 2.0 | 100 | Admin dashboard; minimal traffic |
| angie | 256 MB | 32 MB | 2.0 | 100 | Reverse proxy; handles all incoming connections |
| **Total ceiling** | **~15.8 GB** | **~1.7 GB** | | **1,350** | |

**Memory limits** are hard ceilings. If a container exceeds its limit, Docker OOM-kills it and the `restart: unless-stopped` policy brings it back. This prevents a runaway service from killing the host.

**Memory reservations** are soft guarantees. Docker tries to ensure each container has at least this much memory available, even under host memory pressure. This prevents critical services like PostgreSQL from being starved.

**PID limits** prevent fork bombs. The limit includes threads (Linux counts threads as lightweight processes in cgroups). A compromised container trying `:(){ :|:& };:` hits the PID ceiling and cannot spawn more processes.

---

## Read-Only Filesystem

### What we do

The `angie` reverse proxy runs with `read_only: true`, making its entire root filesystem immutable. Writable paths are provided exclusively via tmpfs:

```yaml
read_only: true
tmpfs:
  - /tmp:size=256M
  - /var/cache/angie:size=128M
  - /var/log/angie:size=64M
  - /run:size=16M
```

### Why this matters

The reverse proxy is the most exposed service — it processes all incoming HTTP requests. If an attacker finds a vulnerability in Angie/nginx that allows arbitrary file writes, a read-only filesystem prevents them from:

- Writing malicious scripts or webshells to the filesystem
- Modifying the proxy configuration to redirect traffic
- Planting persistent backdoors that survive container restarts
- Overwriting binaries to maintain persistent access

The tmpfs mounts provide necessary writable paths (cache, logs, PID files, temp uploads) without allowing persistent writes. tmpfs is RAM-backed, size-limited, and cleared on restart.

---

## IPC Isolation

### What we do

All containers use:

```yaml
ipc: private
```

### Why this matters

By default, Docker containers share the host's IPC namespace, which includes shared memory segments (`/dev/shm`), semaphores, and message queues. This creates a covert channel between containers:

- An attacker in one container could read shared memory from another container
- Shared memory can be used for inter-process communication between containers that should be isolated
- Some attack techniques use shared memory to escape container boundaries

`ipc: private` gives each container its own IPC namespace, eliminating these cross-container communication channels.

---

## tmpfs Mounts

### What we do

Every container has `/tmp` mounted as tmpfs with size limits. Services that need additional writable paths (nginx cache, log directories, PID files) also use tmpfs.

### Why this matters

- **RAM-backed storage** — temporary files never touch disk. Sensitive data (session tokens, partial uploads, temp files) that applications write to `/tmp` disappear when the container stops.
- **Size limits** — each tmpfs mount has an explicit size cap (e.g., `/tmp:size=256M`). A compromised container cannot fill the host's disk by writing to `/tmp`.
- **Automatic cleanup** — tmpfs is cleared on container restart, preventing accumulation of temp files and ensuring a clean state.
- **Performance** — RAM-backed I/O is significantly faster than disk I/O for temporary operations.

### tmpfs allocation

| Service | tmpfs Mounts | Total tmpfs Budget |
|---------|-------------|-------------------|
| postgres | `/tmp` (256M), `/run/postgresql` (16M) | 272 MB |
| dragonfly | `/tmp` (256M) | 256 MB |
| minio | `/tmp` (256M) | 256 MB |
| gotrue | `/tmp` (256M) | 256 MB |
| appflowy_cloud | `/tmp` (256M) | 256 MB |
| appflowy_worker | `/tmp` (256M) | 256 MB |
| appflowy_web | `/tmp` (256M), `/var/log/nginx` (64M), `/var/log/supervisor` (16M), `/var/run` (16M), `/var/cache/nginx` (64M) | 416 MB |
| admin_frontend | `/tmp` (256M) | 256 MB |
| angie | `/tmp` (256M), `/var/cache/angie` (128M), `/var/log/angie` (64M), `/run` (16M) | 464 MB |

---

## Log Rotation

### What we do

All containers use the `json-file` logging driver with rotation:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

### Why this matters

Without log rotation, Docker stores container logs indefinitely in `/var/lib/docker/containers/<id>/`. A verbose application (or an attacker intentionally generating log spam) can fill the host's disk, leading to:

- Database corruption (PostgreSQL requires free disk space for WAL)
- Service failures across all containers
- Host system instability
- Inability to SSH into the server to fix the problem

The `json-file` driver with `max-size: 10m` and `max-file: 3` caps each container's logs at 30 MB (3 files x 10 MB). With 9 containers, the total maximum log storage is **270 MB** — a bounded, predictable amount.

---

## Dragonfly with Authentication

### What we do

Replace the official Redis deployment with [Dragonfly](https://www.dragonflydb.io/), configured with mandatory authentication:

```yaml
command:
  - --requirepass=${DRAGONFLY_PASSWORD}
  - --maxmemory=1536mb
  - --proactor_threads=2
```

### Why Dragonfly instead of Redis

See [README.md](README.md#why-dragonfly-instead-of-redis) for the full comparison. In summary: Dragonfly is multi-threaded (up to 25x throughput), more memory-efficient (30-40% less RAM), drop-in Redis-compatible, designed for containers, and actively developed. It replaces Redis transparently — AppFlowy services connect via standard `redis://` URIs.

### Why authentication matters

The official AppFlowy Cloud runs Redis with **no password**. This means any process on the Docker network can read and write cache data, which includes:

- Session tokens and authentication state
- Real-time collaboration state
- Background job queues
- Rate limiting counters

An attacker who compromises any service on the same network gets full unauthenticated access to the cache. With password authentication enabled, even if an attacker reaches Dragonfly's port, they cannot interact with it without the password.

### Additional hardening

- **Internal-only network** — Dragonfly is only on `appflowy-cache`, unreachable from any frontend service
- **Memory ceiling** — `--maxmemory=1536mb` prevents Dragonfly from consuming more than 1.5 GB regardless of workload
- **Thread limit** — `--proactor_threads=2` bounds CPU usage

---

## Angie Reverse Proxy

### What we do

Use [Angie](https://angie.software/en/) instead of nginx as the internal reverse proxy.

### Why Angie instead of nginx

See [README.md](README.md#why-angie-instead-of-nginx) for the full comparison. In summary: Angie is an actively maintained fork of nginx by former nginx core developers, fully configuration-compatible, includes features that nginx reserves for the paid "Plus" tier, has a transparent security policy with fast patches, and ships a minimal Alpine-based image.

### Security headers

The Angie configuration adds security headers to all responses:

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

- **X-Content-Type-Options: nosniff** — prevents browsers from MIME-sniffing responses, blocking content-type confusion attacks
- **X-Frame-Options: SAMEORIGIN** — prevents clickjacking by blocking the site from being embedded in iframes on other domains
- **Referrer-Policy: strict-origin-when-cross-origin** — limits information leaked in the Referer header to same-origin requests

### Reverse proxy configuration

Your external reverse proxy should additionally configure:
- **TLS 1.2+ only** — disable TLS 1.0/1.1 which have known vulnerabilities
- **HSTS headers** — `Strict-Transport-Security: max-age=63072000; includeSubDomains`
- **Certificate auto-renewal** — Let's Encrypt / ACME for zero-downtime certificate rotation
- **Rate limiting** — optional but recommended for authentication endpoints

---

## Signup Disabled by Default

### What we do

The `.env.example` ships with:

```
GOTRUE_DISABLE_SIGNUP=true
```

### Why this matters

A fresh deployment should not be open to the world. Common scenarios where open signup is dangerous:

- **Before TLS is configured** — credentials transmitted in cleartext
- **Before SMTP is configured** — no email verification, anyone can create accounts with fake emails
- **Before the admin has tested the deployment** — bugs or misconfigurations could expose data
- **Internal/team deployments** — many organizations don't want public registration

Administrators explicitly enable signup after verifying the deployment is secure and functional.

---

## Health Checks

### What we do

All stateful services have Docker health checks with dependency ordering via `depends_on: condition: service_healthy`.

### Why this matters

Health checks enable Docker to:
- Detect when a service is down or unresponsive and restart it automatically
- Order startup correctly (e.g., don't start GoTrue until PostgreSQL is healthy)
- Prevent cascading failures from services connecting to dependencies that aren't ready

| Service | Health Check | Interval | Start Period |
|---------|-------------|----------|-------------|
| postgres | `pg_isready -U appflowy` | 5s | — |
| dragonfly | AUTH + PING via netcat | 5s | — |
| minio | `mc ready local` | 5s | — |
| gotrue | `curl /health` | 5s | 40s |
| appflowy_cloud | `curl /api/health` | 5s | 30s |
| angie | `curl /` | 10s | 30s |

**Start period** gives services time to initialize before health checks begin counting failures. GoTrue has a 40-second start period because it runs database migrations on first start.

### Startup ordering

```
postgres (must be healthy)
  └── gotrue (must be healthy)
  └── dragonfly (must be healthy)
  └── minio (must be healthy)
      └── appflowy_cloud (must be healthy)
          └── appflowy_worker
          └── appflowy_web
          └── admin_frontend
          └── angie
```

---

## Secret Management

### What we do

- `.env` file permissions: `chmod 600` (owner read/write only)
- `.env` is in `.gitignore` to prevent accidental commits
- All passwords use `openssl rand -hex` (URL-safe hex encoding)
- The setup script generates all secrets automatically
- Generated credentials are displayed once at setup time and never stored elsewhere

### Why hex encoding

Database connection strings embed passwords directly in URLs:

```
postgres://user:PASSWORD@host:5432/db
```

Base64 encoding produces characters like `/`, `+`, and `=` that have special meaning in URLs and will break connection parsing. Hex encoding (`openssl rand -hex 24`) produces only `0-9a-f` characters, which are always URL-safe.

### Password strength

| Secret | Generation Method | Entropy |
|--------|------------------|---------|
| PostgreSQL password | `openssl rand -hex 24` | 192 bits |
| Dragonfly password | `openssl rand -hex 24` | 192 bits |
| MinIO password | `openssl rand -hex 24` | 192 bits |
| JWT secret | `openssl rand -hex 32` | 256 bits |
| Admin password (if auto-generated) | `openssl rand -hex 16` | 128 bits |

All secrets exceed the recommended minimum of 128 bits of entropy for cryptographic keys.

---

## What This Does NOT Cover

This project hardens the Docker Compose deployment layer. The following are outside its scope and should be addressed separately:

| Area | Recommendation |
|------|---------------|
| **TLS termination** | Handled by your reverse proxy (Caddy, Traefik, Pangolin, etc.) |
| **Firewall rules** | Configure `ufw`, `iptables`, or cloud security groups to restrict inbound traffic |
| **Host OS hardening** | Kernel parameters (`sysctl`), SSH key-only auth, automatic security updates |
| **Backup encryption** | Encrypt PostgreSQL dumps and MinIO backups at rest (`gpg`, `age`, cloud KMS) |
| **Intrusion detection** | Consider `fail2ban` for SSH, `CrowdSec` for application-layer protection |
| **Image vulnerability scanning** | Use `trivy` or `grype` to scan images before deployment |
| **Secret rotation** | Rotate database passwords, JWT secrets, and API keys on a regular schedule |
| **Monitoring and alerting** | Set up `Prometheus` + `Grafana` or cloud monitoring for resource usage and uptime |
| **WAF (Web Application Firewall)** | Consider `ModSecurity` or cloud WAF for additional HTTP-layer protection |
| **Database hardening** | Configure `pg_hba.conf` for strict client authentication, enable SSL for database connections |
