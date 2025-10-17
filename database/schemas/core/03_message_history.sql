-- ================================================================
-- DarkSpere: Message History Table
-- Purpose: Complete audit log of all data transmissions through system
-- Data Flow: Records every message at each transmission point
-- ================================================================

CREATE TABLE IF NOT EXISTS message_history (
    -- Primary identifier
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Session reference (CRITICAL FOREIGN KEY)
    session_id UUID NOT NULL REFERENCES agent_sessions(session_id) ON DELETE CASCADE,

    -- Message transmission details
    direction VARCHAR(10) NOT NULL CHECK (direction IN ('inbound', 'outbound')),
    sender VARCHAR(50) NOT NULL, -- Phone number or 'agent' or 'system'
    recipient VARCHAR(50) NOT NULL, -- Phone number or 'agent' or 'system'
    message_text TEXT NOT NULL,

    -- Data transmission metadata
    transmission_path JSONB NOT NULL DEFAULT '{}', -- Track full path: twilio → n8n → agent → n8n → twilio
    message_metadata JSONB DEFAULT '{}', -- Store Twilio metadata, n8n execution ID, etc.
    twilio_message_sid VARCHAR(100), -- Twilio unique identifier for tracking

    -- Agent processing details
    agent_endpoint TEXT, -- Which endpoint processed this message
    agent_response JSONB, -- Full agent API response
    agent_processing_time_ms INTEGER, -- Time agent took to process

    -- n8n workflow transmission details
    n8n_execution_id VARCHAR(100), -- n8n workflow execution ID for debugging
    n8n_node_id VARCHAR(100), -- Which n8n node processed this
    workflow_processing_time_ms INTEGER, -- Total n8n processing time

    -- Transmission status tracking
    transmission_status VARCHAR(20) DEFAULT 'pending' CHECK (
        transmission_status IN ('pending', 'transmitted', 'delivered', 'failed', 'retrying')
    ),
    delivery_timestamp TIMESTAMP, -- When message was successfully delivered
    error_details JSONB, -- Store any transmission errors

    -- Timing
    timestamp TIMESTAMP DEFAULT NOW(), -- When message entered system
    created_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- INDEXES FOR FAST MESSAGE RETRIEVAL AND DEBUGGING
-- Optimize for session context lookups and transmission debugging
-- ================================================================

-- PRIMARY INDEX: Get messages for a session (conversation context)
-- This is used CONSTANTLY for AI context building
CREATE INDEX IF NOT EXISTS idx_session_messages_ordered ON message_history(session_id, timestamp DESC);

-- Transmission path debugging (find failed transmissions)
CREATE INDEX IF NOT EXISTS idx_transmission_status ON message_history(transmission_status, timestamp DESC)
WHERE transmission_status IN ('failed', 'retrying');

-- Twilio message ID lookup (for webhook callbacks and status updates)
CREATE UNIQUE INDEX IF NOT EXISTS idx_twilio_message_sid ON message_history(twilio_message_sid)
WHERE twilio_message_sid IS NOT NULL;

-- Time-based queries (analytics, monitoring)
CREATE INDEX IF NOT EXISTS idx_timestamp ON message_history(timestamp DESC);

-- Direction-based queries (inbound vs outbound analysis)
CREATE INDEX IF NOT EXISTS idx_direction_timestamp ON message_history(direction, timestamp DESC);

-- Agent performance analysis
CREATE INDEX IF NOT EXISTS idx_agent_processing ON message_history(agent_endpoint, agent_processing_time_ms)
WHERE agent_processing_time_ms IS NOT NULL;

-- n8n execution tracking (for debugging workflow issues)
CREATE INDEX IF NOT EXISTS idx_n8n_execution ON message_history(n8n_execution_id)
WHERE n8n_execution_id IS NOT NULL;

-- ================================================================
-- TRIGGERS FOR DATA INTEGRITY
-- ================================================================

-- Update session message counters
CREATE OR REPLACE FUNCTION update_session_message_count()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.direction = 'inbound' THEN
        UPDATE agent_sessions
        SET total_messages_received = total_messages_received + 1,
            last_transmitted_message_id = NEW.message_id
        WHERE session_id = NEW.session_id;
    ELSIF NEW.direction = 'outbound' THEN
        UPDATE agent_sessions
        SET total_messages_sent = total_messages_sent + 1,
            last_transmitted_message_id = NEW.message_id
        WHERE session_id = NEW.session_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_message_count ON message_history;
CREATE TRIGGER trigger_update_message_count
AFTER INSERT ON message_history
FOR EACH ROW
EXECUTE FUNCTION update_session_message_count();

-- ================================================================
-- FUNCTIONS FOR MESSAGE RETRIEVAL AND ANALYSIS
-- ================================================================

-- Get recent conversation history (for AI context)
CREATE OR REPLACE FUNCTION get_conversation_history(
    p_session_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    message_id UUID,
    direction VARCHAR(10),
    sender VARCHAR(50),
    message_text TEXT,
    msg_timestamp TIMESTAMP,
    agent_processing_time_ms INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.message_id,
        m.direction,
        m.sender,
        m.message_text,
        m.timestamp AS msg_timestamp,
        m.agent_processing_time_ms
    FROM message_history m
    WHERE m.session_id = p_session_id
    ORDER BY m.timestamp DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql;

-- Get transmission metrics for monitoring
CREATE OR REPLACE FUNCTION get_transmission_metrics(
    p_time_window INTERVAL DEFAULT '1 hour'
)
RETURNS TABLE (
    total_messages BIGINT,
    inbound_messages BIGINT,
    outbound_messages BIGINT,
    failed_transmissions BIGINT,
    avg_agent_processing_ms NUMERIC,
    avg_workflow_processing_ms NUMERIC,
    p95_agent_processing_ms NUMERIC,
    p95_workflow_processing_ms NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*)::BIGINT AS total_messages,
        COUNT(*) FILTER (WHERE direction = 'inbound')::BIGINT AS inbound_messages,
        COUNT(*) FILTER (WHERE direction = 'outbound')::BIGINT AS outbound_messages,
        COUNT(*) FILTER (WHERE transmission_status = 'failed')::BIGINT AS failed_transmissions,
        ROUND(AVG(agent_processing_time_ms)::NUMERIC, 2) AS avg_agent_processing_ms,
        ROUND(AVG(workflow_processing_time_ms)::NUMERIC, 2) AS avg_workflow_processing_ms,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY agent_processing_time_ms)::NUMERIC, 2) AS p95_agent_processing_ms,
        ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY workflow_processing_time_ms)::NUMERIC, 2) AS p95_workflow_processing_ms
    FROM message_history
    WHERE timestamp > NOW() - p_time_window;
