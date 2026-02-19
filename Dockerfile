# MongoDB Atlas Alert Automation - Container Image
FROM python:3.11-slim

LABEL maintainer="Atlas Alert Automation"
LABEL description="Creates MongoDB Atlas alerts from Excel configuration"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install MongoDB Atlas CLI (direct download from GitHub releases)
RUN curl -L https://fastdl.mongodb.org/mongocli/mongodb-atlas-cli_1.14.0_linux_x86_64.tar.gz -o /tmp/atlas-cli.tar.gz \
    && tar -xzf /tmp/atlas-cli.tar.gz -C /tmp \
    && mv /tmp/mongodb-atlas-cli_1.14.0_linux_x86_64/bin/atlas /usr/local/bin/atlas \
    && chmod +x /usr/local/bin/atlas \
    && rm -rf /tmp/atlas-cli.tar.gz /tmp/mongodb-atlas-cli_*

# Set working directory
WORKDIR /app

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY create_atlas_alerts.py .
COPY atlas_alert_configurations.xlsx .

# Create directories for output
RUN mkdir -p /app/alerts /app/logs

# Environment variables will be provided at runtime by Kubernetes secrets

# Default command - can be overridden
ENTRYPOINT ["python3", "create_atlas_alerts.py"]
CMD ["--help"]
