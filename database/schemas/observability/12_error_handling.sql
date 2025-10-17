-- ================================================================
-- DarkSpere: Error Handling & Retry System
-- Purpose: Classify errors, implement retry policies, track failures
-- Pattern: Error → Classify → Retry → Escalate → Resolve
-- ================================================================

-- ================================================================
-- ERROR CLASSIFICATION
-- ================================================================

CREATE TYPE error_severity AS ENUM (
    'low',       -- Minor issue, doesn't affect functionality
    'medium',    -- Affects some functionality
    'high',      -- Critical functionality affected
    'critical'   -- System-wide failure
);

CREATE TYPE error_category AS ENUM (
    'network',           -- Network/connectivity errors
    'authentication',    -- Auth/permission errors
    'validation',        -- Input validation errors
    'rate_limit',        -- Rate limiting errors
    'agent_unavailable', -- Agent not responding
    'agent_error',       -- Agent returned error
    'database',          -- Database errors
    'external_api',      -- Third-party API errors
    'timeout',           -- Timeout errors
    'configuration',     -- Configuration errors
    'unknown'            -- Unclassified errors
);

CREATE TYPE retry_strategy AS ENUM (
    'immediate',     -- Retry immediately
    'exponential',   -- Exponential backoff
    'linear',        -- Linear backoff
    'fixed_delay',   -- Fixed delay between retries
    'no_retry'       -- Don't retry
);

-- ================================================================
-- ERROR LOG TABLE
-- Central error logging for all system components
-- ================================================================

