-- ================================================================
-- DarkSpere: Database Connection Pooling Configuration
-- Purpose: Optimize database connections for different workload types
-- Data Flow: Separate connection pools for web, workers, and admin tasks
-- ================================================================

-- ================================================================
-- DATABASE ROLES FOR CONNECTION POOLING
-- Create dedicated roles with specific connection limits
-- ================================================================

-- Web application role (read-heavy, occasional writes)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'darkspere_web') THEN
        CREATE ROLE darkspere_web WITH LOGIN PASSWORD 'CHANGE_ME_WEB_PASSWORD' CONNECTION LIMIT 50;
    END IF;
END
$$;

-- Worker role (heavy writes, session management, queue processing)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'darkspere_worker') THEN
        CREATE ROLE darkspere_worker WITH LOGIN PASSWORD 'CHANGE_ME_WORKER_PASSWORD' CONNECTION LIMIT 100;
    END IF;
END
$$;

-- Admin role (full access, monitoring, manual operations)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'darkspere_admin') THEN
        CREATE ROLE darkspere_admin WITH LOGIN PASSWORD 'CHANGE_ME_ADMIN_PASSWORD' CONNECTION LIMIT 10;
    END IF;
END
$$;

-- ================================================================
-- GRANT PERMISSIONS BY ROLE
-- ================================================================

-- Web role: Read-heavy operations
GRANT CONNECT ON DATABASE postgres TO darkspere_web;
GRANT USAGE ON SCHEMA public TO darkspere_web;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO darkspere_web;
GRANT INSERT ON message_history, permission_usage, webhook_audit_log TO darkspere_web;
GRANT UPDATE ON agent_sessions, rate_limit_tracking TO darkspere_web;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO darkspere_web;

-- Worker role: Full CRUD for workflow processing
GRANT CONNECT ON DATABASE postgres TO darkspere_worker;
GRANT USAGE ON SCHEMA public TO darkspere_worker;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO darkspere_worker;
GRANT DELETE ON rate_limit_tracking, webhook_audit_log TO darkspere_worker; -- Cleanup operations
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO darkspere_worker;

-- Admin role: Full access
GRANT CONNECT ON DATABASE postgres TO darkspere_admin;
GRANT USAGE ON SCHEMA public TO darkspere_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO darkspere_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO darkspere_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO darkspere_admin;

-- ================================================================
-- CONNECTION POOLING CONFIGURATION
-- These settings should be applied in postgresql.conf or via ALTER DATABASE
-- ================================================================

-- Connection limits
COMMENT ON ROLE darkspere_web IS 'Web application connection pool: max 50 connections';
COMMENT ON ROLE darkspere_worker IS 'Worker/n8n connection pool: max 100 connections';
COMMENT ON ROLE darkspere_admin IS 'Admin operations connection pool: max 10 connections';

-- ================================================================
-- POOLING CONFIGURATION TABLE
-- Store connection pool settings for different services
-- ================================================================

CREATE TABLE IF NOT EXISTS connection_pool_config (
    config_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_name VARCHAR(50) UNIQUE NOT NULL,
    db_role VARCHAR(50) NOT NULL,
    min_pool_size INTEGER DEFAULT 5,
    max_pool_size INTEGER DEFAULT 20,
    idle_timeout_seconds INTEGER DEFAULT 300,
    connection_timeout_seconds INTEGER DEFAULT 30,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Insert default configurations
INSERT INTO connection_pool_config (service_name, db_role, min_pool_size, max_pool_size) VALUES
('n8n_webhook', 'darkspere_web', 10, 30),
('n8n_worker', 'darkspere_worker', 20, 80),
('health_monitor', 'darkspere_web', 2, 5),
('admin_dashboard', 'darkspere_admin', 1, 5),
('agent_api', 'darkspere_worker', 10, 40)
ON CONFLICT (service_name) DO NOTHING;

-- ================================================================
-- CONNECTION MONITORING
-- Track active connections per role
-- ================================================================

CREATE VIEW connection_pool_status AS
SELECT
    datname AS database,
    usename AS role,
    COUNT(*) AS active_connections,
    MAX(state) AS connection_state,
    MAX(wait_event_type) AS wait_event
FROM pg_stat_activity
WHERE datname = current_database()
  AND usename IN ('darkspere_web', 'darkspere_worker', 'darkspere_admin')
GROUP BY datname, usename;

-- ================================================================
-- FUNCTIONS FOR POOL MANAGEMENT
-- ================================================================

-- Get recommended pool size based on current load
CREATE OR REPLACE FUNCTION get_recommended_pool_size(p_service_name VARCHAR(50))
RETURNS TABLE(
    current_connections INTEGER,
    recommended_min INTEGER,
    recommended_max INTEGER,
    cpu_count INTEGER
) AS $$
DECLARE
    v_config RECORD;
    v_current_conn INTEGER;
    v_cpu_count INTEGER := 4; -- Default, should be detected from system
BEGIN
    -- Get current configuration
    SELECT * INTO v_config
    FROM connection_pool_config
    WHERE service_name = p_service_name;

    -- Get current connection count
    SELECT COUNT(*) INTO v_current_conn
    FROM pg_stat_activity
    WHERE usename = v_config.db_role
      AND datname = current_database();

    -- Calculate recommendations (2 * CPU cores for min, 4 * CPU cores for max)
    RETURN QUERY SELECT
        v_current_conn,
        v_cpu_count * 2,
        v_cpu_count * 4,
        v_cpu_count;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE connection_pool_config IS 'Connection pool configuration for different services';
COMMENT ON VIEW connection_pool_status IS 'Real-time view of active connections per role';
COMMENT ON FUNCTION get_recommended_pool_size IS 'Calculate optimal pool size based on CPU cores and load';
