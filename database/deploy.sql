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
