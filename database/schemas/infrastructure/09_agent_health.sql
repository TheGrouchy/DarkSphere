-- ================================================================
-- DarkSpere: Agent Health Monitoring System
-- Purpose: Automated health checks, response time tracking, auto-failover
-- Data Flow: Health probe → Status update → Load balancer decision
-- ================================================================

-- ================================================================
-- HEALTH STATUS ENUM
-- Define possible agent health states
-- ================================================================

CREATE TYPE agent_health_status AS ENUM (
    'healthy',      -- Agent responding normally
    'degraded',     -- Slow responses but functional
    'unhealthy',    -- Failing health checks
    'unreachable',  -- Cannot connect to agent
    'maintenance'   -- Manually set offline
);

-- ================================================================
-- AGENT HEALTH CHECKS TABLE
-- Track health check results over time
-- ================================================================

CREATE TABLE IF NOT EXISTS agent_health_checks (
    -- Primary identifier
    check_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Agent reference
    agent_id UUID NOT NULL REFERENCES agent_registry(agent_id) ON DELETE CASCADE,

    -- Health check details
    check_timestamp TIMESTAMP DEFAULT NOW(),
    health_status agent_health_status NOT NULL,

    -- Performance metrics
    response_time_ms INTEGER, -- NULL if unreachable
    status_code INTEGER, -- HTTP status code

    -- Health check metadata
    check_type VARCHAR(50) DEFAULT 'http_probe', -- http_probe, tcp_probe, custom
    endpoint_checked TEXT, -- URL or endpoint that was checked
    error_message TEXT, -- Error details if unhealthy

    -- Context
    check_metadata JSONB DEFAULT '{}', -- Additional check details
    consecutive_failures INTEGER DEFAULT 0, -- Track failure streak

    -- Auto-generated fields
    is_auto_check BOOLEAN DEFAULT TRUE -- FALSE if manual health check
);

-- ================================================================
-- AGENT HEALTH SUMMARY TABLE
-- Current health state for each agent (materialized view alternative)
-- ================================================================