END;
$$ LANGUAGE plpgsql;

-- Analyze failed transmissions
CREATE OR REPLACE FUNCTION analyze_failed_transmissions(
    p_time_window INTERVAL DEFAULT '1 hour'
)
RETURNS TABLE (
    agent_endpoint TEXT,
    failure_count BIGINT,
    last_failure TIMESTAMP,
    common_errors TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        m.agent_endpoint,
        COUNT(*)::BIGINT AS failure_count,
        MAX(m.timestamp) AS last_failure,
        ARRAY_AGG(DISTINCT (m.error_details->>'error_type')::TEXT) AS common_errors
    FROM message_history m
    WHERE m.transmission_status = 'failed'
      AND m.timestamp > NOW() - p_time_window
      AND m.agent_endpoint IS NOT NULL
    GROUP BY m.agent_endpoint
    ORDER BY failure_count DESC;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- VIEWS FOR MONITORING AND ANALYTICS
-- ================================================================

-- Real-time transmission monitoring
CREATE OR REPLACE VIEW transmission_monitoring AS
SELECT
    DATE_TRUNC('minute', timestamp) AS minute,
    COUNT(*) AS total_messages,
    COUNT(*) FILTER (WHERE direction = 'inbound') AS inbound,
    COUNT(*) FILTER (WHERE direction = 'outbound') AS outbound,
    COUNT(*) FILTER (WHERE transmission_status = 'delivered') AS delivered,
    COUNT(*) FILTER (WHERE transmission_status = 'failed') AS failed,
    ROUND(AVG(agent_processing_time_ms), 2) AS avg_agent_ms,
    ROUND(AVG(workflow_processing_time_ms), 2) AS avg_workflow_ms
FROM message_history
WHERE timestamp > NOW() - INTERVAL '1 hour'
GROUP BY DATE_TRUNC('minute', timestamp)
ORDER BY minute DESC;

-- Agent performance view
CREATE OR REPLACE VIEW agent_performance AS
SELECT
    m.agent_endpoint,
    a.agent_name,
    COUNT(*) AS messages_processed,
    COUNT(*) FILTER (WHERE m.transmission_status = 'delivered') AS successful,
    COUNT(*) FILTER (WHERE m.transmission_status = 'failed') AS failed,
    ROUND(AVG(m.agent_processing_time_ms), 2) AS avg_processing_ms,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY m.agent_processing_time_ms)::NUMERIC, 2) AS p95_processing_ms,
    MAX(m.timestamp) AS last_message
