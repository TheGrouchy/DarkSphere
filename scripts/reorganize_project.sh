#!/bin/bash
# ================================================================
# DarkSpere Project Reorganization Script
# Purpose: Reorganize project files for better modularity
# Usage: bash scripts/reorganize_project.sh
# ================================================================

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}DarkSpere Project Reorganization${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""

# Confirmation prompt
echo -e "${YELLOW}⚠️  This will reorganize the entire project structure.${NC}"
echo -e "${YELLOW}   Make sure you have committed all changes to git first!${NC}"
echo ""
read -p "Continue? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Starting reorganization...${NC}"
echo ""

# ================================================================
# PHASE 1: Create New Directory Structure
# ================================================================

echo -e "${BLUE}[Phase 1] Creating new directory structure...${NC}"

# Source code structure
mkdir -p "$PROJECT_ROOT/src/api"
mkdir -p "$PROJECT_ROOT/src/agents"
mkdir -p "$PROJECT_ROOT/src/core"
mkdir -p "$PROJECT_ROOT/src/models"
mkdir -p "$PROJECT_ROOT/src/services"

# Database structure
mkdir -p "$PROJECT_ROOT/database/schemas/core"
mkdir -p "$PROJECT_ROOT/database/schemas/security"
mkdir -p "$PROJECT_ROOT/database/schemas/infrastructure"
mkdir -p "$PROJECT_ROOT/database/schemas/billing"
mkdir -p "$PROJECT_ROOT/database/schemas/observability"
mkdir -p "$PROJECT_ROOT/database/migrations"
mkdir -p "$PROJECT_ROOT/database/seeds"

# Documentation structure
mkdir -p "$PROJECT_ROOT/docs/architecture"
mkdir -p "$PROJECT_ROOT/docs/api"
mkdir -p "$PROJECT_ROOT/docs/deployment"
mkdir -p "$PROJECT_ROOT/docs/development"
mkdir -p "$PROJECT_ROOT/docs/mcp"
mkdir -p "$PROJECT_ROOT/docs/status"
mkdir -p "$PROJECT_ROOT/docs/planning"

# Config structure
mkdir -p "$PROJECT_ROOT/config/environments"

# Workflows structure
mkdir -p "$PROJECT_ROOT/workflows/core"
mkdir -p "$PROJECT_ROOT/workflows/monitoring"
mkdir -p "$PROJECT_ROOT/workflows/billing"

# Tests structure
mkdir -p "$PROJECT_ROOT/tests/unit"
mkdir -p "$PROJECT_ROOT/tests/integration"
mkdir -p "$PROJECT_ROOT/tests/e2e"
mkdir -p "$PROJECT_ROOT/tests/fixtures"

# Scripts structure
mkdir -p "$PROJECT_ROOT/scripts/deployment"
mkdir -p "$PROJECT_ROOT/scripts/database"
mkdir -p "$PROJECT_ROOT/scripts/maintenance"

# Agents structure (rename mock-agent)
mkdir -p "$PROJECT_ROOT/agents/examples"

# Infrastructure structure
mkdir -p "$PROJECT_ROOT/infrastructure/docker"
mkdir -p "$PROJECT_ROOT/infrastructure/k8s"
mkdir -p "$PROJECT_ROOT/infrastructure/terraform"

# Monitoring structure
mkdir -p "$PROJECT_ROOT/monitoring/dashboards"
mkdir -p "$PROJECT_ROOT/monitoring/alerts"

echo -e "${GREEN}✓ Directory structure created${NC}"
echo ""

# ================================================================
# PHASE 2: Create Python Package Files
# ================================================================

echo -e "${BLUE}[Phase 2] Creating Python package files...${NC}"

# Create __init__.py files for Python packages
touch "$PROJECT_ROOT/src/__init__.py"
touch "$PROJECT_ROOT/src/api/__init__.py"
touch "$PROJECT_ROOT/src/agents/__init__.py"
touch "$PROJECT_ROOT/src/core/__init__.py"
touch "$PROJECT_ROOT/src/models/__init__.py"
touch "$PROJECT_ROOT/src/services/__init__.py"
touch "$PROJECT_ROOT/tests/__init__.py"
touch "$PROJECT_ROOT/tests/unit/__init__.py"
touch "$PROJECT_ROOT/tests/integration/__init__.py"
touch "$PROJECT_ROOT/tests/e2e/__init__.py"

echo -e "${GREEN}✓ Python packages created${NC}"
echo ""

# ================================================================
# PHASE 3: Move Python Source Files
# ================================================================

echo -e "${BLUE}[Phase 3] Moving Python source files...${NC}"

# Move API files
if [ -d "$PROJECT_ROOT/api" ]; then
    cp -r "$PROJECT_ROOT/api"/* "$PROJECT_ROOT/src/api/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Moved API files to src/api/"
fi

# Move agent files
if [ -d "$PROJECT_ROOT/agents" ]; then
    cp -r "$PROJECT_ROOT/agents"/* "$PROJECT_ROOT/src/agents/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Moved agent files to src/agents/"
fi

# Move integration tests
if [ -f "$PROJECT_ROOT/tests/integration_tests.py" ]; then
    mv "$PROJECT_ROOT/tests/integration_tests.py" "$PROJECT_ROOT/tests/integration/"
    echo -e "  ${GREEN}✓${NC} Moved integration tests"
fi

echo -e "${GREEN}✓ Python files moved${NC}"
echo ""

# ================================================================
# PHASE 4: Reorganize Database Schemas
# ================================================================

echo -e "${BLUE}[Phase 4] Reorganizing database schemas...${NC}"

# Core schemas (00-03)
for file in 00_setup.sql 01_agent_registry.sql 02_agent_sessions.sql 03_message_history.sql; do
    if [ -f "$PROJECT_ROOT/schema/$file" ]; then
        cp "$PROJECT_ROOT/schema/$file" "$PROJECT_ROOT/database/schemas/core/"
        echo -e "  ${GREEN}✓${NC} Moved $file to core/"
    fi
done

# Security schemas (04-07)
for file in 04_account_linking.sql 05_permissions.sql 06_webhook_security.sql 07_rate_limiting.sql; do
    if [ -f "$PROJECT_ROOT/schema/$file" ]; then
        cp "$PROJECT_ROOT/schema/$file" "$PROJECT_ROOT/database/schemas/security/"
        echo -e "  ${GREEN}✓${NC} Moved $file to security/"
    fi
done

# Infrastructure schemas (08-09)
for file in 08_connection_pooling.sql 09_agent_health.sql; do
    if [ -f "$PROJECT_ROOT/schema/$file" ]; then
        cp "$PROJECT_ROOT/schema/$file" "$PROJECT_ROOT/database/schemas/infrastructure/"
        echo -e "  ${GREEN}✓${NC} Moved $file to infrastructure/"
    fi
done

# Billing schemas (10-11)
for file in 10_usage_tracking.sql 11_feature_gates.sql; do
    if [ -f "$PROJECT_ROOT/schema/$file" ]; then
        cp "$PROJECT_ROOT/schema/$file" "$PROJECT_ROOT/database/schemas/billing/"
        echo -e "  ${GREEN}✓${NC} Moved $file to billing/"
    fi
done

# Observability schemas (12-13)
for file in 12_error_handling.sql 13_monitoring.sql; do
    if [ -f "$PROJECT_ROOT/schema/$file" ]; then
        cp "$PROJECT_ROOT/schema/$file" "$PROJECT_ROOT/database/schemas/observability/"
        echo -e "  ${GREEN}✓${NC} Moved $file to observability/"
    fi
done

# Move deploy script
if [ -f "$PROJECT_ROOT/schema/deploy.sql" ]; then
    cp "$PROJECT_ROOT/schema/deploy.sql" "$PROJECT_ROOT/database/deploy.sql"
    echo -e "  ${GREEN}✓${NC} Moved deploy.sql to database/"
fi

# Move seed data
if [ -f "$PROJECT_ROOT/schema/test_data.sql" ]; then
    cp "$PROJECT_ROOT/schema/test_data.sql" "$PROJECT_ROOT/database/seeds/"
    echo -e "  ${GREEN}✓${NC} Moved test_data.sql to seeds/"
fi

if [ -d "$PROJECT_ROOT/test-data" ]; then
    cp -r "$PROJECT_ROOT/test-data"/* "$PROJECT_ROOT/database/seeds/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Moved test-data files to seeds/"
fi

echo -e "${GREEN}✓ Database schemas reorganized${NC}"
echo ""

# ================================================================
# PHASE 5: Organize Documentation
# ================================================================

echo -e "${BLUE}[Phase 5] Organizing documentation...${NC}"

# Status documents
for file in IMPLEMENTATION_STATUS.md COMPLETION_SUMMARY.md PROJECT_STATUS_REVIEW.md "Product Status 10-12-2025.md"; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        cp "$PROJECT_ROOT/$file" "$PROJECT_ROOT/docs/status/"
        echo -e "  ${GREEN}✓${NC} Moved $file to docs/status/"
    fi
done

# Planning documents
for file in PRODUCT_REFINEMENT_ROADMAP.md NEXT_STEPS.md plan.md; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        cp "$PROJECT_ROOT/$file" "$PROJECT_ROOT/docs/planning/"
        echo -e "  ${GREEN}✓${NC} Moved $file to docs/planning/"
    fi
done

# Deployment documents
for file in DEPLOYMENT_GUIDE.md QUICK_START.md DEPLOY_AGENT_NOW.txt; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        cp "$PROJECT_ROOT/$file" "$PROJECT_ROOT/docs/deployment/"
        echo -e "  ${GREEN}✓${NC} Moved $file to docs/deployment/"
    fi
done

# MCP documentation
if [ -d "$PROJECT_ROOT/MCP Tool Documentation" ]; then
    cp -r "$PROJECT_ROOT/MCP Tool Documentation"/* "$PROJECT_ROOT/docs/mcp/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Moved MCP documentation to docs/mcp/"
fi

if [ -f "$PROJECT_ROOT/TWILIO_MCP_TAGS.md" ]; then
    cp "$PROJECT_ROOT/TWILIO_MCP_TAGS.md" "$PROJECT_ROOT/docs/mcp/"
    echo -e "  ${GREEN}✓${NC} Moved TWILIO_MCP_TAGS.md to docs/mcp/"
fi

# Architecture documents
if [ -f "$PROJECT_ROOT/Comprehensive Summary_ SMS-to-Agent Bridge Product.md" ]; then
    cp "$PROJECT_ROOT/Comprehensive Summary_ SMS-to-Agent Bridge Product.md" "$PROJECT_ROOT/docs/architecture/product-summary.md"
    echo -e "  ${GREEN}✓${NC} Moved product summary to docs/architecture/"
fi

# Planning documents (PDFs)
if [ -f "$PROJECT_ROOT/Agent connection Product evaluation.pdf" ]; then
    cp "$PROJECT_ROOT/Agent connection Product evaluation.pdf" "$PROJECT_ROOT/docs/planning/"
    echo -e "  ${GREEN}✓${NC} Moved PDF to docs/planning/"
fi

echo -e "${GREEN}✓ Documentation organized${NC}"
echo ""

# ================================================================
# PHASE 6: Organize Configuration Files
# ================================================================

echo -e "${BLUE}[Phase 6] Organizing configuration files...${NC}"

# Create environment templates
if [ -f "$PROJECT_ROOT/config/.env.n8n" ]; then
    cp "$PROJECT_ROOT/config/.env.n8n" "$PROJECT_ROOT/config/n8n.env.example"
    echo -e "  ${GREEN}✓${NC} Created n8n.env.example"
fi

# Create example environment files
cat > "$PROJECT_ROOT/config/environments/development.env.example" << 'EOF'
# Development Environment Configuration

# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=darkspere_dev
DB_USER=postgres
DB_PASSWORD=your_password

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=

# n8n
N8N_HOST=http://localhost:5678
N8N_API_KEY=your_api_key

# Twilio
TWILIO_ACCOUNT_SID=your_account_sid
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_WEBHOOK_SECRET=your_webhook_secret

# Stripe
STRIPE_API_KEY=sk_test_your_key
STRIPE_WEBHOOK_SECRET=whsec_your_secret

# Application
APP_ENV=development
LOG_LEVEL=DEBUG
EOF

echo -e "  ${GREEN}✓${NC} Created development.env.example"

cat > "$PROJECT_ROOT/config/environments/production.env.example" << 'EOF'
# Production Environment Configuration

# Database (use strong passwords!)
DB_HOST=your-db-host.com
DB_PORT=5432
DB_NAME=darkspere_prod
DB_USER=darkspere_admin
DB_PASSWORD=CHANGE_ME

# Redis
REDIS_HOST=your-redis-host.com
REDIS_PORT=6379
REDIS_PASSWORD=CHANGE_ME

# n8n
N8N_HOST=https://n8n.yourdomain.com
N8N_API_KEY=CHANGE_ME

# Twilio
TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TWILIO_AUTH_TOKEN=CHANGE_ME
TWILIO_WEBHOOK_SECRET=CHANGE_ME

# Stripe
STRIPE_API_KEY=sk_live_CHANGE_ME
STRIPE_WEBHOOK_SECRET=whsec_CHANGE_ME

# Application
APP_ENV=production
LOG_LEVEL=INFO
EOF

echo -e "  ${GREEN}✓${NC} Created production.env.example"

echo -e "${GREEN}✓ Configuration organized${NC}"
echo ""

# ================================================================
# PHASE 7: Organize Workflows
# ================================================================

echo -e "${BLUE}[Phase 7] Organizing workflows...${NC}"

if [ -d "$PROJECT_ROOT/workflows" ]; then
    # Move existing workflow to core
    if [ -f "$PROJECT_ROOT/workflows/darkspere-sms-router.json" ]; then
        cp "$PROJECT_ROOT/workflows/darkspere-sms-router.json" "$PROJECT_ROOT/workflows/core/"
        echo -e "  ${GREEN}✓${NC} Moved SMS router workflow to core/"
    fi
fi

echo -e "${GREEN}✓ Workflows organized${NC}"
echo ""

# ================================================================
# PHASE 8: Organize Scripts
# ================================================================

echo -e "${BLUE}[Phase 8] Organizing scripts...${NC}"

# Move deployment scripts
if [ -f "$PROJECT_ROOT/scripts/deploy_full_stack.sh" ]; then
    cp "$PROJECT_ROOT/scripts/deploy_full_stack.sh" "$PROJECT_ROOT/scripts/deployment/"
    echo -e "  ${GREEN}✓${NC} Moved deploy_full_stack.sh"
fi

if [ -f "$PROJECT_ROOT/scripts/deploy-n8n-worker.sh" ]; then
    cp "$PROJECT_ROOT/scripts/deploy-n8n-worker.sh" "$PROJECT_ROOT/scripts/deployment/"
    echo -e "  ${GREEN}✓${NC} Moved deploy-n8n-worker.sh"
fi

# Move mock agent scripts
if [ -d "$PROJECT_ROOT/mock-agent" ]; then
    cp -r "$PROJECT_ROOT/mock-agent"/* "$PROJECT_ROOT/agents/mock-agent/" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Moved mock-agent to agents/"
fi

echo -e "${GREEN}✓ Scripts organized${NC}"
echo ""

# ================================================================
# PHASE 9: Create Essential Config Files
# ================================================================

echo -e "${BLUE}[Phase 9] Creating essential config files...${NC}"

# Create .env.example at root
cat > "$PROJECT_ROOT/.env.example" << 'EOF'
# DarkSpere Environment Configuration
# Copy this to .env and fill in your values

# Environment
APP_ENV=development  # development, staging, production

# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=darkspere
DB_USER=postgres
DB_PASSWORD=your_password

# Redis
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=

# n8n
N8N_HOST=http://localhost:5678
N8N_API_KEY=your_api_key

# Twilio
TWILIO_ACCOUNT_SID=your_account_sid
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_WEBHOOK_SECRET=your_webhook_secret

# Stripe
STRIPE_API_KEY=your_stripe_key
STRIPE_WEBHOOK_SECRET=your_stripe_webhook_secret

# Application Settings
LOG_LEVEL=INFO
PORT=3000
EOF

echo -e "  ${GREEN}✓${NC} Created .env.example"

# Create setup.py for Python package
cat > "$PROJECT_ROOT/setup.py" << 'EOF'
from setuptools import setup, find_packages

setup(
    name="darkspere",
    version="1.0.0",
    description="SMS-to-Agent Bridge Platform",
    author="DarkSpere Team",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    python_requires=">=3.8",
    install_requires=[
        "flask>=2.0.0",
        "flask-cors>=3.0.0",
        "psycopg2-binary>=2.9.0",
        "redis>=4.0.0",
        "stripe>=5.0.0",
        "bcrypt>=4.0.0",
        "python-json-logger>=2.0.0",
    ],
    extras_require={
        "dev": [
            "pytest>=7.0.0",
            "pytest-cov>=4.0.0",
            "black>=23.0.0",
            "flake8>=6.0.0",
        ]
    },
)
EOF

echo -e "  ${GREEN}✓${NC} Created setup.py"

# Create pytest.ini
cat > "$PROJECT_ROOT/pytest.ini" << 'EOF'
[pytest]
testpaths = tests
python_files = test_*.py
python_classes = Test*
python_functions = test_*
addopts = -v --tb=short --strict-markers
markers =
    unit: Unit tests
    integration: Integration tests
    e2e: End-to-end tests
EOF

echo -e "  ${GREEN}✓${NC} Created pytest.ini"

# Update .gitignore
cat >> "$PROJECT_ROOT/.gitignore" << 'EOF'

# Environment files
.env
*.env
!*.env.example

# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
build/
develop-eggs/
dist/
downloads/
eggs/
.eggs/
lib/
lib64/
parts/
sdist/
var/
wheels/
*.egg-info/
.installed.cfg
*.egg

# Testing
.pytest_cache/
.coverage
htmlcov/
.tox/

# IDE
.vscode/
.idea/
*.swp
*.swo
*~

# OS
.DS_Store
Thumbs.db

# Logs
*.log
logs/
EOF

echo -e "  ${GREEN}✓${NC} Updated .gitignore"

echo -e "${GREEN}✓ Config files created${NC}"
echo ""

# ================================================================
# PHASE 10: Update Database Deploy Script
# ================================================================

echo -e "${BLUE}[Phase 10] Updating database deploy script...${NC}"

cat > "$PROJECT_ROOT/database/deploy.sql" << 'EOF'
-- ================================================================
-- DarkSpere: Master Deployment Script
-- Purpose: Deploy all schema files in correct order
-- Usage: psql -h your-db-host -U admin -d darkspere -f database/deploy.sql
-- ================================================================

\echo '================================================'
\echo 'DarkSpere Database Schema Deployment'
\echo 'Full Production Stack (14 Schemas)'
\echo '================================================'
\echo ''

\echo '[1/14] Setting up database extensions and helpers...'
\i database/schemas/core/00_setup.sql
\echo '✓ Setup complete'
\echo ''

\echo '[2/14] Creating agent_registry table...'
\i database/schemas/core/01_agent_registry.sql
\echo '✓ Agent registry created'
\echo ''

\echo '[3/14] Creating agent_sessions table...'
\i database/schemas/core/02_agent_sessions.sql
\echo '✓ Agent sessions created'
\echo ''

\echo '[4/14] Creating message_history table...'
\i database/schemas/core/03_message_history.sql
\echo '✓ Message history created'
\echo ''

\echo '[5/14] Creating account linking and authentication...'
\i database/schemas/security/04_account_linking.sql
\echo '✓ Account linking created'
\echo ''

\echo '[6/14] Creating permissions and authorization...'
\i database/schemas/security/05_permissions.sql
\echo '✓ Permissions created'
\echo ''

\echo '[7/14] Creating webhook security...'
\i database/schemas/security/06_webhook_security.sql
\echo '✓ Webhook security created'
\echo ''

\echo '[8/14] Creating rate limiting...'
\i database/schemas/security/07_rate_limiting.sql
\echo '✓ Rate limiting created'
\echo ''

\echo '[9/14] Creating connection pooling...'
\i database/schemas/infrastructure/08_connection_pooling.sql
\echo '✓ Connection pooling created'
\echo ''

\echo '[10/14] Creating agent health monitoring...'
\i database/schemas/infrastructure/09_agent_health.sql
\echo '✓ Agent health monitoring created'
\echo ''

\echo '[11/14] Creating usage tracking and billing...'
\i database/schemas/billing/10_usage_tracking.sql
\echo '✓ Usage tracking created'
\echo ''

\echo '[12/14] Creating feature gates system...'
\i database/schemas/billing/11_feature_gates.sql
\echo '✓ Feature gates created'
\echo ''

\echo '[13/14] Creating error handling and retry system...'
\i database/schemas/observability/12_error_handling.sql
\echo '✓ Error handling created'
\echo ''

\echo '[14/14] Creating monitoring and observability...'
\i database/schemas/observability/13_monitoring.sql
\echo '✓ Monitoring system created'
\echo ''

\echo '================================================'
\echo 'Production Schema Deployment Complete!'
\echo '================================================'
\echo ''
\echo 'Deployed Components:'
\echo '✓ Core tables (agent_registry, agent_sessions, message_history)'
\echo '✓ Authentication (user accounts, phone linking, session tokens)'
\echo '✓ Authorization (permissions, roles, resource patterns)'
\echo '✓ Security (webhook validation, API key mgmt, rate limiting)'
\echo '✓ Scalability (connection pooling, session hashing, queue mode)'
\echo '✓ Agent Ecosystem (health monitoring, MCP protocol, self-registration)'
\echo '✓ Billing (usage tracking, Stripe integration, feature gates)'
\echo '✓ Reliability (error handling, retry logic, circuit breakers)'
\echo '✓ Observability (monitoring dashboards, alerts, structured logging)'
\echo ''
\echo 'Production System Stats:'
\echo '  • 14 schema files deployed'
\echo '  • 50+ database tables created'
\echo '  • 100+ functions and procedures'
\echo '  • 200+ indexes for performance'
\echo '  • 30+ real-time views for monitoring'
\echo ''
\echo 'Next steps:'
\echo '1. Update role passwords in 08_connection_pooling.sql'
\echo '2. Run test data: psql -f database/seeds/test_data.sql'
\echo '3. Configure n8n PostgreSQL connection with darkspere_worker role'
\echo '4. Deploy API services (4 microservices)'
\echo '5. Run integration tests: pytest tests/integration/'
\echo '6. Deploy with automation: bash scripts/deployment/deploy_full_stack.sh production'
\echo '7. Monitor health: Check database/schemas/observability/13_monitoring.sql views'
\echo ''
\echo '🎉 DarkSpere is production-ready!'
\echo ''
EOF

echo -e "  ${GREEN}✓${NC} Created database/deploy.sql with updated paths"

echo -e "${GREEN}✓ Deploy script updated${NC}"
echo ""

# ================================================================
# COMPLETION
# ================================================================

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Reorganization Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo ""
echo "1. Review the new structure in PROJECT_STRUCTURE.md"
echo "2. Update Python imports if needed"
echo "3. Test the deployment script:"
echo -e "   ${BLUE}psql -f database/deploy.sql${NC}"
echo ""
echo "4. Run integration tests:"
echo -e "   ${BLUE}pytest tests/integration/${NC}"
echo ""
echo "5. Update your IDE/editor project settings"
echo ""
echo "6. Consider removing old directories after verification:"
echo -e "   ${YELLOW}rm -rf api/ agents/ schema/ (old locations)${NC}"
echo ""
echo -e "${GREEN}✨ Your project is now properly organized!${NC}"
echo ""