CREATE TABLE IF NOT EXISTS error_log (
    -- Error identifier
    error_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Error classification
    error_code VARCHAR(100),
    error_category error_category NOT NULL,
    error_severity error_severity NOT NULL,

    -- Error details
    error_message TEXT NOT NULL,
    error_stack_trace TEXT,

    -- Context
    component VARCHAR(100), -- e.g., 'sms_router', 'agent_connector', 'webhook_handler'
    user_id UUID REFERENCES user_accounts(user_id),
    session_id UUID REFERENCES agent_sessions(session_id),
    agent_id UUID REFERENCES agent_registry(agent_id),

    -- Request context
    request_id VARCHAR(100), -- Correlation ID
    phone_number VARCHAR(20),
    endpoint VARCHAR(255),
    http_method VARCHAR(10),
    http_status_code INTEGER,

    -- Retry information
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    retry_strategy retry_strategy DEFAULT 'exponential',
    next_retry_at TIMESTAMP,

    -- Resolution
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at TIMESTAMP,
    resolution_notes TEXT,

    -- Metadata
    error_metadata JSONB DEFAULT '{}',
    occurred_at TIMESTAMP DEFAULT NOW(),
    created_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- RETRY CONFIGURATION TABLE
-- Define retry policies per error category/component
-- ================================================================

CREATE TABLE IF NOT EXISTS retry_configuration (
    -- Config identifier
    config_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Scope
    error_category error_category,
    component VARCHAR(100),

    -- Retry policy
    retry_strategy retry_strategy NOT NULL,
    max_retries INTEGER DEFAULT 3,
    base_delay_seconds INTEGER DEFAULT 1,
    max_delay_seconds INTEGER DEFAULT 300,
    backoff_multiplier DECIMAL(3,2) DEFAULT 2.0,

    -- Conditions
    retry_on_status_codes INTEGER[] DEFAULT ARRAY[500, 502, 503, 504],
    skip_retry_on_status_codes INTEGER[] DEFAULT ARRAY[400, 401, 403, 404],

    -- Circuit breaker
    circuit_breaker_threshold INTEGER DEFAULT 5, -- Open circuit after N failures
    circuit_breaker_timeout_seconds INTEGER DEFAULT 60,

    -- Metadata
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    -- Either category or component must be specified
    CHECK (error_category IS NOT NULL OR component IS NOT NULL)
);

-- ================================================================
-- RETRY ATTEMPTS TABLE
-- Track individual retry attempts
-- ================================================================

CREATE TABLE IF NOT EXISTS retry_attempts (
    -- Attempt identifier
    attempt_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Error reference
    error_id UUID NOT NULL REFERENCES error_log(error_id) ON DELETE CASCADE,

    -- Attempt details
    attempt_number INTEGER NOT NULL,
    attempted_at TIMESTAMP DEFAULT NOW(),

    -- Result
    success BOOLEAN NOT NULL,
    response_code INTEGER,
    response_message TEXT,
    response_time_ms INTEGER,

    -- Metadata
    attempt_metadata JSONB DEFAULT '{}'
);

-- ================================================================
-- CIRCUIT BREAKER STATE TABLE
-- Track circuit breaker state per component/endpoint
-- ================================================================

CREATE TABLE IF NOT EXISTS circuit_breaker_state (
    -- State identifier
    breaker_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Scope
    component VARCHAR(100) NOT NULL,
    endpoint VARCHAR(255),

    -- State
    state VARCHAR(20) DEFAULT 'closed', -- closed, open, half_open
    failure_count INTEGER DEFAULT 0,
    last_failure_at TIMESTAMP,

    -- Circuit breaker config
    threshold INTEGER DEFAULT 5,
    timeout_seconds INTEGER DEFAULT 60,

    -- State transitions
    opened_at TIMESTAMP,
    last_tested_at TIMESTAMP,

    -- Metadata
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE (component, endpoint)
);

-- ================================================================
-- INDEXES
-- ================================================================

-- Error log by category and severity
CREATE INDEX idx_error_log_category_severity ON error_log(error_category, error_severity, occurred_at DESC);

-- Unresolved errors
CREATE INDEX idx_error_log_unresolved ON error_log(is_resolved, occurred_at DESC)
WHERE is_resolved = FALSE;

-- Errors by component
CREATE INDEX idx_error_log_component ON error_log(component, occurred_at DESC);

-- Errors by request ID (correlation)
CREATE INDEX idx_error_log_request_id ON error_log(request_id)
WHERE request_id IS NOT NULL;

-- Errors pending retry
CREATE INDEX idx_error_log_retry_pending ON error_log(next_retry_at)
WHERE next_retry_at IS NOT NULL AND next_retry_at <= NOW() AND is_resolved = FALSE;

-- Retry attempts by error
CREATE INDEX idx_retry_attempts_error ON retry_attempts(error_id, attempted_at DESC);

-- ================================================================
-- ERROR HANDLING FUNCTIONS
-- ================================================================

-- Log an error with automatic retry scheduling
CREATE OR REPLACE FUNCTION log_error(
    p_error_code VARCHAR(100),
    p_error_category error_category,
    p_error_severity error_severity,
    p_error_message TEXT,
    p_component VARCHAR(100) DEFAULT NULL,
    p_request_id VARCHAR(100) DEFAULT NULL,
    p_user_id UUID DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_agent_id UUID DEFAULT NULL,
    p_error_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_error_id UUID;
    v_retry_config RECORD;
    v_next_retry_at TIMESTAMP;
BEGIN
    -- Get retry configuration
    SELECT * INTO v_retry_config
    FROM retry_configuration
    WHERE (error_category = p_error_category OR error_category IS NULL)
      AND (component = p_component OR component IS NULL)
      AND is_active = TRUE
    ORDER BY
        CASE WHEN error_category IS NOT NULL THEN 1 ELSE 2 END,
        CASE WHEN component IS NOT NULL THEN 1 ELSE 2 END
    LIMIT 1;

    -- Calculate next retry time
    IF v_retry_config IS NOT NULL AND v_retry_config.retry_strategy != 'no_retry' THEN
        v_next_retry_at := NOW() + (v_retry_config.base_delay_seconds || ' seconds')::INTERVAL;
    END IF;

    -- Insert error log
    INSERT INTO error_log (
        error_code,
        error_category,
        error_severity,
        error_message,
        component,
        request_id,
        user_id,
        session_id,
        agent_id,
        max_retries,
        retry_strategy,
        next_retry_at,
        error_metadata
    ) VALUES (
        p_error_code,
        p_error_category,
        p_error_severity,
        p_error_message,
        p_component,
        p_request_id,
        p_user_id,
        p_session_id,
        p_agent_id,
        COALESCE(v_retry_config.max_retries, 3),
        COALESCE(v_retry_config.retry_strategy, 'exponential'),
        v_next_retry_at,
        p_error_metadata
    ) RETURNING error_id INTO v_error_id;

    RETURN v_error_id;
END;
$$ LANGUAGE plpgsql;

-- Record a retry attempt
CREATE OR REPLACE FUNCTION record_retry_attempt(
    p_error_id UUID,
    p_success BOOLEAN,
    p_response_code INTEGER DEFAULT NULL,
    p_response_message TEXT DEFAULT NULL,
    p_response_time_ms INTEGER DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_attempt_id UUID;
    v_retry_count INTEGER;
    v_max_retries INTEGER;
    v_retry_strategy retry_strategy;
    v_base_delay INTEGER;
    v_backoff_multiplier DECIMAL(3,2);
    v_next_retry_at TIMESTAMP;
    v_delay_seconds INTEGER;
BEGIN
    -- Get current error info
    SELECT retry_count, max_retries, retry_strategy
    INTO v_retry_count, v_max_retries, v_retry_strategy
    FROM error_log
    WHERE error_id = p_error_id;

    v_retry_count := v_retry_count + 1;

    -- Insert retry attempt
    INSERT INTO retry_attempts (
        error_id,
        attempt_number,
        success,
        response_code,
        response_message,
        response_time_ms
    ) VALUES (
        p_error_id,
        v_retry_count,
        p_success,
        p_response_code,
        p_response_message,
        p_response_time_ms
    ) RETURNING attempt_id INTO v_attempt_id;

    -- Update error log
    IF p_success THEN
        -- Mark as resolved
        UPDATE error_log
        SET retry_count = v_retry_count,
            is_resolved = TRUE,
            resolved_at = NOW(),
            next_retry_at = NULL
        WHERE error_id = p_error_id;
    ELSE
        -- Calculate next retry time
        IF v_retry_count < v_max_retries THEN
            -- Get retry config
            SELECT base_delay_seconds, backoff_multiplier
            INTO v_base_delay, v_backoff_multiplier
            FROM retry_configuration rc
            JOIN error_log el ON
                (rc.error_category = el.error_category OR rc.error_category IS NULL) AND
                (rc.component = el.component OR rc.component IS NULL)
            WHERE el.error_id = p_error_id
              AND rc.is_active = TRUE
            ORDER BY
                CASE WHEN rc.error_category IS NOT NULL THEN 1 ELSE 2 END,
                CASE WHEN rc.component IS NOT NULL THEN 1 ELSE 2 END
            LIMIT 1;

            v_base_delay := COALESCE(v_base_delay, 1);
            v_backoff_multiplier := COALESCE(v_backoff_multiplier, 2.0);

            -- Calculate delay based on strategy
            CASE v_retry_strategy
                WHEN 'exponential' THEN
                    v_delay_seconds := (v_base_delay * (v_backoff_multiplier ^ v_retry_count))::INTEGER;
                WHEN 'linear' THEN
                    v_delay_seconds := v_base_delay * v_retry_count;
                WHEN 'fixed_delay' THEN
                    v_delay_seconds := v_base_delay;
                WHEN 'immediate' THEN
                    v_delay_seconds := 0;
                ELSE
                    v_delay_seconds := v_base_delay;
            END CASE;

            v_next_retry_at := NOW() + (v_delay_seconds || ' seconds')::INTERVAL;

            -- Update error log with next retry time
            UPDATE error_log
            SET retry_count = v_retry_count,
                next_retry_at = v_next_retry_at
            WHERE error_id = p_error_id;
        ELSE
            -- Max retries exceeded, mark as unresolvable
            UPDATE error_log
            SET retry_count = v_retry_count,
                next_retry_at = NULL,
                error_metadata = error_metadata || jsonb_build_object('max_retries_exceeded', TRUE)
            WHERE error_id = p_error_id;
        END IF;
    END IF;

    RETURN v_attempt_id;
END;
$$ LANGUAGE plpgsql;

-- Get errors ready for retry
CREATE OR REPLACE FUNCTION get_errors_for_retry()
RETURNS TABLE (
    error_id UUID,
    error_code VARCHAR(100),
    error_category error_category,
    component VARCHAR(100),
    retry_count INTEGER,
    max_retries INTEGER,
    error_metadata JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        el.error_id,
        el.error_code,
        el.error_category,
        el.component,
        el.retry_count,
        el.max_retries,
        el.error_metadata
    FROM error_log el
    WHERE el.next_retry_at IS NOT NULL
      AND el.next_retry_at <= NOW()
      AND el.is_resolved = FALSE
      AND el.retry_count < el.max_retries
    ORDER BY el.next_retry_at ASC
    LIMIT 100;
END;
$$ LANGUAGE plpgsql;

-- Check circuit breaker state
CREATE OR REPLACE FUNCTION check_circuit_breaker(
    p_component VARCHAR(100),
    p_endpoint VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE (
    state VARCHAR(20),
    failure_count INTEGER,
    can_proceed BOOLEAN
) AS $$
DECLARE
    v_state VARCHAR(20);
    v_failure_count INTEGER;
    v_threshold INTEGER;
    v_timeout_seconds INTEGER;
    v_opened_at TIMESTAMP;
    v_can_proceed BOOLEAN;
BEGIN
    -- Get circuit breaker state
    SELECT cbs.state, cbs.failure_count, cbs.threshold, cbs.timeout_seconds, cbs.opened_at
    INTO v_state, v_failure_count, v_threshold, v_timeout_seconds, v_opened_at
    FROM circuit_breaker_state cbs
    WHERE cbs.component = p_component
      AND (p_endpoint IS NULL OR cbs.endpoint = p_endpoint);

    -- If no state exists, circuit is closed
    IF v_state IS NULL THEN
        v_state := 'closed';
        v_failure_count := 0;
        v_can_proceed := TRUE;
    ELSIF v_state = 'open' THEN
        -- Check if timeout has passed (move to half_open)
        IF v_opened_at + (v_timeout_seconds || ' seconds')::INTERVAL <= NOW() THEN
            v_state := 'half_open';
            v_can_proceed := TRUE;

            -- Update state to half_open
            UPDATE circuit_breaker_state
            SET state = 'half_open',
                last_tested_at = NOW()
            WHERE component = p_component
              AND (p_endpoint IS NULL OR endpoint = p_endpoint);
        ELSE
            v_can_proceed := FALSE;
        END IF;
    ELSE
        v_can_proceed := TRUE;
    END IF;

    RETURN QUERY SELECT v_state, v_failure_count, v_can_proceed;
END;
$$ LANGUAGE plpgsql;

-- Record circuit breaker event
CREATE OR REPLACE FUNCTION record_circuit_breaker_event(
    p_component VARCHAR(100),
    p_endpoint VARCHAR(255),
    p_success BOOLEAN
)
RETURNS VOID AS $$
DECLARE
    v_failure_count INTEGER;
    v_threshold INTEGER;
    v_current_state VARCHAR(20);
BEGIN
    -- Upsert circuit breaker state
    INSERT INTO circuit_breaker_state (
        component,
        endpoint,
        failure_count,
        last_failure_at
    ) VALUES (
        p_component,
        p_endpoint,
        CASE WHEN p_success THEN 0 ELSE 1 END,
        CASE WHEN p_success THEN NULL ELSE NOW() END
    )
    ON CONFLICT (component, endpoint) DO UPDATE
    SET failure_count = CASE
            WHEN p_success THEN 0
            ELSE circuit_breaker_state.failure_count + 1
        END,
        last_failure_at = CASE
            WHEN p_success THEN NULL
            ELSE NOW()
        END,
        updated_at = NOW()
    RETURNING state, failure_count, threshold INTO v_current_state, v_failure_count, v_threshold;

    -- Check if circuit should open
    IF NOT p_success AND v_failure_count >= v_threshold AND v_current_state != 'open' THEN
        UPDATE circuit_breaker_state
        SET state = 'open',
            opened_at = NOW()
        WHERE component = p_component
          AND endpoint = p_endpoint;
    ELSIF p_success AND v_current_state IN ('half_open', 'open') THEN
        -- Close circuit on success
        UPDATE circuit_breaker_state
        SET state = 'closed',
            failure_count = 0,
            opened_at = NULL
        WHERE component = p_component
          AND endpoint = p_endpoint;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT RETRY CONFIGURATIONS
-- ================================================================

DO $$
BEGIN
    -- Network errors: exponential backoff
    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries,
        base_delay_seconds, backoff_multiplier
    ) VALUES (
        'network', 'exponential', 5, 1, 2.0
    ) ON CONFLICT DO NOTHING;

    -- Agent unavailable: exponential backoff with longer delays
    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries,
        base_delay_seconds, max_delay_seconds, backoff_multiplier
    ) VALUES (
        'agent_unavailable', 'exponential', 3, 5, 60, 2.0
    ) ON CONFLICT DO NOTHING;

    -- External API: linear backoff
    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries,
        base_delay_seconds
    ) VALUES (
        'external_api', 'linear', 3, 2
    ) ON CONFLICT DO NOTHING;

    -- Timeout: fixed delay
    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries,
        base_delay_seconds
    ) VALUES (
        'timeout', 'fixed_delay', 3, 5
    ) ON CONFLICT DO NOTHING;

    -- Authentication/validation: no retry
    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries
    ) VALUES (
        'authentication', 'no_retry', 0
    ) ON CONFLICT DO NOTHING;

    INSERT INTO retry_configuration (
        error_category, retry_strategy, max_retries
    ) VALUES (
        'validation', 'no_retry', 0
    ) ON CONFLICT DO NOTHING;
END $$;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE error_log IS 'Central error log with retry scheduling and resolution tracking';
COMMENT ON TABLE retry_configuration IS 'Retry policies per error category and component';
COMMENT ON TABLE retry_attempts IS 'Individual retry attempt records';
COMMENT ON TABLE circuit_breaker_state IS 'Circuit breaker state per component/endpoint';

COMMENT ON FUNCTION log_error IS 'Log error with automatic retry scheduling based on category';
COMMENT ON FUNCTION record_retry_attempt IS 'Record retry attempt and calculate next retry time';
COMMENT ON FUNCTION get_errors_for_retry IS 'Get errors ready for retry processing';
COMMENT ON FUNCTION check_circuit_breaker IS 'Check if circuit breaker allows requests';
COMMENT ON FUNCTION record_circuit_breaker_event IS 'Record success/failure and update circuit breaker state';
