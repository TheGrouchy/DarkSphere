-- ================================================================
-- DarkSpere: Agent Sessions Table
-- Purpose: Session-precise mapping of phone numbers to agent endpoints
-- Data Flow: PRIMARY ROUTING TABLE - Maps incoming SMS to specific agent
-- ================================================================

CREATE TABLE IF NOT EXISTS agent_sessions (
    -- Primary identifier
    session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Routing identifiers (CRITICAL FOR DATA TRANSMISSION)
    phone_number VARCHAR(20) NOT NULL, -- E.164 format: +15551234567
    agent_id UUID NOT NULL REFERENCES agent_registry(agent_id) ON DELETE CASCADE,
    agent_endpoint TEXT NOT NULL, -- Cached endpoint URL for fast routing (no JOIN needed)

    -- Session state for context preservation
    session_state JSONB DEFAULT '{}', -- Store conversation context, preferences, variables
    conversation_context TEXT[], -- Array of recent messages for quick access

    -- Timing and lifecycle
    created_at TIMESTAMP DEFAULT NOW(),
    last_activity TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP DEFAULT (NOW() + INTERVAL '24 hours'), -- Auto-expire inactive sessions
    is_active BOOLEAN DEFAULT TRUE,

    -- Session security
    session_hash VARCHAR(64) UNIQUE, -- SHA256 hash for secure session identification

    -- Data transmission metadata
    total_messages_sent INTEGER DEFAULT 0,
    total_messages_received INTEGER DEFAULT 0,
    last_transmitted_message_id UUID, -- Reference to last message in message_history
    routing_metadata JSONB DEFAULT '{}', -- Store routing decisions, failovers, etc.

    -- Constraints for data integrity
    CONSTRAINT unique_active_phone_per_agent UNIQUE (phone_number, agent_id, is_active),
    CONSTRAINT valid_phone_format CHECK (phone_number ~ '^\+[1-9]\d{1,14}$'), -- E.164 format
    CONSTRAINT valid_expiration CHECK (expires_at > created_at)
);

-- ================================================================
-- INDEXES FOR ULTRA-FAST SESSION ROUTING
-- These indexes are CRITICAL for sub-50ms data routing
-- ================================================================

-- PRIMARY ROUTING INDEX: Phone number lookup for active sessions
-- This is THE most important query for data transmission
CREATE UNIQUE INDEX idx_phone_active_routing ON agent_sessions(phone_number, is_active)
WHERE is_active = TRUE;

-- Composite index for session lookup with endpoint (avoids JOIN)
CREATE INDEX idx_phone_endpoint ON agent_sessions(phone_number, agent_endpoint, is_active)
WHERE is_active = TRUE;

-- Agent-based session lookup (for agent health checks)
CREATE INDEX idx_agent_sessions_active ON agent_sessions(agent_id, is_active)
WHERE is_active = TRUE;

-- Expiration cleanup (for background jobs)
CREATE INDEX idx_expires_at ON agent_sessions(expires_at)
WHERE is_active = TRUE;

-- Recent activity tracking (for analytics)
CREATE INDEX idx_last_activity ON agent_sessions(last_activity DESC)
WHERE is_active = TRUE;

-- ================================================================
-- TRIGGERS FOR SESSION LIFECYCLE MANAGEMENT
-- ================================================================

-- Auto-update last_activity timestamp on session updates
CREATE OR REPLACE FUNCTION update_session_activity()
RETURNS TRIGGER AS $$
BEGIN
    NEW.last_activity = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_session_activity
BEFORE UPDATE ON agent_sessions
FOR EACH ROW
EXECUTE FUNCTION update_session_activity();

-- Trigger to increment agent session count when session created
CREATE TRIGGER trigger_session_created
AFTER INSERT ON agent_sessions
FOR EACH ROW
WHEN (NEW.is_active = TRUE)
EXECUTE FUNCTION increment_agent_sessions();

-- Trigger to decrement agent session count when session ends
CREATE TRIGGER trigger_session_ended
AFTER UPDATE ON agent_sessions
FOR EACH ROW
WHEN (OLD.is_active = TRUE AND NEW.is_active = FALSE)
EXECUTE FUNCTION decrement_agent_sessions();

-- ================================================================
-- SESSION SECURITY FUNCTIONS
-- ================================================================

-- Generate SHA256 session hash
CREATE OR REPLACE FUNCTION generate_session_hash(
    p_phone_number VARCHAR(20),
    p_agent_id UUID,
    p_timestamp TIMESTAMP DEFAULT NOW()
)
RETURNS VARCHAR(64) AS $$
BEGIN
    RETURN encode(
        digest(
            p_phone_number || '::' || p_agent_id::TEXT || '::' || p_timestamp::TEXT || '::' || gen_random_uuid()::TEXT,
            'sha256'
        ),
        'hex'
    );
END;
$$ LANGUAGE plpgsql;

