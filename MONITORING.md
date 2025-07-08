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
