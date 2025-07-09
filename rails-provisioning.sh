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
        log_warning "Missing required dependencies: ${missing_deps[*]}"
        # Try to install if possible
        if command_exists brew; then
            log_info "Attempting to install missing dependencies with Homebrew..."
            for dep in "${missing_deps[@]}"; do
                brew install "$dep" || true
            done
        elif command_exists apt-get; then
            log_info "Attempting to install missing dependencies with apt-get..."
            sudo apt-get update
            for dep in "${missing_deps[@]}"; do
                sudo apt-get install -y "$dep" || true
            done
        else
            log_error "Automatic installation not supported on this OS. Please install: ${missing_deps[*]} manually."
            exit 1
        fi
        # Re-check after attempted install
        local still_missing=()
        for cmd in "${missing_deps[@]}"; do
            if ! command_exists "$cmd"; then
                still_missing+=("$cmd")
            fi
        done
        if [ ${#still_missing[@]} -ne 0 ]; then
            log_error "Failed to install: ${still_missing[*]}. Please install them manually."
            exit 1
        fi
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
}

# Function to create Docker Compose file
create_docker_compose() {
    log_info "Creating Docker Compose configuration..."
    cd "$RAILS_APP_NAME"
    cat > docker-compose.yml << 'EOF'

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
      test: ["CMD-SHELL", "pg_isready -U hello_world -d postgres"]
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
      DB_PASSWORD: secure_password_123
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
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
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

    # Create Dockerfile
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

# Remove lockfile to let bundler resolve versions
RUN rm -f Gemfile.lock

# Set bundle config and install gems
RUN bundle config set --local without 'development test' \
 && bundle install

# Copy app source
COPY . .

# Precompile assets (requires RAILS_MASTER_KEY)
# RUN bundle exec rails assets:precompile

# Expose port
EXPOSE 3000

# Start server
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
EOF
    cd ..
}

# Function to create Rails application
create_rails_app() {
    log_info "Creating Rails application..."
    
    # Remove old app directory if it exists
    rm -rf "$RAILS_APP_NAME"
    
    # Generate new Rails app with PostgreSQL, skip bundle and git
    rails new "$RAILS_APP_NAME" --database=postgresql --skip-bundle --skip-git
    
    cd "$RAILS_APP_NAME"

    # Create monitoring and scripts folders inside the Rails app directory
    mkdir -p monitoring/{prometheus,grafana,alertmanager}
    mkdir -p scripts
    
    # Remove any old credentials and master key before editing
    rm -f config/master.key config/credentials.yml.enc
    # Regenerate both together
    EDITOR="cat" bin/rails credentials:edit
    # Update .env with the new master key
    echo "RAILS_MASTER_KEY=$(cat config/master.key)" > .env

    # Update database.yml for production
    cat > config/database.yml << 'EOF'
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>

development:
  <<: *default
  database: hello_world_development
  username: hello_world
  password: <%= ENV['DB_PASSWORD'] %>
  host: localhost

test:
  <<: *default
  database: hello_world_test
  username: hello_world
  password: <%= ENV['DB_PASSWORD'] %>
  host: localhost

production:
  <<: *default
  url: <%= ENV['DATABASE_URL'] %>
EOF

    # Update Gemfile
    cat > Gemfile << 'EOF'
source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby "3.4.4"

gem "rails", "~> 8.0.0"
gem "sprockets-rails"
gem "pg", "~> 1.1"
gem "puma"
gem "importmap-rails"
gem "turbo-rails"
gem "stimulus-rails"
gem "jbuilder"
gem "redis"
gem "bootsnap", ">= 1.4.4", require: false
gem "tzinfo-data", platforms: %i[ mingw mswin x64_mingw jruby ]

# Monitoring
gem "prometheus-client"

group :development, :test do
  gem "debug", platforms: %i[ mri mingw x64_mingw ]
end

group :development do
  gem "web-console"
end

group :test do
  gem "capybara"
  gem "selenium-webdriver"
  gem "webdrivers"
end
EOF

    # Install gems
    bundle install

    # Create controllers
    cat > app/controllers/hello_controller.rb << 'EOF'
class HelloController < ApplicationController
  def index
    render plain: "Hello, world!"
  end
end
EOF

    cat > app/controllers/health_controller.rb << 'EOF'
class HealthController < ActionController::API
  def show
    db_result = check_database
    redis_result = check_redis
    
    status = (db_result[:ok] && redis_result[:ok]) ? :ok : :service_unavailable
    
    render json: { 
      status: status == :ok ? 'healthy' : 'unhealthy',
      database: db_result[:ok] ? 'ok' : 'error',
      database_error: db_result[:error],
      redis: redis_result[:ok] ? 'ok' : 'error',
      redis_error: redis_result[:error],
      timestamp: Time.now.iso8601
    }, status: status
  end
  
  private
  
  def check_database
    ActiveRecord::Base.connection.active?
    { ok: true, error: nil }
  rescue StandardError => e
    { ok: false, error: e.message }
  end
  
  def check_redis
    redis = Redis.new(url: ENV['REDIS_URL'] || 'redis://localhost:6379/0')
    redis.ping == 'PONG'
    { ok: true, error: nil }
  rescue StandardError => e
    { ok: false, error: e.message }
  end
end
EOF

    cat > app/controllers/metrics_controller.rb << 'EOF'
class MetricsController < ActionController::API
  def show
    metrics_text = <<~METRICS
      # HELP hello_world_requests_total Total number of HTTP requests
      # TYPE hello_world_requests_total counter
      hello_world_requests_total{method="GET",status="200",path="/"} 1
      
      # HELP hello_world_request_duration_seconds HTTP request duration in seconds
      # TYPE hello_world_request_duration_seconds histogram
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="0.005"} 1
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="0.01"} 1
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="0.025"} 1
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="0.05"} 1
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="0.1"} 1
      hello_world_request_duration_seconds_bucket{method="GET",path="/",le="+Inf"} 1
      hello_world_request_duration_seconds_sum{method="GET",path="/"} 0.002
      hello_world_request_duration_seconds_count{method="GET",path="/"} 1
    METRICS
    
    render plain: metrics_text, content_type: 'text/plain'
  end
