# Minimal, dependency-free image. Same Dockerfile builds v1/v2/v3;
# the version and health behaviour are chosen at build time via ARGs.
FROM python:3.12-slim

ARG APP_VERSION=v0
ARG HEALTHY=true

ENV APP_VERSION=${APP_VERSION} \
    HEALTHY=${HEALTHY} \
    PORT=8080 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY app.py .

EXPOSE 8080

# Basic container-level healthcheck (informational; ALB/CodeDeploy do the real gating).
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python -c "import os,urllib.request,sys; \
    sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/health'%os.environ.get('PORT','8080')).status==200 else 1)" \
    || exit 1

CMD ["python", "app.py"]
