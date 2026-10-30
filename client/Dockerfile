# Imagem do cliente de ensaio.
FROM python:3.13.18-slim-trixie@sha256:76baad6037690d6e8c4397fbcaef17bca6f19eecef822b708fe8fa3417d30bb5

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /app

# Instala as versões exatas de todas as dependências (diretas e transitivas).
COPY requirements.lock .
RUN pip install --no-cache-dir -r requirements.lock

COPY ensaio.py .

ENTRYPOINT ["python", "ensaio.py"]