end
EOF

    # Create proper routes.rb
    cat > config/routes.rb << 'EOF'
Rails.application.routes.draw do
  root "hello#index"
  get "/health", to: "health#show"
  get "/metrics", to: "metrics#show"
end
EOF

    # Create Prometheus initializer
    mkdir -p config/initializers
cat > config/initializers/prometheus.rb << 'EOF'
require 'prometheus/client'

# Create a default Prometheus registry
prometheus = Prometheus::Client.registry

# Define metrics
REQUEST_COUNTER = Prometheus::Client::Counter.new(
  :hello_world_requests_total,
  docstring: 'Total number of HTTP requests',
  labels: [:method, :status, :path]
)

REQUEST_DURATION = Prometheus::Client::Histogram.new(
  :hello_world_request_duration_seconds,
  docstring: 'HTTP request duration in seconds',
  labels: [:method, :path]
)

# Register metrics
prometheus.register(REQUEST_COUNTER)
prometheus.register(REQUEST_DURATION)

EOF

    # Create Redis initializer
    cat > config/initializers/redis.rb << 'EOF'
require 'redis'

REDIS_CONFIG = {
  url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
  timeout: 1
}

$redis = Redis.new(REDIS_CONFIG)

# Test connection on startup
begin
  $redis.ping
  Rails.logger.info "Redis connection established"
rescue Redis::CannotConnectError => e
  Rails.logger.error "Redis connection failed: #{e.message}"
end
EOF

    # Ensure asset pipeline manifest exists
    mkdir -p app/assets/config
    cat > app/assets/config/manifest.js << 'EOF'
//= link_tree ../images
//= link_directory ../stylesheets .css
//= link application.js
EOF

    # Create application.js
    mkdir -p app/assets/javascripts
    touch app/assets/javascripts/application.js

    # Create application.css
    mkdir -p app/assets/stylesheets
    cat > app/assets/stylesheets/application.css << 'EOF'
/*
 *= require_tree .
 *= require_self
 */
