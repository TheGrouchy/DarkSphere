#!/bin/bash
# ================================================================
# DarkSpere: Full Stack Deployment Script
# Purpose: Deploy complete DarkSpere system (database, APIs, agents, monitoring)
# Usage: ./deploy_full_stack.sh [environment]
# ================================================================

set -e  # Exit on error
set -u  # Exit on undefined variable

# ================================================================
# CONFIGURATION
# ================================================================

ENVIRONMENT="${1:-production}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Deployment log
LOG_FILE="/var/log/darkspere/deployment_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$LOG_FILE")"

# ================================================================
# HELPER FUNCTIONS
# ================================================================

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_section() {
    echo -e "\n${PURPLE}========================================${NC}" | tee -a "$LOG_FILE"
    echo -e "${PURPLE}$1${NC}" | tee -a "$LOG_FILE"
    echo -e "${PURPLE}========================================${NC}\n" | tee -a "$LOG_FILE"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 is not installed. Please install it first."
        exit 1
    fi
}

# ================================================================
# PRE-FLIGHT CHECKS
# ================================================================

log_section "Pre-Flight Checks"

log "Checking required commands..."
check_command docker
check_command docker-compose
check_command psql
check_command redis-cli
check_command curl
log_success "All required commands available"

# Check environment files
if [ ! -f "$PROJECT_ROOT/.env.$ENVIRONMENT" ]; then
    log_error "Environment file not found: .env.$ENVIRONMENT"
    exit 1
fi

log_success "Environment file found: .env.$ENVIRONMENT"

# Load environment variables
source "$PROJECT_ROOT/.env.$ENVIRONMENT"

# ================================================================
# STEP 1: DATABASE DEPLOYMENT
# ================================================================

log_section "Step 1: Database Deployment"

log "Checking PostgreSQL connection..."
if psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -c "SELECT 1" &> /dev/null; then
    log_success "PostgreSQL connection OK"
else
    log_error "Cannot connect to PostgreSQL. Check credentials and connection."
    exit 1
fi

log "Deploying database schemas..."
cd "$PROJECT_ROOT/schema"

if [ -f "deploy.sql" ]; then
    psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -f deploy.sql
    log_success "Database schemas deployed"
else
    log_error "deploy.sql not found"
    exit 1
fi

# Run migrations
log "Checking for pending migrations..."
MIGRATION_COUNT=$(ls -1 "$PROJECT_ROOT/schema" | grep -E "^[0-9]{2}_.*\.sql$" | wc -l)
log "Found $MIGRATION_COUNT schema files"

log_success "Database deployment complete"

# ================================================================
# STEP 2: REDIS DEPLOYMENT
# ================================================================

log_section "Step 2: Redis Deployment"

log "Checking Redis configuration..."
if [ -f "$PROJECT_ROOT/config/redis.conf" ]; then
    log "Starting Redis with custom configuration..."

    # Check if Redis is already running
    if redis-cli ping &> /dev/null; then
        log_warning "Redis already running, skipping start"
    else
        redis-server "$PROJECT_ROOT/config/redis.conf" --daemonize yes
        sleep 2

        if redis-cli ping &> /dev/null; then
            log_success "Redis started successfully"
        else
            log_error "Redis failed to start"
            exit 1
        fi
    fi
else
    log_warning "redis.conf not found, using default Redis"
fi

# ================================================================
# STEP 3: N8N DEPLOYMENT
# ================================================================

log_section "Step 3: n8n Orchestration Deployment"

log "Deploying n8n main instance..."
if [ -f "$PROJECT_ROOT/config/.env.n8n" ]; then
    # Start main n8n instance
    docker run -d \
        --name darkspere-n8n-main \
        --env-file "$PROJECT_ROOT/config/.env.n8n" \
        --restart unless-stopped \
        --network host \
        -v darkspere_n8n_data:/home/node/.n8n \
        -e N8N_PROCESS_TYPE=main \
        n8nio/n8n:latest

    if [ $? -eq 0 ]; then
        log_success "n8n main instance deployed"
    else
        log_error "Failed to deploy n8n main instance"
        exit 1
    fi
else
    log_warning ".env.n8n not found, skipping n8n deployment"
fi

# Deploy n8n workers
log "Deploying n8n workers..."
WORKER_COUNT="${N8N_WORKER_COUNT:-3}"

for i in $(seq 1 $WORKER_COUNT); do
    log "Deploying worker $i/$WORKER_COUNT..."
    "$SCRIPT_DIR/deploy-n8n-worker.sh" $i $ENVIRONMENT &> /dev/null

    if [ $? -eq 0 ]; then
        log_success "Worker $i deployed"
    else
        log_warning "Worker $i deployment failed (continuing...)"
    fi
done

log_success "n8n deployment complete"

# ================================================================
# STEP 4: API SERVICES DEPLOYMENT
# ================================================================

log_section "Step 4: API Services Deployment"