-- Verify session hash
CREATE OR REPLACE FUNCTION verify_session_hash(
    p_session_id UUID,
    p_session_hash VARCHAR(64)
)
RETURNS BOOLEAN AS $$
DECLARE
    v_stored_hash VARCHAR(64);
BEGIN
    SELECT session_hash INTO v_stored_hash
    FROM agent_sessions
    WHERE session_id = p_session_id;

    RETURN v_stored_hash = p_session_hash;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- FUNCTIONS FOR SESSION MANAGEMENT
-- ================================================================

-- Get or create session (atomic operation for data routing)
CREATE OR REPLACE FUNCTION get_or_create_session(
    p_phone_number VARCHAR(20),
    p_agent_type VARCHAR(50) DEFAULT NULL
)
RETURNS TABLE (
    session_id UUID,
    agent_id UUID,
    agent_endpoint TEXT,
    api_key_hash TEXT,
    session_hash VARCHAR(64),
    session_state JSONB,
    conversation_context TEXT[]
) AS $$
DECLARE
    v_session_id UUID;
    v_agent_id UUID;
    v_agent_endpoint TEXT;
    v_api_key_hash TEXT;
    v_session_hash VARCHAR(64);
    v_session_state JSONB;
    v_conversation_context TEXT[];
BEGIN
    -- Try to find existing active session
    SELECT
        s.session_id,
        s.agent_id,
        s.agent_endpoint,
        a.api_key_hash,
        s.session_hash,
        s.session_state,
        s.conversation_context
    INTO
        v_session_id,
        v_agent_id,
        v_agent_endpoint,
        v_api_key_hash,
        v_session_hash,
        v_session_state,
        v_conversation_context
    FROM agent_sessions s
    JOIN agent_registry a ON s.agent_id = a.agent_id
    WHERE s.phone_number = p_phone_number
      AND s.is_active = TRUE
      AND s.expires_at > NOW()
    ORDER BY s.last_activity DESC
    LIMIT 1;

    -- If no active session, create new one with available agent
    IF v_session_id IS NULL THEN
        -- Find available agent using enhanced load balancing
        -- Prioritizes: 1) Health score, 2) Capacity, 3) Response time
        SELECT a.agent_id, a.endpoint_url, a.api_key_hash
        INTO v_agent_id, v_agent_endpoint, v_api_key_hash
        FROM agent_registry a
        LEFT JOIN agent_health_summary ahs ON a.agent_id = ahs.agent_id
        WHERE a.status = 'active'
          AND a.current_sessions < a.max_concurrent_sessions
          AND (p_agent_type IS NULL OR a.agent_type = p_agent_type)
          AND (ahs.current_status IS NULL OR ahs.current_status = 'healthy')
          AND (ahs.health_score IS NULL OR ahs.health_score >= 70)
        ORDER BY
            COALESCE(ahs.health_score, 100) DESC,  -- Prefer higher health scores
            (a.current_sessions::DECIMAL / NULLIF(a.max_concurrent_sessions, 0)::DECIMAL) ASC,  -- Prefer less loaded agents
            COALESCE(ahs.avg_response_time_ms, 999999) ASC  -- Prefer faster agents
        LIMIT 1;

        -- Create new session
        IF v_agent_id IS NOT NULL THEN
            -- Generate secure session hash
            v_session_hash := generate_session_hash(p_phone_number, v_agent_id);

            INSERT INTO agent_sessions (phone_number, agent_id, agent_endpoint, session_hash, session_state, conversation_context)
            VALUES (p_phone_number, v_agent_id, v_agent_endpoint, v_session_hash, '{}'::jsonb, ARRAY[]::TEXT[])
            RETURNING
                agent_sessions.session_id,
                agent_sessions.agent_id,
                agent_sessions.agent_endpoint,
                agent_sessions.session_hash,
                agent_sessions.session_state,
                agent_sessions.conversation_context
            INTO
                v_session_id,
                v_agent_id,
                v_agent_endpoint,
                v_session_hash,
                v_session_state,
                v_conversation_context;
        END IF;
    END IF;

    -- Return session details
    RETURN QUERY SELECT
        v_session_id,
        v_agent_id,
        v_agent_endpoint,
        v_api_key_hash,
        v_session_hash,
        v_session_state,
        v_conversation_context;
END;
$$ LANGUAGE plpgsql;

-- Failover session to different agent (when current agent becomes unhealthy)
CREATE OR REPLACE FUNCTION failover_session_to_healthy_agent(
    p_session_id UUID
)
RETURNS TABLE (
    success BOOLEAN,
    new_agent_id UUID,
    new_agent_endpoint TEXT,
    failover_reason TEXT
) AS $$
DECLARE
    v_phone_number VARCHAR(20);
    v_agent_type VARCHAR(50);
    v_old_agent_id UUID;
    v_new_agent_id UUID;
    v_new_agent_endpoint TEXT;
    v_new_api_key_hash TEXT;
    v_session_state JSONB;
    v_conversation_context TEXT[];
