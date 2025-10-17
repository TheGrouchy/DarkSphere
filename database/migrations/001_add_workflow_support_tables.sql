-- ================================================================
-- DarkSpere: Workflow Support Tables Migration
-- Purpose: Add tables required by the comprehensive n8n workflow suite
-- Version: 1.0
-- Created: 2025-10-16
-- ================================================================

-- ================================================================
-- BILLING DOMAIN: Usage Records Table
-- ================================================================

CREATE TABLE IF NOT EXISTS usage_records (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Foreign keys
    agent_id UUID NOT NULL REFERENCES agent_registry(agent_id) ON DELETE CASCADE,
    subscription_id TEXT, -- Stripe subscription item ID

    -- Usage period
    period_start TIMESTAMP NOT NULL,
    period_end TIMESTAMP NOT NULL,

    -- Message counts
    message_count INTEGER NOT NULL DEFAULT 0,
    inbound_count INTEGER DEFAULT 0,
    outbound_count INTEGER DEFAULT 0,

    -- Billing
    total_cost DECIMAL(10,4) DEFAULT 0.0000,
    stripe_reported BOOLEAN DEFAULT FALSE,
    stripe_usage_record_id TEXT,

    -- Metadata
    metadata JSONB DEFAULT '{}',

    -- Timestamps
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    -- Constraints
    CONSTRAINT unique_agent_period UNIQUE (agent_id, period_start),
    CONSTRAINT valid_period CHECK (period_end > period_start),
    CONSTRAINT positive_message_count CHECK (message_count >= 0)
);

-- Indexes for usage records
CREATE INDEX idx_usage_records_agent ON usage_records(agent_id, period_start DESC);
CREATE INDEX idx_usage_records_unreported ON usage_records(stripe_reported, created_at) WHERE stripe_reported = FALSE;
CREATE INDEX idx_usage_records_subscription ON usage_records(subscription_id, period_start DESC) WHERE subscription_id IS NOT NULL;

COMMENT ON TABLE usage_records IS 'Hourly message usage aggregation for billing and analytics';
COMMENT ON COLUMN usage_records.stripe_reported IS 'TRUE if usage has been reported to Stripe metered billing';

-- ================================================================
-- OBSERVABILITY DOMAIN: Maintenance Logs Table
-- ================================================================

CREATE TABLE IF NOT EXISTS maintenance_logs (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Task information
    task_type VARCHAR(50) NOT NULL,
    details JSONB DEFAULT '{}',
    metrics JSONB DEFAULT '{}',

    -- Timing
    completed_at TIMESTAMP DEFAULT NOW(),

    -- Status
    success BOOLEAN DEFAULT TRUE,
    error_message TEXT
);

-- Indexes for maintenance logs
CREATE INDEX idx_maintenance_logs_type ON maintenance_logs(task_type, completed_at DESC);
CREATE INDEX idx_maintenance_logs_completed ON maintenance_logs(completed_at DESC);

COMMENT ON TABLE maintenance_logs IS 'Logs for database maintenance and cleanup operations';
COMMENT ON COLUMN maintenance_logs.metrics IS 'JSONB object with table sizes and cleanup statistics';

-- ================================================================
-- OBSERVABILITY DOMAIN: Test Results Table
-- ================================================================

