-- ================================================================
-- DarkSpere: Universal Rate Limiting System
-- Purpose: Comprehensive rate limiting for SMS, API, and system resources
-- Data Flow: Request → Rate check → Allow/Deny → Track usage
-- ================================================================

-- ================================================================
-- RATE LIMIT DEFINITIONS
-- Define rate limit rules for different entity types
-- ================================================================

CREATE TABLE IF NOT EXISTS rate_limit_rules (
    -- Primary identifier
    rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Rule identification
    rule_name VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,

    -- Target entity type
    entity_type VARCHAR(50) NOT NULL, -- 'phone_number', 'user_id', 'ip_address', 'api_key', 'agent_id'

    -- Limit configuration
    limit_type VARCHAR(50) NOT NULL, -- 'sms_inbound', 'sms_outbound', 'api_call', 'agent_request'
    max_requests INTEGER NOT NULL,
    window_duration INTERVAL NOT NULL,

    -- Behavior on limit exceeded
    block_duration INTERVAL, -- NULL = reject but don't block, else block for this duration
    penalty_multiplier FLOAT DEFAULT 1.0, -- Increase block duration on repeat violations

    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    -- Priority (higher priority rules checked first)
    priority INTEGER DEFAULT 0,

    CONSTRAINT positive_max_requests CHECK (max_requests > 0)
);

-- ================================================================
-- RATE LIMIT TRACKING
-- Track current usage per entity
-- ================================================================

CREATE TABLE IF NOT EXISTS rate_limit_tracking (
    -- Primary identifier
    tracking_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Entity identification
    entity_type VARCHAR(50) NOT NULL,
    entity_value VARCHAR(255) NOT NULL,
    limit_type VARCHAR(50) NOT NULL,

    -- Window tracking
    window_start TIMESTAMP DEFAULT NOW(),
    window_duration INTERVAL NOT NULL,
    request_count INTEGER DEFAULT 0,
    max_requests INTEGER NOT NULL,

    -- Block status
    is_blocked BOOLEAN DEFAULT FALSE,
    blocked_at TIMESTAMP,
    blocked_until TIMESTAMP,
    block_reason TEXT,
    violation_count INTEGER DEFAULT 0, -- Number of times limit exceeded

    -- Last activity
    last_request_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(entity_type, entity_value, limit_type)
);

-- ================================================================
-- RATE LIMIT VIOLATIONS LOG
-- Audit trail of rate limit violations
-- ================================================================

CREATE TABLE IF NOT EXISTS rate_limit_violations (
    -- Primary identifier
    violation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Violation details
    entity_type VARCHAR(50) NOT NULL,
    entity_value VARCHAR(255) NOT NULL,
    limit_type VARCHAR(50) NOT NULL,

    -- Violation context
    violated_at TIMESTAMP DEFAULT NOW(),
    request_count INTEGER, -- Count at time of violation
    max_allowed INTEGER,
    window_duration INTERVAL,

    -- Block action taken
    was_blocked BOOLEAN DEFAULT FALSE,
    block_duration INTERVAL,

    -- Request context
    request_metadata JSONB DEFAULT '{}', -- IP, endpoint, etc.
    session_id UUID -- Reference to agent_sessions if applicable
);

-- ================================================================
-- CUSTOM RATE LIMIT OVERRIDES
-- Override default limits for specific entities (premium users, etc.)
-- ================================================================

CREATE TABLE IF NOT EXISTS rate_limit_overrides (
    -- Primary identifier
    override_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Override target
    entity_type VARCHAR(50) NOT NULL,
    entity_value VARCHAR(255) NOT NULL,
    limit_type VARCHAR(50) NOT NULL,

    -- Override values
    custom_max_requests INTEGER NOT NULL,
    custom_window_duration INTERVAL NOT NULL,

    -- Override metadata
    reason TEXT,
    created_by UUID REFERENCES user_accounts(user_id),
    created_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP,

    -- Status
    is_active BOOLEAN DEFAULT TRUE,

    UNIQUE(entity_type, entity_value, limit_type)
);

-- ================================================================
-- INDEXES FOR FAST RATE LIMIT CHECKS
-- ================================================================

-- Fast rule lookup
CREATE INDEX idx_rate_limit_rules_active ON rate_limit_rules(entity_type, limit_type, is_active, priority DESC)
WHERE is_active = TRUE;

-- Fast tracking lookup
CREATE INDEX idx_rate_limit_tracking_entity ON rate_limit_tracking(entity_type, entity_value, limit_type);

-- Check for blocked entities
CREATE INDEX idx_rate_limit_blocked ON rate_limit_tracking(entity_type, entity_value, is_blocked, blocked_until)
WHERE is_blocked = TRUE;

