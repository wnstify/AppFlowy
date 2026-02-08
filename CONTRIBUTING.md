# Contributing

Thank you for your interest in contributing to this project.

## Acknowledgments

This project would not exist without [AppFlowy](https://appflowy.com) and the incredible work of the AppFlowy team. They have built a world-class open-source collaboration platform — a real alternative to Notion — and made it available to everyone under AGPL-3.0. The backend ([AppFlowy Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud)), the desktop and mobile clients ([AppFlowy](https://github.com/AppFlowy-IO/AppFlowy)), the real-time collaboration engine, the AI features — all open source. That is a rare and meaningful commitment.

This repository is a community wrapper that adds security hardening to the official Docker Compose deployment. The real work — the collaboration engine, the editor, the mobile apps, the AI integrations — is done by the AppFlowy team. We are standing on their shoulders.

## Support AppFlowy

Before contributing here, consider supporting the upstream project directly. Open-source sustainability depends on it.

### Use Their Official Offerings

The best way to ensure AppFlowy continues to exist and improve is to support them financially:

- **[AppFlowy Cloud (SaaS)](https://appflowy.com/pricing)** — Managed hosting with a free tier, Pro plan ($10/month) with unlimited storage, AI features, and up to 50 team members. If you don't need self-hosting, this is the easiest way to use AppFlowy and support the team simultaneously.

- **[Self-Hosted Licenses](https://appflowy.com/pricing)** — For organizations that require self-hosted deployments with official support, SLAs, priority bug fixes, and enterprise features. If you're running AppFlowy for your company, this is the right path.

- **[AI Add-ons](https://appflowy.com/pricing)** — AppFlowy AI MAX ($8/month) gives access to advanced models (GPT-5, Gemini 2.5 Pro, Claude) with unlimited responses. Vault Workspace ($6/month) enables local AI processing with zero data transfer.

### Contribute Upstream

- **[Star AppFlowy on GitHub](https://github.com/AppFlowy-IO/AppFlowy)** — Visibility matters. Stars help attract contributors and signal community support.
- **[Report bugs](https://github.com/AppFlowy-IO/AppFlowy-Cloud/issues)** — Found a bug in AppFlowy Cloud itself (not in this hardening wrapper)? Report it upstream where the core team can fix it.
- **[Submit pull requests](https://github.com/AppFlowy-IO/AppFlowy-Cloud/pulls)** — Code contributions to the official repository benefit the entire community.
- **[Join the community](https://discord.gg/9Q2xaN37tV)** — The AppFlowy Discord is active and welcoming.

## Contributing to This Project

This project focuses specifically on the Docker Compose deployment layer — security hardening, container configuration, networking, and setup automation. It does not modify AppFlowy Cloud itself.

### What We Accept

- **Security improvements** — better hardening, new security measures, vulnerability fixes
- **Configuration fixes** — corrections to docker-compose.yml, nginx/Angie configs, environment variables
- **Setup script improvements** — better error handling, new platform support, UX improvements
- **Documentation** — clearer instructions, additional troubleshooting tips, new deployment scenarios
- **Version bumps** — updating pinned image versions and SHA256 digests when new releases are available

### What Belongs Upstream

If your change involves modifying how AppFlowy Cloud works (not how it's deployed), it belongs in the official repositories:

- [AppFlowy-IO/AppFlowy-Cloud](https://github.com/AppFlowy-IO/AppFlowy-Cloud) — Backend, API, worker
- [AppFlowy-IO/AppFlowy](https://github.com/AppFlowy-IO/AppFlowy) — Desktop and mobile clients
- [AppFlowy-IO/AppFlowy-Web](https://github.com/AppFlowy-IO/AppFlowy-Web) — Web client

### How to Contribute

1. **Open an issue first** — describe what you want to change and why. This avoids wasted effort on changes that might not align with the project's goals.
2. **Fork and branch** — create a feature branch from `main`.
3. **Test your changes** — run `bash setup.sh` in a clean environment and verify all 9 services start healthy.
4. **Keep commits atomic** — one logical change per commit, clear commit messages.
5. **Submit a pull request** — reference the issue, describe what changed, and include testing steps.

### Guidelines

- Keep it simple. This project values minimalism — don't add complexity that isn't necessary.
- Security first. Every change should maintain or improve the security posture.
- Don't break the setup script. It should work on a fresh clone with no prerequisites beyond Docker.
- Test on both amd64 and arm64 if possible. AppFlowy Cloud supports both architectures.
