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
./sub.sh
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