-- Override lookup
CREATE INDEX idx_rate_limit_overrides ON rate_limit_overrides(entity_type, entity_value, limit_type, is_active)
WHERE is_active = TRUE AND (expires_at IS NULL OR expires_at > NOW());

-- Violation analysis
CREATE INDEX idx_violations_time ON rate_limit_violations(violated_at DESC);
CREATE INDEX idx_violations_entity ON rate_limit_violations(entity_type, entity_value, violated_at DESC);

-- ================================================================
-- CORE RATE LIMITING FUNCTIONS
-- ================================================================

-- Check and enforce rate limit
CREATE OR REPLACE FUNCTION check_rate_limit(
    p_entity_type VARCHAR(50),
    p_entity_value VARCHAR(255),
    p_limit_type VARCHAR(50),
    p_request_metadata JSONB DEFAULT '{}',
    p_session_id UUID DEFAULT NULL
)
RETURNS TABLE(
    allowed BOOLEAN,
    current_count INTEGER,
    max_requests INTEGER,
    reset_at TIMESTAMP,
    is_blocked BOOLEAN,
    blocked_until TIMESTAMP,
    deny_reason TEXT
) AS $$
DECLARE
    v_rule RECORD;
    v_tracking RECORD;
    v_override RECORD;
    v_allowed BOOLEAN := TRUE;
    v_deny_reason TEXT := NULL;
    v_current_count INTEGER := 0;
    v_max_requests INTEGER;
    v_window_duration INTERVAL;
    v_reset_at TIMESTAMP;
    v_is_blocked BOOLEAN := FALSE;
    v_blocked_until TIMESTAMP := NULL;
BEGIN
    -- Check for custom override first
    SELECT * INTO v_override
    FROM rate_limit_overrides
    WHERE entity_type = p_entity_type
      AND entity_value = p_entity_value
      AND limit_type = p_limit_type
      AND is_active = TRUE
      AND (expires_at IS NULL OR expires_at > NOW());

    IF FOUND THEN
        v_max_requests := v_override.custom_max_requests;
        v_window_duration := v_override.custom_window_duration;
    ELSE
        -- Get default rule
        SELECT * INTO v_rule
        FROM rate_limit_rules
        WHERE entity_type = p_entity_type
          AND limit_type = p_limit_type
          AND is_active = TRUE
        ORDER BY priority DESC
        LIMIT 1;

        IF NOT FOUND THEN
            -- No rule defined, allow by default
            RETURN QUERY SELECT TRUE, 0, 999999, NULL::TIMESTAMP, FALSE, NULL::TIMESTAMP, NULL::TEXT;
            RETURN;
        END IF;

        v_max_requests := v_rule.max_requests;
        v_window_duration := v_rule.window_duration;
    END IF;

    -- Get or create tracking entry
    SELECT * INTO v_tracking
    FROM rate_limit_tracking
    WHERE entity_type = p_entity_type
      AND entity_value = p_entity_value
      AND limit_type = p_limit_type;

    IF NOT FOUND THEN
        -- Create new tracking entry
        INSERT INTO rate_limit_tracking (
            entity_type,
            entity_value,
            limit_type,
            window_duration,
            max_requests,
            request_count
        ) VALUES (
            p_entity_type,
            p_entity_value,
            p_limit_type,
            v_window_duration,
            v_max_requests,
            0
        ) RETURNING * INTO v_tracking;
    END IF;

    -- Check if currently blocked
    IF v_tracking.is_blocked AND v_tracking.blocked_until > NOW() THEN
        v_deny_reason := v_tracking.block_reason;
        RETURN QUERY SELECT
            FALSE,
            v_tracking.request_count,
            v_max_requests,
            v_tracking.blocked_until,
            TRUE,
            v_tracking.blocked_until,
            v_deny_reason;
        RETURN;
    END IF;

    -- Reset block if expired
    IF v_tracking.is_blocked AND v_tracking.blocked_until <= NOW() THEN
        UPDATE rate_limit_tracking
        SET is_blocked = FALSE,
            blocked_at = NULL,
            blocked_until = NULL,
            block_reason = NULL
        WHERE tracking_id = v_tracking.tracking_id;

        v_tracking.is_blocked := FALSE;
    END IF;

    -- Check if window expired
    IF NOW() > (v_tracking.window_start + v_tracking.window_duration) THEN
        -- Reset window
        UPDATE rate_limit_tracking
        SET window_start = NOW(),
            request_count = 1,
            last_request_at = NOW()
        WHERE tracking_id = v_tracking.tracking_id;

        v_reset_at := NOW() + v_window_duration;

        RETURN QUERY SELECT
            TRUE,
            1,
            v_max_requests,
            v_reset_at,
            FALSE,
            NULL::TIMESTAMP,
            NULL::TEXT;
        RETURN;
    END IF;

    -- Check if limit exceeded
    v_current_count := v_tracking.request_count;

    IF v_current_count >= v_max_requests THEN
        -- Limit exceeded - log violation
        INSERT INTO rate_limit_violations (
            entity_type,
            entity_value,
            limit_type,
            request_count,
            max_allowed,
            window_duration,
            request_metadata,
            session_id
        ) VALUES (
            p_entity_type,
            p_entity_value,
            p_limit_type,
            v_current_count,
            v_max_requests,
            v_window_duration,
            p_request_metadata,
            p_session_id
        );

        -- Check if should block
        IF v_rule.block_duration IS NOT NULL THEN
            -- Calculate block duration with penalty multiplier
            DECLARE
                v_block_duration INTERVAL;
            BEGIN
                v_block_duration := v_rule.block_duration * POWER(v_rule.penalty_multiplier, v_tracking.violation_count);
                v_blocked_until := NOW() + v_block_duration;

                UPDATE rate_limit_tracking
                SET is_blocked = TRUE,
                    blocked_at = NOW(),
                    blocked_until = v_blocked_until,
                    block_reason = 'Rate limit exceeded',
                    violation_count = violation_count + 1
                WHERE tracking_id = v_tracking.tracking_id;

                UPDATE rate_limit_violations
                SET was_blocked = TRUE,
                    block_duration = v_block_duration
                WHERE entity_type = p_entity_type
                  AND entity_value = p_entity_value
                  AND limit_type = p_limit_type
                  AND violated_at = (SELECT MAX(violated_at) FROM rate_limit_violations
                                     WHERE entity_type = p_entity_type
                                       AND entity_value = p_entity_value
                                       AND limit_type = p_limit_type);

                v_deny_reason := format('Rate limit exceeded. Blocked for %s', v_block_duration);
                v_is_blocked := TRUE;
            END;
        ELSE
            v_deny_reason := 'Rate limit exceeded';
        END IF;

        RETURN QUERY SELECT
            FALSE,
            v_current_count,
            v_max_requests,
            v_tracking.window_start + v_window_duration,
            v_is_blocked,
            v_blocked_until,
            v_deny_reason;
        RETURN;
    END IF;

    -- Increment counter
    UPDATE rate_limit_tracking
    SET request_count = request_count + 1,
        last_request_at = NOW()
    WHERE tracking_id = v_tracking.tracking_id;

    v_reset_at := v_tracking.window_start + v_window_duration;

    RETURN QUERY SELECT
        TRUE,
        v_current_count + 1,
        v_max_requests,
        v_reset_at,
        FALSE,
        NULL::TIMESTAMP,
        NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Create rate limit rule
