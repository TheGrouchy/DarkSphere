-- ================================================================
-- DarkSpere: Database Setup Script
-- Purpose: Initialize database with all required extensions and setup
-- Run this FIRST before other schema files
-- ================================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- For gen_random_uuid()

-- Enable JSONB operations (included by default in PostgreSQL 9.4+)
-- No extension needed

-- Set timezone
SET timezone = 'UTC';

-- ================================================================
-- DATABASE CONFIGURATION FOR OPTIMAL DATA TRANSMISSION
-- ================================================================

-- Increase work memory for complex queries
-- ALTER DATABASE darkspere SET work_mem = '16MB';

-- Optimize for many connections (n8n workers)
-- ALTER DATABASE darkspere SET max_connections = 100;

-- Enable query performance tracking
-- ALTER DATABASE darkspere SET track_activities = on;
-- ALTER DATABASE darkspere SET track_counts = on;

-- ================================================================
-- HELPER FUNCTIONS
-- ================================================================

-- Function to generate E.164 format phone numbers (for testing)
CREATE OR REPLACE FUNCTION generate_test_phone()
RETURNS VARCHAR(20) AS $$
BEGIN
    RETURN '+1555' || LPAD(FLOOR(RANDOM() * 10000000)::TEXT, 7, '0');
END;
$$ LANGUAGE plpgsql;

-- Function to calculate transmission latency
CREATE OR REPLACE FUNCTION calculate_transmission_latency(
    p_start_time TIMESTAMP,
    p_end_time TIMESTAMP
)
RETURNS INTEGER AS $$
BEGIN
    RETURN EXTRACT(EPOCH FROM (p_end_time - p_start_time)) * 1000;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- SCHEMA VERSION TRACKING
-- ================================================================

CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(20) PRIMARY KEY,
    description TEXT,
    applied_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO schema_migrations (version, description)
VALUES ('1.0.0', 'Initial schema with agent_registry, agent_sessions, message_history')
ON CONFLICT (version) DO NOTHING;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON EXTENSION "pgcrypto" IS 'Required for UUID generation (gen_random_uuid)';