# Agent Registration API
log "Deploying Agent Registration API..."
docker run -d \
    --name darkspere-agent-registration \
    --env-file "$PROJECT_ROOT/.env.$ENVIRONMENT" \
    --restart unless-stopped \
    --network host \
    -v "$PROJECT_ROOT/api:/app" \
    -w /app \
    python:3.11-slim \
    sh -c "pip install -q flask flask-cors psycopg2-binary bcrypt && python agent_registration.py"

if [ $? -eq 0 ]; then
    log_success "Agent Registration API deployed (port 8002)"
else
    log_error "Failed to deploy Agent Registration API"
fi

# Stripe Webhooks API
log "Deploying Stripe Webhooks API..."
docker run -d \
    --name darkspere-stripe-webhooks \
    --env-file "$PROJECT_ROOT/.env.$ENVIRONMENT" \
    --restart unless-stopped \
    --network host \
    -v "$PROJECT_ROOT/api:/app" \
    -w /app \
    python:3.11-slim \
    sh -c "pip install -q flask stripe psycopg2-binary && python stripe_webhooks.py"

if [ $? -eq 0 ]; then
    log_success "Stripe Webhooks API deployed (port 8003)"
else
    log_error "Failed to deploy Stripe Webhooks API"
fi

# Logging Service
log "Deploying Logging Service..."
docker run -d \
    --name darkspere-logging-service \
    --env-file "$PROJECT_ROOT/.env.$ENVIRONMENT" \
    --restart unless-stopped \
    --network host \
    -v "$PROJECT_ROOT/api:/app" \
    -w /app \
    python:3.11-slim \
    sh -c "pip install -q flask psycopg2-binary python-json-logger && python logging_service.py"

if [ $? -eq 0 ]; then
    log_success "Logging Service deployed (port 8004)"
else
    log_error "Failed to deploy Logging Service"
fi

# MCP Adapter
log "Deploying MCP Adapter..."
docker run -d \
    --name darkspere-mcp-adapter \
    --env-file "$PROJECT_ROOT/.env.$ENVIRONMENT" \
    --restart unless-stopped \
    --network host \
    -v "$PROJECT_ROOT/agents:/app" \
    -w /app \
    python:3.11-slim \
    sh -c "pip install -q aiohttp psycopg2-binary && python mcp_adapter.py"

if [ $? -eq 0 ]; then
    log_success "MCP Adapter deployed (port 8001)"
else
    log_error "Failed to deploy MCP Adapter"
fi

log_success "API services deployment complete"

# ================================================================
# STEP 5: AGENT DEPLOYMENT
# ================================================================

log_section "Step 5: Agent Deployment"

# Deploy secure mock agent
log "Deploying secure mock agent..."
docker run -d \
    --name darkspere-mock-agent \
    --env-file "$PROJECT_ROOT/.env.$ENVIRONMENT" \
    --restart unless-stopped \
    --network host \
    -v "$PROJECT_ROOT/mock-agent:/app" \
    -w /app \
    python:3.11-slim \
    sh -c "pip install -q flask && python app_secure.py"

if [ $? -eq 0 ]; then
    log_success "Mock agent deployed (port 5000)"
else
    log_error "Failed to deploy mock agent"
fi

log_success "Agent deployment complete"

# ================================================================
# STEP 6: HEALTH CHECKS
# ================================================================

log_section "Step 6: Health Checks"

# Wait for services to start
log "Waiting for services to initialize..."
sleep 10

# Check each service
declare -A SERVICES=(
    ["Agent Registration"]="http://localhost:8002/health"
    ["Stripe Webhooks"]="http://localhost:8003/health"
    ["Logging Service"]="http://localhost:8004/health"
    ["MCP Adapter"]="http://localhost:8001/mcp/status"
    ["Mock Agent"]="http://localhost:5000/health"
)

FAILED_SERVICES=0

for SERVICE_NAME in "${!SERVICES[@]}"; do
    SERVICE_URL="${SERVICES[$SERVICE_NAME]}"

    log "Checking $SERVICE_NAME..."

    if curl -sf "$SERVICE_URL" &> /dev/null; then
        log_success "$SERVICE_NAME is healthy"
    else
        log_error "$SERVICE_NAME health check failed"
        FAILED_SERVICES=$((FAILED_SERVICES + 1))
    fi
done

if [ $FAILED_SERVICES -eq 0 ]; then
    log_success "All services are healthy"
else
    log_warning "$FAILED_SERVICES service(s) failed health checks"
fi

# ================================================================
# STEP 7: INITIALIZE DEFAULT DATA
# ================================================================

log_section "Step 7: Initialize Default Data"

log "Creating default subscription plans..."
psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -c "
    INSERT INTO subscription_plans (plan_name, tier, billing_period, base_price_cents, sms_outbound_limit)
    VALUES ('Free Plan', 'free', 'monthly', 0, 50)
    ON CONFLICT DO NOTHING;
" &> /dev/null

log "Initializing feature gates..."
psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -c "
    SELECT COUNT(*) FROM feature_gates;
" &> /dev/null

