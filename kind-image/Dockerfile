ARG KIND_IMAGE=kindest/node:v1.34.0
FROM ${KIND_IMAGE}

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      vim \
      nano \
      wget \
      less \
      git \
      procps \
      iproute2 \
      iputils-ping \
      dnsutils \
      net-tools \
      tcpdump \
      lsof \
      strace \
      openssl \
      ca-certificates \
      gnupg \
      socat \
      conntrack \
      iptables \
      nftables \
      file \
      tree \
      unzip \
      zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
