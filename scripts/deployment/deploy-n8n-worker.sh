#!/bin/bash
# ================================================================
# DarkSpere: n8n Worker Deployment Script
# Purpose: Deploy n8n worker instances for horizontal scaling
# Usage: ./deploy-n8n-worker.sh [worker_id] [environment]
# ================================================================

set -e  # Exit on error
set -u  # Exit on undefined variable

# ================================================================
# CONFIGURATION
# ================================================================

WORKER_ID="${1:-1}"
ENVIRONMENT="${2:-production}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ================================================================
# HELPER FUNCTIONS
# ================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependency() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

# ================================================================
# PRE-FLIGHT CHECKS
# ================================================================

log_info "Starting n8n worker deployment (Worker ID: $WORKER_ID, Environment: $ENVIRONMENT)"

# Check dependencies
log_info "Checking dependencies..."
check_dependency docker
check_dependency redis-cli
check_dependency psql

# Check if Redis is running
log_info "Checking Redis connection..."
if ! redis-cli -a "${QUEUE_BULL_REDIS_PASSWORD:-}" ping &> /dev/null; then
    log_error "Cannot connect to Redis. Make sure Redis is running."
    exit 1
fi
log_success "Redis connection OK"

# Check if PostgreSQL is accessible
log_info "Checking PostgreSQL connection..."
if ! psql -h "${DB_POSTGRESDB_HOST:-localhost}" -U "${DB_POSTGRESDB_USER:-darkspere_worker}" -d postgres -c "SELECT 1" &> /dev/null; then
    log_error "Cannot connect to PostgreSQL. Check database configuration."
    exit 1
fi
log_success "PostgreSQL connection OK"

# ================================================================
# ENVIRONMENT SETUP
# ================================================================

ENV_FILE="$CONFIG_DIR/.env.n8n.$ENVIRONMENT"
if [ ! -f "$ENV_FILE" ]; then
    log_warning "Environment file not found: $ENV_FILE"
    log_info "Using default .env.n8n file"
    ENV_FILE="$CONFIG_DIR/.env.n8n"
fi

if [ ! -f "$ENV_FILE" ]; then
    log_error "No environment file found. Please create $CONFIG_DIR/.env.n8n"
    exit 1
fi

log_success "Using environment file: $ENV_FILE"

# ================================================================
# WORKER CONFIGURATION
# ================================================================

WORKER_NAME="darkspere-n8n-worker-$WORKER_ID"
WORKER_PORT=$((5678 + WORKER_ID))
METRICS_PORT=$((9090 + WORKER_ID))
HEALTHCHECK_PORT=$((8080 + WORKER_ID))

log_info "Worker configuration:"
log_info "  - Name: $WORKER_NAME"
log_info "  - Worker Port: $WORKER_PORT"
log_info "  - Metrics Port: $METRICS_PORT"
log_info "  - Health Check Port: $HEALTHCHECK_PORT"

# ================================================================
# STOP EXISTING WORKER
# ================================================================

if docker ps -a --format '{{.Names}}' | grep -q "^${WORKER_NAME}$"; then
    log_info "Stopping existing worker: $WORKER_NAME"
    docker stop "$WORKER_NAME" 2>/dev/null || true
    docker rm "$WORKER_NAME" 2>/dev/null || true
    log_success "Existing worker stopped and removed"
fi

# ================================================================
# CREATE WORKER-SPECIFIC ENV FILE
# ================================================================

WORKER_ENV_FILE="/tmp/${WORKER_NAME}.env"
cp "$ENV_FILE" "$WORKER_ENV_FILE"

# Override settings for worker instance
cat >> "$WORKER_ENV_FILE" << EOF

# ================================================================
# WORKER-SPECIFIC OVERRIDES (Auto-generated)
# ================================================================

# Set process type to worker
N8N_PROCESS_TYPE=worker

# Worker-specific ports
N8N_PORT=$WORKER_PORT
N8N_METRICS_PORT=$METRICS_PORT
N8N_HEALTHCHECK_SERVER_PORT=$HEALTHCHECK_PORT

# Worker identification
N8N_WORKER_ID=$WORKER_ID
N8N_WORKER_NAME=$WORKER_NAME

# Log file for this worker
N8N_LOG_FILE_LOCATION=/var/log/n8n/${WORKER_NAME}.log
EOF

log_success "Worker-specific environment file created: $WORKER_ENV_FILE"

# ================================================================
# DEPLOY WORKER CONTAINER
# ================================================================

log_info "Deploying n8n worker container..."

docker run -d \
    --name "$WORKER_NAME" \
    --env-file "$WORKER_ENV_FILE" \
    --restart unless-stopped \
    --network host \
    --memory 4g \
    --cpus 2 \
    -v darkspere_n8n_data:/home/node/.n8n \
    -v /var/log/n8n:/var/log/n8n \
    n8nio/n8n:latest worker