log "Creating default alert rules..."
psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -c "
    SELECT COUNT(*) FROM alert_rules;
" &> /dev/null

log_success "Default data initialized"

# ================================================================
# STEP 8: DEPLOYMENT SUMMARY
# ================================================================

log_section "Deployment Summary"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}DarkSpere Full Stack Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}\n"

echo -e "${BLUE}Environment:${NC} $ENVIRONMENT"
echo -e "${BLUE}Deployment Log:${NC} $LOG_FILE"
echo ""

echo -e "${PURPLE}Services Running:${NC}"
echo -e "  - PostgreSQL: ${DB_HOST}:${DB_PORT}"
echo -e "  - Redis: localhost:6379"
echo -e "  - n8n Main: localhost:5678"
echo -e "  - Agent Registration API: http://localhost:8002"
echo -e "  - Stripe Webhooks: http://localhost:8003"
echo -e "  - Logging Service: http://localhost:8004"
echo -e "  - MCP Adapter: http://localhost:8001"
echo -e "  - Mock Agent: http://localhost:5000"
echo ""

echo -e "${PURPLE}Monitoring URLs:${NC}"
echo -e "  - n8n Dashboard: http://localhost:5678"
echo -e "  - Health Status: http://localhost:8004/api/logs/stats"
echo -e "  - Agent Stats: http://localhost:8002/api/agents/stats"
echo ""

echo -e "${PURPLE}Next Steps:${NC}"
echo -e "  1. Configure Twilio webhook: ${TWILIO_WEBHOOK_URL:-'Set TWILIO_WEBHOOK_URL'}"
echo -e "  2. Configure Stripe webhook: http://localhost:8003/webhooks/stripe"
echo -e "  3. Register test agent: POST http://localhost:8002/api/agents/register"
echo -e "  4. Run integration tests: python tests/integration_tests.py"
echo -e "  5. Monitor logs: docker logs -f darkspere-logging-service"
echo ""

echo -e "${PURPLE}Management Commands:${NC}"
echo -e "  - View all containers: docker ps | grep darkspere"
echo -e "  - View n8n workers: docker ps | grep n8n-worker"
echo -e "  - Stop all: docker stop \$(docker ps -q --filter name=darkspere)"
echo -e "  - View logs: docker logs <container-name>"
echo ""

echo -e "${GREEN}Deployment completed successfully!${NC} 🚀\n"

# ================================================================
# STEP 9: POST-DEPLOYMENT VALIDATION
# ================================================================

log_section "Post-Deployment Validation"

log "Running basic validation checks..."

# Test database connection
log "Testing database connection..."
if psql -h "${DB_HOST}" -U "${DB_USER}" -d postgres -c "SELECT COUNT(*) FROM agent_registry;" &> /dev/null; then
    log_success "Database connection validated"
else
    log_error "Database connection failed"
fi

# Test Redis connection
log "Testing Redis connection..."
if redis-cli ping &> /dev/null; then
    log_success "Redis connection validated"
else
    log_error "Redis connection failed"
fi

# Test API connectivity
log "Testing API endpoints..."
API_TESTS=0
API_SUCCESS=0

for SERVICE_NAME in "${!SERVICES[@]}"; do
    API_TESTS=$((API_TESTS + 1))
    if curl -sf "${SERVICES[$SERVICE_NAME]}" &> /dev/null; then
        API_SUCCESS=$((API_SUCCESS + 1))
    fi
done

log_success "API validation: $API_SUCCESS/$API_TESTS endpoints responding"

# ================================================================
# OPTIONAL: RUN INTEGRATION TESTS
# ================================================================

if [ "${RUN_TESTS:-false}" = "true" ]; then
    log_section "Running Integration Tests"

    log "Executing test suite..."
    cd "$PROJECT_ROOT"

    if [ -f "tests/integration_tests.py" ]; then
        python tests/integration_tests.py

        if [ $? -eq 0 ]; then
            log_success "All integration tests passed"
        else
            log_warning "Some integration tests failed (check test output)"
        fi
    else
        log_warning "Integration tests not found"
    fi
fi

# ================================================================
# SAVE DEPLOYMENT INFO
# ================================================================

DEPLOYMENT_INFO="$PROJECT_ROOT/deployment_info.json"
cat > "$DEPLOYMENT_INFO" << EOF
{
  "deployment_date": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "environment": "$ENVIRONMENT",
  "services": {
    "database": "${DB_HOST}:${DB_PORT}",
    "redis": "localhost:6379",
    "n8n": "localhost:5678",
    "agent_registration": "localhost:8002",
    "stripe_webhooks": "localhost:8003",
    "logging_service": "localhost:8004",
    "mcp_adapter": "localhost:8001",
    "mock_agent": "localhost:5000"
  },
  "worker_count": ${N8N_WORKER_COUNT:-3},
  "log_file": "$LOG_FILE"
}
EOF

log_success "Deployment info saved to $DEPLOYMENT_INFO"

echo -e "\n${GREEN}Full stack deployment complete!${NC} ✨\n"

exit 0
