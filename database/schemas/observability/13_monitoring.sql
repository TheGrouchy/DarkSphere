-- ================================================================
-- DarkSpere: Monitoring & Observability System
-- Purpose: Real-time metrics, dashboards, alerting
-- Pattern: Collect → Aggregate → Alert → Visualize
-- ================================================================

-- ================================================================
-- APPLICATION LOGS TABLE
-- Persistent structured logs from all services
-- ================================================================

CREATE TABLE IF NOT EXISTS application_logs (
    -- Log identifier
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Log level
    log_level VARCHAR(20) NOT NULL, -- DEBUG, INFO, WARNING, ERROR, CRITICAL

    -- Log message
    message TEXT NOT NULL,

    -- Component/service
    component VARCHAR(100),

    -- Request correlation
    request_id VARCHAR(100),
    user_id UUID REFERENCES user_accounts(user_id),
    session_id UUID REFERENCES agent_sessions(session_id),

    -- Log metadata (structured)
    log_metadata JSONB DEFAULT '{}',

    -- Timestamp
    created_at TIMESTAMP DEFAULT NOW()
);

-- Indexes for application logs
CREATE INDEX idx_app_logs_level ON application_logs(log_level, created_at DESC);
CREATE INDEX idx_app_logs_component ON application_logs(component, created_at DESC);
CREATE INDEX idx_app_logs_request_id ON application_logs(request_id)
WHERE request_id IS NOT NULL;

-- ================================================================
-- METRIC TYPES
-- ================================================================

CREATE TYPE metric_type AS ENUM (
    'counter',      -- Incrementing value (total requests)
    'gauge',        -- Point-in-time value (active sessions)
    'histogram',    -- Distribution of values (response times)
    'summary'       -- Statistical summary (p50, p95, p99)
);

CREATE TYPE alert_severity AS ENUM (
    'info',
    'warning',
    'error',
    'critical'
);

-- ================================================================
-- SYSTEM METRICS TABLE
-- Time-series metrics for monitoring
-- ================================================================

CREATE TABLE IF NOT EXISTS system_metrics (
    -- Metric identifier
    metric_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Metric definition
    metric_name VARCHAR(100) NOT NULL,
    metric_type metric_type NOT NULL,
    metric_value DECIMAL(20, 4) NOT NULL,

    -- Dimensions (tags)
    component VARCHAR(100),
    environment VARCHAR(50) DEFAULT 'production',
    labels JSONB DEFAULT '{}',

    -- Timestamp
    recorded_at TIMESTAMP DEFAULT NOW(),

    -- Metadata
    metric_metadata JSONB DEFAULT '{}'
);

-- ================================================================
-- PERFORMANCE METRICS TABLE
-- Response time and latency tracking
-- ================================================================

CREATE TABLE IF NOT EXISTS performance_metrics (
    -- Metric identifier
    perf_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Request context
    component VARCHAR(100) NOT NULL,
    endpoint VARCHAR(255),
    operation VARCHAR(100),

    -- Timing (milliseconds)
    response_time_ms INTEGER NOT NULL,
    db_query_time_ms INTEGER,
    external_api_time_ms INTEGER,

    -- Request details
    request_id VARCHAR(100),
    user_id UUID REFERENCES user_accounts(user_id),
    session_id UUID REFERENCES agent_sessions(session_id),

    -- Result
    success BOOLEAN NOT NULL,
    status_code INTEGER,

    -- Timestamp
    recorded_at TIMESTAMP DEFAULT NOW(),

    -- Metadata
    perf_metadata JSONB DEFAULT '{}'
);

-- ================================================================
-- ALERT RULES TABLE
-- Define monitoring alerts
-- ================================================================

