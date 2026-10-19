# RabbitMQ 4 Message Broker with Management UI — Railway template spec

## Listing

- **Name:** RabbitMQ 4 Message Broker with Management UI (round-4 listing; major version of the pinned 4.3.6)
- **Description (72 chars):** AMQP broker with dashboard, metrics and persistent queues, ready to use.
- **Category:** Queues
- **Tags:** rabbitmq, amqp, message-broker, message-queue, queues, pubsub, prometheus, management-ui
- **Template repo:** `baranberkay96/rabbitmq-railway` (this folder)

The description is delivered as written: dashboard = management UI on the public domain, metrics = management statistics plus the Prometheus endpoint, persistent queues = volume plus a fixed node name, ready to use = generated credentials and connection URLs, no required input.

## Base market templates

| Code | What it is | Taken |
|---|---|---|
| `_o12zG` "RabbitMQ" (379 active, 2024) | Unpinned `rabbitmq:management`; volume `/var/lib/rabbitmq`; node name `rabbit@rabbitmq` made resolvable by appending `127.0.0.1 rabbitmq` to `/etc/hosts` in the start command; `management.tcp.ip = ::`; random user and password; AMQP on a public TCP proxy; a second service (`railway-public-to-private-proxy`) to publish the UI | The ideas of a fixed node name and binding the management listener to `::` |
| `rabbitmq-starter` "RabbitMQ Starter Package" (74 active, 2023) | Same broker definition plus two Node.js demo services (publisher/receiver) from `railwayapp-templates/rabbitmq` (MIT) | Nothing (demo apps not needed; the broker definition is the same as above) |
| `kafka` (13 active) | Apache Kafka, unrelated broker that ranks for "RabbitMQ alternative" | Nothing |

Market templates read for ideas only; no files or text copied (see NOTICE.md).

## Pinned versions

| Service | Image | Tag | Released |
|---|---|---|---|
| RabbitMQ (`services/rabbitmq`) | `rabbitmq` (Docker official image) | `4.3.6-management` (index digest `sha256:54cb013d76cd1fd6c0a0708f34062ad61c452bb6f016b434c6c33f1a765d2b58`, rebuilt 2026-10-17; Ubuntu 24.04, Erlang/OTP bundled) | RabbitMQ 4.3.6: 2026-09-14 |

Checked 2026-10-20. RabbitMQ **4.4.0** was released on GitHub on 2026-10-19, but Docker Hub has no `4.4*` tag yet (`4.4.0-management`, `4.4-management` and `4.4.0` all 404), so 4.3.6 is the newest official image. The listing name ("RabbitMQ 4") stays valid for 4.4.

## Architecture

```
 Apps on Railway ── AMQP (user/password) ──> RabbitMQ:5672    (rabbitmq.railway.internal, IPv6 + IPv4)
 Apps elsewhere ─── AMQP ──> [TCP proxy, optional, no TLS] ──> RabbitMQ:5672
 Browser ── HTTPS ──> Railway edge ──> RabbitMQ:15672  management UI + HTTP API (RabbitMQ login)
 Prometheus/Alloy on Railway ──> RabbitMQ:15692/metrics (private only, no auth)
 epmd :4369 and Erlang distribution :25672 ── 127.0.0.1 only (CLI tools inside the container)
```

One service. The market's separate proxy service for the UI is unnecessary: a Railway public domain can target port 15672 directly.

## Design decisions

### Stable node name (persistence across redeploys)

RabbitMQ stores its data in `/var/lib/rabbitmq/mnesia/<node name>/` and records the node name inside the metadata store (Khepri is the only metadata store since 4.3; its Raft member IDs contain the node name). The default node name is `rabbit@$(hostname)`, and Railway gives each deployment a new container hostname. Without a fixed name every redeploy would start an empty database next to the old one.