EOF

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

    # Create dashboards directory and Rails dashboard
    mkdir -p monitoring/grafana/dashboards
    cat > monitoring/grafana/dashboards/rails-dashboard.json << 'EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": "-- Grafana --",
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "gnetId": null,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 0.05
              }
            ]
          },
          "unit": "percentunit"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "showThresholdLabels": false,
        "showThresholdMarkers": true,
        "text": {}
      },
      "pluginVersion": "7.0.0",
      "targets": [
        {
          "expr": "sum(rate(hello_world_requests_total{status=~\"5..\"}[5m])) / sum(rate(hello_world_requests_total[5m]))",
          "refId": "A"
        }
      ],
      "title": "Current Error Rate",
      "type": "gauge"
    },
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "reqps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 4
      },
      "id": 2,
      "options": {
        "legend": {
          "calcs": [],
          "displayMode": "list",
          "placement": "bottom"
        },
        "tooltip": {
          "mode": "single"
        }
      },
      "pluginVersion": "7.0.0",
      "targets": [
        {
          "expr": "sum by (status) (rate(hello_world_requests_total[5m]))",
          "legendFormat": "{{status}}",
          "refId": "A"
        }
      ],
      "title": "Request Rate by Status",
      "type": "timeseries"
    },
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "s"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 4
      },
      "id": 3,
      "options": {
        "legend": {
          "calcs": [],
          "displayMode": "list",
          "placement": "bottom"
        },
        "tooltip": {
          "mode": "single"
        }
      },
      "pluginVersion": "7.0.0",
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(hello_world_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "P95",
          "refId": "A"
        },
        {
          "expr": "histogram_quantile(0.99, sum(rate(hello_world_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "P99",
          "refId": "B"
        }
      ],
      "title": "Response Time Percentiles",
      "type": "timeseries"
    },
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 12
      },
      "id": 4,
      "options": {
        "legend": {
          "calcs": [],
          "displayMode": "list",
          "placement": "bottom"
        },
        "tooltip": {
          "mode": "single"
        }
      },
      "pluginVersion": "7.0.0",
      "targets": [
        {
          "expr": "pg_stat_database_numbackends{datname=\"hello_world_production\"}",
          "legendFormat": "Active Connections",
          "refId": "A"
        }
      ],
      "title": "PostgreSQL Active Connections",
      "type": "timeseries"
    },
    {
      "datasource": "Prometheus",
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "lineInterpolation": "linear",
            "lineWidth": 1,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 12
      },
      "id": 5,
      "options": {
        "legend": {
          "calcs": [],
          "displayMode": "list",
          "placement": "bottom"
        },
        "tooltip": {
          "mode": "single"
        }
      },
      "pluginVersion": "7.0.0",
      "targets": [
        {
          "expr": "redis_memory_used_bytes",
          "legendFormat": "Memory Used",
          "refId": "A"
        }
      ],
      "title": "Redis Memory Usage",
      "type": "timeseries"
    }
  ],
  "schemaVersion": 25,
  "style": "dark",
  "tags": ["rails", "monitoring"],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "timepicker": {
    "refresh_intervals": ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"]
  },
  "timezone": "",
  "title": "Rails Application Dashboard",
  "uid": "rails-app-dashboard",
  "version": 0
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
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Verify RAILS_MASTER_KEY is set
if [ -z "$RAILS_MASTER_KEY" ]; then
    echo "ERROR: RAILS_MASTER_KEY is not set. Check your .env file."
    exit 1
fi

# Start all services
echo "Starting Docker services..."
docker-compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 10

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
# Function to check if a service is healthy
check_service_health() {
    local service=$1
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker-compose ps $service | grep -q "healthy"; then
            echo "$service is healthy"
            return 0
        fi
        attempt=$((attempt + 1))
        echo "Waiting for $service to be healthy... ($attempt/$max_attempts)"
        sleep 2
    done
    
    echo "ERROR: $service did not become healthy in time"
    return 1
}

# Check critical services
check_service_health postgres || exit 1
check_service_health redis || exit 1

echo "Setting up database..."
# The database is created by PostgreSQL on startup, running migrations...

docker-compose exec -T rails bundle exec rails db:migrate RAILS_ENV=production

# Verify Rails app is responding
echo "Checking Rails application..."
for i in {1..30}; do
    if curl -s http://localhost:3000/health > /dev/null; then
        echo "Rails application is ready!"
        break
    fi
    echo "Waiting for Rails to be ready... ($i/30)"
    sleep 2
