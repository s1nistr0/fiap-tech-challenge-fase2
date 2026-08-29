FROM golang:1.21-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/evaluation-service .

FROM alpine:3.19
# ca-certificates pro SDK da AWS conseguir falar https com o SQS
RUN apk add --no-cache ca-certificates && adduser -D -u 10001 app
COPY --from=build /out/evaluation-service /usr/local/bin/evaluation-service
USER app
EXPOSE 8004
ENTRYPOINT ["evaluation-service"]
