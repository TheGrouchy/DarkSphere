-- ================================================================
-- DarkSpere: Account Linking & Authentication
-- Purpose: Enable users to link phone numbers to accounts for access control
-- Data Flow: SMS verification → Account linking → Permission grants
-- ================================================================

-- ================================================================
-- USER ACCOUNTS TABLE
-- Central registry of authenticated users
-- ================================================================

CREATE TABLE IF NOT EXISTS user_accounts (
    -- Primary identifier
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- User credentials
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash TEXT NOT NULL, -- bcrypt hash

    -- Account status
    is_verified BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,

    -- Verification
    verification_token TEXT,
    verification_token_expires TIMESTAMP,

    -- Password reset
    reset_token TEXT,
    reset_token_expires TIMESTAMP,

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    last_login TIMESTAMP,
    login_count INTEGER DEFAULT 0,

    -- Additional profile data
    profile_data JSONB DEFAULT '{}', -- e.g., {"display_name": "John Doe"}

    -- Constraints
    CONSTRAINT email_format CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- ================================================================
-- PHONE-ACCOUNT LINKING TABLE
-- Maps phone numbers to user accounts with verification
-- ================================================================

CREATE TABLE IF NOT EXISTS phone_account_links (
    -- Primary identifier
    link_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Linking data
    phone_number VARCHAR(20) NOT NULL,
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,

    -- Verification via SMS
    verification_code VARCHAR(6),
    verification_code_expires TIMESTAMP,
    is_verified BOOLEAN DEFAULT FALSE,

    -- Linking metadata
    linked_at TIMESTAMP,
    last_verified TIMESTAMP,
    verification_attempts INTEGER DEFAULT 0,

    -- Status
    is_active BOOLEAN DEFAULT TRUE,

    -- Unique constraint: one active link per phone-user combo
    UNIQUE(phone_number, user_id),

    -- Constraints
    CONSTRAINT valid_phone_format CHECK (phone_number ~ '^\+[1-9][0-9]{1,14}$'),
    CONSTRAINT max_verification_attempts CHECK (verification_attempts <= 5)
);

-- ================================================================
-- SESSION TOKENS TABLE
-- For API authentication and persistent sessions
-- ================================================================

CREATE TABLE IF NOT EXISTS user_session_tokens (
    -- Primary identifier
    token_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Token data
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL, -- SHA256 hash of actual token

    -- Token metadata
    created_at TIMESTAMP DEFAULT NOW(),
    expires_at TIMESTAMP NOT NULL,
    last_used TIMESTAMP,

    -- Device/client info
    device_info JSONB DEFAULT '{}', -- e.g., {"user_agent": "...", "ip": "..."}

    -- Status
    is_revoked BOOLEAN DEFAULT FALSE,
    revoked_at TIMESTAMP,
    revoke_reason TEXT,

    -- Constraints
    CONSTRAINT valid_expiry CHECK (expires_at > created_at)
);

-- ================================================================
-- INDEXES FOR FAST AUTHENTICATION
-- ================================================================

-- Fast email lookup for login
CREATE INDEX idx_user_email ON user_accounts(email) WHERE is_active = TRUE;

-- Fast phone number verification lookup
CREATE INDEX idx_phone_verification ON phone_account_links(phone_number, verification_code)
WHERE is_verified = FALSE AND verification_code IS NOT NULL;

-- Fast user session lookup
CREATE INDEX idx_active_phone_links ON phone_account_links(phone_number, is_active)
WHERE is_active = TRUE;

-- Token lookup for API authentication
CREATE INDEX idx_active_tokens ON user_session_tokens(token_hash, expires_at)
WHERE is_revoked = FALSE;

-- User's active tokens
CREATE INDEX idx_user_tokens ON user_session_tokens(user_id, expires_at)
WHERE is_revoked = FALSE;

-- ================================================================
-- HELPER FUNCTIONS
-- ================================================================

-- Generate 6-digit verification code
CREATE OR REPLACE FUNCTION generate_verification_code()
RETURNS VARCHAR(6) AS $$
BEGIN
    RETURN LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
END;
$$ LANGUAGE plpgsql;

-- Generate secure token (for session/verification)
CREATE OR REPLACE FUNCTION generate_secure_token()
RETURNS TEXT AS $$
BEGIN
    RETURN encode(gen_random_bytes(32), 'hex');
END;
$$ LANGUAGE plpgsql;

-- Hash password with bcrypt
CREATE OR REPLACE FUNCTION hash_password(password TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN crypt(password, gen_salt('bf', 10));
END;
$$ LANGUAGE plpgsql;

-- Verify password
CREATE OR REPLACE FUNCTION verify_password(password TEXT, hash TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN hash = crypt(password, hash);
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- ACCOUNT LINKING FUNCTIONS
-- ================================================================

-- Initiate phone linking process (sends verification code via SMS)
CREATE OR REPLACE FUNCTION initiate_phone_link(
    p_phone_number VARCHAR(20),
    p_user_id UUID
)
RETURNS TABLE(
    verification_code VARCHAR(6),
    expires_at TIMESTAMP,
    link_id UUID
) AS $$
DECLARE
    v_code VARCHAR(6);
    v_expires TIMESTAMP;
    v_link_id UUID;
BEGIN
    -- Generate verification code
    v_code := generate_verification_code();
    v_expires := NOW() + INTERVAL '10 minutes';

    -- Insert or update link record
    INSERT INTO phone_account_links (
        phone_number,
        user_id,
        verification_code,
        verification_code_expires,
        verification_attempts
    ) VALUES (
        p_phone_number,
        p_user_id,
        v_code,
        v_expires,
        0
    )
    ON CONFLICT (phone_number, user_id) DO UPDATE
    SET verification_code = v_code,
        verification_code_expires = v_expires,
        verification_attempts = 0,
        is_verified = FALSE
    RETURNING phone_account_links.link_id INTO v_link_id;

    RETURN QUERY SELECT v_code, v_expires, v_link_id;
END;
$$ LANGUAGE plpgsql;

-- Verify phone linking code
CREATE OR REPLACE FUNCTION verify_phone_link(
    p_phone_number VARCHAR(20),
    p_user_id UUID,
    p_code VARCHAR(6)
)
RETURNS TABLE(
    success BOOLEAN,
    message TEXT,
    link_id UUID
) AS $$
DECLARE
    v_link RECORD;
    v_success BOOLEAN := FALSE;
    v_message TEXT;
    v_link_id UUID;
BEGIN
    -- Get link record
    SELECT * INTO v_link
    FROM phone_account_links
    WHERE phone_number = p_phone_number
      AND user_id = p_user_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'No verification pending'::TEXT, NULL::UUID;
        RETURN;
    END IF;

    -- Check if already verified
    IF v_link.is_verified THEN
        RETURN QUERY SELECT TRUE, 'Already verified'::TEXT, v_link.link_id;
        RETURN;
    END IF;

    -- Check expiration
    IF v_link.verification_code_expires < NOW() THEN
        RETURN QUERY SELECT FALSE, 'Code expired'::TEXT, v_link.link_id;
        RETURN;
    END IF;

    -- Check attempts
    IF v_link.verification_attempts >= 5 THEN
        RETURN QUERY SELECT FALSE, 'Too many attempts'::TEXT, v_link.link_id;
        RETURN;
    END IF;

    -- Verify code
    IF v_link.verification_code = p_code THEN
        -- Success - mark as verified
        UPDATE phone_account_links
        SET is_verified = TRUE,
            linked_at = NOW(),
            last_verified = NOW(),
            verification_code = NULL,
            is_active = TRUE
        WHERE link_id = v_link.link_id;

        v_success := TRUE;
        v_message := 'Verification successful';
        v_link_id := v_link.link_id;
    ELSE
        -- Failed - increment attempts
        UPDATE phone_account_links
        SET verification_attempts = verification_attempts + 1
        WHERE link_id = v_link.link_id;

        v_message := 'Invalid code';
        v_link_id := v_link.link_id;
    END IF;

    RETURN QUERY SELECT v_success, v_message, v_link_id;
END;
$$ LANGUAGE plpgsql;

-- Get user from phone number (if linked and verified)
CREATE OR REPLACE FUNCTION get_user_from_phone(p_phone_number VARCHAR(20))
RETURNS TABLE(
    user_id UUID,
    email VARCHAR(255),
    is_verified BOOLEAN,
    profile_data JSONB
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ua.user_id,
        ua.email,
        ua.is_verified,
        ua.profile_data
    FROM user_accounts ua
    JOIN phone_account_links pal ON pal.user_id = ua.user_id
    WHERE pal.phone_number = p_phone_number
      AND pal.is_verified = TRUE
      AND pal.is_active = TRUE
      AND ua.is_active = TRUE;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- SESSION TOKEN FUNCTIONS
-- ================================================================

-- Create session token for user
CREATE OR REPLACE FUNCTION create_session_token(
    p_user_id UUID,
    p_expires_hours INTEGER DEFAULT 24,
    p_device_info JSONB DEFAULT '{}'
)
RETURNS TABLE(
    token TEXT,
    token_id UUID,
    expires_at TIMESTAMP
) AS $$
DECLARE
    v_token TEXT;
    v_token_hash TEXT;
    v_token_id UUID;
    v_expires TIMESTAMP;
BEGIN
    -- Generate token
    v_token := generate_secure_token();
    v_token_hash := encode(digest(v_token, 'sha256'), 'hex');
    v_expires := NOW() + (p_expires_hours || ' hours')::INTERVAL;

    -- Store token
    INSERT INTO user_session_tokens (
        user_id,
        token_hash,
        expires_at,
        device_info
    ) VALUES (
        p_user_id,
        v_token_hash,
        v_expires,
        p_device_info
    ) RETURNING user_session_tokens.token_id INTO v_token_id;

    RETURN QUERY SELECT v_token, v_token_id, v_expires;
END;
$$ LANGUAGE plpgsql;

-- Validate session token
CREATE OR REPLACE FUNCTION validate_session_token(p_token TEXT)
RETURNS TABLE(
    valid BOOLEAN,
    user_id UUID,
    token_id UUID
) AS $$
DECLARE
    v_token_hash TEXT;
    v_token RECORD;
BEGIN
    v_token_hash := encode(digest(p_token, 'sha256'), 'hex');

    SELECT * INTO v_token
    FROM user_session_tokens
    WHERE token_hash = v_token_hash
      AND is_revoked = FALSE
      AND expires_at > NOW();

    IF FOUND THEN
        -- Update last used
        UPDATE user_session_tokens
        SET last_used = NOW()
        WHERE user_session_tokens.token_id = v_token.token_id;

        RETURN QUERY SELECT TRUE, v_token.user_id, v_token.token_id;
    ELSE
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Revoke session token
CREATE OR REPLACE FUNCTION revoke_session_token(
    p_token_id UUID,
    p_reason TEXT DEFAULT 'User logout'
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE user_session_tokens
    SET is_revoked = TRUE,
        revoked_at = NOW(),
        revoke_reason = p_reason
    WHERE token_id = p_token_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- TRIGGERS
-- ================================================================

-- Auto-increment login count
CREATE OR REPLACE FUNCTION update_login_stats()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.last_login IS DISTINCT FROM OLD.last_login THEN
        NEW.login_count := OLD.login_count + 1;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_login_stats
BEFORE UPDATE ON user_accounts
FOR EACH ROW EXECUTE FUNCTION update_login_stats();

-- Clean expired verification codes
CREATE OR REPLACE FUNCTION clean_expired_verification_codes()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.verification_code_expires < NOW() THEN
        NEW.verification_code := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_clean_verification_codes
BEFORE INSERT OR UPDATE ON phone_account_links
FOR EACH ROW EXECUTE FUNCTION clean_expired_verification_codes();

-- ================================================================
-- VIEWS FOR MONITORING
-- ================================================================

-- Active user sessions view
CREATE VIEW active_user_sessions AS
SELECT
    ua.user_id,
    ua.email,
    pal.phone_number,
    COUNT(ust.token_id) AS active_sessions,
    MAX(ust.last_used) AS last_activity
FROM user_accounts ua
LEFT JOIN phone_account_links pal ON pal.user_id = ua.user_id AND pal.is_active = TRUE
LEFT JOIN user_session_tokens ust ON ust.user_id = ua.user_id
    AND ust.is_revoked = FALSE
    AND ust.expires_at > NOW()
WHERE ua.is_active = TRUE
GROUP BY ua.user_id, ua.email, pal.phone_number;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE user_accounts IS 'Authenticated user accounts for permission-based access';
COMMENT ON TABLE phone_account_links IS 'Links phone numbers to user accounts via SMS verification';
COMMENT ON TABLE user_session_tokens IS 'API session tokens for authenticated requests';

COMMENT ON FUNCTION initiate_phone_link IS 'Starts phone verification process, returns code to send via SMS';
COMMENT ON FUNCTION verify_phone_link IS 'Verifies SMS code and activates phone-account link';
COMMENT ON FUNCTION get_user_from_phone IS 'Retrieves user account from verified phone number';
COMMENT ON FUNCTION create_session_token IS 'Creates new API session token for authenticated user';
COMMENT ON FUNCTION validate_session_token IS 'Validates session token and returns user info';