FROM message_history m
LEFT JOIN agent_sessions s ON m.session_id = s.session_id
LEFT JOIN agent_registry a ON s.agent_id = a.agent_id
WHERE m.timestamp > NOW() - INTERVAL '24 hours'
  AND m.agent_endpoint IS NOT NULL
GROUP BY m.agent_endpoint, a.agent_name
ORDER BY messages_processed DESC;

-- Data transmission flow visualization
CREATE OR REPLACE VIEW data_flow_audit AS
SELECT
    m.message_id,
    m.timestamp,
    s.phone_number,
    a.agent_name,
    m.direction,
    m.transmission_status,
    m.transmission_path,
    COALESCE(m.agent_processing_time_ms, 0) + COALESCE(m.workflow_processing_time_ms, 0) AS total_processing_ms,
    m.twilio_message_sid,
    m.n8n_execution_id
FROM message_history m
JOIN agent_sessions s ON m.session_id = s.session_id
JOIN agent_registry a ON s.agent_id = a.agent_id
ORDER BY m.timestamp DESC;

-- ================================================================
-- PARTITIONING STRATEGY (For High Volume)
-- ================================================================

-- Note: For production with high message volume (>1M messages/month),
-- consider partitioning message_history by timestamp:
--
-- CREATE TABLE message_history (
--     ...
-- ) PARTITION BY RANGE (timestamp);
--
-- CREATE TABLE message_history_2025_10 PARTITION OF message_history
-- FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- ================================================================
-- DATA RETENTION POLICY
-- ================================================================

-- Function to archive old messages (run daily via cron)
CREATE OR REPLACE FUNCTION archive_old_messages(
    p_retention_days INTEGER DEFAULT 90
)
RETURNS INTEGER AS $$
DECLARE
    archived_count INTEGER;
BEGIN
    -- In production, move to archive table instead of DELETE
    -- For now, just mark messages older than retention period
    UPDATE message_history
    SET message_metadata = message_metadata || jsonb_build_object('archived', TRUE)
    WHERE timestamp < NOW() - (p_retention_days || ' days')::INTERVAL
      AND (message_metadata->>'archived')::BOOLEAN IS DISTINCT FROM TRUE;

    GET DIAGNOSTICS archived_count = ROW_COUNT;
    RETURN archived_count;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- COMMENTS FOR DOCUMENTATION
-- ================================================================

COMMENT ON TABLE message_history IS 'Complete audit log of all message transmissions through the system';
COMMENT ON COLUMN message_history.transmission_path IS 'JSONB tracking full data path through system components';
COMMENT ON COLUMN message_history.agent_processing_time_ms IS 'Time taken by remote agent to process message';
COMMENT ON COLUMN message_history.workflow_processing_time_ms IS 'Time taken by n8n workflow to route message';
COMMENT ON FUNCTION get_conversation_history IS 'Retrieve recent messages for AI context building';
COMMENT ON FUNCTION get_transmission_metrics IS 'Real-time metrics for monitoring data transmission performance';
COMMENT ON VIEW transmission_monitoring IS 'Real-time per-minute transmission statistics';
COMMENT ON VIEW agent_performance IS '24-hour agent performance and latency metrics';
COMMENT ON VIEW data_flow_audit IS 'Complete audit trail of data flow through system';
