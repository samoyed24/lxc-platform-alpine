# lxc-platform

A lightweight LXC platform script for creating and managing per-user containers with:
- automatic bridge/NAT networking
- optional IPv6 allocation
- sshpiper + sniproxy routing
- bundled metrics/API agent bootstrap and OpenRC integration
- OpenRC service integration
- runtime state files for API consumption

## Current Support

- This codebase is currently designed for Alpine hosts (bootstrap/runtime paths assume Alpine tools and layout).
- Container distro values are configurable, but non-Alpine paths are provided as examples and are not guaranteed by the current implementation.

## Repository Layout

- `lxc-platform.sh`: main control script
- `platform.yaml`: global platform configuration
- `example/platform.yaml`: documented global config example
- `example/user.alpine.yaml`: documented per-user config example (Alpine)
- `example/user.debian.yaml`: documented per-user config example (Debian, reference)
- `agent/`: bundled Go metrics/API agent source

## Commands

Run from this directory:

```bash
./lxc-platform.sh bootstrap
./lxc-platform.sh apply
./lxc-platform.sh status
./lxc-platform.sh doctor
```

## Quick Operation Flow

1. Update and upgrade Alpine packages first:

```bash
apk update
apk upgrade --available
```

2. Install base tools on Alpine host:

```bash
apk add --no-cache bash git vim
```

3. Clone repository:

```bash
git clone https://github.com/samoyed24/lxc-platform-alpine.git
cd lxc-platform-alpine
```

4. Copy example platform config to project root:

```bash
cp example/platform.yaml platform.yaml
```

5. Edit global config `platform.yaml` for your environment.

6. Run bootstrap:

```bash
./lxc-platform.sh bootstrap
```

7. Create or update user container YAML files, then place them in `CONFIG_DIR` (default `/opt/lxc-platform/lxc.d`).

   The `lxc-platform-watch` service will detect the changes automatically and apply them. No manual step needed.

### Command Notes

- `bootstrap`: installs dependencies and services on the host. Also installs and starts `lxc-platform-watch`, which monitors `CONFIG_DIR` for file changes and runs `apply` automatically.
- `bootstrap`: also compiles the bundled agent into the platform runtime directory, renders its config from `platform.yaml`, installs `lxc-platform-agent` OpenRC service, and starts it.
- `apply`: reconciles containers from config files in `CONFIG_DIR`. Normally invoked automatically by the watch service; can also be run manually.
- `status`: prints runtime status for configured users.
- `doctor`: prints diagnostics for bridge/network/lxc/sniproxy.

## Configuration Model

1. Global config is loaded from `platform.yaml`.
2. Global config examples use lowercase keys (script accepts lowercase and maps them internally).
3. User configs are loaded from `CONFIG_DIR` (for example `/opt/lxc-platform/lxc.d`).
4. Each user config filename is the user id, for example `user-a.yaml`.
5. User config uses plain lowercase keys (for example `name`, `route`, `ports`) and does not require `C_<ID>_` prefix.
6. List style is supported for fields such as `ports` and `sni`.
7. SSH keys support map style under `keys` (`name: public_key`), which is the recommended format.
8. Optional per-container bandwidth limits are supported with `bandwidth_up` and `bandwidth_down` (tc rate format, for example `20mbit`, `500kbit`).
9. Agent settings are now managed from `platform.yaml` via `agent_*` keys; the standalone `agent/config.yaml` is treated as source reference only.

Example:
- file: `user-a.yaml`
- keys: `name`, `route`, `ports`, `sni`, `keys`, `bandwidth_up`, `bandwidth_down`

## Runtime State For API

Container state files are written under:

- `/opt/lxc-platform/runtime/state/containers/<container>.json`

These files are refreshed on create/start/stop/apply flows and can be consumed by your API.

## Bundled Agent

During `bootstrap`, lxc-platform will:

- install Go build dependency on Alpine hosts
- compile the bundled agent from `agent/` into the runtime directory
- render agent runtime config from `platform.yaml`
- install and enable `lxc-platform-agent` OpenRC service
- start the agent automatically

Default runtime paths:

- binary: `/opt/lxc-platform/runtime/agent/bin/lxc-platform-agent`
- config: `/opt/lxc-platform/runtime/generated/agent.yaml`
- state: `/opt/lxc-platform/runtime/state/agent/lxc-platform-agent-state.json`
- log: `/var/log/lxc-platform-agent.log`

The agent exposes Prometheus metrics and REST API based on the `agent_*` settings in `platform.yaml`.

## Examples

See:
- `example/platform.yaml`
- `example/user.alpine.yaml`
- `example/user.debian.yaml`
