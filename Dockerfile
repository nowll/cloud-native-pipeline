FROM golang:1.22-alpine AS modules
WORKDIR /modules
COPY go.mod go.sum ./
RUN go mod download && go mod verify

FROM golang:1.22-alpine AS builder

RUN apk add --no-cache \
    git \
    ca-certificates \
    tzdata \
    && update-ca-certificates

WORKDIR /build

COPY --from=modules /go/pkg/mod /go/pkg/mod

COPY go.mod go.sum ./
COPY . .

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=arm64 \
    go build \
      -ldflags="-s -w \
        -X main.Version=${VERSION} \
        -X main.BuildDate=${BUILD_DATE} \
        -X main.GitCommit=${VCS_REF} \
        -extldflags '-static'" \
      -trimpath \
      -tags "netgo osusergo static_build" \
      -o /bin/app \
      ./cmd/server

RUN /bin/app --version

FROM aquasec/trivy:latest AS scanner
COPY --from=builder /bin/app /bin/app
RUN trivy rootfs --exit-code 0 --severity HIGH,CRITICAL /bin/app || true

FROM gcr.io/distroless/static-debian12:nonroot AS final

COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

COPY --from=builder /bin/app /bin/app

LABEL org.opencontainers.image.title="App" \
      org.opencontainers.image.description="Cloud-native application" \
      org.opencontainers.image.vendor="Your Org" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/your-org/your-repo" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"

USER nonroot:nonroot

EXPOSE 8080 9090 9000

ENTRYPOINT ["/bin/app"]
CMD ["serve"]
