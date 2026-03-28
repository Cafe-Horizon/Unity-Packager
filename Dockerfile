FROM nimlang/nim:latest AS builder

RUN apk add --no-cache musl-dev gcc

WORKDIR /usr/src/app

COPY . .

RUN nimble install -y zippy
RUN nimble build -y -d:release --passL:-static

FROM ghcr.io/cafe-horizon/horiz-os:latest

COPY --from=builder /usr/src/app/unity_packager /usr/local/bin/unity_packager

ENTRYPOINT ["unity_packager"]