if [ $? -eq 0 ]; then
    log_success "Worker container deployed successfully: $WORKER_NAME"
else
    log_error "Failed to deploy worker container"
    exit 1
fi

# ================================================================
# HEALTH CHECK
# ================================================================

log_info "Waiting for worker to become healthy..."

MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if docker ps | grep -q "$WORKER_NAME"; then
        CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$WORKER_NAME")
        if [ "$CONTAINER_STATUS" = "running" ]; then
            log_success "Worker is running!"
            break
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo -n "."
    sleep 2
done

echo ""

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    log_error "Worker failed to start within timeout period"
    log_info "Container logs:"
    docker logs "$WORKER_NAME"
    exit 1
fi

# Check health endpoint
log_info "Checking health endpoint..."
sleep 3

if curl -sf "http://localhost:$HEALTHCHECK_PORT/healthz" > /dev/null; then
    log_success "Health check passed!"
else
    log_warning "Health endpoint not responding (this is normal for worker-only instances)"
fi

# ================================================================
# VERIFY REDIS CONNECTION
# ================================================================

log_info "Verifying Redis queue connection..."

REDIS_PASSWORD=$(grep QUEUE_BULL_REDIS_PASSWORD "$WORKER_ENV_FILE" | cut -d'=' -f2)
REDIS_QUEUE_KEY="bull:workflow-queue:*"

if redis-cli -a "$REDIS_PASSWORD" --scan --pattern "$REDIS_QUEUE_KEY" | wc -l &> /dev/null; then
    log_success "Worker connected to Redis queue successfully"
else
    log_warning "Could not verify Redis queue connection"
fi

# ================================================================
# DISPLAY WORKER INFO
# ================================================================

echo ""
log_success "========================================="
log_success "Worker Deployment Complete!"
log_success "========================================="
echo ""
log_info "Worker Details:"
log_info "  - Container Name: $WORKER_NAME"
log_info "  - Worker ID: $WORKER_ID"
log_info "  - Environment: $ENVIRONMENT"
log_info "  - Status: $(docker inspect --format='{{.State.Status}}' $WORKER_NAME)"
echo ""
log_info "Ports:"
log_info "  - Metrics: http://localhost:$METRICS_PORT/metrics"
log_info "  - Health Check: http://localhost:$HEALTHCHECK_PORT/healthz"
echo ""
log_info "Management Commands:"
log_info "  - View logs: docker logs -f $WORKER_NAME"
log_info "  - Stop worker: docker stop $WORKER_NAME"
log_info "  - Restart worker: docker restart $WORKER_NAME"
log_info "  - Remove worker: docker rm -f $WORKER_NAME"
echo ""
log_info "Redis Queue:"
log_info "  - Monitor queue: redis-cli -a <password> --scan --pattern 'bull:workflow-queue:*'"
log_info "  - Queue stats: redis-cli -a <password> INFO stats"
echo ""

# ================================================================
# OPTIONAL: REGISTER WORKER IN DATABASE
# ================================================================

log_info "Registering worker in monitoring system..."

REGISTER_SQL="
INSERT INTO worker_registry (
    worker_id,
    worker_name,
    worker_type,
    endpoint_url,
    metrics_url,
    health_url,
    status,
    metadata
) VALUES (
    '$WORKER_ID',
    '$WORKER_NAME',
    'n8n_worker',
    'http://localhost:$WORKER_PORT',
    'http://localhost:$METRICS_PORT/metrics',
    'http://localhost:$HEALTHCHECK_PORT/healthz',
    'active',
    '{\"environment\": \"$ENVIRONMENT\", \"deployed_at\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}'::jsonb
)
ON CONFLICT (worker_name) DO UPDATE
SET status = 'active',
    endpoint_url = EXCLUDED.endpoint_url,
    metrics_url = EXCLUDED.metrics_url,
    health_url = EXCLUDED.health_url,
    metadata = EXCLUDED.metadata,
    last_seen = NOW();
"

if psql -h "${DB_POSTGRESDB_HOST:-localhost}" \
        -U "${DB_POSTGRESDB_USER:-darkspere_worker}" \
        -d postgres \
        -c "$REGISTER_SQL" &> /dev/null; then
    log_success "Worker registered in database"
else
    log_warning "Could not register worker in database (table may not exist yet)"
fi

# ================================================================
# CLEANUP
# ================================================================

# Remove temporary env file
rm -f "$WORKER_ENV_FILE"

# ================================================================
# DISPLAY NEXT STEPS
# ================================================================

echo ""
log_info "Next Steps:"
log_info "1. Monitor worker logs: docker logs -f $WORKER_NAME"
log_info "2. Check metrics: curl http://localhost:$METRICS_PORT/metrics"
log_info "3. Deploy additional workers: ./deploy-n8n-worker.sh 2"
log_info "4. Set up load balancer to distribute webhook traffic"
echo ""
log_success "Worker deployment completed successfully! 🚀"
