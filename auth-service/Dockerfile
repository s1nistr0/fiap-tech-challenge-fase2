FROM golang:1.21-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO off = binario estatico, roda em qualquer imagem sem libc
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/auth-service .

FROM alpine:3.19
RUN adduser -D -u 10001 app
COPY --from=build /out/auth-service /usr/local/bin/auth-service
USER app
EXPOSE 8001
ENTRYPOINT ["auth-service"]
