-- ================================================================
-- DarkSpere: Feature Gates System
-- Purpose: Control feature access based on subscription tier
-- Pattern: Check feature → Enforce limit → Track usage
-- ================================================================

-- ================================================================
-- FEATURE DEFINITION
-- ================================================================

CREATE TYPE feature_type AS ENUM (
    'sms_inbound',              -- Receive SMS
    'sms_outbound',             -- Send SMS
    'agent_routing',            -- Route to AI agents
    'mcp_protocol',             -- MCP protocol support
    'api_access',               -- API access
    'webhook_custom',           -- Custom webhooks
    'health_monitoring',        -- Agent health monitoring
    'priority_routing',         -- Priority agent routing
    'analytics_dashboard',      -- Usage analytics
    'custom_agents',            -- Custom agent deployment
    'multi_phone',              -- Multiple phone numbers
    'team_collaboration',       -- Team features
    'advanced_security',        -- Advanced security features
    'dedicated_support'         -- Dedicated support
);

-- ================================================================
-- FEATURE GATES TABLE
-- Define which features are available per tier
-- ================================================================

CREATE TABLE IF NOT EXISTS feature_gates (
    -- Gate identifier
    gate_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Feature definition
    feature_name feature_type NOT NULL,
    display_name VARCHAR(100) NOT NULL,
    description TEXT,

    -- Tier availability
    available_on_free BOOLEAN DEFAULT FALSE,
    available_on_pro BOOLEAN DEFAULT FALSE,
    available_on_enterprise BOOLEAN DEFAULT TRUE,

    -- Limits per tier (NULL = unlimited)
    free_tier_limit INTEGER,
    pro_tier_limit INTEGER,
    enterprise_tier_limit INTEGER,

    -- Feature configuration
    feature_config JSONB DEFAULT '{}',

    -- Status
    is_enabled BOOLEAN DEFAULT TRUE,

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE (feature_name)
);

-- ================================================================
-- USER FEATURE OVERRIDES TABLE
-- Per-user feature overrides (for custom deals, beta access)
-- ================================================================

CREATE TABLE IF NOT EXISTS user_feature_overrides (
    -- Override identifier
    override_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,

    -- Feature reference
    feature_name feature_type NOT NULL,

    -- Override settings
    is_enabled BOOLEAN NOT NULL,
    custom_limit INTEGER, -- NULL = use tier default or unlimited

    -- Reason and expiry
    override_reason TEXT,
    expires_at TIMESTAMP, -- NULL = permanent

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    created_by UUID, -- Admin user who created override

    UNIQUE (user_id, feature_name)
);

-- ================================================================
-- FEATURE USAGE TRACKING
-- Track feature usage for enforcement
-- ================================================================

CREATE TABLE IF NOT EXISTS feature_usage (
    -- Usage identifier
    usage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,

    -- Feature reference
    feature_name feature_type NOT NULL,

    -- Usage timestamp
    used_at TIMESTAMP DEFAULT NOW(),

    -- Usage metadata
    usage_metadata JSONB DEFAULT '{}',

    -- Session context (if applicable)
    session_id UUID REFERENCES agent_sessions(session_id)
);

-- ================================================================
-- INDEXES
-- ================================================================

-- Feature usage by user and feature
CREATE INDEX idx_feature_usage_user_feature ON feature_usage(user_id, feature_name, used_at DESC);

-- Active overrides
CREATE INDEX idx_feature_overrides_active ON user_feature_overrides(user_id, feature_name)
WHERE is_enabled = TRUE AND (expires_at IS NULL OR expires_at > NOW());

-- ================================================================
-- FEATURE ACCESS FUNCTIONS
-- ================================================================

-- Check if user has access to feature
CREATE OR REPLACE FUNCTION has_feature_access(
    p_user_id UUID,
    p_feature_name feature_type
)
RETURNS TABLE (
    has_access BOOLEAN,
    tier subscription_tier,
    limit_value INTEGER,
    current_usage INTEGER,
    remaining INTEGER,
    deny_reason TEXT
) AS $$
DECLARE
    v_user_tier subscription_tier;
    v_feature_limit INTEGER;
    v_current_usage INTEGER;
    v_has_access BOOLEAN := FALSE;
    v_override_enabled BOOLEAN;
    v_override_limit INTEGER;
    v_deny_reason TEXT;
