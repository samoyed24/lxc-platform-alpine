# lxc-platform-agent

A lightweight metrics agent for containers managed by lxc-platform.

## Features

- On-demand collection of container metrics when metrics API is queried:
  - network rx/tx (current and cumulative)
  - CPU usage
  - memory usage
  - disk usage and image size
- Collects all containers currently known by lxc-platform state files
- Exposes Prometheus metrics for passive scraping
- Exposes RESTful API for JSON metrics access
- Supports API CRUD for lxc.d user YAML files
- Supports API readback of lxc-platform state JSON files
- Supports AK/SK authentication (Basic Auth or signature headers)
- Persists cumulative traffic counters across agent restart and host reboot
  - so traffic can continue accumulating even if container counters reset

## Configuration

Edit [config.yaml](config.yaml):

- `listen_addr`: HTTP listen address, e.g. `:9108`
- `metrics_path`: Prometheus endpoint path, default `/metrics`
- `api_base_path`: REST API base path, default `/api/v1`
- `ak`: access key
- `sk`: secret key
- `signature_scope`: optional signature scope string
- `auth_timestamp_skew_seconds`: max allowed timestamp skew for signature verification
- `container_interface`: usually `eth0`
- `platform_state_dir`: lxc-platform state path
- `config_dir`: lxc.d path, default `/opt/lxc-platform/lxc.d`
- `image_dir`: image path used for disk total size
- `state_file`: local persistent counter state file

## Endpoints

- Health check (no auth):
  - `GET /healthz`
- Prometheus metrics (auth required):
  - `GET /metrics` (or custom `metrics_path`)
- RESTful API (auth required):
  - `GET /api/v1/metrics`: full latest payload
  - `GET /api/v1/containers`: container metrics array
  - `GET /api/v1/status`: scrape/collect status
  - `GET /api/v1/configs`: list yaml files in lxc.d
  - `POST /api/v1/configs`: create yaml (`{"id":"user-a","content":"...yaml..."}`)
  - `GET /api/v1/configs/{id}`: get one yaml content
  - `PUT /api/v1/configs/{id}`: create/update yaml (raw yaml body or json content)
  - `DELETE /api/v1/configs/{id}`: delete yaml
  - `GET /api/v1/states`: list state json payloads
  - `GET /api/v1/states/{id}`: get one state payload

## AK/SK Auth

All protected endpoints support two auth modes.

1. Basic Auth (recommended for Prometheus scrape)

- username = `AK`
- password = `SK`

2. Signature headers

Headers:

- `X-AK`
- `X-Timestamp` (unix seconds)
- `X-Nonce`
- `X-Signature`

Signature payload (joined by newline):

1. HTTP method
2. URL path
3. timestamp
4. nonce
5. signature_scope
6. raw body (GET usually empty)

`X-Signature = hex(HMAC_SHA256(sk, payload))`

## Prometheus Example

```yaml
scrape_configs:
  - job_name: lxc-platform-agent
    metrics_path: /metrics
    static_configs:
      - targets: ["127.0.0.1:9108"]
    basic_auth:
      username: your-ak
      password: your-sk
```

## Build And Run

From [lxc-platform-agent](.) directory:

```sh
./scripts/agentctl.sh build
./scripts/agentctl.sh start
./scripts/agentctl.sh status
./scripts/agentctl.sh stop
```

Run in foreground:

```sh
./scripts/agentctl.sh run
```

## Runtime Files

Default runtime files:

- PID: `run/lxc-platform-agent.pid`
- Log: `run/lxc-platform-agent.log`
- State: `/opt/lxc-platform/runtime/state/agent/lxc-platform-agent-state.json`

## Example REST Payload

```json
{
  "hostname": "host-1",
  "collected_at": "2026-05-22T12:00:00Z",
  "containers": [
    {
      "id": "user-a",
      "container": "user-a",
      "route": "user-a",
      "running": true,
      "cpu_seconds": 12.3,
      "memory_bytes": 73400320,
      "disk_total_bytes": 4294967296,
      "disk_used_bytes": 734003200,
      "disk_free_bytes": 3560964096,
      "net_rx_bytes": 10831,
      "net_tx_bytes": 9021,
      "net_rx_cumulative_bytes": 123456,
      "net_tx_cumulative_bytes": 234567
    }
  ]
}
```