CREATE TABLE IF NOT EXISTS alert_rules (
    -- Rule identifier
    rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Rule definition
    rule_name VARCHAR(100) UNIQUE NOT NULL,
    rule_description TEXT,

    -- Metric to monitor
    metric_name VARCHAR(100) NOT NULL,
    component VARCHAR(100),

    -- Condition
    condition_operator VARCHAR(20) NOT NULL, -- '>', '<', '>=', '<=', '==', '!='
    threshold_value DECIMAL(20, 4) NOT NULL,
    evaluation_window_minutes INTEGER DEFAULT 5,

    -- Alert settings
    alert_severity alert_severity NOT NULL,
    alert_message_template TEXT,

    -- Notification
    notification_channels JSONB DEFAULT '[]', -- ['email', 'slack', 'webhook']
    webhook_url TEXT,

    -- Cooldown (prevent alert spam)
    cooldown_minutes INTEGER DEFAULT 15,
    last_triggered_at TIMESTAMP,

    -- Status
    is_enabled BOOLEAN DEFAULT TRUE,

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- ALERT HISTORY TABLE
-- Track triggered alerts
-- ================================================================

CREATE TABLE IF NOT EXISTS alert_history (
    -- Alert identifier
    alert_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Rule reference
    rule_id UUID NOT NULL REFERENCES alert_rules(rule_id) ON DELETE CASCADE,

    -- Alert details
    alert_severity alert_severity NOT NULL,
    alert_message TEXT NOT NULL,

    -- Trigger details
    metric_value DECIMAL(20, 4),
    threshold_value DECIMAL(20, 4),

    -- Status
    acknowledged BOOLEAN DEFAULT FALSE,
    acknowledged_by UUID REFERENCES user_accounts(user_id),
    acknowledged_at TIMESTAMP,

    resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMP,
    resolution_notes TEXT,

    -- Timestamp
    triggered_at TIMESTAMP DEFAULT NOW(),

    -- Metadata
    alert_metadata JSONB DEFAULT '{}'
);

-- ================================================================
-- INDEXES FOR FAST QUERIES
-- ================================================================

-- System metrics by name and time
CREATE INDEX idx_system_metrics_name_time ON system_metrics(metric_name, recorded_at DESC);
CREATE INDEX idx_system_metrics_component ON system_metrics(component, recorded_at DESC);

-- Performance metrics by component
CREATE INDEX idx_perf_metrics_component ON performance_metrics(component, recorded_at DESC);
CREATE INDEX idx_perf_metrics_endpoint ON performance_metrics(endpoint, recorded_at DESC);

-- Recent performance metrics (last hour)
CREATE INDEX idx_perf_metrics_recent ON performance_metrics(recorded_at DESC)
WHERE recorded_at > NOW() - INTERVAL '1 hour';

-- Active alerts
CREATE INDEX idx_alert_history_active ON alert_history(triggered_at DESC)
WHERE resolved = FALSE;

-- Alert rules by metric
CREATE INDEX idx_alert_rules_metric ON alert_rules(metric_name)
WHERE is_enabled = TRUE;

-- ================================================================
-- MONITORING VIEWS
-- ================================================================

-- Real-time system health overview
CREATE OR REPLACE VIEW system_health_overview AS
SELECT
    -- Overall health score (0-100)
    ROUND(AVG(
        CASE
            WHEN ahs.health_score IS NOT NULL THEN ahs.health_score
            ELSE 100
        END
    ))::INTEGER AS overall_health_score,

    -- Agent health
    COUNT(DISTINCT ar.agent_id) AS total_agents,
    COUNT(DISTINCT ar.agent_id) FILTER (WHERE ar.status = 'active') AS active_agents,
    COUNT(DISTINCT ahs.agent_id) FILTER (WHERE ahs.current_status = 'healthy') AS healthy_agents,
    COUNT(DISTINCT ahs.agent_id) FILTER (WHERE ahs.current_status IN ('unhealthy', 'unreachable')) AS unhealthy_agents,

    -- Session metrics
    COUNT(DISTINCT asess.session_id) FILTER (WHERE asess.is_active = TRUE) AS active_sessions,
    AVG(asess.total_messages_received) FILTER (WHERE asess.is_active = TRUE) AS avg_messages_per_session,

    -- Error metrics (last hour)
    COUNT(DISTINCT el.error_id) FILTER (
        WHERE el.occurred_at > NOW() - INTERVAL '1 hour'
    ) AS errors_last_hour,
    COUNT(DISTINCT el.error_id) FILTER (
        WHERE el.error_severity IN ('high', 'critical')
        AND el.occurred_at > NOW() - INTERVAL '1 hour'
    ) AS critical_errors_last_hour,

    -- Active alerts
    COUNT(DISTINCT ah.alert_id) FILTER (WHERE ah.resolved = FALSE) AS active_alerts,

    -- Timestamp
    NOW() AS snapshot_time
FROM agent_registry ar
LEFT JOIN agent_health_summary ahs ON ar.agent_id = ahs.agent_id
LEFT JOIN agent_sessions asess ON ar.agent_id = asess.agent_id
LEFT JOIN error_log el ON TRUE
LEFT JOIN alert_history ah ON TRUE;

-- Performance dashboard (last 24 hours)
CREATE OR REPLACE VIEW performance_dashboard AS
SELECT
    pm.component,
    pm.endpoint,

    -- Request counts
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE pm.success = TRUE) AS successful_requests,
    COUNT(*) FILTER (WHERE pm.success = FALSE) AS failed_requests,
    ROUND((COUNT(*) FILTER (WHERE pm.success = TRUE)::DECIMAL / COUNT(*)::DECIMAL) * 100, 2) AS success_rate,

    -- Response time metrics
    ROUND(AVG(pm.response_time_ms))::INTEGER AS avg_response_time_ms,
    MIN(pm.response_time_ms) AS min_response_time_ms,
    MAX(pm.response_time_ms) AS max_response_time_ms,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY pm.response_time_ms)::INTEGER AS p50_response_time_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY pm.response_time_ms)::INTEGER AS p95_response_time_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY pm.response_time_ms)::INTEGER AS p99_response_time_ms,

    -- Slow requests (>1s)
    COUNT(*) FILTER (WHERE pm.response_time_ms > 1000) AS slow_requests_count,

    -- Database performance
    ROUND(AVG(pm.db_query_time_ms))::INTEGER AS avg_db_time_ms,
    ROUND(AVG(pm.external_api_time_ms))::INTEGER AS avg_external_api_time_ms,

    -- Time window
    MIN(pm.recorded_at) AS window_start,
    MAX(pm.recorded_at) AS window_end