BEGIN
    -- Get user's subscription tier
    SELECT sp.tier
    INTO v_user_tier
    FROM user_subscriptions us
    JOIN subscription_plans sp ON us.plan_id = sp.plan_id
    WHERE us.user_id = p_user_id
      AND us.status = 'active'
      AND us.current_period_start <= NOW()
      AND us.current_period_end >= NOW()
    ORDER BY us.created_at DESC
    LIMIT 1;

    -- Default to free tier if no subscription
    v_user_tier := COALESCE(v_user_tier, 'free');

    -- Check for user-specific override
    SELECT is_enabled, custom_limit
    INTO v_override_enabled, v_override_limit
    FROM user_feature_overrides
    WHERE user_id = p_user_id
      AND feature_name = p_feature_name
      AND (expires_at IS NULL OR expires_at > NOW());

    -- If override exists, use it
    IF v_override_enabled IS NOT NULL THEN
        IF v_override_enabled = TRUE THEN
            v_has_access := TRUE;
            v_feature_limit := v_override_limit;
        ELSE
            v_has_access := FALSE;
            v_deny_reason := 'Feature explicitly disabled for user';
        END IF;
    ELSE
        -- Check feature gate for tier
        SELECT
            CASE v_user_tier
                WHEN 'free' THEN fg.available_on_free
                WHEN 'pro' THEN fg.available_on_pro
                WHEN 'enterprise' THEN fg.available_on_enterprise
                ELSE FALSE
            END,
            CASE v_user_tier
                WHEN 'free' THEN fg.free_tier_limit
                WHEN 'pro' THEN fg.pro_tier_limit
                WHEN 'enterprise' THEN fg.enterprise_tier_limit
                ELSE NULL
            END
        INTO v_has_access, v_feature_limit
        FROM feature_gates fg
        WHERE fg.feature_name = p_feature_name
          AND fg.is_enabled = TRUE;

        -- If feature gate not found, deny by default
        IF v_has_access IS NULL THEN
            v_has_access := FALSE;
            v_deny_reason := 'Feature not configured';
        ELSIF v_has_access = FALSE THEN
            v_deny_reason := format('Feature not available on %s tier', v_user_tier);
        END IF;
    END IF;

    -- If access granted, check usage limit
    IF v_has_access = TRUE AND v_feature_limit IS NOT NULL THEN
        -- Get current usage (this month)
        SELECT COUNT(*)::INTEGER
        INTO v_current_usage
        FROM feature_usage
        WHERE user_id = p_user_id
          AND feature_name = p_feature_name
          AND used_at >= date_trunc('month', NOW());

        v_current_usage := COALESCE(v_current_usage, 0);

        -- Check if limit exceeded
        IF v_current_usage >= v_feature_limit THEN
            v_has_access := FALSE;
            v_deny_reason := format('Monthly limit exceeded (%s/%s)', v_current_usage, v_feature_limit);
        END IF;
    ELSE
        v_current_usage := 0;
    END IF;

    -- Return result
    RETURN QUERY SELECT
        v_has_access,
        v_user_tier,
        v_feature_limit,
        v_current_usage,
        GREATEST(0, COALESCE(v_feature_limit, 999999) - v_current_usage) AS remaining,
        v_deny_reason;
END;
$$ LANGUAGE plpgsql;

