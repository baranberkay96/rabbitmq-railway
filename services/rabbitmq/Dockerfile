# RabbitMQ 4 with the management UI and Prometheus plugin, prepared for Railway.
# railway-entrypoint.sh pins the node name, writes the Erlang cookie and sizes memory,
# disk and CPU settings from the container, then runs the image's own entrypoint.
FROM rabbitmq:4.3.6-management

# The image's 10-defaults.conf lets `guest` log in from any address. Replace it.
# Fail the build early if the image layout this template relies on ever changes.
RUN rm -f /etc/rabbitmq/conf.d/10-defaults.conf \
    && test -x /usr/local/bin/docker-entrypoint.sh \
    && grep -q rabbitmq_management /etc/rabbitmq/enabled_plugins \
    && grep -q rabbitmq_prometheus /etc/rabbitmq/enabled_plugins

COPY --chown=rabbitmq:rabbitmq 10-railway.conf /etc/rabbitmq/conf.d/10-railway.conf
COPY --chmod=0755 railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN bash -n /usr/local/bin/railway-entrypoint.sh

# 5672 AMQP (private network), 15672 management UI/API (public domain),
# 15692 Prometheus metrics (private network).
EXPOSE 5672 15672 15692

# Starts as root to prepare the volume; docker-entrypoint.sh then drops to `rabbitmq`.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["rabbitmq-server"]
