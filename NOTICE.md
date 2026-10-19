# Notice

This is a community template. It is not affiliated with or endorsed by Broadcom Inc. or the RabbitMQ project.

## Upstream software

| Component | License | Images used |
|---|---|---|
| RabbitMQ server and its core plugins (management, Prometheus) | Mozilla Public License 2.0 (`LICENSE`, `LICENSE-MPL-RabbitMQ` in rabbitmq/rabbitmq-server; some OCF files Apache-2.0). Copyright Broadcom Inc. and/or its subsidiaries. | `rabbitmq:4.3.6-management` |
| Erlang/OTP (bundled in the image) | Apache-2.0 | (inside the RabbitMQ image) |
| rabbitmqadmin v2 (bundled in the management image) | Dual-licensed Apache-2.0 / MIT (github.com/rabbitmq/rabbitmqadmin-ng) | (inside the RabbitMQ image) |
| Docker official image build files | MIT (docker-library/rabbitmq) | Used as the base image only; no files copied |

The template ships RabbitMQ unmodified, as the official Docker image. MPL-2.0 obligations about source availability are met by the upstream project (https://github.com/rabbitmq/rabbitmq-server). This template adds only its own configuration and start-up script, which are not derived from RabbitMQ source files.

## Verified against

| What | Source | Version / ref | Checked |
|---|---|---|---|
| Current release and image tags | GitHub releases of rabbitmq/rabbitmq-server (v4.3.6 2026-09-14; v4.4.0 2026-10-19, no Docker image yet); Docker Hub `library/rabbitmq` tags API (`4.3.6-management` 200, `4.4.0-management` / `4.4-management` / `4.4.0` 404); docker-library/official-images `library/rabbitmq` | 4.3.6 | 2026-10-20 |
| Image layout: entrypoint (`gosu` step-down, volume `chown`, deprecated env vars incl. `RABBITMQ_VM_MEMORY_HIGH_WATERMARK`, `RABBITMQ_USE_LONGNAME` logic), `10-defaults.conf` (`loopback_users.guest = false`), enabled plugins, `RUNNING_UNDER_SYSTEMD`, `HOME`, cookie symlink | docker-library/rabbitmq `4.3/ubuntu/Dockerfile`, `docker-entrypoint.sh`, `10-defaults.conf`, `4.3/ubuntu/management/Dockerfile` | commits d484e226, a2d49841 | 2026-10-20 |
| Environment variables read by the server and CLI (incl. unprefixed fallbacks), cookie handling, process-env debug logging | `deps/rabbit_common/src/rabbit_env.erl`, `deps/rabbitmq_cli/lib/rabbitmq/cli/core/config.ex`, `deps/rabbitmq_prelaunch/src/rabbit_prelaunch_dist.erl`, `deps/rabbit_common/src/rabbit_nodes_common.erl`, `deps/rabbit/scripts/rabbitmq-env`, `rabbitmq-server` | v4.3.6 | 2026-10-20 |
| Config keys and value formats (`loopback_users`, `log.*`, `listeners.tcp`, `default_user/pass`, `vm_memory_high_watermark.*`, `total_memory_available_override_value`, `disk_free_limit.absolute`, `deprecated_features.permit.*`, `management.tcp.*`, `management.hsts.policy`, `management.headers.*`, `prometheus.tcp.*`) | `deps/rabbit/priv/schema/rabbit.schema`, `deps/rabbitmq_management/priv/schema/rabbitmq_management.schema`, `deps/rabbitmq_prometheus/priv/schema/rabbitmq_prometheus.schema`, `rabbit_resource_monitor_misc.erl` | v4.3.6 | 2026-10-20 |
| Memory detection (no cgroup support) and absolute-limit capping | `deps/rabbit/src/vm_memory_monitor.erl` | v4.3.6 | 2026-10-20 |
| Listener addresses (dual-stack probing) | `deps/rabbit/src/rabbit_networking.erl` | v4.3.6 | 2026-10-20 |
| Healthcheck path `/` (static index, no auth) | `deps/rabbitmq_management/src/rabbit_mgmt_dispatcher.erl` | v4.3.6 | 2026-10-20 |
| Deprecated features denied in 4.3 and their behaviour | 4.3.0 release notes; `rabbit_amqqueue.erl`, `rabbit_channel.erl` | v4.3.0 / v4.3.6 | 2026-10-20 |
| Celery/kombu control queues (exclusive by default) | celery/kombu `kombu/pidbox.py`, celery/celery `celery/app/defaults.py` | main | 2026-10-20 |
| Docs: configuration, memory (absolute watermark recommended in containers), disk alarms (default 50 MB), runtime (schedulers, busy-wait defaults, `RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS`), upgrades | https://www.rabbitmq.com/docs/configure, /memory, /disk-alarms, /runtime, /upgrade | 4.3 docs | 2026-10-20 |
| Railway: plan limits (RAM, vCPU, volume per plan), volumes (default sizes, redeploy downtime), deployment draining (default 0 s), TCP proxy | https://docs.railway.com/reference/pricing/plans, /reference/volumes, /deployments/reference, /variables/reference, /reference/tcp-proxy | docs | 2026-10-20 |

## Adapted code

None. `services/rabbitmq/Dockerfile`, `10-railway.conf` and `railway-entrypoint.sh` were written for this template from the RabbitMQ documentation and source code listed above. The cgroup-reading approach follows this project's own Ollama entrypoint (templates/51-odysseus), not third-party code.

## Reference only (not copied)

- Railway marketplace template `_o12zG` "RabbitMQ" and `rabbitmq-starter` "RabbitMQ Starter Package": their `serializedConfig` was read for the fixed node name and `management.tcp.ip = ::` ideas. No configuration text copied.
- `railwayapp-templates/rabbitmq` (MIT, "Copyright (c) 2023 Railway"): demo publisher/receiver apps. Not used; nothing copied.

## Trademarks

RabbitMQ is a trademark of Broadcom Inc. and/or its subsidiaries. Erlang is a trademark of Ericsson AB. Docker is a trademark of Docker, Inc. Railway belongs to its respective owner. Names are used only to describe what the template runs.