-- Record feature usage
CREATE OR REPLACE FUNCTION record_feature_usage(
    p_user_id UUID,
    p_feature_name feature_type,
    p_session_id UUID DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_usage_id UUID;
    v_has_access BOOLEAN;
BEGIN
    -- Check access first
    SELECT has_access INTO v_has_access
    FROM has_feature_access(p_user_id, p_feature_name);

    IF v_has_access = FALSE THEN
        RAISE EXCEPTION 'User does not have access to feature: %', p_feature_name;
    END IF;

    -- Record usage
    INSERT INTO feature_usage (
        user_id,
        feature_name,
        session_id,
        usage_metadata
    ) VALUES (
        p_user_id,
        p_feature_name,
        p_session_id,
        p_metadata
    ) RETURNING usage_id INTO v_usage_id;

    RETURN v_usage_id;
END;
$$ LANGUAGE plpgsql;

-- Grant feature override to user
CREATE OR REPLACE FUNCTION grant_feature_override(
    p_user_id UUID,
    p_feature_name feature_type,
    p_is_enabled BOOLEAN,
    p_custom_limit INTEGER DEFAULT NULL,
    p_override_reason TEXT DEFAULT 'Manual grant',
    p_expires_at TIMESTAMP DEFAULT NULL,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_override_id UUID;
BEGIN
    INSERT INTO user_feature_overrides (
        user_id,
        feature_name,
        is_enabled,
        custom_limit,
        override_reason,
        expires_at,
        created_by
    ) VALUES (
        p_user_id,
        p_feature_name,
        p_is_enabled,
        p_custom_limit,
        p_override_reason,
        p_expires_at,
        p_created_by
    )
    ON CONFLICT (user_id, feature_name) DO UPDATE
    SET is_enabled = EXCLUDED.is_enabled,
        custom_limit = EXCLUDED.custom_limit,
        override_reason = EXCLUDED.override_reason,
        expires_at = EXCLUDED.expires_at,
        created_by = EXCLUDED.created_by,
        created_at = NOW()
    RETURNING override_id INTO v_override_id;

    RETURN v_override_id;
END;
$$ LANGUAGE plpgsql;

-- Get user's feature access summary
CREATE OR REPLACE FUNCTION get_user_features(p_user_id UUID)
RETURNS TABLE (
    feature_name feature_type,
    display_name VARCHAR(100),
    has_access BOOLEAN,
    tier subscription_tier,
    limit_value INTEGER,
    current_usage INTEGER,
    remaining INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        fg.feature_name,
        fg.display_name,
        fa.has_access,
        fa.tier,
        fa.limit_value,
        fa.current_usage,
        fa.remaining
    FROM feature_gates fg
    CROSS JOIN LATERAL has_feature_access(p_user_id, fg.feature_name) fa
    WHERE fg.is_enabled = TRUE
    ORDER BY fg.feature_name;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT FEATURE GATES
-- ================================================================

DO $$
BEGIN
    -- SMS Inbound
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit, enterprise_tier_limit
    ) VALUES (
        'sms_inbound', 'SMS Inbound', 'Receive SMS messages',
        TRUE, TRUE, TRUE,
        100, 5000, NULL
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- SMS Outbound
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit, enterprise_tier_limit
    ) VALUES (
        'sms_outbound', 'SMS Outbound', 'Send SMS messages',
        TRUE, TRUE, TRUE,
        50, 2000, NULL
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Agent Routing
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit
    ) VALUES (
        'agent_routing', 'Agent Routing', 'Route messages to AI agents',
        TRUE, TRUE, TRUE,
        500, 10000
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- MCP Protocol
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'mcp_protocol', 'MCP Protocol', 'Model Context Protocol support',
        FALSE, TRUE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- API Access
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit
    ) VALUES (
        'api_access', 'API Access', 'REST API access',
        TRUE, TRUE, TRUE,
        1000, 50000
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Priority Routing
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'priority_routing', 'Priority Routing', 'Priority agent routing with health scores',
        FALSE, TRUE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Health Monitoring
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'health_monitoring', 'Health Monitoring', 'Agent health monitoring dashboard',
        FALSE, TRUE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Custom Agents
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit
    ) VALUES (
        'custom_agents', 'Custom Agents', 'Deploy custom AI agents',
        FALSE, TRUE, TRUE,
        NULL, 5
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Multi Phone
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise,
        free_tier_limit, pro_tier_limit
    ) VALUES (
        'multi_phone', 'Multiple Phone Numbers', 'Link multiple phone numbers',
        FALSE, TRUE, TRUE,
        NULL, 10
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Analytics Dashboard
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'analytics_dashboard', 'Analytics Dashboard', 'Usage analytics and insights',
        FALSE, TRUE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Advanced Security
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'advanced_security', 'Advanced Security', 'Advanced security features (2FA, IP allowlist)',
        FALSE, FALSE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;

    -- Dedicated Support
    INSERT INTO feature_gates (
        feature_name, display_name, description,
        available_on_free, available_on_pro, available_on_enterprise
    ) VALUES (
        'dedicated_support', 'Dedicated Support', '24/7 dedicated support',
        FALSE, FALSE, TRUE
    ) ON CONFLICT (feature_name) DO NOTHING;
END $$;

-- ================================================================
-- VIEWS
-- ================================================================

-- Feature access summary view
CREATE OR REPLACE VIEW feature_access_summary AS
SELECT
    fg.feature_name,
    fg.display_name,
    fg.description,
    fg.available_on_free,
    fg.available_on_pro,
    fg.available_on_enterprise,
    fg.free_tier_limit,
    fg.pro_tier_limit,
    fg.enterprise_tier_limit,
    COUNT(DISTINCT ufo.user_id) FILTER (WHERE ufo.is_enabled = TRUE) AS users_with_override,
    COUNT(DISTINCT fu.user_id) AS users_using_feature,
    SUM(CASE WHEN fu.used_at >= NOW() - INTERVAL '24 hours' THEN 1 ELSE 0 END)::INTEGER AS usage_last_24h
FROM feature_gates fg
LEFT JOIN user_feature_overrides ufo ON fg.feature_name = ufo.feature_name
LEFT JOIN feature_usage fu ON fg.feature_name = fu.feature_name
WHERE fg.is_enabled = TRUE
GROUP BY fg.gate_id, fg.feature_name, fg.display_name, fg.description,
         fg.available_on_free, fg.available_on_pro, fg.available_on_enterprise,
         fg.free_tier_limit, fg.pro_tier_limit, fg.enterprise_tier_limit;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE feature_gates IS 'Feature availability and limits per subscription tier';
COMMENT ON TABLE user_feature_overrides IS 'Per-user feature access overrides (beta access, custom deals)';
COMMENT ON TABLE feature_usage IS 'Feature usage tracking for enforcement and analytics';

COMMENT ON FUNCTION has_feature_access IS 'Check if user has access to a feature with usage limits';
COMMENT ON FUNCTION record_feature_usage IS 'Record feature usage (enforces limits)';
COMMENT ON FUNCTION grant_feature_override IS 'Grant or revoke feature access override for specific user';
COMMENT ON FUNCTION get_user_features IS 'Get comprehensive feature access summary for user';

COMMENT ON VIEW feature_access_summary IS 'Summary of all features with usage statistics';