- `RABBITMQ_NODENAME=rabbit@localhost`, `RABBITMQ_USE_LONGNAME=false`. `localhost` always resolves to the container itself, so nothing is written to `/etc/hosts` and the name never depends on Railway's DNS (a service cannot resolve its own private name at boot, Rule 8.13). The same default is used by Homebrew installs.
- If a user picks another host part (e.g. `rabbit@rabbitmq` to reuse an older volume layout), the entrypoint maps it to 127.0.0.1 in `/etc/hosts` when it does not resolve.
- If the volume holds data for a different node name but not for the configured one, the entrypoint logs a loud warning before RabbitMQ starts with an empty database.
- `RABBITMQ_USE_LONGNAME` is set explicitly because the image's entrypoint switches to long names when `hostname` and `hostname -s` differ, and a node cannot switch name types without a reset.

### Credentials and the guest user

- The image ships `10-defaults.conf` with `loopback_users.guest = false` (guest from anywhere). The Dockerfile deletes it and ships `10-railway.conf` with `loopback_users.guest = true` (RabbitMQ's own default). `guest` is never created anyway: the default user comes from `RABBITMQ_DEFAULT_USER`, and the entrypoint refuses `guest` as user or password.
- `RABBITMQ_DEFAULT_PASS` is `secret(32)` (letters and digits). The entrypoint writes user and password into `conf.d/90-railway-runtime.conf` (`default_user`, `default_pass`, mode 0600) instead of passing them as environment variables, which the RabbitMQ docs describe as meant for development and CI. The variable keeps its familiar name for references.
- Credentials are limited to `A-Z a-z 0-9 . _ -` (at least 16 characters for the password) so they are valid in `rabbitmq.conf` and in an `amqp://` URL without percent-encoding.
- Before `exec`, the entrypoint unsets `RABBITMQ_DEFAULT_USER/PASS`, `RABBITMQ_ERLANG_COOKIE`, `RABBITMQ_URL` and `AMQP_URL`: RabbitMQ logs its whole process environment at debug level (`rabbit_env:log_process_env/0`).

### Erlang cookie and distribution

- `RABBITMQ_ERLANG_COOKIE` is `secret(48)`. The entrypoint writes it to `/var/lib/rabbitmq/.erlang.cookie` (0400, owner rabbitmq) on every start, which is what the docker-library docs recommend. The server reads the file (the variable is unset for it, which also avoids RabbitMQ's per-boot "Overriding Erlang cookie using the value set in the environment" warning). CLI tools in `railway ssh` read the same value from the variable (`RabbitMQ.CLI.Core.Config` honours `RABBITMQ_ERLANG_COOKIE`) or from the file via the image's `/root/.erlang.cookie` symlink.
- Single node, so epmd (`ERL_EPMD_ADDRESS=127.0.0.1`) and the distribution listener (`-kernel inet_dist_use_interface {127,0,0,1}`) are bound to loopback. Other services on the private network cannot reach ports 4369/25672 at all; the cookie is a second layer.

### Memory and disk alarms (Rule 8.15)

- RabbitMQ 4.3.6 reads total memory from `/proc/meminfo` (`vm_memory_monitor:get_total_memory/1`, no cgroup support), so in a container it sees the host's RAM, and the official docs recommend an absolute watermark in containers.
- The entrypoint reads the tightest cgroup limit visible to the container (v2 `memory.max`/`memory.high` of its cgroup and visible ancestors, then v1 `memory.limit_in_bytes`). If one is found and is below MemTotal it writes `total_memory_available_override_value` = that limit and `vm_memory_high_watermark.absolute` = `MEMORY_HIGH_WATERMARK` (default 0.6) × limit.
- No visible limit: 2 GiB is assumed (watermark 1.2 GiB). `total_memory_available_override_value` is then **not** written, because RabbitMQ caps an absolute watermark at that value (`interpret_limit/2` uses `min`), which would silently cap a user's own absolute setting.
- `MEMORY_HIGH_WATERMARK` also accepts an absolute size (`2GiB`, `1536MiB`), passed through as is.
- `DISK_FREE_LIMIT=auto` = 20% of the volume size (from `df`), at least 50 MB (RabbitMQ's default) and at most 2 GB: about 1 GB on a 5 GB Hobby volume, about 100 MB on the 0.5 GB Free/Trial volume (a fixed 1 GB limit would raise the disk alarm and block publishers right at boot there), 2 GB on Pro's 50 GB default.

### Erlang schedulers

Erlang starts one scheduler per detected core (and, since OTP 23, limits the online ones to a visible CPU quota). On a large host that means dozens of schedulers, each with its own allocator instances. `ERLANG_SCHEDULERS=auto` sets `+S N:N` with N = the container's CPU quota rounded up (cgroup v2 `cpu.max` or v1 `cfs_quota`), else `nproc`, capped at 8. RabbitMQ 4.3 already disables scheduler busy-waiting by default (`+sbwt none +sbwtdcpu none +sbwtdio none` in `rabbitmq-env`), so nothing else is needed for burstable CPUs. User-supplied `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS` are appended after the template's flags.

### Listeners (Rules 8.2 and 8.14)

- AMQP: `listeners.tcp.default = 5672`. For a bare port RabbitMQ probes the stack (`rabbit_networking:port_to_listeners/1`) and listens on `::` (dual-stack on Linux) or on both `::` and `0.0.0.0`.
- Management: `management.tcp.ip = ::` and Prometheus `prometheus.tcp.ip = ::`. On Linux an IPv6 socket bound to `::` also accepts IPv4 unless `IPV6_V6ONLY` is set (`net.ipv6.bindv6only=0` is the default). RabbitMQ's AMQP stack probe above depends on the same behaviour: on a typical Linux host it ends up with the single `[::]:5672` listener. Without `ip`, the management and Prometheus listeners would be IPv4-only and unreachable for IPv6-first clients in legacy (IPv6-only) environments. The market template uses `management.tcp.ip = ::` on Railway.

### Healthcheck

`PORT=15672`, `healthcheckPath=/`. `/` serves the management UI's `index.html` (`rabbit_mgmt_dispatcher:build_root_index_routes/2`, static file, no auth) and answers 200 as soon as the management listener is up. That listener starts only after the core broker has booted, so a 200 also means RabbitMQ is running. `/api/health/checks/*` and `/api/overview` need credentials, which Railway's healthcheck cannot send. Timeout 300 s (first boot takes well under a minute).

### Plugins

The image enables `rabbitmq_management` and `rabbitmq_prometheus` in `/etc/rabbitmq/enabled_plugins`, which is reset on every deploy. `RABBITMQ_ENABLED_PLUGINS_FILE=/var/lib/rabbitmq/enabled_plugins` moves the list onto the volume (seeded from the image on first start), so `rabbitmq-plugins enable …` survives redeploys. The entrypoint re-adds `rabbitmq_management` if someone removes it (UI and healthcheck depend on it).

### Deprecated features in 4.3

RabbitMQ 4.3.0 moved `transient_nonexcl_queues` and `global_qos` to `denied_by_default`. Denied global QoS is silently downgraded to per-consumer prefetch (`rabbit_channel`), but declaring a non-durable, non-exclusive queue fails with a channel error. Current Celery/kombu declare their control queues exclusive and are unaffected; tutorial code and older clients are not. `ALLOW_TRANSIENT_QUEUES=true` adds `deprecated_features.permit.transient_nonexcl_queues = true`. Default `false` follows upstream.

### Shutdown

Railway's default is SIGKILL right after SIGTERM (`RAILWAY_DEPLOYMENT_DRAINING_SECONDS` default 0). The template sets 60 s. The image runs `beam.smp` via `exec` (`RUNNING_UNDER_SYSTEMD=true`) and the wrapper `exec`s too, so SIGTERM reaches the VM, which stops RabbitMQ gracefully.

## Services

<!-- BEGIN SERVICES -->

### RabbitMQ

Single RabbitMQ 4.3.6 node with the management UI and Prometheus plugins.

- Source: repo `baranberkay96/rabbitmq-railway`, root directory `/services/rabbitmq` (Dockerfile build, `FROM rabbitmq:4.3.6-management`)
- Start command: image default (`railway-entrypoint.sh rabbitmq-server`)
- Pre-deploy command: none
- Healthcheck: `/` on `PORT` 15672 (timeout 300 s)
- Public domain: yes, target port `15672` (management UI and HTTP API)
- TCP proxy: none (optional, port 5672; see README)
- Volume: `/var/lib/rabbitmq`
- Restart policy: ALWAYS; replicas: 1; cron: none

| Variable | Value | Description |
|---|---|---|
| `PORT` | `15672` | Management UI port: public domain target; the healthcheck GETs / (login page, no auth needed). |
| `RABBITMQ_DEFAULT_USER` | `admin` | Administrator created with a new database: management UI and AMQP login. Not 'guest'. |
| `RABBITMQ_DEFAULT_PASS` | `${{secret(32, "abc…XYZ0123456789")}}` | Administrator password (16+ chars: letters, digits, . _ -). Applied only when the database is created. |
| `RABBITMQ_ERLANG_COOKIE` | `${{secret(48, "abc…XYZ0123456789")}}` | Erlang cookie (shared secret for rabbitmqctl and other CLI tools), written to the cookie file. |
| `RABBITMQ_NODENAME` | `rabbit@localhost` | Fixed node name; the database folder is named after it. Do not change after the first deploy. |
| `RABBITMQ_USE_LONGNAME` | `false` | Short node names (required for rabbit@localhost). |
| `RABBITMQ_ENABLED_PLUGINS_FILE` | `/var/lib/rabbitmq/enabled_plugins` | Plugin list on the volume, so rabbitmq-plugins enable/disable survives redeploys. |
| `RABBITMQ_URL` | `amqp://${{RABBITMQ_DEFAULT_USER}}:${{RABBITMQ_DEFAULT_PASS}}@${{RAILWAY_PRIVATE_DOMAIN}}:5672` | AMQP URL on the private network (default vhost). Reference it as ${{RabbitMQ.RABBITMQ_URL}}. |
| `AMQP_URL` | `${{RABBITMQ_URL}}` | Alias of RABBITMQ_URL for libraries that read AMQP_URL. |
| `RABBITMQ_HOST` | `${{RAILWAY_PRIVATE_DOMAIN}}` | Private hostname for clients configured with separate host/port settings. |
| `RABBITMQ_PORT` | `5672` | AMQP port on the private network. |
| `RABBITMQ_MANAGEMENT_URL` | `http://${{RAILWAY_PRIVATE_DOMAIN}}:15672` | Management HTTP API on the private network (HTTP Basic auth with the administrator). |
| `RABBITMQ_PROMETHEUS_URL` | `http://${{RAILWAY_PRIVATE_DOMAIN}}:15692/metrics` | Prometheus scrape URL on the private network (no auth; never exposed publicly). |
| `MEMORY_HIGH_WATERMARK` | `0.6` | Publishers block above this: fraction (max 0.9) of the container memory limit, or a size like 2GiB. |
| `DISK_FREE_LIMIT` | `auto` | Publishers block when free disk drops below this. auto = 20% of the volume (50 MB to 2 GB), or e.g. 1GB. |
| `ERLANG_SCHEDULERS` | `auto` | Erlang scheduler threads. auto = the container CPU quota, at most 8; or a number. |
| `ALLOW_TRANSIENT_QUEUES` | `false` | true permits non-durable, non-exclusive queues (deprecated, denied by default since 4.3) for older clients. |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | `60` | Seconds between SIGTERM and SIGKILL on redeploy, so RabbitMQ can stop cleanly (Railway default 0). |

None of the template's own names (`MEMORY_HIGH_WATERMARK`, `DISK_FREE_LIMIT`, `ERLANG_SCHEDULERS`, `ALLOW_TRANSIENT_QUEUES`, `RABBITMQ_URL/HOST/PORT/…_URL`) is read by RabbitMQ: `rabbit_env` also reads *unprefixed* variants of its own variables (e.g. `NODENAME`, `ERLANG_COOKIE`, `DIST_PORT`), so those were avoided; and the image's entrypoint aborts if `RABBITMQ_VM_MEMORY_HIGH_WATERMARK` is set, hence the different name.

<!-- END SERVICES -->

### Files

| File | Purpose |
|---|---|
| `services/rabbitmq/Dockerfile` | `FROM rabbitmq:4.3.6-management`; removes `10-defaults.conf`; adds the config and entrypoint; build-time checks (`docker-entrypoint.sh` present, both plugins enabled in the image, `bash -n`) |
| `services/rabbitmq/10-railway.conf` | Static settings: guest loopback-only, console logs, listeners (`::`), management security headers (HSTS, nosniff, frame DENY) |
| `services/rabbitmq/railway-entrypoint.sh` | Validation, node name, cookie, plugin file, runtime config (credentials, memory, disk, deprecated features), Erlang flags; then `exec docker-entrypoint.sh rabbitmq-server` |

## Improvements over market templates

1. **Pinned version** (`4.3.6-management`) instead of the floating `rabbitmq:management`, which would jump majors on any redeploy.
2. **Stable node name without editing `/etc/hosts`** (`rabbit@localhost`), plus a warning when the volume holds another node's data.
3. **Memory alarm sized to the container**, not the host's RAM; **disk alarm sized to the volume** (RabbitMQ's 50 MB default is too small to protect a 5 GB volume; a fixed 1 GB would block publishers on 0.5 GB volumes). Market templates set neither.
4. **Erlang schedulers sized to the CPU quota** (capped at 8) instead of one per host core.
5. **guest restricted to localhost** (the image allows it from anywhere) and refused as the configured user; credentials passed via config file, not the broker's environment.
6. **Erlang cookie generated** and epmd/distribution bound to loopback (market templates expose 4369/25672 on the private network with an auto-generated cookie).
7. **AMQP private by default.** Market templates publish AMQP through a TCP proxy (plain text over the internet) from the first deploy. Here the TCP proxy is optional and documented with its TLS caveat.
8. **One service instead of two**: the UI is served on the broker's own public domain (target port 15672), no separate proxy service.
9. **Healthcheck** (`/` on 15672) and **graceful shutdown** (60 s draining instead of Railway's immediate SIGKILL). Market templates have neither.
10. **Prometheus endpoint** bound dual-stack and documented with a ready scrape URL; management HTTP API URL for tools.
11. **Plugins persist** (plugin list on the volume).
12. **Ready-made variables**: `RABBITMQ_URL`, `AMQP_URL`, `RABBITMQ_HOST`, `RABBITMQ_PORT`, `RABBITMQ_MANAGEMENT_URL`, `RABBITMQ_PROMETHEUS_URL`; every variable has a description (market templates have short or missing ones).
13. **RabbitMQ 4.3 compatibility switch** (`ALLOW_TRANSIENT_QUEUES`) for clients that still declare transient non-exclusive queues, documented instead of failing mysteriously.
14. **Management security headers** (HSTS, `X-Content-Type-Options`, `X-Frame-Options: DENY`) on the public UI.

## Resource estimate

Not measured (no local Docker this round); estimates from RabbitMQ's typical footprint with the management and Prometheus plugins.

| Service | Idle RAM | Typical RAM | Idle vCPU | Typical vCPU | Volume |
|---|---|---|---|---|---|
| RabbitMQ | 0.15–0.25 GB | 0.5 GB | 0.02 | 0.15 | 0.1–5 GB |

Railway prices: RAM $10/GB-month, vCPU $20/vCPU-month, volume $0.15/GB-month.

- **Idle:** 0.2 GB × $10 + 0.02 vCPU × $20 + 0.2 GB × $0.15 ≈ **$2.50/month**.
- **Typical (a few apps, a few hundred messages/s, small backlogs):** 0.5 GB × $10 + 0.15 vCPU × $20 + 2 GB × $0.15 ≈ **$8/month**.
- **Busy (thousands of messages/s or large backlogs):** 2 GB × $10 + 1 vCPU × $20 + 5 GB × $0.15 ≈ **$41/month**.
- Management statistics cost some CPU and memory with many queues/connections; `management.disable_stats = true` (in a conf file) is the lever if you rely on Prometheus only.

**Minimum plan:** Free/Trial for evaluation (0.5–1 GB RAM fits an idle node; 0.5 GB volume, disk limit auto-sized to ~100 MB). **Hobby** for real workloads (5 GB volume). **Pro** when queued data can exceed ~4 GB.

## Verification checklist

1. Build succeeds on Railway (Dockerfile build checks pass); deploy is healthy (`/` → 200 within the 300 s window).
2. Logs show, in order: `[railway] plugins: rabbitmq_management rabbitmq_prometheus`, `[railway] memory: high watermark … (container memory limit)` (or `assumed`), `[railway] disk: free space limit …`, `[railway] erlang: N schedulers (…)`, then RabbitMQ's `node : rabbit@localhost`, `Memory high watermark set to …`, `started TCP listener on [::]:5672`, `Server startup complete`. **Record** the detected cgroup memory limit and CPU quota (these decide the defaults; see Open questions).
3. Open the public domain, log in with `admin` / `RABBITMQ_DEFAULT_PASS`. `guest`/`guest` is rejected. Wrong password is rejected.
4. `curl -u admin:{password} https://{domain}/api/overview` → 200; without credentials → 401.
5. From another service in the project: connect with `${{RabbitMQ.RABBITMQ_URL}}`, declare a durable queue, publish a persistent message, consume it. Also connect by IPv4 and IPv6 address if possible (dual-stack).
6. From the same service: `curl ${{RabbitMQ.RABBITMQ_PROMETHEUS_URL}}` returns metrics; `nc -z rabbitmq.railway.internal 4369` and `25672` fail (loopback only).
7. `railway ssh` into RabbitMQ: `rabbitmq-diagnostics status` and `rabbitmqctl list_users` work (cookie + node name in env); `rabbitmq-diagnostics environment | grep -E 'vm_memory_high_watermark|disk_free_limit|total_memory'` shows the generated values.
8. Persistence: create a vhost, a user, a durable queue with a persistent message; redeploy; all still there, log shows the same node name and no "EMPTY database" warning.
9. Plugins: `rabbitmq-plugins enable rabbitmq_shovel`; redeploy; still enabled.
10. Optional: add a TCP proxy on 5672 and connect from outside with the proxy host/port.

## Open questions

- **Not deploy-tested; no local container run.** Verified statically only: `bash -n` (local bash 3.2; the image has bash 5.2), 90 unit/integration checks of the entrypoint under fake cgroup v1/v2 trees with stubbed `chown`/`getent`/`docker-entrypoint.sh` (memory/disk/scheduler sizing, validation, node-name checks, plugin file handling, secrets removed from the broker env, runtime config contents and modes), JSON/serializer check, Docker Hub tag checks, and every config key checked against the 4.3.6 schemas (`rabbit.schema`, `rabbitmq_management.schema`, `rabbitmq_prometheus.schema`). shellcheck/hadolint were not available.
- **Railway's cgroup visibility is unknown.** If Railway exposes the plan limit (Hobby up to 48 GB) as `memory.max`, the default watermark becomes ~29 GB; if it exposes nothing, 2 GiB is assumed. Both are safe (the first avoids OOM at the limit; the second is conservative), but the first deploy should record which case applies. Same for `cpu.max` (schedulers).
- **`rabbit@localhost` with loopback-only distribution** follows Erlang and RabbitMQ documented options (`ERL_EPMD_ADDRESS`, `inet_dist_use_interface`) and the prelaunch code paths were read (`rabbit_prelaunch_dist`, `rabbit_nodes_common`), but the combination has not been run. If the node fails to start with a distribution error, removing the `-kernel inet_dist_use_interface` flag is the first thing to try.
- **Management on `::`**: the market template proves it binds on Railway; that it accepts Railway's IPv4 healthcheck is inferred from Linux dual-stack defaults, not observed.
- **No TLS for external AMQP.** An AMQPS listener would need certificates for the TCP proxy hostname; not provided. Documented.
- **RabbitMQ 4.4.0** is out (2026-10-19) without an official image yet. When `4.4.x-management` appears: enable all feature flags, back up, then bump. The 4.4.0 notes ask for 4.3.7+ first when Erlang 28+ changes at the same time.
- **Repo name** `baranberkay96/rabbitmq-railway` and the deploy-button slug `rabbitmq-4-message-broker-with-management-ui` follow the existing convention; confirm at publish time.