FROM performance_metrics pm
WHERE pm.recorded_at > NOW() - INTERVAL '24 hours'
GROUP BY pm.component, pm.endpoint
ORDER BY total_requests DESC;

-- Usage metrics dashboard
CREATE OR REPLACE VIEW usage_metrics_dashboard AS
SELECT
    DATE_TRUNC('hour', ue.event_timestamp) AS hour,
    ue.event_type,

    -- Usage counts
    COUNT(*) AS event_count,
    COUNT(DISTINCT ue.user_id) AS unique_users,

    -- Cost metrics
    SUM(ue.total_cost_cents)::INTEGER AS total_cost_cents,
    SUM(ue.total_cost_cents) FILTER (WHERE ue.is_overage = TRUE)::INTEGER AS overage_cost_cents,

    -- Agent usage
    COUNT(DISTINCT ue.agent_id) AS agents_used,
    COUNT(DISTINCT ue.session_id) AS sessions_created

FROM usage_events ue
WHERE ue.event_timestamp > NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('hour', ue.event_timestamp), ue.event_type
ORDER BY hour DESC, event_type;

-- Error analytics view
CREATE OR REPLACE VIEW error_analytics AS
SELECT
    DATE_TRUNC('hour', el.occurred_at) AS hour,
    el.error_category,
    el.error_severity,
    el.component,

    -- Error counts
    COUNT(*) AS error_count,
    COUNT(DISTINCT el.user_id) AS affected_users,
    COUNT(DISTINCT el.session_id) AS affected_sessions,

    -- Resolution metrics
    COUNT(*) FILTER (WHERE el.is_resolved = TRUE) AS resolved_count,
    COUNT(*) FILTER (WHERE el.is_resolved = FALSE) AS unresolved_count,
    ROUND(AVG(el.retry_count), 2) AS avg_retry_count,

    -- Most common errors
    MODE() WITHIN GROUP (ORDER BY el.error_code) AS most_common_error_code

FROM error_log el
WHERE el.occurred_at > NOW() - INTERVAL '24 hours'
GROUP BY DATE_TRUNC('hour', el.occurred_at), el.error_category, el.error_severity, el.component
ORDER BY hour DESC, error_count DESC;