CREATE TABLE IF NOT EXISTS test_results (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Test information
    test_type VARCHAR(50) NOT NULL,
    test_name VARCHAR(100),
    agent_id UUID REFERENCES agent_registry(agent_id) ON DELETE SET NULL,

    -- Test outcome
    status VARCHAR(20) NOT NULL CHECK (status IN ('success', 'failure', 'error', 'timeout')),
    response_time_ms INTEGER DEFAULT 0,
    error_message TEXT,

    -- Test data
    test_data JSONB DEFAULT '{}',

    -- Timing
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for test results
CREATE INDEX idx_test_results_type ON test_results(test_type, created_at DESC);
CREATE INDEX idx_test_results_agent ON test_results(agent_id, created_at DESC) WHERE agent_id IS NOT NULL;
CREATE INDEX idx_test_results_status ON test_results(status, created_at DESC);

COMMENT ON TABLE test_results IS 'MCP protocol and agent communication test results';
COMMENT ON COLUMN test_results.test_data IS 'JSONB object with complete test request/response data';

-- ================================================================
-- OBSERVABILITY DOMAIN: Analytics Snapshots Table
-- ================================================================

CREATE TABLE IF NOT EXISTS analytics_snapshots (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Snapshot metadata
    snapshot_type VARCHAR(50) NOT NULL,
    metrics JSONB NOT NULL,

    -- Timing
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for analytics snapshots
CREATE INDEX idx_analytics_snapshots_type_time ON analytics_snapshots(snapshot_type, created_at DESC);
CREATE INDEX idx_analytics_snapshots_recent ON analytics_snapshots(created_at DESC);

-- Partitioning for analytics (optional, for high-volume deployments)
-- CREATE TABLE analytics_snapshots_y2025m10 PARTITION OF analytics_snapshots
--     FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

COMMENT ON TABLE analytics_snapshots IS 'Real-time system metrics snapshots for dashboards and alerting';
COMMENT ON COLUMN analytics_snapshots.metrics IS 'JSONB object with sessions, messages, agents, and health metrics';

-- ================================================================
-- OBSERVABILITY DOMAIN: System Alerts Table
-- ================================================================

CREATE TABLE IF NOT EXISTS system_alerts (
    -- Primary identifier
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Alert information
    alert_type VARCHAR(50) NOT NULL,
    severity VARCHAR(20) NOT NULL CHECK (severity IN ('info', 'warning', 'error', 'critical')),
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    details JSONB DEFAULT '{}',

    -- Alert lifecycle
    acknowledged BOOLEAN DEFAULT FALSE,
    acknowledged_at TIMESTAMP,
    acknowledged_by TEXT,
    resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMP,

    -- Timing
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for system alerts
CREATE INDEX idx_system_alerts_unacknowledged ON system_alerts(acknowledged, created_at DESC) WHERE acknowledged = FALSE;
CREATE INDEX idx_system_alerts_type ON system_alerts(alert_type, created_at DESC);
CREATE INDEX idx_system_alerts_severity ON system_alerts(severity, created_at DESC);

COMMENT ON TABLE system_alerts IS 'Automated system alerts for health, capacity, and performance issues';
COMMENT ON COLUMN system_alerts.details IS 'JSONB object with alert-specific diagnostic information';

-- ================================================================
-- TRIGGERS FOR AUTOMATIC TIMESTAMP UPDATES
-- ================================================================

-- Update timestamp for usage_records
CREATE OR REPLACE FUNCTION update_usage_records_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_usage_records_timestamp
BEFORE UPDATE ON usage_records
FOR EACH ROW
EXECUTE FUNCTION update_usage_records_timestamp();

-- ================================================================
-- VIEWS FOR WORKFLOW SUPPORT
-- ================================================================

-- View: Unreported Usage (for billing workflow)
CREATE OR REPLACE VIEW unreported_usage AS
SELECT
    ur.id,
    ur.agent_id,
    a.agent_name,
    a.stripe_customer_id,
    ur.subscription_id,
    ur.period_start,
    ur.period_end,
    ur.message_count,
    ur.total_cost,
    ur.created_at
FROM usage_records ur
JOIN agent_registry a ON ur.agent_id = a.agent_id
WHERE ur.stripe_reported = FALSE
  AND ur.subscription_id IS NOT NULL
ORDER BY ur.created_at;

COMMENT ON VIEW unreported_usage IS 'Usage records pending Stripe metered billing report';

-- View: Recent Alerts (for dashboard)
CREATE OR REPLACE VIEW recent_alerts AS
SELECT
    id,
    alert_type,
    severity,
    title,
    message,
    acknowledged,
    created_at,
    EXTRACT(EPOCH FROM (NOW() - created_at)) AS age_seconds
FROM system_alerts
WHERE created_at >= NOW() - INTERVAL '24 hours'
ORDER BY
    CASE severity
        WHEN 'critical' THEN 1
        WHEN 'error' THEN 2
        WHEN 'warning' THEN 3
        WHEN 'info' THEN 4
    END,
    created_at DESC;

COMMENT ON VIEW recent_alerts IS 'System alerts from the last 24 hours, ordered by severity';

-- View: Test Summary (for test dashboard)
CREATE OR REPLACE VIEW test_summary AS
SELECT
    test_type,
    COUNT(*) as total_tests,
    SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) as successful_tests,
    SUM(CASE WHEN status = 'failure' THEN 1 ELSE 0 END) as failed_tests,
    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_tests,
    SUM(CASE WHEN status = 'timeout' THEN 1 ELSE 0 END) as timeout_tests,
    AVG(response_time_ms) as avg_response_time_ms,
    MAX(created_at) as last_test_at
FROM test_results
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY test_type
ORDER BY last_test_at DESC;

COMMENT ON VIEW test_summary IS 'Test execution summary for the last 7 days';

-- ================================================================
-- UTILITY FUNCTIONS FOR WORKFLOWS
-- ================================================================

-- Function: Get latest metrics snapshot
CREATE OR REPLACE FUNCTION get_latest_metrics(p_snapshot_type VARCHAR(50) DEFAULT NULL)
RETURNS TABLE (
    snapshot_type VARCHAR(50),
    metrics JSONB,
    created_at TIMESTAMP
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.snapshot_type,
        a.metrics,
        a.created_at
    FROM analytics_snapshots a
    WHERE (p_snapshot_type IS NULL OR a.snapshot_type = p_snapshot_type)
    ORDER BY a.created_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION get_latest_metrics IS 'Retrieve the most recent analytics snapshot';

-- Function: Acknowledge alert
CREATE OR REPLACE FUNCTION acknowledge_alert(
    p_alert_id UUID,
    p_acknowledged_by TEXT DEFAULT 'system'
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE system_alerts
    SET acknowledged = TRUE,
        acknowledged_at = NOW(),
        acknowledged_by = p_acknowledged_by
    WHERE id = p_alert_id
      AND acknowledged = FALSE;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION acknowledge_alert IS 'Mark a system alert as acknowledged';

-- Function: Cleanup old analytics snapshots
CREATE OR REPLACE FUNCTION cleanup_old_analytics(p_retention_days INTEGER DEFAULT 90)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM analytics_snapshots
    WHERE created_at < NOW() - (p_retention_days || ' days')::INTERVAL;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION cleanup_old_analytics IS 'Delete analytics snapshots older than specified retention period';

-- ================================================================
-- SAMPLE DATA FOR TESTING (Optional - comment out for production)
-- ================================================================

-- Uncomment to insert sample test results:
-- INSERT INTO test_results (test_type, test_name, status, response_time_ms, test_data)
-- VALUES
--     ('mcp_agent_test', 'MCP Protocol Validation', 'success', 250, '{"message": "Test passed"}'),
--     ('health_check', 'Agent Health Check', 'success', 75, '{"endpoint": "https://agent.example.com/health"}');

-- ================================================================
-- MIGRATION COMPLETION LOG
-- ================================================================

INSERT INTO maintenance_logs (task_type, details, completed_at)
VALUES (
    'schema_migration',
    jsonb_build_object(
        'migration_name', '001_add_workflow_support_tables',
        'tables_created', ARRAY['usage_records', 'maintenance_logs', 'test_results', 'analytics_snapshots', 'system_alerts'],
        'views_created', ARRAY['unreported_usage', 'recent_alerts', 'test_summary'],
        'functions_created', ARRAY['get_latest_metrics', 'acknowledge_alert', 'cleanup_old_analytics']
    ),
    NOW()
);

-- ================================================================
-- VERIFICATION QUERIES
-- ================================================================

-- Run these queries to verify migration success:

-- SELECT 'Migration completed successfully!' AS status;

-- SELECT tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size
-- FROM pg_tables
-- WHERE schemaname = 'public'
--   AND tablename IN ('usage_records', 'maintenance_logs', 'test_results', 'analytics_snapshots', 'system_alerts')
-- ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;

-- SELECT viewname FROM pg_views
-- WHERE schemaname = 'public'
--   AND viewname IN ('unreported_usage', 'recent_alerts', 'test_summary');

-- ================================================================
-- END OF MIGRATION
-- ================================================================