CREATE OR REPLACE FUNCTION create_rate_limit_rule(
    p_rule_name VARCHAR(100),
    p_entity_type VARCHAR(50),
    p_limit_type VARCHAR(50),
    p_max_requests INTEGER,
    p_window_duration INTERVAL,
    p_block_duration INTERVAL DEFAULT NULL,
    p_description TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_rule_id UUID;
BEGIN
    INSERT INTO rate_limit_rules (
        rule_name,
        entity_type,
        limit_type,
        max_requests,
        window_duration,
        block_duration,
        description
    ) VALUES (
        p_rule_name,
        p_entity_type,
        p_limit_type,
        p_max_requests,
        p_window_duration,
        p_block_duration,
        p_description
    ) RETURNING rule_id INTO v_rule_id;

    RETURN v_rule_id;
END;
$$ LANGUAGE plpgsql;

-- Create rate limit override
CREATE OR REPLACE FUNCTION create_rate_limit_override(
    p_entity_type VARCHAR(50),
    p_entity_value VARCHAR(255),
    p_limit_type VARCHAR(50),
    p_custom_max_requests INTEGER,
    p_custom_window_duration INTERVAL,
    p_reason TEXT DEFAULT NULL,
    p_created_by UUID DEFAULT NULL,
    p_expires_at TIMESTAMP DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_override_id UUID;
BEGIN
    INSERT INTO rate_limit_overrides (
        entity_type,
        entity_value,
        limit_type,
        custom_max_requests,
        custom_window_duration,
        reason,
        created_by,
        expires_at
    ) VALUES (
        p_entity_type,
        p_entity_value,
        p_limit_type,
        p_custom_max_requests,
        p_custom_window_duration,
        p_reason,
        p_created_by,
        p_expires_at
    )
    ON CONFLICT (entity_type, entity_value, limit_type) DO UPDATE
    SET custom_max_requests = p_custom_max_requests,
        custom_window_duration = p_custom_window_duration,
        reason = p_reason,
        created_by = p_created_by,
        expires_at = p_expires_at,
        is_active = TRUE,
        created_at = NOW()
    RETURNING override_id INTO v_override_id;

    RETURN v_override_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT RATE LIMIT RULES
-- ================================================================

DO $$
BEGIN
    -- SMS rate limits (per phone number)
    PERFORM create_rate_limit_rule(
        'sms_inbound_default',
        'phone_number',
        'sms_inbound',
        60,
        '1 minute'::INTERVAL,
        '5 minutes'::INTERVAL,
        'Default inbound SMS rate limit: 60 per minute'
    );

    PERFORM create_rate_limit_rule(
        'sms_outbound_default',
        'phone_number',
        'sms_outbound',
        10,
        '1 minute'::INTERVAL,
        '10 minutes'::INTERVAL,
        'Default outbound SMS rate limit: 10 per minute to prevent spam'
    );

    -- API rate limits (per user)
    PERFORM create_rate_limit_rule(
        'api_call_default',
        'user_id',
        'api_call',
        1000,
        '1 hour'::INTERVAL,
        NULL,
        'Default API rate limit: 1000 calls per hour'
    );

    -- Agent request limits (per agent)
    PERFORM create_rate_limit_rule(
        'agent_request_default',
        'agent_id',
        'agent_request',
        100,
        '1 minute'::INTERVAL,
        NULL,
        'Default agent request limit: 100 per minute'
    );

    -- IP-based limits (anti-abuse)
    PERFORM create_rate_limit_rule(
        'ip_global_limit',
        'ip_address',
        'global_request',
        300,
        '1 minute'::INTERVAL,
        '15 minutes'::INTERVAL,
        'Global IP rate limit: 300 requests per minute'
    );
END $$;

-- ================================================================
-- VIEWS FOR MONITORING
-- ================================================================

-- Active rate limit violations
CREATE VIEW active_rate_limit_violations AS
SELECT
    entity_type,
    entity_value,
    limit_type,
    COUNT(*) AS violation_count,
    MAX(violated_at) AS last_violation,
    SUM(CASE WHEN was_blocked THEN 1 ELSE 0 END) AS block_count
FROM rate_limit_violations
WHERE violated_at > NOW() - INTERVAL '1 hour'
GROUP BY entity_type, entity_value, limit_type
ORDER BY violation_count DESC;

-- Current usage summary
CREATE VIEW rate_limit_usage_summary AS
SELECT
    rlt.entity_type,
    rlt.limit_type,
    COUNT(*) AS tracked_entities,
    SUM(rlt.request_count) AS total_requests,
    AVG(rlt.request_count) AS avg_requests_per_entity,
    MAX(rlt.request_count) AS max_requests,
    COUNT(*) FILTER (WHERE rlt.is_blocked) AS blocked_count,
    ROUND(AVG(rlt.request_count::FLOAT / rlt.max_requests * 100), 2) AS avg_utilization_pct
FROM rate_limit_tracking rlt
WHERE rlt.window_start > NOW() - INTERVAL '1 hour'
GROUP BY rlt.entity_type, rlt.limit_type;

-- ================================================================
-- CLEANUP FUNCTIONS
-- ================================================================

-- Clean up expired tracking entries
CREATE OR REPLACE FUNCTION cleanup_rate_limit_tracking()
RETURNS INTEGER AS $$
DECLARE
    v_deleted_count INTEGER;
BEGIN
    DELETE FROM rate_limit_tracking
    WHERE last_request_at < NOW() - INTERVAL '7 days'
      AND is_blocked = FALSE;

    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- TRIGGERS
-- ================================================================

-- Auto-update tracking timestamp
CREATE OR REPLACE FUNCTION update_rate_limit_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_rate_limit_rules
BEFORE UPDATE ON rate_limit_rules
FOR EACH ROW EXECUTE FUNCTION update_rate_limit_timestamp();

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE rate_limit_rules IS 'Defines rate limit rules for different entity types and actions';
COMMENT ON TABLE rate_limit_tracking IS 'Tracks current usage and enforces rate limits per entity';
COMMENT ON TABLE rate_limit_violations IS 'Audit log of all rate limit violations';
COMMENT ON TABLE rate_limit_overrides IS 'Custom rate limits for specific entities (premium users, etc.)';

COMMENT ON FUNCTION check_rate_limit IS 'Primary function to check and enforce rate limits with blocking';
COMMENT ON FUNCTION create_rate_limit_rule IS 'Creates a new rate limit rule for an entity type';
COMMENT ON FUNCTION create_rate_limit_override IS 'Creates custom rate limit for specific entity';
