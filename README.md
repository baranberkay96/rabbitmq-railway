# Deploy and Host RabbitMQ with Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/rabbitmq-4-message-broker-with-management-ui?referralCode=20H68q)

RabbitMQ is an open-source message broker for AMQP 0-9-1 and AMQP 1.0, with plugins for MQTT, STOMP and streams. This community template runs a RabbitMQ 4.3 node with a persistent volume, the management UI on a password-protected HTTPS domain, Prometheus metrics, and ready-made connection URLs for your other Railway services.

## About Hosting RabbitMQ

RabbitMQ is easy to start but easy to host badly in containers. It names its database after the machine's hostname, which changes on every Railway deploy. It sizes its memory alarm from the host's RAM rather than the container's limit. And the Docker image lets the default `guest` user log in from any address. This template pins a fixed node name, so users, queues and messages survive redeploys. It sizes the memory and disk alarms to the container and its volume, creates an administrator with a generated password, and keeps `guest` limited to localhost. AMQP stays on Railway's private network; the management UI and HTTP API sit behind RabbitMQ's own login.

## Common Use Cases

- Background job queues for web apps and workers, for example Celery, Spring AMQP, MassTransit or NestJS microservices.
- Decoupling services with exchanges and routing keys: work queues, publish/subscribe fan-out and topic routing.
- Absorbing bursts of events or webhooks so consumers work at their own pace, with acknowledgements, retries and dead-letter exchanges.
- Durable quorum queues and streams for messages that must survive restarts, monitored through Prometheus and Grafana.
- A shared broker for staging and preview environments, inspected through the familiar management UI.

## Dependencies for RabbitMQ Hosting

- RabbitMQ `4.3.6` from the official Docker image `rabbitmq:4.3.6-management` (Erlang/OTP included)
- The management and Prometheus plugins (bundled and enabled)
- A Railway volume mounted at `/var/lib/rabbitmq`

### Deployment Dependencies

- RabbitMQ documentation: https://www.rabbitmq.com/docs
- Configuration reference: https://www.rabbitmq.com/docs/configure
- Memory and disk alarms: https://www.rabbitmq.com/docs/memory and https://www.rabbitmq.com/docs/disk-alarms
- Management UI and HTTP API: https://www.rabbitmq.com/docs/management
- Prometheus monitoring: https://www.rabbitmq.com/docs/prometheus
- Upgrades: https://www.rabbitmq.com/docs/upgrade
- Official Docker image: https://hub.docker.com/_/rabbitmq
- Source code and release notes: https://github.com/rabbitmq/rabbitmq-server
- Railway private networking: https://docs.railway.com/networking/private-networking
- Railway TCP proxy: https://docs.railway.com/networking/tcp-proxy

### Implementation Details

| Service | Role | Public | Storage |
|---|---|---|---|
| RabbitMQ | Broker. AMQP on 5672 (private network), management UI and HTTP API on 15672 (public HTTPS domain), Prometheus metrics on 15692 (private network) | Management UI only; optional TCP proxy for AMQP | Volume `/var/lib/rabbitmq` |

**First login**

1. Deploy the template. No input is required: the administrator password and the Erlang cookie are generated.
2. Open the RabbitMQ service's public domain and log in with `RABBITMQ_DEFAULT_USER` (default `admin`) and `RABBITMQ_DEFAULT_PASS` from the service's Variables tab.
3. Optional but recommended: under Admin, create a virtual host and a separate user per application instead of sharing the administrator.

**Connecting services in the same project**

Add one of these to your app service:

- `RABBITMQ_URL` = `${{RabbitMQ.RABBITMQ_URL}}`, which resolves to `amqp://admin:{password}@rabbitmq.railway.internal:5672`
- `AMQP_URL` = `${{RabbitMQ.AMQP_URL}}` (same value)
- For Celery: `CELERY_BROKER_URL` = `${{RabbitMQ.RABBITMQ_URL}}`
- Separate settings: `${{RabbitMQ.RABBITMQ_HOST}}`, `${{RabbitMQ.RABBITMQ_PORT}}`, `${{RabbitMQ.RABBITMQ_DEFAULT_USER}}`, `${{RabbitMQ.RABBITMQ_DEFAULT_PASS}}`

The URL has no virtual host path, so clients use the default vhost `/`. For another vhost, append `/{vhost}`. Declare durable queues, or exclusive queues for temporary replies: RabbitMQ 4.3 rejects non-durable queues that are not exclusive. Older clients that need them can set `ALLOW_TRANSIENT_QUEUES=true`.

**Connecting from outside Railway (optional)**

1. On the RabbitMQ service open Settings, Networking, TCP Proxy, and enter port `5672`.
2. Railway shows a `{proxy-domain}:{proxy-port}` pair. Other services can reference it as `${{RabbitMQ.RAILWAY_TCP_PROXY_DOMAIN}}` and `${{RabbitMQ.RAILWAY_TCP_PROXY_PORT}}`.
3. Connect with `amqp://{user}:{password}@{proxy-domain}:{proxy-port}`.