-- Alert status dashboard
CREATE OR REPLACE VIEW alert_status_dashboard AS
SELECT
    ar.rule_name,
    ar.metric_name,
    ar.alert_severity,
    ar.is_enabled,

    -- Trigger statistics
    COUNT(ah.alert_id) AS total_triggers,
    COUNT(ah.alert_id) FILTER (WHERE ah.triggered_at > NOW() - INTERVAL '24 hours') AS triggers_last_24h,
    COUNT(ah.alert_id) FILTER (WHERE ah.resolved = FALSE) AS active_alerts,

    -- Last trigger
    MAX(ah.triggered_at) AS last_triggered_at,
    MAX(ah.metric_value) FILTER (WHERE ah.triggered_at = (
        SELECT MAX(triggered_at) FROM alert_history WHERE rule_id = ar.rule_id
    )) AS last_metric_value,

    -- Resolution rate
    ROUND((COUNT(ah.alert_id) FILTER (WHERE ah.resolved = TRUE)::DECIMAL /
           NULLIF(COUNT(ah.alert_id), 0)::DECIMAL) * 100, 2) AS resolution_rate

FROM alert_rules ar
LEFT JOIN alert_history ah ON ar.rule_id = ah.rule_id
GROUP BY ar.rule_id, ar.rule_name, ar.metric_name, ar.alert_severity, ar.is_enabled
ORDER BY active_alerts DESC, triggers_last_24h DESC;

-- ================================================================
-- MONITORING FUNCTIONS
-- ================================================================

