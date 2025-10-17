-- ================================================================
-- DarkSpere: Test Data for Data Transmission Testing
-- Purpose: Insert sample agents, sessions, and messages to test data flow
-- ================================================================

\echo 'Inserting test data for data transmission testing...'
\echo ''

-- ================================================================
-- 1. INSERT TEST AGENTS
-- ================================================================

\echo '[1/3] Creating test agents...'

INSERT INTO agent_registry (agent_name, agent_type, endpoint_url, api_key_hash, capabilities, status, max_concurrent_sessions, owner_email)
VALUES
    -- Agent 1: Customer Support Bot
    (
        'CustomerSupportBot',
        'customer_support',
        'http://localhost:8001/chat',
        '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewY5HelKQKdGlRBy', -- bcrypt hash of 'test-key-1'
        '["faq_lookup", "ticket_creation", "order_status"]'::jsonb,
        'active',
        10,
        'support@example.com'
    ),

    -- Agent 2: Sales Assistant
    (
        'SalesAssistant',
        'sales',
        'http://localhost:8002/chat',
        '$2b$12$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', -- bcrypt hash of 'test-key-2'
        '["product_info", "pricing", "quote_generation"]'::jsonb,
        'active',
        5,
        'sales@example.com'
    ),

    -- Agent 3: Technical Support (currently in maintenance)
    (
        'TechSupportAgent',
        'technical',
        'http://localhost:8003/chat',
        '$2b$12$PgOUJFg2VQIy2lVPfhXl5.S9NdDO.v3z1RVmHvbQx5v8C8p8CZVPi', -- bcrypt hash of 'test-key-3'
        '["troubleshooting", "api_access", "code_examples"]'::jsonb,
        'maintenance',
        3,
        'tech@example.com'
    );

SELECT COUNT(*) AS agents_created FROM agent_registry;
\echo ''

-- ================================================================
-- 2. CREATE TEST SESSIONS
-- ================================================================

\echo '[2/3] Creating test sessions with phone number mappings...'

-- Insert test sessions using the function for atomic operation
DO $$
DECLARE
    test_session_1 UUID;
    test_session_2 UUID;
    test_session_3 UUID;
    agent_1_id UUID;
    agent_2_id UUID;
BEGIN
    -- Get agent IDs
    SELECT agent_id INTO agent_1_id FROM agent_registry WHERE agent_name = 'CustomerSupportBot';
    SELECT agent_id INTO agent_2_id FROM agent_registry WHERE agent_name = 'SalesAssistant';

    -- Session 1: Active customer support session
    INSERT INTO agent_sessions (phone_number, agent_id, agent_endpoint, session_state, conversation_context)
    VALUES (
        '+15551234567',
        agent_1_id,
        'http://localhost:8001/chat',
        '{"customer_id": "CUST-001", "last_topic": "order_status"}'::jsonb,
        ARRAY['User: Where is my order?', 'Agent: Let me check that for you...']
    ) RETURNING session_id INTO test_session_1;

    -- Session 2: Active sales session
    INSERT INTO agent_sessions (phone_number, agent_id, agent_endpoint, session_state)
    VALUES (
        '+15559876543',
        agent_2_id,
        'http://localhost:8002/chat',
        '{"lead_score": 85, "interest": "enterprise_plan"}'::jsonb
    ) RETURNING session_id INTO test_session_2;

    -- Session 3: Expired session (for testing cleanup)
    INSERT INTO agent_sessions (phone_number, agent_id, agent_endpoint, expires_at, is_active)
    VALUES (
        '+15555555555',
        agent_1_id,
        'http://localhost:8001/chat',
        NOW() - INTERVAL '1 hour',
        FALSE
    ) RETURNING session_id INTO test_session_3;

    RAISE NOTICE 'Created test sessions: %, %, %', test_session_1, test_session_2, test_session_3;
END $$;

SELECT COUNT(*) AS sessions_created FROM agent_sessions;
SELECT COUNT(*) FILTER (WHERE is_active = TRUE) AS active_sessions FROM agent_sessions;
\echo ''

-- ================================================================
-- 3. INSERT TEST MESSAGE HISTORY
-- ================================================================

\echo '[3/3] Creating test message transmission history...'

-- Insert sample messages to demonstrate data flow
DO $$
DECLARE
    session_1 UUID;
    session_2 UUID;
