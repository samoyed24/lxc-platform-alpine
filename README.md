# lxc-platform

A lightweight LXC platform script for creating and managing per-user containers with:
- automatic bridge/NAT networking
- optional IPv6 allocation
- sshpiper + sniproxy routing
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

## Commands

Run from this directory:

```bash
./lxc-platform.sh bootstrap
./lxc-platform.sh apply
./lxc-platform.sh status
./lxc-platform.sh doctor
```

## Quick Operation Flow

1. Install base tools on Alpine host:

```bash
apk add --no-cache bash git
```

2. Clone repository:

```bash
git clone git@github.com:samoyed24/lxc-platform-alpine.git
cd lxc-platform-alpine
```

3. Edit global config `platform.yaml` for your environment.

4. Run bootstrap:

```bash
./lxc-platform.sh bootstrap
```

5. Create or update user container YAML files, then place them in `CONFIG_DIR` (default `/opt/lxc-platform/lxc.d`).

6. Apply configuration:

```bash
./lxc-platform.sh apply
```

### Command Notes

- `bootstrap`: installs dependencies and services on the host.
- `apply`: reconciles containers from config files in `CONFIG_DIR`.
- `status`: prints runtime status for configured users.
- `doctor`: prints diagnostics for bridge/network/lxc/sniproxy.

## Configuration Model

1. Global config is loaded from `platform.yaml`.
2. User configs are loaded from `CONFIG_DIR` (for example `/opt/lxc-platform/lxc.d`).
3. Each user config filename is the user id, for example `USER_A.yaml`.
4. User keys must be prefixed with `C_<ID>_`, matching the file id.

Example:
- file: `USER_A.yaml`
- key prefix: `C_USER_A_...`

## Runtime State For API

Container state files are written under:

- `/opt/lxc-platform/runtime/state/containers/<container>.json`

These files are refreshed on create/start/stop/apply flows and can be consumed by your API.

## Examples

See:
- `example/platform.yaml`
- `example/user.alpine.yaml`
- `example/user.debian.yaml`
