FROM python:3.11-slim AS build
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.11-slim
COPY --from=build /install /usr/local
RUN useradd -u 10001 -m app
WORKDIR /app
COPY app.py .
USER app
ENV PORT=8005
EXPOSE 8005
# cada worker do gunicorn sobe sua propria thread de consumo do SQS, entao
# escalar replica = escalar consumo. e isso que faz o HPA por CPU funcionar aqui.
CMD gunicorn -b 0.0.0.0:${PORT} -w 2 --access-logfile - app:app
