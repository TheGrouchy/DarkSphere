-- ================================================================
-- DarkSpere: Usage Tracking & Billing System
-- Purpose: Track usage events, calculate costs, generate invoices
-- Integration: Stripe webhooks, tier-based pricing
-- ================================================================

-- ================================================================
-- SUBSCRIPTION TIERS
-- ================================================================

CREATE TYPE subscription_tier AS ENUM (
    'free',        -- Free tier with limits
    'pro',         -- Pro tier with higher limits
    'enterprise'   -- Enterprise tier with custom limits
);

CREATE TYPE billing_period AS ENUM (
    'monthly',
    'annual'
);

-- ================================================================
-- USAGE EVENT TYPES
-- ================================================================

CREATE TYPE usage_event_type AS ENUM (
    'sms_inbound',      -- Incoming SMS
    'sms_outbound',     -- Outgoing SMS
    'agent_message',    -- Agent interaction
    'mcp_request',      -- MCP protocol request
    'api_call',         -- API request
    'storage_mb',       -- Storage usage (MB)
    'compute_seconds'   -- Compute time
);

-- ================================================================
-- SUBSCRIPTION PLANS TABLE
-- Pricing configuration for different tiers
-- ================================================================

CREATE TABLE IF NOT EXISTS subscription_plans (
    -- Plan identifier
    plan_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Plan details
    plan_name VARCHAR(100) NOT NULL,
    tier subscription_tier NOT NULL,
    billing_period billing_period NOT NULL,

    -- Pricing
    base_price_cents INTEGER NOT NULL, -- Base monthly/annual price in cents

    -- Usage limits (NULL = unlimited)
    sms_inbound_limit INTEGER,
    sms_outbound_limit INTEGER,
    agent_messages_limit INTEGER,
    api_calls_limit INTEGER,
    storage_mb_limit INTEGER,

    -- Overage pricing (cents per unit)
    sms_inbound_overage_cents INTEGER DEFAULT 0,
    sms_outbound_overage_cents INTEGER DEFAULT 5,  -- $0.05 per SMS
    agent_message_overage_cents INTEGER DEFAULT 1, -- $0.01 per message
    api_call_overage_cents INTEGER DEFAULT 0,
    storage_mb_overage_cents INTEGER DEFAULT 10,   -- $0.10 per MB

    -- Plan features
    features JSONB DEFAULT '[]',

    -- Stripe integration
    stripe_price_id VARCHAR(255) UNIQUE, -- Stripe Price ID
    stripe_product_id VARCHAR(255),      -- Stripe Product ID

    -- Status
    is_active BOOLEAN DEFAULT TRUE,

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- USER SUBSCRIPTIONS TABLE
-- Active subscriptions for users
-- ================================================================

CREATE TABLE IF NOT EXISTS user_subscriptions (
    -- Subscription identifier
    subscription_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,

    -- Plan reference
    plan_id UUID NOT NULL REFERENCES subscription_plans(plan_id),

    -- Subscription period
    current_period_start TIMESTAMP NOT NULL DEFAULT NOW(),
    current_period_end TIMESTAMP NOT NULL,

    -- Status
    status VARCHAR(50) DEFAULT 'active', -- active, canceled, past_due, trialing
    cancel_at_period_end BOOLEAN DEFAULT FALSE,

    -- Stripe integration
    stripe_subscription_id VARCHAR(255) UNIQUE,
    stripe_customer_id VARCHAR(255),

    -- Trial
    trial_start TIMESTAMP,
    trial_end TIMESTAMP,

    -- Metadata
    subscription_metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- USAGE EVENTS TABLE
-- Track all billable usage events
-- ================================================================

CREATE TABLE IF NOT EXISTS usage_events (
    -- Event identifier
    event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User/subscription reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES user_subscriptions(subscription_id),

    -- Event details
    event_type usage_event_type NOT NULL,
    event_timestamp TIMESTAMP DEFAULT NOW(),

    -- Quantity (e.g., 1 SMS, 5 MB, 120 seconds)
    quantity DECIMAL(10, 2) NOT NULL DEFAULT 1.0,

    -- Cost calculation
    unit_price_cents INTEGER, -- Price per unit at time of event
    total_cost_cents INTEGER, -- Calculated cost
    is_overage BOOLEAN DEFAULT FALSE,

    -- Event context
    session_id UUID REFERENCES agent_sessions(session_id),
    agent_id UUID REFERENCES agent_registry(agent_id),
    phone_number VARCHAR(20),

    -- Event metadata
    event_metadata JSONB DEFAULT '{}',

    -- Billing status
    is_billed BOOLEAN DEFAULT FALSE,
    invoice_id UUID, -- Reference to invoice (when generated)

    -- Indexes for fast lookups
    UNIQUE (event_id)
);

-- ================================================================
-- USAGE SUMMARY TABLE (MATERIALIZED VIEW ALTERNATIVE)
-- Current period usage aggregated by user
-- ================================================================

CREATE TABLE IF NOT EXISTS usage_summary (
    -- Summary identifier
    summary_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User/subscription reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES user_subscriptions(subscription_id),

    -- Period
    period_start TIMESTAMP NOT NULL,
    period_end TIMESTAMP NOT NULL,

    -- Usage counts
    sms_inbound_count INTEGER DEFAULT 0,
    sms_outbound_count INTEGER DEFAULT 0,
    agent_messages_count INTEGER DEFAULT 0,
    api_calls_count INTEGER DEFAULT 0,
    storage_mb_used DECIMAL(10, 2) DEFAULT 0,
    compute_seconds_used DECIMAL(10, 2) DEFAULT 0,

    -- Cost breakdown
    base_cost_cents INTEGER DEFAULT 0,
    overage_cost_cents INTEGER DEFAULT 0,
    total_cost_cents INTEGER DEFAULT 0,

    -- Limits and remaining
    sms_inbound_limit INTEGER,
    sms_outbound_limit INTEGER,
    agent_messages_limit INTEGER,

    sms_inbound_remaining INTEGER,
    sms_outbound_remaining INTEGER,
    agent_messages_remaining INTEGER,

    -- Metadata
    last_updated TIMESTAMP DEFAULT NOW(),

    UNIQUE (user_id, period_start, period_end)
);

-- ================================================================
-- INVOICES TABLE
-- Generated invoices for billing periods
-- ================================================================

CREATE TABLE IF NOT EXISTS invoices (
    -- Invoice identifier
    invoice_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User/subscription reference
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES user_subscriptions(subscription_id),

    -- Invoice details
    invoice_number VARCHAR(50) UNIQUE NOT NULL,
    invoice_date TIMESTAMP DEFAULT NOW(),
    due_date TIMESTAMP,

    -- Billing period
    period_start TIMESTAMP NOT NULL,
    period_end TIMESTAMP NOT NULL,

    -- Amounts (in cents)
    subtotal_cents INTEGER NOT NULL,
    tax_cents INTEGER DEFAULT 0,
    total_cents INTEGER NOT NULL,
    amount_paid_cents INTEGER DEFAULT 0,

    -- Status
    status VARCHAR(50) DEFAULT 'draft', -- draft, open, paid, void, uncollectible

    -- Payment
    paid_at TIMESTAMP,

    -- Stripe integration
    stripe_invoice_id VARCHAR(255) UNIQUE,
    stripe_charge_id VARCHAR(255),

    -- Invoice line items (stored as JSONB)
    line_items JSONB DEFAULT '[]',

    -- Metadata
    invoice_metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- ================================================================
-- INDEXES FOR FAST QUERIES
-- ================================================================

-- Usage events by user and period
CREATE INDEX idx_usage_events_user_period ON usage_events(user_id, event_timestamp DESC);
CREATE INDEX idx_usage_events_subscription ON usage_events(subscription_id, event_timestamp DESC);

-- Unbilled usage events
CREATE INDEX idx_usage_events_unbilled ON usage_events(user_id, is_billed)
WHERE is_billed = FALSE;

-- Usage events by type
CREATE INDEX idx_usage_events_type ON usage_events(event_type, event_timestamp DESC);

-- Active subscriptions
CREATE INDEX idx_subscriptions_active ON user_subscriptions(user_id, status)
WHERE status = 'active';

-- Current period subscriptions
CREATE INDEX idx_subscriptions_current_period ON user_subscriptions(current_period_end)
WHERE status = 'active';

-- Invoices by user and status
CREATE INDEX idx_invoices_user_status ON invoices(user_id, status, invoice_date DESC);

-- ================================================================
-- USAGE TRACKING FUNCTIONS
-- ================================================================

-- Record a usage event
CREATE OR REPLACE FUNCTION record_usage_event(
    p_user_id UUID,
    p_event_type usage_event_type,
    p_quantity DECIMAL(10, 2) DEFAULT 1.0,
    p_session_id UUID DEFAULT NULL,
    p_agent_id UUID DEFAULT NULL,
    p_phone_number VARCHAR(20) DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_event_id UUID;
    v_subscription_id UUID;
    v_plan_id UUID;
    v_unit_price_cents INTEGER := 0;
    v_total_cost_cents INTEGER := 0;
    v_is_overage BOOLEAN := FALSE;
    v_current_usage INTEGER;
    v_usage_limit INTEGER;
BEGIN
    -- Get active subscription
    SELECT subscription_id, plan_id
    INTO v_subscription_id, v_plan_id
    FROM user_subscriptions
    WHERE user_id = p_user_id
      AND status = 'active'
      AND current_period_start <= NOW()
      AND current_period_end >= NOW()
    ORDER BY created_at DESC
    LIMIT 1;

    -- Calculate pricing based on usage limits
    IF v_subscription_id IS NOT NULL THEN
        -- Get current period usage
        SELECT
            CASE p_event_type
                WHEN 'sms_inbound' THEN sms_inbound_count
                WHEN 'sms_outbound' THEN sms_outbound_count
                WHEN 'agent_message' THEN agent_messages_count
                WHEN 'api_call' THEN api_calls_count
                ELSE 0
            END
        INTO v_current_usage
        FROM usage_summary
        WHERE user_id = p_user_id
          AND subscription_id = v_subscription_id
          AND period_start <= NOW()
          AND period_end >= NOW();

        v_current_usage := COALESCE(v_current_usage, 0);

        -- Get usage limit and overage pricing
        SELECT
            CASE p_event_type
                WHEN 'sms_inbound' THEN sp.sms_inbound_limit
                WHEN 'sms_outbound' THEN sp.sms_outbound_limit
                WHEN 'agent_message' THEN sp.agent_messages_limit
                WHEN 'api_call' THEN sp.api_calls_limit
                ELSE NULL
            END,
            CASE p_event_type
                WHEN 'sms_inbound' THEN sp.sms_inbound_overage_cents
                WHEN 'sms_outbound' THEN sp.sms_outbound_overage_cents
                WHEN 'agent_message' THEN sp.agent_message_overage_cents
                WHEN 'api_call' THEN sp.api_call_overage_cents
                WHEN 'storage_mb' THEN sp.storage_mb_overage_cents
                ELSE 0
            END
        INTO v_usage_limit, v_unit_price_cents
        FROM subscription_plans sp
        WHERE sp.plan_id = v_plan_id;

        -- Check if overage
        IF v_usage_limit IS NOT NULL AND v_current_usage >= v_usage_limit THEN
            v_is_overage := TRUE;
            v_total_cost_cents := (v_unit_price_cents * p_quantity)::INTEGER;
        ELSE
            v_is_overage := FALSE;
            v_total_cost_cents := 0; -- Included in base price
        END IF;
    END IF;

    -- Insert usage event
    INSERT INTO usage_events (
        user_id,
        subscription_id,
        event_type,
        quantity,
        unit_price_cents,
        total_cost_cents,
        is_overage,
        session_id,
        agent_id,
        phone_number,
        event_metadata
    ) VALUES (
        p_user_id,
        v_subscription_id,
        p_event_type,
        p_quantity,
        v_unit_price_cents,
        v_total_cost_cents,
        v_is_overage,
        p_session_id,
        p_agent_id,
        p_phone_number,
        p_metadata
    ) RETURNING event_id INTO v_event_id;

    RETURN v_event_id;
END;
$$ LANGUAGE plpgsql;

-- Update usage summary (trigger function)
CREATE OR REPLACE FUNCTION update_usage_summary()
RETURNS TRIGGER AS $$
DECLARE
    v_summary_exists BOOLEAN;
    v_period_start TIMESTAMP;
    v_period_end TIMESTAMP;
BEGIN
    -- Get subscription period
    SELECT current_period_start, current_period_end
    INTO v_period_start, v_period_end
    FROM user_subscriptions
    WHERE subscription_id = NEW.subscription_id;

    -- If no subscription, use monthly period
    IF v_period_start IS NULL THEN
        v_period_start := date_trunc('month', NOW());
        v_period_end := v_period_start + INTERVAL '1 month';
    END IF;

    -- Upsert usage summary
    INSERT INTO usage_summary (
        user_id,
        subscription_id,
        period_start,
        period_end,
        sms_inbound_count,
        sms_outbound_count,
        agent_messages_count,
        api_calls_count,
        storage_mb_used,
        compute_seconds_used,
        overage_cost_cents,
        total_cost_cents
    ) VALUES (
        NEW.user_id,
        NEW.subscription_id,
        v_period_start,
        v_period_end,
        CASE WHEN NEW.event_type = 'sms_inbound' THEN NEW.quantity::INTEGER ELSE 0 END,
        CASE WHEN NEW.event_type = 'sms_outbound' THEN NEW.quantity::INTEGER ELSE 0 END,
        CASE WHEN NEW.event_type = 'agent_message' THEN NEW.quantity::INTEGER ELSE 0 END,
        CASE WHEN NEW.event_type = 'api_call' THEN NEW.quantity::INTEGER ELSE 0 END,
        CASE WHEN NEW.event_type = 'storage_mb' THEN NEW.quantity ELSE 0 END,
        CASE WHEN NEW.event_type = 'compute_seconds' THEN NEW.quantity ELSE 0 END,
        NEW.total_cost_cents,
        NEW.total_cost_cents
    )
    ON CONFLICT (user_id, period_start, period_end) DO UPDATE
    SET sms_inbound_count = usage_summary.sms_inbound_count +
            CASE WHEN NEW.event_type = 'sms_inbound' THEN NEW.quantity::INTEGER ELSE 0 END,
        sms_outbound_count = usage_summary.sms_outbound_count +
            CASE WHEN NEW.event_type = 'sms_outbound' THEN NEW.quantity::INTEGER ELSE 0 END,
        agent_messages_count = usage_summary.agent_messages_count +
            CASE WHEN NEW.event_type = 'agent_message' THEN NEW.quantity::INTEGER ELSE 0 END,
        api_calls_count = usage_summary.api_calls_count +
            CASE WHEN NEW.event_type = 'api_call' THEN NEW.quantity::INTEGER ELSE 0 END,
        storage_mb_used = usage_summary.storage_mb_used +
            CASE WHEN NEW.event_type = 'storage_mb' THEN NEW.quantity ELSE 0 END,
        compute_seconds_used = usage_summary.compute_seconds_used +
            CASE WHEN NEW.event_type = 'compute_seconds' THEN NEW.quantity ELSE 0 END,
        overage_cost_cents = usage_summary.overage_cost_cents + NEW.total_cost_cents,
        total_cost_cents = usage_summary.total_cost_cents + NEW.total_cost_cents,
        last_updated = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_usage_summary
AFTER INSERT ON usage_events
FOR EACH ROW
EXECUTE FUNCTION update_usage_summary();

-- Get current usage for user
CREATE OR REPLACE FUNCTION get_current_usage(p_user_id UUID)
RETURNS TABLE (
    event_type usage_event_type,
    count INTEGER,
    limit_value INTEGER,
    remaining INTEGER,
    overage INTEGER,
    overage_cost_cents INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ue.event_type,
        COUNT(*)::INTEGER AS count,
        CASE ue.event_type
            WHEN 'sms_inbound' THEN sp.sms_inbound_limit
            WHEN 'sms_outbound' THEN sp.sms_outbound_limit
            WHEN 'agent_message' THEN sp.agent_messages_limit
            WHEN 'api_call' THEN sp.api_calls_limit
            ELSE NULL
        END AS limit_value,
        GREATEST(0,
            CASE ue.event_type
                WHEN 'sms_inbound' THEN COALESCE(sp.sms_inbound_limit, 999999)
                WHEN 'sms_outbound' THEN COALESCE(sp.sms_outbound_limit, 999999)
                WHEN 'agent_message' THEN COALESCE(sp.agent_messages_limit, 999999)
                WHEN 'api_call' THEN COALESCE(sp.api_calls_limit, 999999)
                ELSE 999999
            END - COUNT(*)::INTEGER
        ) AS remaining,
        COUNT(*) FILTER (WHERE ue.is_overage = TRUE)::INTEGER AS overage,
        COALESCE(SUM(ue.total_cost_cents) FILTER (WHERE ue.is_overage = TRUE), 0)::INTEGER AS overage_cost_cents
    FROM usage_events ue
    JOIN user_subscriptions us ON ue.subscription_id = us.subscription_id
    JOIN subscription_plans sp ON us.plan_id = sp.plan_id
    WHERE ue.user_id = p_user_id
      AND ue.event_timestamp >= us.current_period_start
      AND ue.event_timestamp < us.current_period_end
    GROUP BY ue.event_type, sp.sms_inbound_limit, sp.sms_outbound_limit,
             sp.agent_messages_limit, sp.api_calls_limit;
END;
$$ LANGUAGE plpgsql;

-- Generate invoice for subscription period
CREATE OR REPLACE FUNCTION generate_invoice(
    p_subscription_id UUID,
    p_period_start TIMESTAMP,
    p_period_end TIMESTAMP
)
RETURNS UUID AS $$
DECLARE
    v_invoice_id UUID;
    v_user_id UUID;
    v_plan_id UUID;
    v_base_price_cents INTEGER;
    v_overage_cost_cents INTEGER;
    v_total_cents INTEGER;
    v_invoice_number VARCHAR(50);
    v_line_items JSONB;
BEGIN
    -- Get subscription details
    SELECT user_id, plan_id INTO v_user_id, v_plan_id
    FROM user_subscriptions
    WHERE subscription_id = p_subscription_id;

    -- Get base price
    SELECT base_price_cents INTO v_base_price_cents
    FROM subscription_plans
    WHERE plan_id = v_plan_id;

    -- Calculate overage costs
    SELECT COALESCE(SUM(total_cost_cents), 0)
    INTO v_overage_cost_cents
    FROM usage_events
    WHERE subscription_id = p_subscription_id
      AND event_timestamp >= p_period_start
      AND event_timestamp < p_period_end
      AND is_overage = TRUE;

    v_total_cents := v_base_price_cents + v_overage_cost_cents;

    -- Generate invoice number
    v_invoice_number := 'INV-' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' ||
                        SUBSTRING(gen_random_uuid()::TEXT, 1, 8);

    -- Build line items
    v_line_items := jsonb_build_array(
        jsonb_build_object(
            'description', 'Subscription - Base Plan',
            'amount_cents', v_base_price_cents
        ),
        jsonb_build_object(
            'description', 'Usage Overages',
            'amount_cents', v_overage_cost_cents
        )
    );

    -- Create invoice
    INSERT INTO invoices (
        user_id,
        subscription_id,
        invoice_number,
        period_start,
        period_end,
        subtotal_cents,
        total_cents,
        line_items,
        due_date
    ) VALUES (
        v_user_id,
        p_subscription_id,
        v_invoice_number,
        p_period_start,
        p_period_end,
        v_total_cents,
        v_total_cents,
        v_line_items,
        p_period_end + INTERVAL '7 days'
    ) RETURNING invoice_id INTO v_invoice_id;

    -- Mark usage events as billed
    UPDATE usage_events
    SET is_billed = TRUE,
        invoice_id = v_invoice_id
    WHERE subscription_id = p_subscription_id
      AND event_timestamp >= p_period_start
      AND event_timestamp < p_period_end;

    RETURN v_invoice_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT SUBSCRIPTION PLANS
-- ================================================================

DO $$
BEGIN
    -- Free tier
    INSERT INTO subscription_plans (
        plan_name, tier, billing_period, base_price_cents,
        sms_inbound_limit, sms_outbound_limit, agent_messages_limit, api_calls_limit,
        sms_outbound_overage_cents, agent_message_overage_cents
    ) VALUES (
        'Free Plan', 'free', 'monthly', 0,
        100, 50, 500, 1000,
        5, 1
    ) ON CONFLICT DO NOTHING;

    -- Pro tier (monthly)
    INSERT INTO subscription_plans (
        plan_name, tier, billing_period, base_price_cents,
        sms_inbound_limit, sms_outbound_limit, agent_messages_limit, api_calls_limit,
        sms_outbound_overage_cents, agent_message_overage_cents
    ) VALUES (
        'Pro Plan (Monthly)', 'pro', 'monthly', 2900,
        5000, 2000, 10000, 50000,
        3, 0
    ) ON CONFLICT DO NOTHING;

    -- Enterprise tier (custom)
    INSERT INTO subscription_plans (
        plan_name, tier, billing_period, base_price_cents,
        sms_inbound_limit, sms_outbound_limit, agent_messages_limit, api_calls_limit
    ) VALUES (
        'Enterprise Plan', 'enterprise', 'monthly', 49900,
        NULL, NULL, NULL, NULL
    ) ON CONFLICT DO NOTHING;
END $$;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE subscription_plans IS 'Subscription plan definitions with pricing and limits';
COMMENT ON TABLE user_subscriptions IS 'Active user subscriptions linked to Stripe';
COMMENT ON TABLE usage_events IS 'Individual usage events for billing calculation';
COMMENT ON TABLE usage_summary IS 'Aggregated usage metrics per billing period';
COMMENT ON TABLE invoices IS 'Generated invoices for billing periods';

COMMENT ON FUNCTION record_usage_event IS 'Record billable usage event with automatic overage calculation';
COMMENT ON FUNCTION get_current_usage IS 'Get current usage with limits and remaining quota';
COMMENT ON FUNCTION generate_invoice IS 'Generate invoice for a subscription billing period';
