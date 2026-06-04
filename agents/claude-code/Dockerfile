FROM ubuntu:latest

RUN apt-get update && apt-get install -y \
    npm \
    python3 \
    python3-pip \
    python3-venv \
    postgresql-client \
    libpq-dev \
    sqlite3 \
    git \
    ripgrep \
    fd-find \
    nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Install common Python development tools
RUN pip3 install --no-cache-dir --break-system-packages \
    django \
    djangorestframework \
    black \
    flake8 \
    pytest \
    mypy \
    isort

WORKDIR /app
COPY . /app
CMD ["claude"]
