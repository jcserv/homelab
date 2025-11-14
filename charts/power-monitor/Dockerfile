FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    openssh-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/arm64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install Python dependencies
RUN pip install --no-cache-dir \
    requests \
    kubernetes

# Create app directory
WORKDIR /app

# Copy power monitor script
COPY power_monitor.py /app/

# Make script executable
RUN chmod +x /app/power_monitor.py

# Create .ssh directory for SSH keys
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Run as root (needed for SSH operations)
USER root

# Run the power monitor
CMD ["python3", "/app/power_monitor.py"]