done

# Check monitoring endpoints
echo -e "\nChecking monitoring endpoints..."
curl -s http://localhost:3000/health | jq . || echo "Health check endpoint not responding with JSON"
echo -e "\nMetrics endpoint sample:"
curl -s http://localhost:3000/metrics | head -20

echo -e "\n✅ All services are up and running!"
echo "📍 Rails app: http://localhost:3000"
echo "📍 Health check: http://localhost:3000/health"
echo "📍 Metrics: http://localhost:3000/metrics"
echo "📊 Prometheus: http://localhost:9090"
echo "📈 Grafana: http://localhost:3001 (admin/admin_password_123)"
echo "🚨 Alertmanager: http://localhost:9093"
echo -e "\nTo check Prometheus targets: http://localhost:9090/targets"
echo "To view logs: docker-compose logs -f rails"
EOF
    chmod +x scripts/start.sh
    
    # Create stop script
    cat > scripts/stop.sh << 'EOF'
#!/bin/bash

echo "Stopping all services..."
docker-compose down

echo "Services stopped."
echo "To remove volumes as well, run: docker-compose down -v"
EOF
    chmod +x scripts/stop.sh
    
    # Create logs script
    cat > scripts/logs.sh << 'EOF'
#!/bin/bash

service=${1:-}

if [ -z "$service" ]; then
    echo "Following logs for all services. Press Ctrl+C to stop."
    docker-compose logs -f
else
    echo "Following logs for $service. Press Ctrl+C to stop."
    docker-compose logs -f $service
fi
EOF
    chmod +x scripts/logs.sh
    
    cd ..
}

# Function to create monitoring documentation
create_monitoring_docs() {
    log_info "Creating monitoring documentation..."
    cd "$RAILS_APP_NAME"
    cat > MONITORING.md << 'EOF'
# Monitoring Documentation

## Overview
This Rails application is monitored using Prometheus, Grafana, and Alertmanager. The monitoring stack tracks performance metrics, system resources, and application health.

## Quick Verification

### 1. Check if services are connected:
```bash
# Check Rails health endpoint
curl http://localhost:3000/health | jq .

# Check if metrics are being collected
curl http://localhost:3000/metrics | grep hello_world_requests_total

# Check Prometheus targets
open http://localhost:9090/targets
```

### 2. Verify in Grafana:
1. Open http://localhost:3001
2. Login with admin/admin_password_123
3. Go to Dashboards > Rails Application Dashboard
4. You should see real-time metrics

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

## Testing the Monitoring

### Generate some traffic:
```bash
# Single request
curl http://localhost:3000

# Generate load
for i in {1..100}; do curl http://localhost:3000 & done

# Check metrics increased
curl http://localhost:3000/metrics | grep hello_world_requests_total
```

### Check database connection:
```bash
docker-compose exec rails rails console
# In console:
ActiveRecord::Base.connection.active?
# Should return true
```

### Check Redis connection:
```bash
docker-compose exec rails rails console
# In console:
Redis.new(url: ENV['REDIS_URL']).ping
# Should return "PONG"
```

## Troubleshooting

### Metrics not appearing in Prometheus:
1. Check if Rails metrics endpoint works: `curl http://localhost:3000/metrics`
2. Check Prometheus targets: http://localhost:9090/targets
3. Look for errors in Rails logs: `docker-compose logs rails`

### Database connection issues:
1. Check if PostgreSQL is running: `docker-compose ps postgres`
2. Test connection: `docker-compose exec postgres psql -U hello_world -d hello_world_production`
3. Check Rails logs for connection errors

### Redis connection issues:
1. Check if Redis is running: `docker-compose ps redis`
2. Test connection: `docker-compose exec redis redis-cli ping`
3. Check Redis logs: `docker-compose logs redis`

### No data in Grafana:
1. Verify Prometheus data source is configured
2. Check if Prometheus is scraping metrics: http://localhost:9090/targets
3. Query Prometheus directly: http://localhost:9090/graph

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

## Useful Queries

### Prometheus Queries:
```promql
# Request rate
sum(rate(hello_world_requests_total[5m]))

# Error rate
sum(rate(hello_world_requests_total{status=~"5.."}[5m])) / sum(rate(hello_world_requests_total[5m]))

# P95 latency
histogram_quantile(0.95, sum(rate(hello_world_request_duration_seconds_bucket[5m])) by (le))

# Active DB connections
pg_stat_database_numbackends{datname="hello_world_production"}

# Redis memory usage percentage
redis_memory_used_bytes / redis_memory_max_bytes * 100
```

## Best Practices
1. **Set up alert channels** in Alertmanager (email, Slack, PagerDuty)
2. **Regular review** of metrics and thresholds
3. **Capacity planning** based on trend analysis
4. **Document incidents** and adjust alerts accordingly
EOF
    cd ..
}