-- Record a metric
CREATE OR REPLACE FUNCTION record_metric(
    p_metric_name VARCHAR(100),
    p_metric_type metric_type,
    p_metric_value DECIMAL(20, 4),
    p_component VARCHAR(100) DEFAULT NULL,
    p_labels JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_metric_id UUID;
BEGIN
    INSERT INTO system_metrics (
        metric_name,
        metric_type,
        metric_value,
        component,
        labels
    ) VALUES (
        p_metric_name,
        p_metric_type,
        p_metric_value,
        p_component,
        p_labels
    ) RETURNING metric_id INTO v_metric_id;

    RETURN v_metric_id;
END;
$$ LANGUAGE plpgsql;

-- Record performance metric
CREATE OR REPLACE FUNCTION record_performance(
    p_component VARCHAR(100),
    p_endpoint VARCHAR(255),
    p_response_time_ms INTEGER,
    p_success BOOLEAN,
    p_request_id VARCHAR(100) DEFAULT NULL,
    p_status_code INTEGER DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_perf_id UUID;
BEGIN
    INSERT INTO performance_metrics (
        component,
        endpoint,
        response_time_ms,
        success,
        request_id,
        status_code,
        perf_metadata
    ) VALUES (
        p_component,
        p_endpoint,
        p_response_time_ms,
        p_success,
        p_request_id,
        p_status_code,
        p_metadata
    ) RETURNING perf_id INTO v_perf_id;

    RETURN v_perf_id;
END;
$$ LANGUAGE plpgsql;

-- Evaluate alert rules
CREATE OR REPLACE FUNCTION evaluate_alert_rules()
RETURNS TABLE (
    rule_id UUID,
    rule_name VARCHAR(100),
    should_trigger BOOLEAN,
    current_value DECIMAL(20, 4),
    threshold_value DECIMAL(20, 4)
) AS $$
BEGIN
    RETURN QUERY
    WITH metric_aggregates AS (
        SELECT
            sm.metric_name,
            sm.component,
            AVG(sm.metric_value) AS avg_value,
            MAX(sm.metric_value) AS max_value,
            MIN(sm.metric_value) AS min_value
        FROM system_metrics sm
        WHERE sm.recorded_at > NOW() - INTERVAL '5 minutes'
        GROUP BY sm.metric_name, sm.component
    )
    SELECT
        ar.rule_id,
        ar.rule_name,
        CASE ar.condition_operator
            WHEN '>' THEN ma.avg_value > ar.threshold_value
            WHEN '<' THEN ma.avg_value < ar.threshold_value
            WHEN '>=' THEN ma.avg_value >= ar.threshold_value
            WHEN '<=' THEN ma.avg_value <= ar.threshold_value
            WHEN '==' THEN ma.avg_value = ar.threshold_value
            WHEN '!=' THEN ma.avg_value != ar.threshold_value
            ELSE FALSE
        END AS should_trigger,
        ma.avg_value AS current_value,
        ar.threshold_value
    FROM alert_rules ar
    JOIN metric_aggregates ma ON ar.metric_name = ma.metric_name
        AND (ar.component IS NULL OR ar.component = ma.component)
    WHERE ar.is_enabled = TRUE
      AND (ar.last_triggered_at IS NULL OR
           ar.last_triggered_at < NOW() - (ar.cooldown_minutes || ' minutes')::INTERVAL);
END;
$$ LANGUAGE plpgsql;

-- Trigger an alert
CREATE OR REPLACE FUNCTION trigger_alert(
    p_rule_id UUID,
    p_metric_value DECIMAL(20, 4)
)
RETURNS UUID AS $$
DECLARE
    v_alert_id UUID;
    v_rule RECORD;
    v_alert_message TEXT;
BEGIN
    -- Get rule details
    SELECT * INTO v_rule
    FROM alert_rules
    WHERE rule_id = p_rule_id;

    -- Build alert message
    v_alert_message := COALESCE(
        v_rule.alert_message_template,
        format('Alert: %s - Current value: %s, Threshold: %s',
               v_rule.rule_name,
               p_metric_value,
               v_rule.threshold_value)
    );

    -- Create alert
    INSERT INTO alert_history (
        rule_id,
        alert_severity,
        alert_message,
        metric_value,
        threshold_value
    ) VALUES (
        p_rule_id,
        v_rule.alert_severity,
        v_alert_message,
        p_metric_value,
        v_rule.threshold_value
    ) RETURNING alert_id INTO v_alert_id;

    -- Update rule's last triggered time
    UPDATE alert_rules
    SET last_triggered_at = NOW()
    WHERE rule_id = p_rule_id;

    -- TODO: Send notifications based on notification_channels

    RETURN v_alert_id;
END;
$$ LANGUAGE plpgsql;

-- Acknowledge alert
CREATE OR REPLACE FUNCTION acknowledge_alert(
    p_alert_id UUID,
    p_user_id UUID
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE alert_history
    SET acknowledged = TRUE,
        acknowledged_by = p_user_id,
        acknowledged_at = NOW()
    WHERE alert_id = p_alert_id
      AND acknowledged = FALSE;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Resolve alert
CREATE OR REPLACE FUNCTION resolve_alert(
    p_alert_id UUID,
    p_resolution_notes TEXT DEFAULT NULL
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE alert_history
    SET resolved = TRUE,
        resolved_at = NOW(),
        resolution_notes = p_resolution_notes
    WHERE alert_id = p_alert_id
      AND resolved = FALSE;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Get system metrics summary
CREATE OR REPLACE FUNCTION get_metrics_summary(
    p_metric_name VARCHAR(100),
    p_hours INTEGER DEFAULT 24
)
RETURNS TABLE (
    metric_name VARCHAR(100),
    avg_value DECIMAL(20, 4),
    min_value DECIMAL(20, 4),
    max_value DECIMAL(20, 4),
    p50_value DECIMAL(20, 4),
    p95_value DECIMAL(20, 4),
    p99_value DECIMAL(20, 4),
    sample_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        sm.metric_name,
        ROUND(AVG(sm.metric_value), 4) AS avg_value,
        MIN(sm.metric_value) AS min_value,
        MAX(sm.metric_value) AS max_value,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY sm.metric_value) AS p50_value,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY sm.metric_value) AS p95_value,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY sm.metric_value) AS p99_value,
        COUNT(*) AS sample_count
    FROM system_metrics sm
    WHERE sm.metric_name = p_metric_name
      AND sm.recorded_at > NOW() - (p_hours || ' hours')::INTERVAL
    GROUP BY sm.metric_name;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT ALERT RULES
-- ================================================================

DO $$
BEGIN
    -- High error rate alert
    INSERT INTO alert_rules (
        rule_name,
        rule_description,
        metric_name,
        condition_operator,
        threshold_value,
        evaluation_window_minutes,
        alert_severity,
        alert_message_template
    ) VALUES (
        'High Error Rate',
        'Triggers when error rate exceeds 10% in 5 minutes',
        'error_rate',
        '>',
        10.0,
        5,
        'critical',
        'CRITICAL: Error rate is {current_value}%, threshold is {threshold_value}%'
    ) ON CONFLICT (rule_name) DO NOTHING;

    -- Slow response time alert
    INSERT INTO alert_rules (
        rule_name,
        rule_description,
        metric_name,
        condition_operator,
        threshold_value,
        evaluation_window_minutes,
        alert_severity
    ) VALUES (
        'Slow Response Time',
        'Triggers when average response time exceeds 1000ms',
        'avg_response_time_ms',
        '>',
        1000.0,
        5,
        'warning'
    ) ON CONFLICT (rule_name) DO NOTHING;

    -- Agent health alert
    INSERT INTO alert_rules (
        rule_name,
        rule_description,
        metric_name,
        condition_operator,
        threshold_value,
        alert_severity
    ) VALUES (
        'Low Agent Health',
        'Triggers when agent health score falls below 70',
        'agent_health_score',
        '<',
        70.0,
        'error'
    ) ON CONFLICT (rule_name) DO NOTHING;

    -- High session count alert
    INSERT INTO alert_rules (
        rule_name,
        rule_description,
        metric_name,
        condition_operator,
        threshold_value,
        alert_severity
    ) VALUES (
        'High Active Sessions',
        'Triggers when active sessions exceed 1000',
        'active_sessions',
        '>',
        1000.0,
        'warning'
    ) ON CONFLICT (rule_name) DO NOTHING;
END $$;

-- ================================================================
-- CLEANUP FUNCTION
-- Delete old metrics (keep last 30 days)
-- ================================================================

CREATE OR REPLACE FUNCTION cleanup_old_metrics()
RETURNS TABLE (
    metrics_deleted INTEGER,
    performance_deleted INTEGER,
    alerts_deleted INTEGER
) AS $$
DECLARE
    v_metrics_deleted INTEGER;
    v_performance_deleted INTEGER;
    v_alerts_deleted INTEGER;
BEGIN
    -- Delete old system metrics
    DELETE FROM system_metrics
    WHERE recorded_at < NOW() - INTERVAL '30 days';
    GET DIAGNOSTICS v_metrics_deleted = ROW_COUNT;

    -- Delete old performance metrics
    DELETE FROM performance_metrics
    WHERE recorded_at < NOW() - INTERVAL '30 days';
    GET DIAGNOSTICS v_performance_deleted = ROW_COUNT;

    -- Delete old resolved alerts
    DELETE FROM alert_history
    WHERE resolved = TRUE
      AND resolved_at < NOW() - INTERVAL '90 days';
    GET DIAGNOSTICS v_alerts_deleted = ROW_COUNT;

    RETURN QUERY SELECT v_metrics_deleted, v_performance_deleted, v_alerts_deleted;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE system_metrics IS 'Time-series system metrics for monitoring dashboards';
COMMENT ON TABLE performance_metrics IS 'Response time and latency tracking per component';
COMMENT ON TABLE alert_rules IS 'Alert rule definitions with thresholds and notifications';
COMMENT ON TABLE alert_history IS 'Triggered alert history with acknowledgment tracking';

COMMENT ON VIEW system_health_overview IS 'Real-time system health snapshot with key metrics';
COMMENT ON VIEW performance_dashboard IS 'Performance metrics dashboard (p50/p95/p99)';
COMMENT ON VIEW usage_metrics_dashboard IS 'Usage events dashboard with cost tracking';
COMMENT ON VIEW error_analytics IS 'Error analytics with categorization and trends';
COMMENT ON VIEW alert_status_dashboard IS 'Alert status and trigger history';

COMMENT ON FUNCTION record_metric IS 'Record a system metric for monitoring';
COMMENT ON FUNCTION record_performance IS 'Record performance metric with response time';
COMMENT ON FUNCTION evaluate_alert_rules IS 'Evaluate all active alert rules against current metrics';
COMMENT ON FUNCTION trigger_alert IS 'Trigger an alert and send notifications';
COMMENT ON FUNCTION get_metrics_summary IS 'Get statistical summary of metric over time period';
COMMENT ON FUNCTION cleanup_old_metrics IS 'Delete metrics and alerts older than retention period';