BEGIN
    -- Get test session IDs
    SELECT session_id INTO session_1 FROM agent_sessions WHERE phone_number = '+15551234567';
    SELECT session_id INTO session_2 FROM agent_sessions WHERE phone_number = '+15559876543';

    -- Session 1: Customer support conversation
    INSERT INTO message_history (session_id, direction, sender, recipient, message_text, transmission_path, twilio_message_sid, agent_endpoint, agent_processing_time_ms, workflow_processing_time_ms, transmission_status, delivery_timestamp)
    VALUES
        -- Inbound message from user
        (
            session_1,
            'inbound',
            '+15551234567',
            '+15558888888',
            'Where is my order #12345?',
            '{"path": ["twilio_webhook", "n8n_trigger", "session_lookup", "agent_api"], "timestamps": {"twilio": "2025-10-10T14:30:00Z", "n8n": "2025-10-10T14:30:01Z", "agent": "2025-10-10T14:30:02Z"}}'::jsonb,
            'SM1234567890abcdef1234567890abcdef',
            'http://localhost:8001/chat',
            450,
            125,
            'delivered',
            NOW() - INTERVAL '5 minutes'
        ),
        -- Outbound response from agent
        (
            session_1,
            'outbound',
            '+15558888888',
            '+15551234567',
            'Your order #12345 is out for delivery! Expected arrival: today by 6 PM.',
            '{"path": ["agent_response", "n8n_handler", "postgres_store", "twilio_send"], "timestamps": {"agent": "2025-10-10T14:30:02Z", "n8n": "2025-10-10T14:30:03Z", "twilio": "2025-10-10T14:30:04Z"}}'::jsonb,
            'SM9876543210fedcba9876543210fedcba',
            'http://localhost:8001/chat',
            450,
            180,
            'delivered',
            NOW() - INTERVAL '4 minutes'
        ),
        -- Follow-up question
        (
            session_1,
            'inbound',
            '+15551234567',
            '+15558888888',
            'Can I change the delivery address?',
            '{"path": ["twilio_webhook", "n8n_trigger", "session_lookup", "agent_api"]}'::jsonb,
            'SM1111111111111111111111111111111',
            'http://localhost:8001/chat',
            520,
            140,
            'delivered',
            NOW() - INTERVAL '2 minutes'
        );

    -- Session 2: Sales conversation
    INSERT INTO message_history (session_id, direction, sender, recipient, message_text, transmission_path, twilio_message_sid, agent_endpoint, agent_processing_time_ms, workflow_processing_time_ms, transmission_status, delivery_timestamp)
    VALUES
        (
            session_2,
            'inbound',
            '+15559876543',
            '+15558888888',
            'Tell me about your enterprise pricing',
            '{"path": ["twilio_webhook", "n8n_trigger", "session_lookup", "agent_api"]}'::jsonb,
            'SM2222222222222222222222222222222',
            'http://localhost:8002/chat',
            380,
            110,
            'delivered',
            NOW() - INTERVAL '10 minutes'
        ),
        (
            session_2,
            'outbound',
            '+15558888888',
            '+15559876543',
            'Our enterprise plan starts at $999/month with unlimited users. Would you like a detailed quote?',
            '{"path": ["agent_response", "n8n_handler", "postgres_store", "twilio_send"]}'::jsonb,
            'SM3333333333333333333333333333333',
            'http://localhost:8002/chat',
            380,
            165,
            'delivered',
            NOW() - INTERVAL '9 minutes'
        );

    -- Simulate a failed transmission for testing error handling
    INSERT INTO message_history (session_id, direction, sender, recipient, message_text, transmission_path, agent_endpoint, transmission_status, error_details)
    VALUES
        (
            session_1,
            'outbound',
            '+15558888888',
            '+15551234567',
            'Failed message test',
            '{"path": ["agent_response", "n8n_handler"], "error_at": "agent_api"}'::jsonb,
            'http://localhost:8001/chat',
            'failed',
            '{"error_type": "connection_timeout", "error_message": "Agent endpoint not responding", "retry_count": 3}'::jsonb
        );
END $$;

SELECT COUNT(*) AS messages_created FROM message_history;
SELECT COUNT(*) FILTER (WHERE direction = 'inbound') AS inbound_messages FROM message_history;
SELECT COUNT(*) FILTER (WHERE direction = 'outbound') AS outbound_messages FROM message_history;
SELECT COUNT(*) FILTER (WHERE transmission_status = 'failed') AS failed_transmissions FROM message_history;
\echo ''

-- ================================================================
-- VERIFICATION QUERIES
-- ================================================================

\echo '================================================'
\echo 'Data Transmission Test Results:'
\echo '================================================'
\echo ''

\echo 'Active Sessions Summary:'
SELECT * FROM active_sessions_summary;
\echo ''

\echo 'Recent Message Transmissions:'
SELECT
    message_id,
    direction,
    LEFT(message_text, 40) AS message_preview,
    transmission_status,
    agent_processing_time_ms,
    workflow_processing_time_ms,
    (agent_processing_time_ms + workflow_processing_time_ms) AS total_latency_ms
FROM message_history
ORDER BY timestamp DESC
LIMIT 10;
\echo ''

\echo 'Agent Performance Metrics:'
SELECT * FROM agent_performance;
\echo ''

\echo 'Transmission Metrics (Last Hour):'
SELECT * FROM get_transmission_metrics('1 hour'::interval);
\echo ''

\echo '================================================'
\echo 'Test Data Installation Complete!'
\echo '================================================'
