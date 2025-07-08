#!/bin/bash

# Rails Application Provisioning Script with Monitoring
# This script sets up a Hello World Rails app with PostgreSQL, Redis, and comprehensive monitoring

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
RAILS_APP_NAME="hello_world_app"
POSTGRES_VERSION="15"
REDIS_VERSION="7"
PROMETHEUS_VERSION="2.45.0"
GRAFANA_VERSION="10.0.0"
NODE_EXPORTER_VERSION="1.6.0"
POSTGRES_EXPORTER_VERSION="0.13.2"
REDIS_EXPORTER_VERSION="1.52.0"

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check system requirements
check_requirements() {
    log_info "Checking system requirements..."
    
    local missing_deps=()
    
    # Check for required commands
    for cmd in docker docker-compose curl git; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install the missing dependencies and run the script again."
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running. Please start Docker and try again."
        exit 1
    fi
    
    log_info "All requirements satisfied."
}

# Function to create directory structure
create_directory_structure() {
    log_info "Creating directory structure..."
    # Remove existing directory if it exists
    if [ -d "$RAILS_APP_NAME" ]; then
        log_warning "Directory $RAILS_APP_NAME already exists. Removing it..."
        rm -rf "$RAILS_APP_NAME"
    fi
    # Let rails new create the app directory
}

# Function to create Docker Compose file
create_docker_compose() {
    log_info "Creating Docker Compose configuration..."
    cd "$RAILS_APP_NAME"
    cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: hello_world_postgres
    environment:
      POSTGRES_DB: hello_world_production
      POSTGRES_USER: hello_world
      POSTGRES_PASSWORD: secure_password_123
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - app_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U hello_world"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis Cache
  redis:
    image: redis:7-alpine
    container_name: hello_world_redis
    command: redis-server --appendonly yes
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    networks:
      - app_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Rails Application
  rails:
    build:
      context: .
      args:
        RAILS_MASTER_KEY: ${RAILS_MASTER_KEY}
    container_name: hello_world_rails
    command: bundle exec rails server -b 0.0.0.0 -p 3000
    ports:
      - "3000:3000"
    environment:
      RAILS_ENV: production
      DATABASE_URL: postgresql://hello_world:secure_password_123@postgres:5432/hello_world_production
      REDIS_URL: redis://redis:6379/0
      RAILS_MASTER_KEY: ${RAILS_MASTER_KEY}
      PORT: 3000
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - bundle_cache:/usr/local/bundle
    networks:
      - app_network

  # Prometheus
  prometheus:
    image: prom/prometheus:v2.45.0
    container_name: hello_world_prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./monitoring/prometheus/alerts.yml:/etc/prometheus/alerts.yml
      - prometheus_data:/prometheus
    networks:
      - app_network
      - monitoring_network

  # Grafana
  grafana:
    image: grafana/grafana:10.0.0
    container_name: hello_world_grafana
    ports:
      - "3001:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: admin_password_123
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning
      - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards
      - grafana_data:/var/lib/grafana
    networks:
      - monitoring_network

  # Alertmanager
  alertmanager:
    image: prom/alertmanager:latest
    container_name: hello_world_alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./monitoring/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml
      - alertmanager_data:/alertmanager
    networks:
      - monitoring_network

  # Node Exporter (System Metrics)
  node_exporter:
    image: prom/node-exporter:v1.6.0
    container_name: hello_world_node_exporter
    ports:
      - "9100:9100"
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - monitoring_network

  # PostgreSQL Exporter
  postgres_exporter:
    image: prometheuscommunity/postgres-exporter:v0.13.2
    container_name: hello_world_postgres_exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://hello_world:secure_password_123@postgres:5432/hello_world_production?sslmode=disable"
    ports:
      - "9187:9187"
    depends_on:
      - postgres
    networks:
      - app_network
      - monitoring_network

  # Redis Exporter
  redis_exporter:
    image: oliver006/redis_exporter:v1.52.0
    container_name: hello_world_redis_exporter
    environment:
      REDIS_ADDR: "redis://redis:6379"
    ports:
      - "9121:9121"
    depends_on:
      - redis
    networks:
      - app_network
      - monitoring_network

networks:
  app_network:
    driver: bridge
  monitoring_network:
    driver: bridge

volumes:
  postgres_data:
  redis_data:
  prometheus_data:
  grafana_data:
  alertmanager_data:
  bundle_cache:
EOF

    # Overwrite Dockerfile with build arg and ENV for RAILS_MASTER_KEY and correct asset precompile step
    cat > Dockerfile <<'EOF'
FROM ruby:3.4.4-alpine

ARG RAILS_MASTER_KEY
ENV RAILS_MASTER_KEY=$RAILS_MASTER_KEY

# Prevent prompts
ENV BUNDLER_VERSION=2.4.10

# Install dependencies
RUN apk update && apk add --no-cache \
    build-base \
    postgresql-dev \
    nodejs \
    yarn \
    tzdata \
    git \
    libffi-dev \
    libxml2-dev \
    libxslt-dev \
    yaml-dev \
    bash

# Set working directory
WORKDIR /app

# Install bundler
RUN gem install bundler:$BUNDLER_VERSION --no-document

# Add gem config
RUN bundle config set --global retry 5 \
 && bundle config set --global jobs 4

# Copy Gemfile and lockfile
COPY Gemfile Gemfile.lock ./

# Set bundle config and install gems
RUN bundle config set --local without 'development test' \
 && bundle install

# Copy app source
COPY . .

# Precompile assets (requires RAILS_MASTER_KEY)
RUN bundle exec rails assets:precompile

# Expose port
EXPOSE 3000

# Start server
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
EOF
    cd ..
}

