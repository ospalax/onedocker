FROM debian:9
LABEL version="1.0" \
    maintainer="Petr Ospalý (pospaly@opennebula.systems)" \
    description="Dockerized OpenNebula"

# basic packages
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    apt-transport-https \
    apt-utils \
    ca-certificates \
    cron \
    curl \
    gpg \
    openssl \
    runit \
    xz-utils \
    && apt-get clean && rm -rf /tmp/* /var/tmp/*

# fake systemd
RUN ln -s /bin/true /bin/systemd-tmpfiles

# opennebula packages
RUN curl -fsSL -o - https://downloads.opennebula.org/repo/repo.key | apt-key add -
RUN echo "deb https://downloads.opennebula.org/repo/5.6/Debian/9 stable opennebula" > /etc/apt/sources.list.d/opennebula.list
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    lsb-release \
    mariadb-client \
    opennebula \
    opennebula-flow \
    opennebula-gate \
    opennebula-sunstone \
    && apt-get clean && rm -rf /tmp/* /var/tmp/*

# ruby dependencies
RUN gem install bundler --version '< 2'
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive /usr/share/one/install_gems --yes \
    && apt-get clean && rm -rf /tmp/* /var/tmp/*

# runit services
#COPY runit.d /etc/runit

# entrypoint
COPY entrypoint.sh /
RUN chown root.root /entrypoint.sh
RUN chmod 755 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 9869/tcp
EXPOSE 2633/tcp
