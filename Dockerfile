FROM ghcr.io/cafe-horizon/horiz-os:latest
ARG TARGETARCH
COPY bin/unity_packager-linux-${TARGETARCH} /usr/local/bin/unity_packager
RUN chmod +x /usr/local/bin/unity_packager
ENTRYPOINT ["unity_packager"]