CREATE TABLE IF NOT EXISTS agent_health_summary (
    -- Agent reference (primary key)
    agent_id UUID PRIMARY KEY REFERENCES agent_registry(agent_id) ON DELETE CASCADE,

    -- Current health status
    current_status agent_health_status DEFAULT 'healthy',
    last_check_timestamp TIMESTAMP DEFAULT NOW(),

    -- Performance metrics (rolling averages)
    avg_response_time_ms INTEGER, -- Last 10 checks
    p95_response_time_ms INTEGER, -- 95th percentile
    p99_response_time_ms INTEGER, -- 99th percentile

    -- Availability metrics
    total_checks INTEGER DEFAULT 0,
    successful_checks INTEGER DEFAULT 0,
    failed_checks INTEGER DEFAULT 0,
    uptime_percentage DECIMAL(5,2) DEFAULT 100.00,

    -- Failure tracking
    consecutive_failures INTEGER DEFAULT 0,
    last_failure_timestamp TIMESTAMP,
    last_success_timestamp TIMESTAMP,

    -- Auto-recovery tracking
    auto_disabled_at TIMESTAMP, -- When agent was auto-disabled
    auto_disabled_reason TEXT,
    manual_override BOOLEAN DEFAULT FALSE, -- Admin manually set status

    -- Health score (0-100)
    health_score INTEGER DEFAULT 100,

    -- Metadata
    last_updated TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- HEALTH CHECK CONFIGURATION TABLE
-- Define health check intervals and thresholds per agent
-- ================================================================

CREATE TABLE IF NOT EXISTS agent_health_config (
    -- Agent reference
    agent_id UUID PRIMARY KEY REFERENCES agent_registry(agent_id) ON DELETE CASCADE,

    -- Check intervals
    check_interval_seconds INTEGER DEFAULT 30, -- How often to check
    timeout_seconds INTEGER DEFAULT 10, -- Request timeout

    -- Failure thresholds
    max_consecutive_failures INTEGER DEFAULT 3, -- Disable after N failures
    degraded_response_threshold_ms INTEGER DEFAULT 1000, -- Mark degraded if > 1s
    unhealthy_response_threshold_ms INTEGER DEFAULT 3000, -- Mark unhealthy if > 3s

    -- Auto-recovery settings
    auto_disable_on_failure BOOLEAN DEFAULT TRUE,
    auto_enable_on_recovery BOOLEAN DEFAULT TRUE,
    recovery_checks_required INTEGER DEFAULT 3, -- Consecutive successes to recover

    -- Health check method
    health_endpoint TEXT DEFAULT '/health', -- Endpoint to check
    expected_status_code INTEGER DEFAULT 200,
    expected_response_contains TEXT, -- Optional: response must contain this string

    -- Alerting
    alert_on_failure BOOLEAN DEFAULT TRUE,
    alert_webhook_url TEXT, -- Send alerts to this webhook

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- INDEXES FOR FAST HEALTH LOOKUPS
-- ================================================================

-- Health check history by agent
CREATE INDEX idx_health_checks_agent ON agent_health_checks(agent_id, check_timestamp DESC);

-- Recent health checks (for monitoring dashboards)
CREATE INDEX idx_health_checks_recent ON agent_health_checks(check_timestamp DESC)
WHERE check_timestamp > NOW() - INTERVAL '1 hour';

-- Failed health checks
CREATE INDEX idx_health_checks_failures ON agent_health_checks(agent_id, health_status)
WHERE health_status IN ('unhealthy', 'unreachable');

-- Agent health summary lookup
CREATE INDEX idx_health_summary_status ON agent_health_summary(current_status, last_check_timestamp DESC);

-- ================================================================
-- TRIGGERS FOR AUTO-UPDATING HEALTH SUMMARY
-- ================================================================

-- Update health summary after each health check
CREATE OR REPLACE FUNCTION update_health_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_total_checks INTEGER;
    v_successful_checks INTEGER;
    v_failed_checks INTEGER;
    v_uptime_pct DECIMAL(5,2);
    v_avg_response_ms INTEGER;
    v_p95_response_ms INTEGER;
    v_p99_response_ms INTEGER;
    v_consecutive_failures INTEGER;
    v_health_score INTEGER;
BEGIN
    -- Calculate metrics from recent health checks (last 100 checks or 24 hours)
    SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE health_status = 'healthy') AS successful,
        COUNT(*) FILTER (WHERE health_status IN ('unhealthy', 'unreachable')) AS failed,
        ROUND(AVG(response_time_ms))::INTEGER AS avg_ms,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY response_time_ms)::INTEGER AS p95_ms,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY response_time_ms)::INTEGER AS p99_ms
    INTO
        v_total_checks,
        v_successful_checks,
        v_failed_checks,
        v_avg_response_ms,
        v_p95_response_ms,
        v_p99_response_ms
    FROM agent_health_checks
    WHERE agent_id = NEW.agent_id
      AND check_timestamp > NOW() - INTERVAL '24 hours'
    LIMIT 100;

    -- Calculate uptime percentage
    IF v_total_checks > 0 THEN
        v_uptime_pct := ROUND((v_successful_checks::DECIMAL / v_total_checks::DECIMAL) * 100, 2);
    ELSE
        v_uptime_pct := 100.00;
    END IF;

    -- Calculate consecutive failures
    SELECT COUNT(*)
    INTO v_consecutive_failures
    FROM (
        SELECT health_status
        FROM agent_health_checks
        WHERE agent_id = NEW.agent_id
        ORDER BY check_timestamp DESC
        LIMIT 10
    ) recent
    WHERE health_status IN ('unhealthy', 'unreachable');

    -- Calculate health score (0-100)
    -- Based on: uptime (60%), response time (30%), consecutive failures (10%)
    v_health_score := LEAST(100, GREATEST(0,
        (v_uptime_pct * 0.6)::INTEGER +
        (CASE
            WHEN v_avg_response_ms IS NULL THEN 0
            WHEN v_avg_response_ms < 500 THEN 30
            WHEN v_avg_response_ms < 1000 THEN 20
            WHEN v_avg_response_ms < 2000 THEN 10
            ELSE 0
        END) +
        (CASE
            WHEN v_consecutive_failures = 0 THEN 10
            WHEN v_consecutive_failures = 1 THEN 7
            WHEN v_consecutive_failures = 2 THEN 3
            ELSE 0
        END)
    ));

    -- Upsert health summary
    INSERT INTO agent_health_summary (
        agent_id,
        current_status,
        last_check_timestamp,
        avg_response_time_ms,
        p95_response_time_ms,
        p99_response_time_ms,
        total_checks,
        successful_checks,
        failed_checks,
        uptime_percentage,
        consecutive_failures,
        last_failure_timestamp,
        last_success_timestamp,
        health_score,
        last_updated
    ) VALUES (
        NEW.agent_id,
        NEW.health_status,
        NEW.check_timestamp,
        v_avg_response_ms,
        v_p95_response_ms,
        v_p99_response_ms,
        v_total_checks,
        v_successful_checks,
        v_failed_checks,
        v_uptime_pct,
        v_consecutive_failures,
        CASE WHEN NEW.health_status IN ('unhealthy', 'unreachable') THEN NEW.check_timestamp ELSE NULL END,
        CASE WHEN NEW.health_status = 'healthy' THEN NEW.check_timestamp ELSE NULL END,
        v_health_score,
        NOW()
    )
    ON CONFLICT (agent_id) DO UPDATE
    SET current_status = NEW.health_status,
        last_check_timestamp = NEW.check_timestamp,
        avg_response_time_ms = v_avg_response_ms,
        p95_response_time_ms = v_p95_response_ms,
        p99_response_time_ms = v_p99_response_ms,
        total_checks = v_total_checks,
        successful_checks = v_successful_checks,
        failed_checks = v_failed_checks,
        uptime_percentage = v_uptime_pct,
        consecutive_failures = v_consecutive_failures,
        last_failure_timestamp = COALESCE(
            CASE WHEN NEW.health_status IN ('unhealthy', 'unreachable') THEN NEW.check_timestamp END,
            agent_health_summary.last_failure_timestamp
        ),
        last_success_timestamp = COALESCE(
            CASE WHEN NEW.health_status = 'healthy' THEN NEW.check_timestamp END,
            agent_health_summary.last_success_timestamp
        ),
        health_score = v_health_score,
        last_updated = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_health_summary
