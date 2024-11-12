# Stage 1: Build
FROM golang:1.18 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /go-sqlx-cnpg-writersvc svc-proxy.go

# Stage 2: Deploy
FROM alpine:3.15
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
COPY --from=builder /go-sqlx-cnpg-writersvc /go-sqlx-cnpg-writersvc
ENTRYPOINT ["/go-sqlx-cnpg-writersvc"]