The TCP proxy forwards plain TCP and adds no TLS. With AMQP's default `PLAIN` login, the username, password and message contents cross the internet unencrypted. Use the proxy only for data that is not sensitive. Give external clients their own user with limited permissions, and remove the proxy when you no longer need it. For encrypted traffic, run the clients on Railway's private network, or set up an AMQPS listener with your own certificates (not configured by this template). Traffic through the proxy counts as public network egress.

**Management HTTP API and monitoring**

- HTTP API: `curl -u admin:{password} https://{your-domain}/api/overview`, or `${{RabbitMQ.RABBITMQ_MANAGEMENT_URL}}` from inside the project.
- Prometheus: scrape `${{RabbitMQ.RABBITMQ_PROMETHEUS_URL}}` (aggregated metrics) from a Prometheus or Grafana Alloy service in the same project. Per-queue metrics are at `/metrics/per-object`. The endpoint has no authentication and is reachable only on the private network.

**Settings worth knowing**

| Variable | Default | Meaning |
|---|---|---|
| `MEMORY_HIGH_WATERMARK` | `0.6` | Publishers are blocked above this memory use. A fraction of the container memory limit (read from cgroups; 2 GiB is assumed if no limit is visible), or an absolute size such as `2GiB`. |
| `DISK_FREE_LIMIT` | `auto` | Publishers are blocked when free disk space falls below this. `auto` = 20% of the volume, between 50 MB and 2 GB (about 1 GB on a 5 GB Hobby volume). |
| `ERLANG_SCHEDULERS` | `auto` | Erlang scheduler threads. `auto` = the container's CPU quota, at most 8 (the VM would otherwise size itself to the host's cores). |
| `ALLOW_TRANSIENT_QUEUES` | `false` | Permits the deprecated non-durable, non-exclusive queues for older clients. |
| `RABBITMQ_NODENAME` | `rabbit@localhost` | The database folder is named after it. Do not change it after the first deploy, or RabbitMQ starts with an empty database (the old data stays on the volume and the log warns). |

- Plugins: run `rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management` (or any bundled plugin) in the service shell (`railway ssh`). The plugin list is kept on the volume, so it survives redeploys. Plugins that open ports, such as MQTT (1883), STOMP (61613) or streams (5552), are reachable on the private network.
- Debug logging: add `RABBITMQ_LOG=debug` temporarily and redeploy.
- Erlang distribution and epmd listen on localhost only. Use `rabbitmqctl` and `rabbitmq-diagnostics` from the service shell.

**Changing the administrator password**

`RABBITMQ_DEFAULT_PASS` is applied only when the database is created. To rotate it, run `rabbitmqctl change_password admin {new-password}` in the service shell (or use Admin, Users in the UI). Then set `RABBITMQ_DEFAULT_PASS` to the same value, so `RABBITMQ_URL` and the services referencing it pick it up, and redeploy those services.

**Persistence and redeploys**

Users, vhosts, queue definitions and messages in durable queues are stored on the volume. Publish messages as persistent (delivery mode 2) if they must survive a restart. A redeploy briefly stops the broker, because a volume can only be mounted by one deployment at a time. `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=60` gives RabbitMQ time to shut down cleanly. Clients should reconnect automatically.

**Scaling**

This is a single RabbitMQ node. Scale it vertically: raise the service's resources, then `MEMORY_HIGH_WATERMARK` and `ERLANG_SCHEDULERS` follow the new limits automatically. Grow the volume in the service settings (5 GB on Hobby, up to 1 TB on Pro). Consumers scale horizontally as replicas of your own worker services. A multi-node RabbitMQ cluster needs stable per-node hostnames and Erlang distribution between services, so it is outside the scope of this template.

**Pinning and upgrades**

The version is pinned in `services/rabbitmq/Dockerfile` (`FROM rabbitmq:4.3.6-management`). For a patch release, change the tag and redeploy. For a minor release, follow the RabbitMQ upgrade guide: upgrade one minor version at a time, run `rabbitmqctl enable_feature_flag all` before upgrading, and export definitions first (Overview, Export definitions, or `rabbitmqctl export_definitions /var/lib/rabbitmq/definitions.json`). Downgrades are not supported.

**Resources**

Expect about 0.2 GB of RAM at idle (roughly $2.50 per month) and 0.5 GB with a typical small workload (roughly $8 per month). Free and Trial plans work for evaluation (0.5 GB volume). Use Hobby for real workloads, and Pro for more than 5 GB of queued data.

### Why Deploy RabbitMQ on Railway?

Railway runs RabbitMQ next to your apps with a persistent volume, private networking, generated credentials and an HTTPS domain for the management UI, all in one project with usage-based billing. You get an authenticated broker with ready-made connection URLs and metrics, without operating servers or tuning the Erlang VM for containers yourself.