BEGIN
    -- Get current session details
    SELECT
        phone_number,
        agent_id,
        session_state,
        conversation_context
    INTO
        v_phone_number,
        v_old_agent_id,
        v_session_state,
        v_conversation_context
    FROM agent_sessions
    WHERE session_id = p_session_id AND is_active = TRUE;

    -- If session not found, return failure
    IF v_phone_number IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::TEXT, 'Session not found'::TEXT;
        RETURN;
    END IF;

    -- Get old agent type for matching
    SELECT agent_type INTO v_agent_type
    FROM agent_registry
    WHERE agent_id = v_old_agent_id;

    -- Find new healthy agent (exclude current agent)
    SELECT a.agent_id, a.endpoint_url, a.api_key_hash
    INTO v_new_agent_id, v_new_agent_endpoint, v_new_api_key_hash
    FROM agent_registry a
    LEFT JOIN agent_health_summary ahs ON a.agent_id = ahs.agent_id
    WHERE a.status = 'active'
      AND a.agent_id != v_old_agent_id
      AND a.current_sessions < a.max_concurrent_sessions
      AND (v_agent_type IS NULL OR a.agent_type = v_agent_type)
      AND (ahs.current_status IS NULL OR ahs.current_status = 'healthy')
      AND (ahs.health_score IS NULL OR ahs.health_score >= 70)
    ORDER BY
        COALESCE(ahs.health_score, 100) DESC,
        (a.current_sessions::DECIMAL / NULLIF(a.max_concurrent_sessions, 0)::DECIMAL) ASC,
        COALESCE(ahs.avg_response_time_ms, 999999) ASC
    LIMIT 1;

    -- If no healthy agent available, return failure
    IF v_new_agent_id IS NULL THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::TEXT, 'No healthy agent available for failover'::TEXT;
        RETURN;
    END IF;

    -- Update session with new agent
    UPDATE agent_sessions
    SET agent_id = v_new_agent_id,
        agent_endpoint = v_new_agent_endpoint,
        routing_metadata = routing_metadata || jsonb_build_object(
            'failover_at', NOW(),
            'old_agent_id', v_old_agent_id,
            'new_agent_id', v_new_agent_id,
            'failover_reason', 'Agent became unhealthy'
        )
    WHERE session_id = p_session_id;

    -- Return success
    RETURN QUERY SELECT TRUE, v_new_agent_id, v_new_agent_endpoint, 'Failover successful'::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Expire old sessions (cleanup function)
CREATE OR REPLACE FUNCTION expire_old_sessions()
RETURNS INTEGER AS $$
DECLARE
    expired_count INTEGER;
BEGIN
    UPDATE agent_sessions
    SET is_active = FALSE
    WHERE is_active = TRUE
      AND expires_at < NOW();

    GET DIAGNOSTICS expired_count = ROW_COUNT;
    RETURN expired_count;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- VIEWS FOR MONITORING DATA TRANSMISSION
-- ================================================================

-- Active sessions with agent details
CREATE OR REPLACE VIEW active_sessions_summary AS
SELECT
    s.session_id,
    s.phone_number,
    a.agent_name,
    a.agent_type,
    s.created_at,
    s.last_activity,
    s.expires_at,
    s.total_messages_sent,
    s.total_messages_received,
    (s.total_messages_sent + s.total_messages_received) AS total_messages,
    EXTRACT(EPOCH FROM (NOW() - s.last_activity)) AS seconds_since_activity
FROM agent_sessions s
JOIN agent_registry a ON s.agent_id = a.agent_id
WHERE s.is_active = TRUE
ORDER BY s.last_activity DESC;

-- ================================================================
-- COMMENTS FOR DOCUMENTATION
-- ================================================================

COMMENT ON TABLE agent_sessions IS 'Primary routing table: maps phone numbers to agent endpoints for data transmission';
COMMENT ON COLUMN agent_sessions.phone_number IS 'User phone number in E.164 format (+15551234567)';
COMMENT ON COLUMN agent_sessions.agent_endpoint IS 'Cached endpoint URL to avoid JOIN during routing';
COMMENT ON COLUMN agent_sessions.session_state IS 'JSONB object storing conversation variables and context';
COMMENT ON COLUMN agent_sessions.conversation_context IS 'Array of recent messages for quick context lookup';
COMMENT ON COLUMN agent_sessions.session_hash IS 'SHA256 hash for secure session identification and validation';
COMMENT ON FUNCTION generate_session_hash IS 'Generate SHA256 hash from phone, agent, timestamp, and random UUID';
COMMENT ON FUNCTION verify_session_hash IS 'Verify session hash for secure session validation';
COMMENT ON FUNCTION get_or_create_session IS 'Atomic function to get existing session or create new one with SHA256 hash and health-aware load balancing (health score + capacity + response time)';
COMMENT ON FUNCTION failover_session_to_healthy_agent IS 'Failover session to a different healthy agent when current agent becomes unhealthy';
