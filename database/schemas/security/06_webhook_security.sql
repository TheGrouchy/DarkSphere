-- ================================================================
-- DarkSpere: Webhook Security & Validation
-- Purpose: Secure webhook endpoints with signature verification
-- Data Flow: Webhook received → Signature validation → Process or reject
-- ================================================================

-- ================================================================
-- WEBHOOK SECRETS TABLE
-- Store authentication secrets for external services
-- ================================================================

CREATE TABLE IF NOT EXISTS webhook_secrets (
    -- Primary identifier
    secret_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Provider identification
    provider VARCHAR(50) NOT NULL, -- 'twilio', 'stripe', 'github', etc.
    environment VARCHAR(20) DEFAULT 'production', -- 'development', 'staging', 'production'

    -- Secret data (encrypted at rest recommended)
    secret_key TEXT NOT NULL,
    algorithm VARCHAR(20) DEFAULT 'hmac-sha256', -- 'hmac-sha1', 'hmac-sha256', 'ed25519'

    -- Rotation management
    created_at TIMESTAMP DEFAULT NOW(),
    rotated_at TIMESTAMP,
    previous_secret_key TEXT, -- Keep old secret during rotation period

    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    deactivated_at TIMESTAMP,

    -- Metadata
    created_by UUID REFERENCES user_accounts(user_id),
    notes TEXT,

    -- Constraint: only one active secret per provider/environment
    UNIQUE(provider, environment, is_active) DEFERRABLE INITIALLY DEFERRED
);

-- ================================================================
-- WEBHOOK AUDIT LOG
-- Track all webhook attempts for security monitoring
-- ================================================================

CREATE TABLE IF NOT EXISTS webhook_audit_log (
    -- Primary identifier
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Webhook details
    provider VARCHAR(50) NOT NULL,
    webhook_endpoint TEXT NOT NULL, -- e.g., '/webhook/sms/incoming'

    -- Validation
    signature_valid BOOLEAN,
    signature_header TEXT,
    computed_signature TEXT,

    -- Request data
    request_timestamp TIMESTAMP DEFAULT NOW(),
    request_method VARCHAR(10), -- GET, POST, etc.
    request_headers JSONB,
    request_body JSONB,
    request_body_raw TEXT, -- For signature verification

    -- Source
    ip_address INET,
    user_agent TEXT,

    -- Validation details
    validation_error TEXT,
    validation_duration_ms INTEGER,

    -- Response
    response_status INTEGER,
    response_body JSONB,

    -- Processing
    processing_status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'processed', 'failed'
    n8n_execution_id VARCHAR(100)
);

-- ================================================================
-- WEBHOOK RATE LIMITING
-- Prevent webhook abuse
-- ================================================================

CREATE TABLE IF NOT EXISTS webhook_rate_limits (
    -- Primary identifier
    limit_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Target
    provider VARCHAR(50) NOT NULL,
    ip_address INET,

    -- Rate limit tracking
    request_count INTEGER DEFAULT 0,
    window_start TIMESTAMP DEFAULT NOW(),
    window_duration INTERVAL DEFAULT '1 minute',
    max_requests INTEGER DEFAULT 60,

    -- Status
    is_blocked BOOLEAN DEFAULT FALSE,
    blocked_until TIMESTAMP,
    block_reason TEXT,

    UNIQUE(provider, ip_address)
);

-- ================================================================
-- BLOCKED IPS TABLE
-- Permanently block malicious IPs
-- ================================================================

CREATE TABLE IF NOT EXISTS webhook_blocked_ips (
    -- Primary identifier
    block_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- IP details
    ip_address INET NOT NULL UNIQUE,
    ip_range CIDR, -- For blocking entire ranges

    -- Block details
    blocked_at TIMESTAMP DEFAULT NOW(),
    blocked_by UUID REFERENCES user_accounts(user_id),
    block_reason TEXT NOT NULL,

    -- Auto-unblock
    unblock_at TIMESTAMP,
    is_permanent BOOLEAN DEFAULT FALSE,

    -- Status
    is_active BOOLEAN DEFAULT TRUE
);