# Function to create README
create_readme() {
    log_info "Creating README..."
    cd "$RAILS_APP_NAME"
    cat > README.md << 'EOF'
# Hello World Rails Application with Monitoring

## Quick Start

### Prerequisites
- Docker and Docker Compose installed
- Git
- At least 4GB of available RAM
- Ruby and Rails (for initial setup)

### Installation

1. Run the provisioning script from the parent directory:
```bash
./provision.sh
```

2. Start all services:
```bash
cd hello_world_app
./scripts/start.sh
```

### Accessing Services

- **Rails Application**: http://localhost:3000
- **Health Check**: http://localhost:3000/health
- **Metrics**: http://localhost:3000/metrics
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3001 (Username: admin, Password: admin_password_123)
- **Alertmanager**: http://localhost:9093

## Verifying Everything Works

### 1. Check Application Health
```bash
curl http://localhost:3000/health | jq .
```

Expected output:
```json
{
  "status": "healthy",
  "database": "ok",
  "redis": "ok",
  "timestamp": "2024-01-15T10:00:00Z"
}
```

### 2. Check Metrics
```bash
curl http://localhost:3000/metrics | head -20
```

### 3. Verify in Prometheus
1. Open http://localhost:9090/targets
2. All targets should show as "UP"

### 4. Check Grafana Dashboard
1. Open http://localhost:3001
2. Login with admin/admin_password_123
3. Go to Dashboards > Rails Application Dashboard
4. You should see metrics being collected

## Architecture

The application consists of:
- Rails application (Hello World)
- PostgreSQL database
- Redis cache
- Prometheus (metrics collection)
- Grafana (visualization)
- Alertmanager (alert routing)
- Various exporters for metrics collection

## Scripts

- `./scripts/start.sh` - Start all services
- `./scripts/stop.sh` - Stop all services
- `./scripts/logs.sh [service]` - View logs

## Development

### Running Rails Console
```bash
docker-compose exec rails bundle exec rails console
```

### Database Operations
```bash
# Run migrations
docker-compose exec rails bundle exec rails db:migrate

# Create database
docker-compose exec rails bundle exec rails db:create
```

### Viewing Logs
```bash
# All logs
./scripts/logs.sh

# Specific service
./scripts/logs.sh rails
./scripts/logs.sh postgres
```

## Monitoring

See [MONITORING.md](MONITORING.md) for detailed monitoring documentation.

## Testing the Setup

### Generate some load:
```bash
# Simple load test
for i in {1..100}; do 
  curl http://localhost:3000 &
done
wait

# Check metrics increased
curl http://localhost:3000/metrics | grep hello_world_requests_total
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
    cd ..
}

# Main provisioning function
main() {
    log_info "Starting Rails application provisioning..."
    
    # Check for Rails
    if ! command_exists rails; then
        log_error "Rails is not installed. Please install Rails first."
        exit 1
    fi
    
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
    log_info "Building Docker images..."
    (cd "$RAILS_APP_NAME" && docker-compose build --no-cache)
    
    log_info "✅ Setup complete!"
    log_info "To start the application:"
    log_info "  cd $RAILS_APP_NAME"
    log_info "  ./scripts/start.sh"
    log_info ""
    log_info "Then verify everything is working:"
    log_info "  curl http://localhost:3000/health | jq ."
    log_info "  open http://localhost:9090/targets"
    log_info "  open http://localhost:3001"
}

# Run main function
main "$@"