# Function to create Rails Dockerfile
create_rails_dockerfile() {
    log_info "Skipping custom Rails Dockerfile creation (using the one generated by rails new)"
    # cat > Dockerfile << 'EOF'
    # ... existing Dockerfile content ...
    # EOF
}

# Function to create Rails application
create_rails_app() {
    log_info "Creating Rails application..."
    
    # Remove old app directory if it exists (already handled above, but safe)
    rm -rf "$RAILS_APP_NAME"
    
    # Generate new Rails app with PostgreSQL, skip bundle and git
    rails new "$RAILS_APP_NAME" --database=postgresql --skip-bundle --skip-git
    
    cd "$RAILS_APP_NAME"

    # Remove require: 'debug/prelude' from debug gem to avoid production load error
    sed -i '' "s/gem ['\"]debug['\"].*require: ['\"]debug\/prelude['\"]/gem 'debug', platforms: %i[ mri windows ]/" Gemfile
    
    # Create monitoring and scripts folders inside the Rails app directory
    mkdir -p monitoring/{prometheus,grafana,alertmanager}
    mkdir -p scripts
    
    # Remove any old credentials and master key before editing
    rm -f config/master.key config/credentials.yml.enc
    # Regenerate both together
    EDITOR="cat" bin/rails credentials:edit
    # Update .env with the new master key
    echo "RAILS_MASTER_KEY=$(cat config/master.key)" > .env

    # Append missing gems to Gemfile if not present (POSIX-compatible, using arrays)
    # Only add if not present at all; if present, do not append. If version bump needed, update in-place.
    gems_none=(
      "gem 'redis', '~> 5.0'"
      "gem 'sprockets-rails'"
      "gem 'prometheus-client'"
    )
    gems_devtest=(
      "gem 'byebug', platforms: [:mri, :mingw, :x64_mingw]"
      "gem 'capybara'"
    )
    gems_dev=(
      "gem 'listen', '~> 3.3'"
      "gem 'spring'"
    )

    # Update puma version if present
    if grep -q "gem ['\"]puma['\"]" Gemfile; then
      sed -i '' "s/gem ['\"]puma['\"].*/gem 'puma', '~> 6.0'/" Gemfile
    fi
    # Update pg version if present
    if grep -q "gem ['\"]pg['\"]" Gemfile; then
      sed -i '' "s/gem ['\"]pg['\"].*/gem 'pg', '~> 1.1'/" Gemfile
    fi
    # Update capybara if present (no version specified)
    if grep -q "gem ['\"]capybara['\"]" Gemfile; then
      sed -i '' "s/gem ['\"]capybara['\"].*/gem 'capybara'/" Gemfile
    fi
    # Update bootsnap if present
    if grep -q "gem ['\"]bootsnap['\"]" Gemfile; then
      sed -i '' "s/gem ['\"]bootsnap['\"].*/gem 'bootsnap', '>= 1.4.4', require: false/" Gemfile
    fi

    # Add gems with no group
    for gemline in "${gems_none[@]}"; do
      gemname=$(echo "$gemline" | awk '{print $2}' | tr -d "'\"")
      if ! grep -q "gem ['\"]$gemname['\"]" Gemfile; then
        echo "$gemline" >> Gemfile
      fi
    done

    # Add gems to :development, :test group
    for gemline in "${gems_devtest[@]}"; do
      gemname=$(echo "$gemline" | awk '{print $2}' | tr -d "'\"")
      if ! grep -q "gem ['\"]$gemname['\"]" Gemfile; then
        if grep -q "group :development, :test do" Gemfile; then
          awk -v gemline="$gemline" '/group :development, :test do/ {print; print "  "gemline; next}1' Gemfile > Gemfile.tmp && mv Gemfile.tmp Gemfile
        else
          echo -e "\ngroup :development, :test do\n  $gemline\nend" >> Gemfile
        fi
      fi
    done

    # Add gems to :development group
    for gemline in "${gems_dev[@]}"; do
      gemname=$(echo "$gemline" | awk '{print $2}' | tr -d "'\"")
      if ! grep -q "gem ['\"]$gemname['\"]" Gemfile; then
        if grep -q "group :development do" Gemfile; then
          awk -v gemline="$gemline" '/group :development do/ {print; print "  "gemline; next}1' Gemfile > Gemfile.tmp && mv Gemfile.tmp Gemfile
        else
          echo -e "\ngroup :development do\n  $gemline\nend" >> Gemfile
        fi
      fi
    done

    # Only add to config.ru if not present
    if ! grep -q 'require_relative "config/environment"' config.ru; then
        echo 'require_relative "config/environment"' | cat - config.ru > temp && mv temp config.ru
    fi
    if ! grep -q "run Rails.application" config.ru; then
        echo -e "\nrun Rails.application" >> config.ru
    fi

    # Note: app/ is the standard Rails structure (app/controllers, app/models, etc.)
    # Ensure HelloController exists
    cat > app/controllers/hello_controller.rb << 'EOF'
class HelloController < ApplicationController
  def index
    render plain: "Hello, world!"
  end
end
EOF

    # Ensure hello view exists
    mkdir -p app/views/hello
    cat > app/views/hello/index.html.erb << 'EOF'
<h1>Hello, world!</h1>
EOF

    # Ensure asset pipeline manifest exists for Sprockets
    mkdir -p app/assets/config
    cat > app/assets/config/manifest.js << 'EOF'
//= link_tree ../images
//= link_directory ../stylesheets .css
EOF

    # Add root route in a portable way (macOS and Linux)
    if sed --version 2>/dev/null | grep -q GNU; then
      # Linux (GNU sed)
      sed -i "/Rails.application.routes.draw do/a\\
root 'hello#index'" config/routes.rb
    else
      # macOS (BSD sed)
      sed -i '' "/Rails.application.routes.draw do/a\\
root 'hello#index'" config/routes.rb
    fi
    if ! grep -q "root 'hello#index'" config/routes.rb; then
      log_error "Failed to add root route to routes.rb"
      exit 1
    fi

    # Install gems after all Gemfile and config changes
    bundle install
    cd ..
}