-- ================================================================
-- INDEXES FOR FAST VALIDATION
-- ================================================================

-- Fast secret lookup for validation
CREATE INDEX idx_webhook_secrets_active ON webhook_secrets(provider, environment, is_active)
WHERE is_active = TRUE;

-- Audit log analysis
CREATE INDEX idx_webhook_audit_time ON webhook_audit_log(request_timestamp DESC);
CREATE INDEX idx_webhook_audit_invalid ON webhook_audit_log(signature_valid, request_timestamp DESC)
WHERE signature_valid = FALSE;
CREATE INDEX idx_webhook_audit_provider ON webhook_audit_log(provider, request_timestamp DESC);

-- Rate limit lookup
CREATE INDEX idx_webhook_rate_limits ON webhook_rate_limits(provider, ip_address);

-- IP blocking
CREATE INDEX idx_blocked_ips_active ON webhook_blocked_ips(ip_address, is_active)
WHERE is_active = TRUE;

-- ================================================================
-- WEBHOOK VALIDATION FUNCTIONS
-- ================================================================

-- Validate Twilio webhook signature
CREATE OR REPLACE FUNCTION validate_twilio_signature(
    p_url TEXT,
    p_params JSONB,
    p_signature TEXT
)
RETURNS TABLE(
    is_valid BOOLEAN,
    error_message TEXT,
    validation_duration_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMP;
    v_auth_token TEXT;
    v_data TEXT;
    v_computed_signature TEXT;
    v_is_valid BOOLEAN := FALSE;
    v_error TEXT := NULL;
    v_duration INTEGER;
BEGIN
    v_start_time := clock_timestamp();

    -- Get active Twilio auth token
    SELECT secret_key INTO v_auth_token
    FROM webhook_secrets
    WHERE provider = 'twilio'
      AND environment = 'production'
      AND is_active = TRUE
    LIMIT 1;

    IF v_auth_token IS NULL THEN
        v_error := 'No active Twilio auth token configured';
        v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
        RETURN QUERY SELECT FALSE, v_error, v_duration::INTEGER;
        RETURN;
    END IF;

    -- Build data string for signature: URL + sorted params
    WITH sorted_params AS (
        SELECT key, value
        FROM jsonb_each_text(p_params)
        ORDER BY key
    )
    SELECT p_url || string_agg(key || value, '' ORDER BY key) INTO v_data
    FROM sorted_params;

    -- Compute HMAC-SHA1 signature (Twilio uses SHA1)
    v_computed_signature := encode(
        hmac(v_data::bytea, v_auth_token::bytea, 'sha1'),
        'base64'
    );

    -- Validate signature
    v_is_valid := (v_computed_signature = p_signature);

    IF NOT v_is_valid THEN
        v_error := 'Signature mismatch';
    END IF;

    v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;

    RETURN QUERY SELECT v_is_valid, v_error, v_duration::INTEGER;
END;
$$ LANGUAGE plpgsql;

-- Validate Stripe webhook signature
CREATE OR REPLACE FUNCTION validate_stripe_signature(
    p_payload TEXT,
    p_signature_header TEXT
)
RETURNS TABLE(
    is_valid BOOLEAN,
    error_message TEXT,
    validation_duration_ms INTEGER
) AS $$
DECLARE
    v_start_time TIMESTAMP;
    v_signing_secret TEXT;
    v_timestamp TEXT;
    v_signature TEXT;
    v_computed_signature TEXT;
    v_signed_payload TEXT;
    v_is_valid BOOLEAN := FALSE;
    v_error TEXT := NULL;
    v_duration INTEGER;
BEGIN
    v_start_time := clock_timestamp();

    -- Get Stripe webhook secret
    SELECT secret_key INTO v_signing_secret
    FROM webhook_secrets
    WHERE provider = 'stripe'
      AND environment = 'production'
      AND is_active = TRUE
    LIMIT 1;

    IF v_signing_secret IS NULL THEN
        v_error := 'No active Stripe webhook secret configured';
        v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
        RETURN QUERY SELECT FALSE, v_error, v_duration::INTEGER;
        RETURN;
    END IF;

    -- Parse signature header (format: "t=timestamp,v1=signature")
    v_timestamp := substring(p_signature_header from 't=([0-9]+)');
    v_signature := substring(p_signature_header from 'v1=([a-f0-9]+)');

    IF v_timestamp IS NULL OR v_signature IS NULL THEN
        v_error := 'Invalid signature header format';
        v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
        RETURN QUERY SELECT FALSE, v_error, v_duration::INTEGER;
        RETURN;
    END IF;

    -- Check timestamp tolerance (5 minutes)
    IF (EXTRACT(EPOCH FROM NOW()) - v_timestamp::INTEGER) > 300 THEN
        v_error := 'Timestamp outside tolerance window';
        v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;
        RETURN QUERY SELECT FALSE, v_error, v_duration::INTEGER;
        RETURN;
    END IF;

    -- Build signed payload
    v_signed_payload := v_timestamp || '.' || p_payload;

    -- Compute HMAC-SHA256
    v_computed_signature := encode(
        hmac(v_signed_payload::bytea, v_signing_secret::bytea, 'sha256'),
        'hex'
    );

    -- Validate
    v_is_valid := (v_computed_signature = v_signature);

    IF NOT v_is_valid THEN
        v_error := 'Signature mismatch';
    END IF;

    v_duration := EXTRACT(EPOCH FROM (clock_timestamp() - v_start_time)) * 1000;

    RETURN QUERY SELECT v_is_valid, v_error, v_duration::INTEGER;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- RATE LIMITING FUNCTIONS
-- ================================================================

-- Check webhook rate limit
CREATE OR REPLACE FUNCTION check_webhook_rate_limit(
    p_provider VARCHAR(50),
    p_ip_address INET,
    p_max_requests INTEGER DEFAULT 60,
    p_window_duration INTERVAL DEFAULT '1 minute'
)
RETURNS TABLE(
    allowed BOOLEAN,
    current_count INTEGER,
    max_requests INTEGER,
    reset_at TIMESTAMP,
    block_reason TEXT
) AS $$
DECLARE
    v_limit RECORD;
    v_allowed BOOLEAN := TRUE;
    v_block_reason TEXT := NULL;
BEGIN
    -- Check if IP is permanently blocked
    IF EXISTS (
        SELECT 1 FROM webhook_blocked_ips
        WHERE ip_address = p_ip_address
          AND is_active = TRUE
          AND (is_permanent OR unblock_at > NOW())
    ) THEN
        SELECT block_reason INTO v_block_reason
        FROM webhook_blocked_ips
        WHERE ip_address = p_ip_address AND is_active = TRUE
        LIMIT 1;

        RETURN QUERY SELECT FALSE, 0, 0, NULL::TIMESTAMP, v_block_reason;
        RETURN;
    END IF;

    -- Get or create rate limit entry
    INSERT INTO webhook_rate_limits (
        provider,
        ip_address,
        max_requests,
        window_duration
    ) VALUES (
        p_provider,
        p_ip_address,
        p_max_requests,
        p_window_duration
    )
    ON CONFLICT (provider, ip_address) DO NOTHING;

    -- Get current limit status
    SELECT * INTO v_limit
    FROM webhook_rate_limits
    WHERE provider = p_provider AND ip_address = p_ip_address;

    -- Check if window expired
    IF NOW() > (v_limit.window_start + v_limit.window_duration) THEN
        -- Reset window
        UPDATE webhook_rate_limits
        SET request_count = 1,
            window_start = NOW(),
            is_blocked = FALSE,
            blocked_until = NULL
        WHERE provider = p_provider AND ip_address = p_ip_address;

        RETURN QUERY SELECT TRUE, 1, v_limit.max_requests,
            (NOW() + v_limit.window_duration)::TIMESTAMP, NULL::TEXT;
        RETURN;
    END IF;

    -- Check if blocked
    IF v_limit.is_blocked AND v_limit.blocked_until > NOW() THEN
        RETURN QUERY SELECT FALSE, v_limit.request_count, v_limit.max_requests,
            v_limit.blocked_until, v_limit.block_reason;
        RETURN;
    END IF;

    -- Check if limit exceeded
    IF v_limit.request_count >= v_limit.max_requests THEN
        -- Block temporarily
        UPDATE webhook_rate_limits
        SET is_blocked = TRUE,
            blocked_until = NOW() + INTERVAL '5 minutes',
            block_reason = 'Rate limit exceeded'
        WHERE provider = p_provider AND ip_address = p_ip_address;

        RETURN QUERY SELECT FALSE, v_limit.request_count, v_limit.max_requests,
            (NOW() + INTERVAL '5 minutes')::TIMESTAMP, 'Rate limit exceeded'::TEXT;
        RETURN;
    END IF;

    -- Increment counter
    UPDATE webhook_rate_limits
    SET request_count = request_count + 1
    WHERE provider = p_provider AND ip_address = p_ip_address;

    RETURN QUERY SELECT TRUE, v_limit.request_count + 1, v_limit.max_requests,
        (v_limit.window_start + v_limit.window_duration)::TIMESTAMP, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Block IP address
CREATE OR REPLACE FUNCTION block_webhook_ip(
    p_ip_address INET,
    p_reason TEXT,
    p_is_permanent BOOLEAN DEFAULT FALSE,
    p_unblock_hours INTEGER DEFAULT 24,
    p_blocked_by UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_block_id UUID;
    v_unblock_at TIMESTAMP := NULL;
BEGIN
    IF NOT p_is_permanent THEN
        v_unblock_at := NOW() + (p_unblock_hours || ' hours')::INTERVAL;
    END IF;

    INSERT INTO webhook_blocked_ips (
        ip_address,
        block_reason,
        is_permanent,
        unblock_at,
        blocked_by
    ) VALUES (
        p_ip_address,
        p_reason,
        p_is_permanent,
        v_unblock_at,
        p_blocked_by
    )
    ON CONFLICT (ip_address) DO UPDATE
    SET is_active = TRUE,
        blocked_at = NOW(),
        block_reason = p_reason,
        is_permanent = p_is_permanent,
        unblock_at = v_unblock_at,
        blocked_by = p_blocked_by
    RETURNING block_id INTO v_block_id;

    RETURN v_block_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- AUDIT LOGGING FUNCTIONS
-- ================================================================

-- Log webhook attempt
CREATE OR REPLACE FUNCTION log_webhook_attempt(
    p_provider VARCHAR(50),
    p_webhook_endpoint TEXT,
    p_signature_valid BOOLEAN,
    p_signature_header TEXT,
    p_request_method VARCHAR(10),
    p_request_headers JSONB,
    p_request_body JSONB,
    p_request_body_raw TEXT,
    p_ip_address INET,
    p_validation_error TEXT DEFAULT NULL,
    p_validation_duration_ms INTEGER DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_log_id UUID;
BEGIN
    INSERT INTO webhook_audit_log (
        provider,
        webhook_endpoint,
        signature_valid,
        signature_header,
        request_method,
        request_headers,
        request_body,
        request_body_raw,
        ip_address,
        user_agent,
        validation_error,
        validation_duration_ms
    ) VALUES (
        p_provider,
        p_webhook_endpoint,
        p_signature_valid,
        p_signature_header,
        p_request_method,
        p_request_headers,
        p_request_body,
        p_request_body_raw,
        p_ip_address,
        p_request_headers->>'user-agent',
        p_validation_error,
        p_validation_duration_ms
    ) RETURNING log_id INTO v_log_id;

    RETURN v_log_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- SECRET ROTATION FUNCTIONS
-- ================================================================

-- Rotate webhook secret
CREATE OR REPLACE FUNCTION rotate_webhook_secret(
    p_provider VARCHAR(50),
    p_new_secret TEXT,
    p_environment VARCHAR(20) DEFAULT 'production'
)
RETURNS UUID AS $$
DECLARE
    v_old_secret TEXT;
    v_secret_id UUID;
BEGIN
    -- Get current secret
    SELECT secret_key, secret_id INTO v_old_secret, v_secret_id
    FROM webhook_secrets
    WHERE provider = p_provider
      AND environment = p_environment
      AND is_active = TRUE;

    IF v_secret_id IS NULL THEN
        -- No existing secret, create new
        INSERT INTO webhook_secrets (
            provider,
            environment,
            secret_key
        ) VALUES (
            p_provider,
            p_environment,
            p_new_secret
        ) RETURNING secret_id INTO v_secret_id;
    ELSE
        -- Update existing secret, keep old one during rotation
        UPDATE webhook_secrets
        SET secret_key = p_new_secret,
            previous_secret_key = v_old_secret,
            rotated_at = NOW()
        WHERE secret_id = v_secret_id;
    END IF;

    RETURN v_secret_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- VIEWS FOR SECURITY MONITORING
-- ================================================================

-- Failed webhook attempts summary
CREATE VIEW webhook_security_alerts AS
SELECT
    provider,
    ip_address,
    COUNT(*) AS failed_attempts,
    MAX(request_timestamp) AS last_attempt,
    array_agg(DISTINCT validation_error) AS error_types
FROM webhook_audit_log
WHERE signature_valid = FALSE
  AND request_timestamp > NOW() - INTERVAL '1 hour'
GROUP BY provider, ip_address
HAVING COUNT(*) >= 3; -- 3+ failures in 1 hour

-- Webhook health summary
CREATE VIEW webhook_health_summary AS
SELECT
    provider,
    COUNT(*) AS total_requests,
    COUNT(*) FILTER (WHERE signature_valid = TRUE) AS valid_requests,
    COUNT(*) FILTER (WHERE signature_valid = FALSE) AS invalid_requests,
    ROUND(AVG(validation_duration_ms)::NUMERIC, 2) AS avg_validation_ms,
    MAX(request_timestamp) AS last_request
FROM webhook_audit_log
WHERE request_timestamp > NOW() - INTERVAL '24 hours'
GROUP BY provider;

-- ================================================================
-- TRIGGERS
-- ================================================================

-- Auto-cleanup old audit logs (keep 90 days)
CREATE OR REPLACE FUNCTION cleanup_old_webhook_logs()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM webhook_audit_log
    WHERE request_timestamp < NOW() - INTERVAL '90 days';

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_cleanup_webhook_logs
AFTER INSERT ON webhook_audit_log
FOR EACH STATEMENT EXECUTE FUNCTION cleanup_old_webhook_logs();

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE webhook_secrets IS 'Stores authentication secrets for webhook providers';
COMMENT ON TABLE webhook_audit_log IS 'Complete audit trail of all webhook attempts';
COMMENT ON TABLE webhook_rate_limits IS 'Rate limiting to prevent webhook abuse';
COMMENT ON TABLE webhook_blocked_ips IS 'Permanently or temporarily blocked IPs';

COMMENT ON FUNCTION validate_twilio_signature IS 'Validates Twilio webhook signature using HMAC-SHA1';
COMMENT ON FUNCTION validate_stripe_signature IS 'Validates Stripe webhook signature using HMAC-SHA256';
COMMENT ON FUNCTION check_webhook_rate_limit IS 'Enforces rate limits on webhook requests per IP';
COMMENT ON FUNCTION log_webhook_attempt IS 'Records webhook attempt with validation results';
