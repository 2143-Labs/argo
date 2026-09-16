FROM registry.k8s.io/kubectl:v1.31.14 AS kubectl

FROM docker.io/library/alpine:3.20

RUN apk add --no-cache \
      ca-certificates \
      curl \
      jq \
      openssl \
      wireguard-tools

COPY --from=kubectl /bin/kubectl /usr/local/bin/kubectl

ENTRYPOINT ["/bin/sh"]
