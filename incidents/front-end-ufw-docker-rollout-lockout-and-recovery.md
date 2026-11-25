---
date: 2026-08-24
resolved: 2026-08-24
severity: outage
kind: incident
hosts: []
backfilled: true
---

# Front-End VPS went completely unreachable during ufw-docker install (lockout + recovery)

**Status**: closed (2026-08-24, recovered via IONOS panel hard reboot)

## What broke

While rolling out `ufw-docker` on the Front-End IONOS VPS to match the rest of the
hardened fleet (see `harden-vm.md` for the pattern,
`VMs/Edge/README.md` for the post-recovery state),
the box went completely network-unreachable partway through the install. From the
operator's workstation:

- `ssh front-end` to the Tailscale IP `100.105.23.48` → connection timed out
- `ssh ubuntu@203.0.113.30` to the public IP → connection timed out (port 22 filtered
  by IONOS anyway, but the public IP itself wasn't responding to pings either)
- `nc 100.105.23.48 22`, `:443`, etc. from another tailnet host (`infra`, `database`) all
  timed out
- `tailscale status` from `infra` showed the node as `active; offers exit node; relay "dfw"`,
  meaning the daemon was still alive on the box and the Tailscale control plane still
  knew about it, but the direct connection (and even the DERP relay path) was broken
- `ping` to both `100.105.23.48` and `203.0.113.30` from the operator's host → 100% loss

So it was a network-level outage, not just SSH dead. Recovery required the **IONOS web
console** (KVM / serial / rescue mode) to get a screen-into-the-VM regardless of network
state — there is no out-of-band path from this side once the host stops responding.

## What was being run when it broke

The intended sequence (fleet-standard pattern):

```sh
apt-get update
apt-get install -y wget
wget -qO /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/main/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install
```

The first call (`apt-get update && apt-get install wget`) ran in a single `ssh ... bash
<<'REMOTE'` block with no per-step timeout. The block hung past the 120s shell timeout
without producing any output. The operator was unable to recover the SSH connection.
Exactly what hung is unknown — possible candidates:

- `apt-get` blocked on a held `dpkg` lock from a previous run (Unattended-Upgrades runs
  daily here per the fleet rollout, so a background `apt` invocation racing the manual
  one is plausible)
- A transient IONOS network issue that just happened to coincide
- An IONOS VM resource-availability event (CPU steal / quota) starving `apt` of cycles

What it almost certainly **wasn't**: a ufw-docker artifact. `ufw-docker install` never
ran (the `wget` step itself failed with exit 8 — see "retry succeeded" below — and
nothing further happened). `after.rules`/`before.rules` were still pristine Ubuntu
defaults on recovery.

## Recovery

1. IONOS web console → VPS → Front-End → "Restart" (hard reboot, not graceful). There's
   no other recovery path once SSH and ping are both dead.
2. Post-reboot: every container came back up with its `restart: unless-stopped` /
   `restart: always` policy preserved, including the **three containers that had been
   recreated earlier in the same session with Tailscale-bound port bindings**
   (`portainer_agent:9001`, `cadvisor:9080`, `homepage:3000`). The new compose / `docker
   run` definitions survived the reboot since they're on disk, so the rebinds held.
3. ufw came back active with exactly the two pre-rollout rules (`9100/tcp` and
   `9080/tcp` from `100.65.68.114`); no partial ufw-docker state was present.
4. Hostname `front-end` (renamed earlier in the same session) survived the reboot.
5. **All public services verified up** post-reboot: `homepage.legacy.example.net` 200,
   `hunter.legacy.example.net` 200, `auth.legacy.example.net` 302, `mc.legacy.example.net:25565`
   TCP open, `plex.old.example.com` 401 (auth required, normal). All tailnet-internal
   services verified up: `homepage:3000` 200, `portainer_agent:9001` 400 (handshake
   expected, not a connection error), `cadvisor:9080/metrics` 200.

## Root cause analysis

The exact cause of the hang is unknown. The reboot cleared it. After the reboot the
**same** `apt-get update && apt-get install wget` sequence (run in the same way, same
block, same SSH session) succeeded in under 5 seconds. The `wget` then failed with
exit 8 (server error) because the upstream repo URL
`https://github.com/chaifeng/ufw-docker/raw/main/ufw-docker` no longer points at a
file — the correct path is
`https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker`. Fixed
locally; the rest of the install ran clean and `ufw-docker allow` rules were added
for every published container port.

So: it was probably transient (apt lock? IONOS network blip?), not a structural
problem with the rollout.

## General rule

When running multi-step installs on a **remotely-managed VPS with no out-of-band
fallback** (no IPMI, no cloud-init serial, no hypervisor console that auto-attaches
on boot failure — IONOS does have a web console but reaching it requires the human):

- **Always wrap each step in a per-command timeout** (e.g. `timeout 60 apt-get update`).
  If a step hangs past the timeout, abort the whole block immediately and diagnose
  before running the next one. The fleet's local VMs (`dyonisis`-hosted Proxmox guests,
  local LAN) have IPMI / Proxmox console / direct monitor access — those don't have
  this problem. The Front-End VPS is the only one where a hung `apt-get` while
  running unattended over SSH is unrecoverable without a human at the IONOS panel.
- **Verify after every step.** A `curl https://api.tailscale.com` or `echo alive`
  after each `apt` call would have caught the loss-of-network state immediately and
  given time to abort and reach the IONOS console without a hard reboot.
- **`wget` exit 8 is "server error response"**, not a network problem. The
  `chaifeng/ufw-docker` repo moved from `/raw/main/` to `/raw/master/` (or the
  default branch was renamed). If the script URL ever 404s again, check the
  upstream repo's current default branch before retrying.
- **`chmod +x` is silently no-op'd if the `set -e` chain is broken** in a way the
  shell tool's batch mode doesn't surface — explicitly verify the perms with
  `ls -la /usr/local/bin/ufw-docker` after chmod, as was needed here on the retry.
- The `Troubleshooting/infra-npm-ufw-docker-stale-ip.md` rule still applies on
  this host now that ufw-docker is installed: any time a container is recreated,
  re-run `ufw-docker allow <container> <port>` afterward, or the per-container
  FORWARD rule will be pinned to a stale container IP and the new container will
  be silently unreachable from anywhere except localhost.

## How long was the outage

Hard to pin down — the SSH session hung at the 120s shell-tool timeout, then a
~5-minute wait + several connect-retry attempts before giving up and getting
Purgos to do the IONOS reboot. The hard reboot itself was fast. End-to-end:
~10–15 minutes of partial-to-full outage. No data was lost.