AFTER INSERT ON agent_health_checks
FOR EACH ROW
EXECUTE FUNCTION update_health_summary();

-- Auto-disable agent after max consecutive failures
CREATE OR REPLACE FUNCTION auto_disable_unhealthy_agent()
RETURNS TRIGGER AS $$
DECLARE
    v_max_failures INTEGER;
    v_auto_disable BOOLEAN;
BEGIN
    -- Get health config
    SELECT max_consecutive_failures, auto_disable_on_failure
    INTO v_max_failures, v_auto_disable
    FROM agent_health_config
    WHERE agent_id = NEW.agent_id;

    -- Default values if no config
    v_max_failures := COALESCE(v_max_failures, 3);
    v_auto_disable := COALESCE(v_auto_disable, TRUE);

    -- Check if should auto-disable
    IF v_auto_disable AND NEW.consecutive_failures >= v_max_failures THEN
        -- Update agent status to inactive
        UPDATE agent_registry
        SET status = 'inactive',
            last_error = format('Auto-disabled: %s consecutive health check failures', NEW.consecutive_failures),
            last_seen = NOW()
        WHERE agent_id = NEW.agent_id;

        -- Record auto-disable in health summary
        UPDATE agent_health_summary
        SET auto_disabled_at = NOW(),
            auto_disabled_reason = format('%s consecutive failures', NEW.consecutive_failures)
        WHERE agent_id = NEW.agent_id;

        -- TODO: Send alert webhook (implement in separate function)
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_auto_disable_agent
AFTER UPDATE ON agent_health_summary
FOR EACH ROW
WHEN (NEW.consecutive_failures >= 3)
EXECUTE FUNCTION auto_disable_unhealthy_agent();

-- ================================================================
-- HEALTH CHECK FUNCTIONS
-- ================================================================

