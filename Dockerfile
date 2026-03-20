# /tmp作成用の軽量ビルダーイメージ
FROM alpine:latest AS tmp-builder
RUN mkdir -p /tmp_dir && chmod 1777 /tmp_dir

# 実行環境ベースイメージ
FROM ghcr.io/cafe-horizon/horiz-os:latest
ARG TARGETARCH

# 適切な権限を持つ一時ディレクトリのコピーと環境変数指定
COPY --from=tmp-builder /tmp_dir /tmp
ENV TMPDIR=/tmp

# CI側で実行権限が付与済みの実行バイナリをコピー
COPY bin/unity_packager-linux-${TARGETARCH} /usr/local/bin/unity_packager

ENTRYPOINT ["unity_packager"]