# Function to create Prometheus configuration
create_prometheus_config() {
    log_info "Creating Prometheus configuration..."
    cd "$RAILS_APP_NAME"
    cat > monitoring/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - 'alerts.yml'

scrape_configs:
  # Rails application metrics
  - job_name: 'rails_app'
    static_configs:
      - targets: ['rails:3000']
    metrics_path: '/metrics'
    scrape_interval: 30s

  # PostgreSQL metrics
  - job_name: 'postgresql'
    static_configs:
      - targets: ['postgres_exporter:9187']

  # Redis metrics
  - job_name: 'redis'
    static_configs:
      - targets: ['redis_exporter:9121']

  # Node metrics
  - job_name: 'node'
    static_configs:
      - targets: ['node_exporter:9100']

  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

    # Create alert rules
    cat > monitoring/prometheus/alerts.yml << 'EOF'
groups:
  - name: rails_app_alerts
    interval: 30s
    rules:
      # Rails Application Alerts
      - alert: RailsApplicationDown
        expr: up{job="rails_app"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Rails application is down"
          description: "Rails application has been down for more than 1 minute."

      - alert: HighResponseTime
        expr: rate(hello_world_request_duration_seconds_sum[5m]) / rate(hello_world_request_duration_seconds_count[5m]) > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High response time detected"
          description: "Average response time is above 1 second for the last 5 minutes."

      - alert: HighErrorRate
        expr: rate(hello_world_requests_total{status=~"5.."}[5m]) > 0.05
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High error rate detected"
          description: "Error rate is above 5% for the last 5 minutes."

  - name: postgresql_alerts
    interval: 30s
    rules:
      - alert: PostgreSQLDown
        expr: up{job="postgresql"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL is down"
          description: "PostgreSQL database has been down for more than 1 minute."

      - alert: PostgreSQLHighConnections
        expr: pg_stat_database_numbackends{datname="hello_world_production"} > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High number of PostgreSQL connections"
          description: "PostgreSQL has more than 80 active connections."

      - alert: PostgreSQLSlowQueries
        expr: rate(pg_stat_database_blks_read{datname="hello_world_production"}[5m]) > 1000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High disk read rate in PostgreSQL"
          description: "PostgreSQL is reading more than 1000 blocks per second from disk."

  - name: redis_alerts
    interval: 30s
    rules:
      - alert: RedisDown
        expr: up{job="redis"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Redis is down"
          description: "Redis has been down for more than 1 minute."

      - alert: RedisHighMemoryUsage
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Redis high memory usage"
          description: "Redis is using more than 80% of maximum memory."

      - alert: RedisHighKeyEviction
        expr: rate(redis_evicted_keys_total[5m]) > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High Redis key eviction rate"
          description: "Redis is evicting more than 100 keys per second."

  - name: system_alerts
    interval: 30s
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage detected"
          description: "CPU usage is above 80% for the last 5 minutes."

      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High memory usage detected"
          description: "Memory usage is above 85% for the last 5 minutes."

      - alert: DiskSpaceLow
        expr: (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 10
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Low disk space"
          description: "Disk space is below 10%."
EOF
    cd ..
}

# Function to create Alertmanager configuration
create_alertmanager_config() {
    log_info "Creating Alertmanager configuration..."
    cd "$RAILS_APP_NAME"
    cat > monitoring/alertmanager/alertmanager.yml << 'EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'default'
  routes:
    - match:
        severity: critical
      receiver: 'critical'
      continue: true

receivers:
  - name: 'default'
    webhook_configs:
      - url: 'http://localhost:5001/webhook'
        send_resolved: true

  - name: 'critical'
    webhook_configs:
      - url: 'http://localhost:5001/critical'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'instance']
EOF
    cd ..
}

# Function to create Grafana provisioning
create_grafana_config() {
    log_info "Creating Grafana configuration..."
    cd "$RAILS_APP_NAME"
    # Create datasource provisioning
    mkdir -p monitoring/grafana/provisioning/datasources
    cat > monitoring/grafana/provisioning/datasources/prometheus.yml << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

    # Create dashboard provisioning
    mkdir -p monitoring/grafana/provisioning/dashboards
    cat > monitoring/grafana/provisioning/dashboards/dashboards.yml << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
EOF

    # Create dashboards directory
    mkdir -p monitoring/grafana/dashboards
    
    # Create Rails dashboard
    cat > monitoring/grafana/dashboards/rails-dashboard.json << 'EOF'
{
  "dashboard": {
    "id": null,
    "title": "Rails Application Dashboard",
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "gridPos": {"x": 0, "y": 0, "w": 12, "h": 8},
        "type": "graph",
        "title": "Request Rate",
        "targets": [
          {
            "expr": "rate(hello_world_requests_total[5m])",
            "legendFormat": "{{method}} - {{status}}"
          }
        ]
      },
      {
        "id": 2,
        "gridPos": {"x": 12, "y": 0, "w": 12, "h": 8},
        "type": "graph",
        "title": "Response Time",
        "targets": [
          {
            "expr": "rate(hello_world_request_duration_seconds_sum[5m]) / rate(hello_world_request_duration_seconds_count[5m])",
            "legendFormat": "Average Response Time"
          }
        ]
      },
      {
        "id": 3,
        "gridPos": {"x": 0, "y": 8, "w": 12, "h": 8},
        "type": "graph",
        "title": "PostgreSQL Connections",
        "targets": [
          {
            "expr": "pg_stat_database_numbackends",
            "legendFormat": "{{datname}}"
          }
        ]
      },
      {
        "id": 4,
        "gridPos": {"x": 12, "y": 8, "w": 12, "h": 8},
        "type": "graph",
        "title": "Redis Memory Usage",
        "targets": [
          {
            "expr": "redis_memory_used_bytes",
            "legendFormat": "Used Memory"
          }
        ]
      }
    ]
  }
}
EOF
    cd ..
}

# Function to create startup script
create_startup_script() {
    log_info "Creating startup script..."
    cd "$RAILS_APP_NAME"
    cat > scripts/start.sh << 'EOF'
#!/bin/bash

# Load environment variables
source .env

# Start all services
docker-compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 5

# Wait for Postgres to be ready
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=hello_world
POSTGRES_DB=hello_world_production
POSTGRES_PASSWORD=secure_password_123

MAX_TRIES=30
TRIES=0
until docker-compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; do
  TRIES=$((TRIES+1))
  if [ $TRIES -ge $MAX_TRIES ]; then
    echo "Postgres did not become ready in time. Exiting."
    exit 1
  fi
  echo "Waiting for Postgres to be ready... ($TRIES/$MAX_TRIES)"
  sleep 2
done

echo "Postgres is ready!"

# Run database migrations
docker-compose exec rails bundle exec rails db:prepare

echo "All services are up and running!"
echo "Rails app: http://localhost:3000"
echo "Prometheus: http://localhost:9090"
echo "Grafana: http://localhost:3001 (admin/admin_password_123)"
echo "Alertmanager: http://localhost:9093"
EOF
    chmod +x scripts/start.sh
    cd ..
}

# Function to create monitoring documentation
create_monitoring_docs() {
    log_info "Creating monitoring documentation..."
    # Only create MONITORING.md if it does not exist
    if [ ! -f MONITORING.md ]; then
      cat > MONITORING.md << 'EOF'
# Monitoring Documentation

## Overview
This Rails application is monitored using Prometheus, Grafana, and Alertmanager. The monitoring stack tracks performance metrics, system resources, and application health.

## Metrics Being Monitored

### Rails Application Metrics
1. **Request Rate** (`hello_world_requests_total`)
   - Tracks total number of requests by method and status code
   - Useful for identifying traffic patterns and error rates

2. **Response Time** (`hello_world_request_duration_seconds`)
   - Measures request processing time
   - Critical for performance monitoring

3. **Application Health**
   - Endpoint: `/health`
   - Checks database and Redis connectivity

### PostgreSQL Metrics
1. **Connection Count** (`pg_stat_database_numbackends`)
   - Monitor connection pool usage
   - Alert threshold: >80 connections

2. **Database Size** (`pg_database_size_bytes`)
   - Track database growth
   - Plan capacity accordingly

3. **Query Performance**
   - Slow query count
   - Cache hit ratio
   - Disk reads/writes

### Redis Metrics
1. **Memory Usage** (`redis_memory_used_bytes`)
   - Track memory consumption
   - Alert threshold: >80% of max memory

2. **Key Evictions** (`redis_evicted_keys_total`)
   - Monitor cache effectiveness
   - High eviction rate indicates memory pressure

3. **Command Statistics**
   - Operations per second
   - Hit/miss ratio

### System Metrics (Node Exporter)
1. **CPU Usage**
   - Alert threshold: >80% for 5 minutes
   - Track by core

2. **Memory Usage**
   - Alert threshold: >85% for 5 minutes
   - Monitor swap usage

3. **Disk Space**
   - Alert threshold: <10% free space
   - Monitor I/O rates

## Alert Rules

### Critical Alerts
- Service Down (Rails, PostgreSQL, Redis)
- Disk space <10%
- Database unreachable

### Warning Alerts
- High CPU usage (>80%)
- High memory usage (>85%)
- Slow response times (>1s average)
- High error rate (>5%)

## Accessing Monitoring Tools
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3001 (admin/admin_password_123)
- Alertmanager: http://localhost:9093

## Grafana Dashboards
Pre-configured dashboards include:
1. Rails Application Dashboard
2. PostgreSQL Performance Dashboard
3. Redis Metrics Dashboard
4. System Overview Dashboard

## Best Practices
1. **Set up alert channels** in Alertmanager (email, Slack, PagerDuty)
2. **Regular review** of metrics and thresholds
3. **Capacity planning** based on trend analysis
4. **Document incidents** and adjust alerts accordingly
EOF
    else
      log_info "MONITORING.md already exists, skipping creation."
    fi
}

# Function to create README
create_readme() {
    log_info "Creating README..."
    # Only create README.md if it does not exist
    if [ ! -f README.md ]; then
      cat > README.md << 'EOF'
# Hello World Rails Application with Monitoring

## Quick Start

### Prerequisites
- Docker and Docker Compose installed
- Git
- At least 4GB of available RAM

### Installation

1. Clone this repository:
```bash
git clone <repository-url>
cd <project-root>
```

2. Run the provisioning script:
```bash
./rails-provisioning.sh
```

3. Start all services:
```bash
./scripts/start.sh
```

### Accessing Services

- **Rails Application**: http://localhost:3000
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3001 (Username: admin, Password: admin_password_123)
- **Alertmanager**: http://localhost:9093

### Service Endpoints

- **Health Check**: http://localhost:3000/health
- **Metrics**: http://localhost:3000/metrics

## Architecture

The application consists of:
- Rails application (Hello World)
- PostgreSQL database
- Redis cache
- Prometheus (metrics collection)
- Grafana (visualization)
- Alertmanager (alert routing)
- Various exporters for metrics collection

## Monitoring

See [MONITORING.md](MONITORING.md) for detailed monitoring documentation.

## Development

### Running Tests
```bash
docker-compose exec rails bundle exec rspec
```

### Database Operations
```bash
# Create database
docker-compose exec rails bundle exec rails db:create

# Run migrations
docker-compose exec rails bundle exec rails db:migrate

# Access Rails console
docker-compose exec rails bundle exec rails console
```

### Logs
```bash
# View all logs
docker-compose logs -f

# View specific service logs
docker-compose logs -f rails
docker-compose logs -f postgres
```

## Troubleshooting

### Services not starting
1. Check Docker daemon is running
2. Ensure ports 3000, 3001, 5432, 6379, 9090, 9093 are available
3. Review logs: `docker-compose logs`

### Database connection issues
1. Verify PostgreSQL is healthy: `docker-compose ps`
2. Check credentials in docker-compose.yml
3. Ensure DATABASE_URL is set correctly

### Monitoring not working
1. Verify exporters are running
2. Check Prometheus targets: http://localhost:9090/targets
3. Ensure metrics endpoint is accessible

## Cleanup

To remove all containers and volumes:
```bash
docker-compose down -v
```

## Security Notes

This is a development setup. For production:
1. Change all default passwords
2. Use environment variables for sensitive data
3. Enable SSL/TLS
4. Implement proper authentication
5. Review and harden security configurations
EOF
    else
      log_info "README.md already exists, skipping creation."
    fi
}

# Main provisioning function
main() {
    log_info "Starting Rails application provisioning..."
    check_requirements
    create_directory_structure
    create_rails_app
    create_docker_compose
    create_prometheus_config
    create_alertmanager_config
    create_grafana_config
    create_startup_script
    create_monitoring_docs
    create_readme
    log_info "Provisioning complete!"
    log_info "To start the application, run: ./scripts/start.sh"
    log_info "See README.md for detailed instructions."

    # Always build Docker images with no cache to ensure latest credentials and key are used
    log_info "Building Docker images with no cache to ensure latest credentials are used..."
    (cd "$RAILS_APP_NAME" && docker-compose build --no-cache)
}

# Run main function
main "$@"
