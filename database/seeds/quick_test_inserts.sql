-- ================================================================
-- DarkSpere: Quick Test Data Inserts
-- Purpose: Fast way to populate database for testing
-- Usage: Copy/paste into Supabase SQL Editor
-- ================================================================

-- ================================================================
-- 1. INSERT TEST AGENTS
-- ================================================================

INSERT INTO agent_registry (
  agent_name,
  agent_type,
  endpoint_url,
  api_key_hash,
  capabilities,
  status,
  max_concurrent_sessions,
  owner_email
) VALUES
  -- Mock Agent for Local Testing
  (
    'MockTestAgent',
    'test',
    'http://localhost:8001/chat',
    'test-key-123',
    '["faq", "general", "greeting"]'::jsonb,
    'active',
    10,
    'test@example.com'
  ),

  -- Customer Support Bot
  (
    'CustomerSupportBot',
    'customer_support',
    'https://agent.example.com/support',
    'support-key-456',
    '["faq_lookup", "ticket_creation", "order_status", "refunds"]'::jsonb,
    'active',
    20,
    'support@example.com'
  ),

  -- Sales Assistant
  (
    'SalesAssistant',
    'sales',
    'https://agent.example.com/sales',
    'sales-key-789',
    '["product_info", "pricing", "quote_generation", "demos"]'::jsonb,
    'active',
    15,
    'sales@example.com'
  ),

  -- Technical Support (Inactive for testing)
  (
    'TechSupportAgent',
    'technical',
    'https://agent.example.com/tech',
    'tech-key-abc',
    '["troubleshooting", "api_access", "code_examples", "debugging"]'::jsonb,
    'inactive',
    5,
    'tech@example.com'
  )
ON CONFLICT (agent_name) DO NOTHING;

-- Verify agents created
SELECT agent_name, agent_type, status, max_concurrent_sessions, endpoint_url
FROM agent_registry
ORDER BY created_at DESC;

-- ================================================================
-- 2. CREATE TEST SESSION (Optional - normally auto-created)
-- ================================================================

-- Test session for development
DO $$
DECLARE
  test_agent_id UUID;
BEGIN
  -- Get first active agent
  SELECT agent_id INTO test_agent_id
  FROM agent_registry
  WHERE status = 'active'
  LIMIT 1;

  -- Create test session
  IF test_agent_id IS NOT NULL THEN
    INSERT INTO agent_sessions (
      phone_number,
      agent_id,
      agent_endpoint,
      session_state
    )
    SELECT
      '+15551234567',
      agent_id,
      endpoint_url,
      '{"test_session": true, "environment": "development"}'::jsonb
    FROM agent_registry
    WHERE agent_id = test_agent_id
    ON CONFLICT (phone_number, agent_id, is_active) DO NOTHING;
  END IF;
END $$;

-- Verify session created
SELECT
  phone_number,
  a.agent_name,
  s.created_at,
  s.is_active
FROM agent_sessions s
JOIN agent_registry a ON s.agent_id = a.agent_id
WHERE s.is_active = TRUE;

-- ================================================================
-- 3. VERIFICATION QUERIES
-- ================================================================

-- Check all tables exist
SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
ORDER BY tablename;

-- Check functions exist
SELECT routine_name, routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name LIKE '%session%'
ORDER BY routine_name;

-- Test get_or_create_session function
SELECT * FROM get_or_create_session('+15559999999');

-- Check agent availability
SELECT
  agent_name,
  status,
  current_sessions,
  max_concurrent_sessions,
  (max_concurrent_sessions - current_sessions) AS available_capacity
FROM agent_registry
ORDER BY status, agent_name;

-- ================================================================
-- CLEANUP (if you need to start fresh)
-- ================================================================

-- Uncomment to delete all test data:
-- DELETE FROM message_history;
-- DELETE FROM agent_sessions;
-- DELETE FROM agent_registry WHERE owner_email LIKE '%example.com';
