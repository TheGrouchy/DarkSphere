-- ================================================================
-- DarkSpere: Agent Registry Table
-- Purpose: Central registry of all available agents with endpoints
-- Data Flow: n8n queries this to route messages to correct agent
-- ================================================================

CREATE TABLE IF NOT EXISTS agent_registry (
    -- Primary identifier
    agent_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Agent identification
    agent_name VARCHAR(100) NOT NULL UNIQUE,
    agent_type VARCHAR(50) NOT NULL, -- e.g., 'customer_support', 'sales', 'technical'

    -- Data transmission endpoint
    endpoint_url TEXT NOT NULL, -- HTTP endpoint for data transmission to agent

    -- Security for data transmission
    api_key_hash TEXT NOT NULL, -- bcrypt hash of agent API key

    -- Agent capabilities (affects routing logic)
    capabilities JSONB DEFAULT '[]', -- e.g., ["file_access", "database_query", "web_search"]

    -- Availability and load balancing
    status VARCHAR(20) DEFAULT 'active' CHECK (status IN ('active', 'inactive', 'maintenance')),
    max_concurrent_sessions INTEGER DEFAULT 5,
    current_sessions INTEGER DEFAULT 0,

    -- Metadata
    owner_email VARCHAR(255),
    created_at TIMESTAMP DEFAULT NOW(),
    last_health_check TIMESTAMP,
    health_check_status JSONB, -- Store last health check response
    metadata JSONB DEFAULT '{}', -- Additional routing metadata

    -- Constraints
    CONSTRAINT positive_max_sessions CHECK (max_concurrent_sessions > 0),
    CONSTRAINT valid_current_sessions CHECK (current_sessions >= 0 AND current_sessions <= max_concurrent_sessions)
);

-- ================================================================
-- INDEXES FOR FAST DATA ROUTING
-- Critical for minimizing transmission latency
-- ================================================================

-- Fast lookup for active agents during routing
CREATE INDEX idx_agent_status_type ON agent_registry(status, agent_type)
WHERE status = 'active';

-- Load balancing: find agents with available capacity
CREATE INDEX idx_agent_availability ON agent_registry(status, current_sessions, max_concurrent_sessions)
WHERE status = 'active';

-- Quick lookup by name (for API calls)
CREATE INDEX idx_agent_name ON agent_registry(agent_name);

-- ================================================================
-- TRIGGERS FOR SESSION COUNTING
-- Automatically maintain current_sessions count
-- ================================================================

-- Function to increment session count when new session created
CREATE OR REPLACE FUNCTION increment_agent_sessions()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE agent_registry
    SET current_sessions = current_sessions + 1
    WHERE agent_id = NEW.agent_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to decrement session count when session ends
CREATE OR REPLACE FUNCTION decrement_agent_sessions()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE agent_registry
    SET current_sessions = current_sessions - 1
    WHERE agent_id = OLD.agent_id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- API KEY MANAGEMENT FUNCTIONS
-- Secure API key handling with bcrypt hashing
-- ================================================================

-- Hash API key with bcrypt
CREATE OR REPLACE FUNCTION hash_agent_api_key(api_key TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN crypt(api_key, gen_salt('bf', 10));
END;
$$ LANGUAGE plpgsql;

-- Verify API key against hash
CREATE OR REPLACE FUNCTION verify_agent_api_key(
    p_agent_id UUID,
    p_api_key TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    v_stored_hash TEXT;
BEGIN
    SELECT api_key_hash INTO v_stored_hash
    FROM agent_registry
    WHERE agent_id = p_agent_id;

    IF v_stored_hash IS NULL THEN
        RETURN FALSE;
    END IF;

    RETURN v_stored_hash = crypt(p_api_key, v_stored_hash);
END;
$$ LANGUAGE plpgsql;

-- Verify API key by agent name
CREATE OR REPLACE FUNCTION verify_agent_api_key_by_name(
    p_agent_name VARCHAR(100),
    p_api_key TEXT
)
RETURNS TABLE(
    valid BOOLEAN,
    agent_id UUID,
    endpoint_url TEXT
) AS $$
DECLARE
    v_agent RECORD;
    v_is_valid BOOLEAN;
BEGIN
    SELECT * INTO v_agent
    FROM agent_registry
    WHERE agent_name = p_agent_name
      AND status = 'active';

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::TEXT;
        RETURN;
    END IF;

    v_is_valid := v_agent.api_key_hash = crypt(p_api_key, v_agent.api_key_hash);

    RETURN QUERY SELECT v_is_valid, v_agent.agent_id, v_agent.endpoint_url;
END;
$$ LANGUAGE plpgsql;

-- Register new agent with API key
CREATE OR REPLACE FUNCTION register_agent(
    p_agent_name VARCHAR(100),
    p_agent_type VARCHAR(50),
    p_endpoint_url TEXT,
    p_api_key TEXT,
    p_capabilities JSONB DEFAULT '[]',
    p_max_concurrent_sessions INTEGER DEFAULT 5,
    p_owner_email VARCHAR(255) DEFAULT NULL
)
RETURNS TABLE(
    agent_id UUID,
    api_key_hash TEXT
) AS $$
DECLARE
    v_agent_id UUID;
    v_api_key_hash TEXT;
BEGIN
    -- Hash the API key
    v_api_key_hash := hash_agent_api_key(p_api_key);

    -- Insert agent
    INSERT INTO agent_registry (
        agent_name,
        agent_type,
        endpoint_url,
        api_key_hash,
        capabilities,
        max_concurrent_sessions,
        owner_email
    ) VALUES (
        p_agent_name,
        p_agent_type,
        p_endpoint_url,
        v_api_key_hash,
        p_capabilities,
        p_max_concurrent_sessions,
        p_owner_email
    ) RETURNING agent_registry.agent_id, agent_registry.api_key_hash
    INTO v_agent_id, v_api_key_hash;

    RETURN QUERY SELECT v_agent_id, v_api_key_hash;
END;
$$ LANGUAGE plpgsql;

-- Rotate agent API key
CREATE OR REPLACE FUNCTION rotate_agent_api_key(
    p_agent_id UUID,
    p_new_api_key TEXT
)
RETURNS TEXT AS $$
DECLARE
    v_new_hash TEXT;
BEGIN
    v_new_hash := hash_agent_api_key(p_new_api_key);

    UPDATE agent_registry
    SET api_key_hash = v_new_hash
    WHERE agent_id = p_agent_id;

    RETURN v_new_hash;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- SAMPLE DATA FOR TESTING DATA TRANSMISSION
-- ================================================================

COMMENT ON TABLE agent_registry IS 'Registry of all agents with endpoints for data transmission routing';
COMMENT ON COLUMN agent_registry.endpoint_url IS 'HTTP endpoint where n8n sends message data';
COMMENT ON COLUMN agent_registry.current_sessions IS 'Real-time count of active sessions for load balancing';
COMMENT ON COLUMN agent_registry.capabilities IS 'JSON array of agent capabilities for intelligent routing';
COMMENT ON COLUMN agent_registry.api_key_hash IS 'Bcrypt hash of agent API key for secure authentication';

COMMENT ON FUNCTION hash_agent_api_key IS 'Hashes API key using bcrypt (cost factor 10)';
COMMENT ON FUNCTION verify_agent_api_key IS 'Verifies API key against stored hash for agent authentication';
COMMENT ON FUNCTION register_agent IS 'Registers new agent with hashed API key and returns agent_id';
COMMENT ON FUNCTION rotate_agent_api_key IS 'Rotates agent API key for security';
