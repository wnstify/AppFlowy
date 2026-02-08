# Installation Guide

## Prerequisites

- **Linux server** (amd64 or arm64) — Debian, Ubuntu, RHEL, or any Docker-supported distribution
- **Docker Engine 24+** with **Compose V2** (`docker compose`, not the legacy `docker-compose`)
- **A reverse proxy** handling TLS termination (Pangolin, Traefik, Caddy, nginx, etc.)
- **A domain name** pointed at your server (e.g., `appflowy.example.com`)
- **SMTP credentials** (optional but recommended for email verification and password recovery)
- **Minimum 4 GB RAM** (8 GB recommended) — see [Resource Limits](#resource-requirements) for details

## Quick Setup (Recommended)

The interactive setup script automates the entire deployment process — secret generation, directory creation, image pulling, asset extraction, UID/GID detection, and `.env` configuration:

```bash
git clone <repo-url> appflowy
cd appflowy
bash setup.sh
```

The script will prompt for:
1. **Domain** — your fully qualified domain name (e.g., `appflowy.example.com`)
2. **Admin email** — used for the initial admin account
3. **Admin password** — press Enter to auto-generate a secure one
4. **SMTP settings** — optional; if skipped, email autoconfirm is enabled so signup works without email
5. **Signup** — disabled by default for security; enable if you want open registration

All service passwords (PostgreSQL, Dragonfly, MinIO, JWT secret) are auto-generated using `openssl rand -hex` with cryptographically secure randomness. Passwords use hex encoding (not base64) to ensure they are URL-safe — this is critical because database connection strings embed passwords directly in URLs, and base64 characters like `/`, `+`, and `=` break URL parsing.

When finished, start with:

```bash
docker compose up -d
docker compose ps          # verify all containers are healthy
```

**Upgrading?** Run `bash setup.sh` again. It detects the existing `.env`, skips all prompts, stops containers, pulls updated images, re-extracts container assets, and sets ownership. Your configuration and data are preserved.

---

## What the Setup Script Does

For transparency, here is exactly what `setup.sh` does in each mode:

### First Run

1. Checks prerequisites (Docker, Compose V2, openssl)
2. Detects your UID/GID and warns if running as root
3. Prompts for domain, admin credentials, SMTP, and signup preference
4. Generates secure passwords for PostgreSQL, Dragonfly, MinIO, and JWT
5. Updates `docker-compose.yml` to use your UID/GID (if not the default 1000:1000)
6. Validates that config files (`angie/angie.conf`, `appflowy-web/nginx.conf`) exist and are files (not directories)
7. Creates data directories (`postgres-data`, `dragonfly-data`, `minio-data`)
8. Generates `.env` from the collected values (heredoc-based, no string escaping issues)
9. Pulls all container images
10. Extracts writable assets from `appflowy_web` and `admin_frontend` images (required for non-root operation)
11. Sets ownership on all directories to your UID/GID
12. Displays generated credentials (save them — they won't be shown again)

### Upgrade Mode

1. Detects existing `.env` — enters upgrade mode
2. Stops running containers (`docker compose down`)
3. Detects your UID/GID
4. Validates config files
5. Pulls updated images
6. Re-extracts container assets from the new images
7. Sets ownership on extracted directories

No prompts, no password regeneration, no `.env` modification. Your existing configuration is fully preserved.

---

## Manual Setup

If you prefer to configure everything by hand, follow the steps below.

### Step 1: Clone and Enter

```bash
git clone <repo-url> appflowy
cd appflowy
```

### Step 2: Set Your UID/GID

All containers run as your host user — not root. This is a core security feature. Find your UID/GID:

```bash
id
# Example output: uid=1000(user) gid=1000(user)
```

The compose file ships with `user: "1000:1000"` (the most common default on Linux). If your UID/GID is different, update every occurrence:

```bash
# Replace 1000:1000 with your actual UID:GID
sed -i 's/1000:1000/YOUR_UID:YOUR_GID/g' docker-compose.yml
sed -i 's/uid=1000,gid=1000/uid=YOUR_UID,gid=YOUR_GID/g' docker-compose.yml
```

The `uid=`/`gid=` values appear in tmpfs mount options (e.g., `/run/postgresql`, `/var/cache/angie`) to ensure non-root processes can write to these directories. Both patterns must be updated.

### Step 3: Create Data Directories

```bash
mkdir -p postgres-data dragonfly-data minio-data
```

### Step 4: Extract Writable Assets from Images

The `appflowy_web` and `admin_frontend` containers use entrypoints that run `sed -i` to inject runtime configuration (like API URLs) into static files at startup. Since containers run as non-root, these files must be on writable bind mounts extracted from the images.

Pull the images first:

```bash
docker compose pull
```

Extract the assets:

```bash
# AppFlowy Web — static HTML and dist files
cid=$(docker create appflowyinc/appflowy_web:0.10.5)
docker cp "$cid:/usr/share/nginx/html" ./appflowy-web-html
docker cp "$cid:/app/dist" ./appflowy-web-dist
docker rm "$cid"

# Admin Frontend — full app directory
cid=$(docker create appflowyinc/admin_frontend:0.12.0)
mkdir -p ./admin-frontend-app
docker cp "$cid:/app/." ./admin-frontend-app/
docker rm "$cid"
```

### Step 5: Set Ownership

```bash
chown -R $(id -u):$(id -g) postgres-data dragonfly-data minio-data \
  appflowy-web-html appflowy-web-dist admin-frontend-app
```

### Step 6: Configure Environment

```bash
cp .env.example .env
chmod 600 .env
```

The `chmod 600` restricts the file to owner read/write only. This file contains database passwords, JWT secrets, and SMTP credentials — it should never be world-readable.

Edit `.env` and set **at minimum**:

| Variable | What to set |
|----------|-------------|
| `FQDN` | Your domain (e.g., `appflowy.example.com`) |
| `POSTGRES_PASSWORD` | `openssl rand -hex 24` |
| `DRAGONFLY_PASSWORD` | `openssl rand -hex 24` |
| `MINIO_ROOT_PASSWORD` | `openssl rand -hex 24` |
| `GOTRUE_ADMIN_EMAIL` | Your admin email |
| `GOTRUE_ADMIN_PASSWORD` | Strong admin password |
| `GOTRUE_JWT_SECRET` | `openssl rand -hex 32` |

Optional but recommended:

| Variable | What to set |
|----------|-------------|
| `GOTRUE_SMTP_HOST` | Your SMTP server |
| `GOTRUE_SMTP_PORT` | Usually `465` |
| `GOTRUE_SMTP_USER` | SMTP username |
| `GOTRUE_SMTP_PASS` | SMTP password |
| `GOTRUE_DISABLE_SIGNUP` | `false` to allow signups |

> **Important:** All passwords must be URL-safe. Use `openssl rand -hex 24` (hex encoding), **not** `openssl rand -base64`. Base64 produces `/`, `+`, and `=` characters that break PostgreSQL connection URLs. The setup script uses hex encoding automatically.

### Step 7: Start

```bash
docker compose up -d
```

### Step 8: Verify

```bash
# All containers should be healthy/running
docker compose ps

# Test endpoints
curl -s http://127.0.0.1:8025/api/health       # Should return: OK
curl -s http://127.0.0.1:8025/gotrue/health     # Should return: JSON
curl -so /dev/null -w "%{http_code}" http://127.0.0.1:8025/       # Should return: 302
curl -so /dev/null -w "%{http_code}" http://127.0.0.1:8025/console # Should return: 200

# Verify all containers run as your user (not root)
docker compose exec postgres id    # Should show your UID/GID, not uid=0(root)
```

### Step 9: Configure Reverse Proxy

Point your reverse proxy at `127.0.0.1:8025`. The internal Angie proxy handles all path-based routing, so your reverse proxy only needs a single upstream target.

**Requirements:**
- Forward all traffic to `127.0.0.1:8025`
- WebSocket support for `/ws` path (pass `Upgrade` and `Connection` headers)
- TLS termination with valid certificate
- Recommended: HSTS headers, TLS 1.2+ minimum

**Example for Pangolin:** Create a single resource for your domain pointing at `127.0.0.1:8025`. Pangolin handles TLS and WebSocket upgrades automatically.

**Example for Caddy:**
```
appflowy.example.com {
    reverse_proxy 127.0.0.1:8025
}
```

---

## Resource Requirements

The compose file defines explicit resource limits for every container. Here are the total resource ceilings:

| Resource | Total Ceiling | Minimum Recommended |
|----------|--------------|-------------------|
| **Memory** | ~15.8 GB (all limits combined) | 4 GB host RAM |
| **CPU** | 22 vCPUs (all limits combined) | 2 vCPUs |
| **Disk** | Depends on usage | 20 GB free |

These are **ceilings**, not constant usage. A fresh deployment with light usage typically consumes 1.5-2 GB of RAM total. The limits exist to prevent any single container from consuming unbounded resources in failure scenarios.

**Memory reservations** (guaranteed minimums) total ~1.7 GB, meaning Docker will ensure at least this much memory is available for the stack even under host memory pressure.

For servers with less than 8 GB RAM, you may want to reduce limits on `postgres` (4G → 2G) and `appflowy_cloud` (4G → 2G) in `docker-compose.yml`.

---

## Upgrading

The easiest way to upgrade is to re-run the setup script:

```bash
bash setup.sh
docker compose up -d
```

The script detects the existing `.env`, stops containers, pulls new images, re-extracts assets, and sets ownership. It skips all prompts and preserves your configuration.

**To update to new image versions:** Edit the `image:` lines in `docker-compose.yml` with the new version tags and SHA256 digests before running `setup.sh`. The pinned digests ensure you get exactly the image you expect.

<details>
<summary>Manual upgrade steps</summary>

```bash
docker compose down
docker compose pull

rm -rf appflowy-web-html appflowy-web-dist admin-frontend-app

cid=$(docker create appflowyinc/appflowy_web:0.10.5)
docker cp "$cid:/usr/share/nginx/html" ./appflowy-web-html
docker cp "$cid:/app/dist" ./appflowy-web-dist
docker rm "$cid"

cid=$(docker create appflowyinc/admin_frontend:0.12.0)
mkdir -p ./admin-frontend-app
docker cp "$cid:/app/." ./admin-frontend-app/
docker rm "$cid"

chown -R $(id -u):$(id -g) appflowy-web-html appflowy-web-dist admin-frontend-app

docker compose up -d
```

</details>

## Backups

Critical data to back up regularly:

| Directory | Contains | Priority |
|-----------|----------|----------|
| `postgres-data/` | All user data, workspaces, documents | **Critical** |
| `minio-data/` | Uploaded files, attachments, images | **Critical** |
| `.env` | Configuration and all secrets | **Critical** |
| `dragonfly-data/` | Cache (rebuilt automatically on restart) | Low |

### PostgreSQL Backup

```bash
# SQL dump (recommended for portability)
docker compose exec postgres pg_dump -U appflowy appflowy > backup_$(date +%Y%m%d).sql

# Restore from dump
docker compose exec -T postgres psql -U appflowy appflowy < backup_20250101.sql
```

### MinIO Backup

```bash
# Simple copy (while containers are stopped for consistency)
docker compose down
cp -r minio-data/ minio-data-backup-$(date +%Y%m%d)/
docker compose up -d
```

### Full Backup Strategy

For production deployments, implement automated daily backups:
1. PostgreSQL: daily `pg_dump` with 30-day retention
2. MinIO: rsync or rclone to offsite storage
3. `.env`: include in your secrets management system
4. Encrypt all backups at rest (e.g., `gpg --symmetric`)

## Enabling OAuth

Uncomment and fill in the provider variables in `.env`:

```bash
GOTRUE_EXTERNAL_GOOGLE_ENABLED=true
GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=your-client-id
GOTRUE_EXTERNAL_GOOGLE_SECRET=your-secret
GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=${API_EXTERNAL_URL}/callback
```

Then restart: `docker compose up -d`

Supported providers: Google, GitHub, Discord, Apple, SAML 2.0.

The redirect URI follows the pattern `https://your-domain.com/gotrue/callback`. Register this exact URL in your OAuth provider's console.

## Enabling Signup

By default, signup is disabled to prevent unauthorized account creation on a fresh deployment. This is a deliberate security choice — you should only open registration after verifying your deployment is working correctly.

To allow new users:

```bash
# In .env
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_MAILER_AUTOCONFIRM=true   # Set to false if SMTP is configured (requires email verification)
```

Then restart: `docker compose up -d`

If SMTP is configured, set `GOTRUE_MAILER_AUTOCONFIRM=false` to require email verification. If SMTP is not configured, keep it `true` so users can register without email confirmation.

## Troubleshooting

**Container keeps restarting:**
```bash
docker compose logs <service-name> --tail=50
```
Check for configuration errors, missing environment variables, or permission denied messages.

**Permission denied errors:**
Ensure all bind mount directories are owned by your UID/GID:
```bash
chown -R $(id -u):$(id -g) postgres-data dragonfly-data minio-data \
  appflowy-web-html appflowy-web-dist admin-frontend-app
```
Also verify `docker-compose.yml` has the correct `user:` value matching your UID/GID.

**GoTrue unhealthy:**
GoTrue depends on PostgreSQL. Check that PostgreSQL is healthy first:
```bash
docker compose logs postgres --tail=20
docker compose logs gotrue --tail=20
```
Common causes: `GOTRUE_JWT_SECRET` not set, PostgreSQL not ready, incorrect database URL.

**WebSocket not connecting:**
Ensure your reverse proxy passes WebSocket upgrade headers for the `/ws` path:
- `Upgrade: websocket`
- `Connection: upgrade`

Most reverse proxies (Caddy, Traefik, Pangolin) handle this automatically. Nginx requires explicit configuration.

**Config files are directories (not files):**
If `angie/angie.conf` or `appflowy-web/nginx.conf` became directories, a previous Docker run with an incorrect volume mount created them. Fix with:
```bash
rm -rf angie/angie.conf appflowy-web/nginx.conf
git checkout -- angie/angie.conf appflowy-web/nginx.conf
```

**SMTP "Invalid TLS kind" error:**
AppFlowy Cloud expects `APPFLOWY_MAILER_SMTP_TLS_KIND=wrapper`. This is the correct value for implicit TLS (port 465) and also works with explicit TLS (port 587) in practice. Do not use `starttls` — it is not recognized by the AppFlowy Cloud binary.

**High memory usage:**
Check which container is consuming the most:
```bash
docker stats --no-stream
```
The resource limits in `docker-compose.yml` prevent any single container from consuming all host RAM. If you need to reduce memory usage, lower the `memory` limits in the `deploy.resources.limits` section for the relevant service.
