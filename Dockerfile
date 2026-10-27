# syntax=docker/dockerfile:1
#
# The app has zero third-party dependencies, so a multi-stage build would add
# complexity without shrinking the runtime image. Python 3.12 on Alpine is the
# smallest practical, still well-maintained base for this PoC.
FROM python:3.12-alpine

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=3002

WORKDIR /app

# Run as an unprivileged, numeric UID/GID compatible with Kubernetes
# runAsNonRoot and readOnlyRootFilesystem security contexts.
RUN addgroup -S -g 10001 app \
    && adduser -S -D -H -u 10001 -G app app

COPY --chown=app:app app.py /app/app.py

USER 10001:10001

EXPOSE 3002

# Kubernetes uses its own probes; this helps `docker run` users too.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3002/healthz', timeout=2)"]

STOPSIGNAL SIGTERM

CMD ["python", "/app/app.py"]