-- Record a health check result
CREATE OR REPLACE FUNCTION record_health_check(
    p_agent_id UUID,
    p_health_status agent_health_status,
    p_response_time_ms INTEGER DEFAULT NULL,
    p_status_code INTEGER DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL,
    p_check_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_check_id UUID;
    v_consecutive_failures INTEGER := 0;
BEGIN
    -- Get current consecutive failures
    SELECT consecutive_failures INTO v_consecutive_failures
    FROM agent_health_summary
    WHERE agent_id = p_agent_id;

    -- Update consecutive failures
    IF p_health_status IN ('unhealthy', 'unreachable') THEN
        v_consecutive_failures := COALESCE(v_consecutive_failures, 0) + 1;
    ELSE
        v_consecutive_failures := 0;
    END IF;

    -- Insert health check record
    INSERT INTO agent_health_checks (
        agent_id,
        health_status,
        response_time_ms,
        status_code,
        error_message,
        check_metadata,
        consecutive_failures
    ) VALUES (
        p_agent_id,
        p_health_status,
        p_response_time_ms,
        p_status_code,
        p_error_message,
        p_check_metadata,
        v_consecutive_failures
    ) RETURNING check_id INTO v_check_id;

    RETURN v_check_id;
END;
$$ LANGUAGE plpgsql;

-- Get healthy agents for load balancing
CREATE OR REPLACE FUNCTION get_healthy_agents(
    p_agent_type VARCHAR(50) DEFAULT NULL,
    p_min_health_score INTEGER DEFAULT 70
)
RETURNS TABLE (
    agent_id UUID,
    agent_name VARCHAR(100),
    agent_type VARCHAR(50),
    endpoint_url TEXT,
    current_sessions INTEGER,
    max_concurrent_sessions INTEGER,
    health_score INTEGER,
    avg_response_time_ms INTEGER,
    uptime_percentage DECIMAL(5,2)
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ar.agent_id,
        ar.agent_name,
        ar.agent_type,
        ar.endpoint_url,
        ar.current_sessions,
        ar.max_concurrent_sessions,
        ahs.health_score,
        ahs.avg_response_time_ms,
        ahs.uptime_percentage
    FROM agent_registry ar
    JOIN agent_health_summary ahs ON ar.agent_id = ahs.agent_id
    WHERE ar.status = 'active'
      AND ahs.current_status = 'healthy'
      AND ahs.health_score >= p_min_health_score
      AND ar.current_sessions < ar.max_concurrent_sessions
      AND (p_agent_type IS NULL OR ar.agent_type = p_agent_type)
    ORDER BY
        ahs.health_score DESC,
        ar.current_sessions ASC,
        ahs.avg_response_time_ms ASC
    LIMIT 10;
END;
$$ LANGUAGE plpgsql;

-- Manually set agent health status (admin override)
CREATE OR REPLACE FUNCTION set_agent_health_status(
    p_agent_id UUID,
    p_status agent_health_status,
    p_reason TEXT DEFAULT 'Manual override'
)
RETURNS BOOLEAN AS $$
BEGIN
    -- Update health summary
    UPDATE agent_health_summary
    SET current_status = p_status,
        manual_override = TRUE,
        last_updated = NOW()
    WHERE agent_id = p_agent_id;

    -- Record manual health check
    PERFORM record_health_check(
        p_agent_id,
        p_status,
        NULL,
        NULL,
        p_reason,
        jsonb_build_object('manual', TRUE, 'reason', p_reason)
    );

    -- Update agent registry status if needed
    IF p_status = 'maintenance' THEN
        UPDATE agent_registry
        SET status = 'inactive'
        WHERE agent_id = p_agent_id;
    ELSIF p_status = 'healthy' THEN
        UPDATE agent_registry
        SET status = 'active',
            last_error = NULL
        WHERE agent_id = p_agent_id;
    END IF;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Get agent health history
CREATE OR REPLACE FUNCTION get_agent_health_history(
    p_agent_id UUID,
    p_hours INTEGER DEFAULT 24
)
RETURNS TABLE (
    check_timestamp TIMESTAMP,
    health_status agent_health_status,
    response_time_ms INTEGER,
    error_message TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ahc.check_timestamp,
        ahc.health_status,
        ahc.response_time_ms,
        ahc.error_message
    FROM agent_health_checks ahc
    WHERE ahc.agent_id = p_agent_id
      AND ahc.check_timestamp > NOW() - (p_hours || ' hours')::INTERVAL
    ORDER BY ahc.check_timestamp DESC;
END;
$$ LANGUAGE plpgsql;

-- Initialize health config for new agent
CREATE OR REPLACE FUNCTION initialize_agent_health_config()
RETURNS TRIGGER AS $$
BEGIN
    -- Create default health config for new agent
    INSERT INTO agent_health_config (agent_id)
    VALUES (NEW.agent_id)
    ON CONFLICT (agent_id) DO NOTHING;

    -- Create initial health summary
    INSERT INTO agent_health_summary (agent_id, current_status)
    VALUES (NEW.agent_id, 'healthy')
    ON CONFLICT (agent_id) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_init_agent_health
AFTER INSERT ON agent_registry
FOR EACH ROW
EXECUTE FUNCTION initialize_agent_health_config();

-- ================================================================
-- VIEWS FOR MONITORING
-- ================================================================

-- Agent health dashboard view
CREATE OR REPLACE VIEW agent_health_dashboard AS
SELECT
    ar.agent_id,
    ar.agent_name,
    ar.agent_type,
    ar.endpoint_url,
    ar.status AS agent_status,
    ahs.current_status AS health_status,
    ahs.health_score,
    ahs.avg_response_time_ms,
    ahs.p95_response_time_ms,
    ahs.uptime_percentage,
    ahs.consecutive_failures,
    ahs.last_check_timestamp,
    ahs.last_failure_timestamp,
    ahs.last_success_timestamp,
    ar.current_sessions,
    ar.max_concurrent_sessions,
    ROUND((ar.current_sessions::DECIMAL / NULLIF(ar.max_concurrent_sessions, 0)::DECIMAL) * 100, 2) AS capacity_percentage,
    EXTRACT(EPOCH FROM (NOW() - ahs.last_check_timestamp)) AS seconds_since_last_check,
    ahc.check_interval_seconds
FROM agent_registry ar
LEFT JOIN agent_health_summary ahs ON ar.agent_id = ahs.agent_id
LEFT JOIN agent_health_config ahc ON ar.agent_id = ahc.agent_id
ORDER BY ahs.health_score DESC NULLS LAST, ar.agent_name;

-- Unhealthy agents view (for alerts)
CREATE OR REPLACE VIEW unhealthy_agents AS
SELECT
    ar.agent_id,
    ar.agent_name,
    ar.agent_type,
    ahs.current_status,
    ahs.consecutive_failures,
    ahs.last_failure_timestamp,
    ahs.last_check_timestamp,
    ahs.auto_disabled_at,
    ahs.auto_disabled_reason
FROM agent_registry ar
JOIN agent_health_summary ahs ON ar.agent_id = ahs.agent_id
WHERE ahs.current_status IN ('unhealthy', 'unreachable', 'degraded')
   OR ahs.consecutive_failures > 0
ORDER BY ahs.consecutive_failures DESC, ahs.last_failure_timestamp DESC;

-- ================================================================
-- CLEANUP FUNCTION
-- Delete old health checks (keep last 7 days)
-- ================================================================

CREATE OR REPLACE FUNCTION cleanup_old_health_checks()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM agent_health_checks
    WHERE check_timestamp < NOW() - INTERVAL '7 days';

    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- COMMENTS FOR DOCUMENTATION
-- ================================================================

COMMENT ON TABLE agent_health_checks IS 'Health check history for all agents with response times and error details';
COMMENT ON TABLE agent_health_summary IS 'Current health status and metrics for each agent (materialized summary)';
COMMENT ON TABLE agent_health_config IS 'Health check configuration per agent (intervals, thresholds, auto-recovery)';

COMMENT ON FUNCTION record_health_check IS 'Record a health check result and update agent health metrics';
COMMENT ON FUNCTION get_healthy_agents IS 'Get list of healthy agents for load balancing (filtered by health score)';
COMMENT ON FUNCTION set_agent_health_status IS 'Manually set agent health status (admin override)';
COMMENT ON FUNCTION get_agent_health_history IS 'Get health check history for an agent over specified hours';
COMMENT ON FUNCTION cleanup_old_health_checks IS 'Delete health checks older than 7 days';

COMMENT ON VIEW agent_health_dashboard IS 'Comprehensive health dashboard showing all agent metrics';
COMMENT ON VIEW unhealthy_agents IS 'View of agents with health issues for alerting';
