FROM ghcr.io/cafe-horizon/horiz-os:latest
ARG TARGETARCH

COPY --chmod=755 bin/unity_packager-linux-${TARGETARCH} /usr/local/bin/unity_packager

ENTRYPOINT ["unity_packager"]
