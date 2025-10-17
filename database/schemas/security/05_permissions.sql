-- ================================================================
-- DarkSpere: Permission & Authorization System
-- Purpose: Fine-grained access control for file access, commands, and resources
-- Data Flow: Permission check → Resource access → Audit log
-- ================================================================

-- ================================================================
-- PERMISSION TYPES
-- Define granular permission categories
-- ================================================================

CREATE TYPE permission_type AS ENUM (
    'file_read',
    'file_write',
    'file_delete',
    'database_query',
    'database_write',
    'command_execute',
    'agent_manage',
    'admin',
    'api_access',
    'webhook_create'
);

-- ================================================================
-- USER PERMISSIONS TABLE
-- Maps users to specific permissions with resource patterns
-- ================================================================

CREATE TABLE IF NOT EXISTS user_permissions (
    -- Primary identifier
    permission_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Permission assignment
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    permission permission_type NOT NULL,

    -- Resource pattern (glob-style matching)
    resource_pattern TEXT, -- e.g., "/home/user/*", "*.txt", "database:customers"

    -- Limits
    limit_value INTEGER, -- e.g., max 100 API calls per day
    limit_window INTERVAL DEFAULT '1 day',

    -- Permission metadata
    granted_at TIMESTAMP DEFAULT NOW(),
    granted_by UUID REFERENCES user_accounts(user_id),
    expires_at TIMESTAMP, -- NULL = never expires

    -- Status
    is_active BOOLEAN DEFAULT TRUE,
    revoked_at TIMESTAMP,
    revoke_reason TEXT,

    -- Unique constraint: one permission per user/resource combo
    UNIQUE(user_id, permission, resource_pattern)
);

-- ================================================================
-- PERMISSION GROUPS (ROLES)
-- Predefined sets of permissions
-- ================================================================

CREATE TABLE IF NOT EXISTS permission_groups (
    -- Primary identifier
    group_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Group details
    group_name VARCHAR(50) UNIQUE NOT NULL,
    description TEXT,

    -- Group hierarchy
    parent_group_id UUID REFERENCES permission_groups(group_id),

    -- Metadata
    created_at TIMESTAMP DEFAULT NOW(),
    is_active BOOLEAN DEFAULT TRUE
);

-- ================================================================
-- GROUP PERMISSIONS MAPPING
-- Define what permissions each group has
-- ================================================================

CREATE TABLE IF NOT EXISTS group_permissions (
    -- Primary identifier
    mapping_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Mapping
    group_id UUID NOT NULL REFERENCES permission_groups(group_id) ON DELETE CASCADE,
    permission permission_type NOT NULL,
    resource_pattern TEXT,

    -- Constraints for this permission
    limit_value INTEGER,
    limit_window INTERVAL DEFAULT '1 day',

    UNIQUE(group_id, permission, resource_pattern)
);

-- ================================================================
-- USER GROUP MEMBERSHIP
-- Assign users to permission groups
-- ================================================================

CREATE TABLE IF NOT EXISTS user_group_membership (
    -- Primary identifier
    membership_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Membership
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    group_id UUID NOT NULL REFERENCES permission_groups(group_id) ON DELETE CASCADE,

    -- Metadata
    assigned_at TIMESTAMP DEFAULT NOW(),
    assigned_by UUID REFERENCES user_accounts(user_id),
    expires_at TIMESTAMP,

    -- Status
    is_active BOOLEAN DEFAULT TRUE,

    UNIQUE(user_id, group_id)
);

-- ================================================================
-- PERMISSION USAGE TRACKING
-- Track permission usage for limit enforcement
-- ================================================================

CREATE TABLE IF NOT EXISTS permission_usage (
    -- Primary identifier
    usage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Usage data
    user_id UUID NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
    permission permission_type NOT NULL,
    resource_accessed TEXT,

    -- Context
    access_timestamp TIMESTAMP DEFAULT NOW(),
    session_id UUID, -- Reference to agent_sessions if applicable
    request_metadata JSONB DEFAULT '{}',

    -- Result
    access_granted BOOLEAN,
    deny_reason TEXT
);

-- ================================================================
-- INDEXES FOR FAST PERMISSION CHECKS
-- ================================================================

-- Fast permission lookup for user
CREATE INDEX idx_user_permissions_lookup ON user_permissions(user_id, permission, is_active)
WHERE is_active = TRUE AND (expires_at IS NULL OR expires_at > NOW());

-- Permission usage tracking
CREATE INDEX idx_permission_usage_tracking ON permission_usage(user_id, permission, access_timestamp DESC);

-- Group membership lookup
CREATE INDEX idx_user_groups ON user_group_membership(user_id, is_active)
WHERE is_active = TRUE AND (expires_at IS NULL OR expires_at > NOW());

-- Group permissions lookup
CREATE INDEX idx_group_permissions ON group_permissions(group_id, permission);

-- ================================================================
-- PERMISSION CHECK FUNCTIONS
-- ================================================================

-- Check if user has specific permission
CREATE OR REPLACE FUNCTION has_permission(
    p_user_id UUID,
    p_permission permission_type,
    p_resource TEXT DEFAULT NULL,
    p_check_limit BOOLEAN DEFAULT FALSE
)
RETURNS TABLE(
    has_access BOOLEAN,
    limit_value INTEGER,
    current_usage INTEGER,
    deny_reason TEXT
) AS $$
DECLARE
    v_has_admin BOOLEAN;
    v_has_direct BOOLEAN;
    v_has_group BOOLEAN;
    v_limit INTEGER := NULL;
    v_usage INTEGER := 0;
    v_pattern TEXT;
    v_limit_window INTERVAL;
    v_deny_reason TEXT := NULL;
BEGIN
    -- Check for admin permission (grants all access)
    SELECT EXISTS (
        SELECT 1 FROM user_permissions
        WHERE user_id = p_user_id
          AND permission = 'admin'
          AND is_active = TRUE
          AND (expires_at IS NULL OR expires_at > NOW())
    ) INTO v_has_admin;

    IF v_has_admin THEN
        RETURN QUERY SELECT TRUE, NULL::INTEGER, 0::INTEGER, NULL::TEXT;
        RETURN;
    END IF;

    -- Check direct user permissions
    SELECT
        up.resource_pattern,
        up.limit_value,
        up.limit_window
    INTO v_pattern, v_limit, v_limit_window
    FROM user_permissions up
    WHERE up.user_id = p_user_id
      AND up.permission = p_permission
      AND up.is_active = TRUE
      AND (up.expires_at IS NULL OR up.expires_at > NOW())
      AND (
          up.resource_pattern IS NULL
          OR p_resource IS NULL
          OR p_resource LIKE up.resource_pattern
      )
    LIMIT 1;

    v_has_direct := FOUND;

    -- If not found in direct permissions, check group permissions
    IF NOT v_has_direct THEN
        SELECT
            gp.resource_pattern,
            gp.limit_value,
            gp.limit_window
        INTO v_pattern, v_limit, v_limit_window
        FROM group_permissions gp
        JOIN user_group_membership ugm ON ugm.group_id = gp.group_id
        WHERE ugm.user_id = p_user_id
          AND gp.permission = p_permission
          AND ugm.is_active = TRUE
          AND (ugm.expires_at IS NULL OR ugm.expires_at > NOW())
          AND (
              gp.resource_pattern IS NULL
              OR p_resource IS NULL
              OR p_resource LIKE gp.resource_pattern
          )
        LIMIT 1;

        v_has_group := FOUND;
    END IF;

    -- If no permission found
    IF NOT v_has_direct AND NOT v_has_group THEN
        v_deny_reason := 'Permission not granted';
        RETURN QUERY SELECT FALSE, NULL::INTEGER, 0::INTEGER, v_deny_reason;
        RETURN;
    END IF;

    -- Check usage limits if requested
    IF p_check_limit AND v_limit IS NOT NULL THEN
        SELECT COUNT(*) INTO v_usage
        FROM permission_usage
        WHERE user_id = p_user_id
          AND permission = p_permission
          AND access_timestamp > (NOW() - v_limit_window)
          AND access_granted = TRUE;

        IF v_usage >= v_limit THEN
            v_deny_reason := format('Limit exceeded: %s/%s used', v_usage, v_limit);
            RETURN QUERY SELECT FALSE, v_limit, v_usage, v_deny_reason;
            RETURN;
        END IF;
    END IF;

    -- Permission granted
    RETURN QUERY SELECT TRUE, v_limit, v_usage, NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Log permission usage
CREATE OR REPLACE FUNCTION log_permission_usage(
    p_user_id UUID,
    p_permission permission_type,
    p_resource TEXT,
    p_access_granted BOOLEAN,
    p_deny_reason TEXT DEFAULT NULL,
    p_session_id UUID DEFAULT NULL,
    p_request_metadata JSONB DEFAULT '{}'
)
RETURNS UUID AS $$
DECLARE
    v_usage_id UUID;
BEGIN
    INSERT INTO permission_usage (
        user_id,
        permission,
        resource_accessed,
        access_granted,
        deny_reason,
        session_id,
        request_metadata
    ) VALUES (
        p_user_id,
        p_permission,
        p_resource,
        p_access_granted,
        p_deny_reason,
        p_session_id,
        p_request_metadata
    ) RETURNING usage_id INTO v_usage_id;

    RETURN v_usage_id;
END;
$$ LANGUAGE plpgsql;

-- Grant permission to user
CREATE OR REPLACE FUNCTION grant_permission(
    p_user_id UUID,
    p_permission permission_type,
    p_resource_pattern TEXT DEFAULT NULL,
    p_granted_by UUID DEFAULT NULL,
    p_limit_value INTEGER DEFAULT NULL,
    p_expires_at TIMESTAMP DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_permission_id UUID;
BEGIN
    INSERT INTO user_permissions (
        user_id,
        permission,
        resource_pattern,
        granted_by,
        limit_value,
        expires_at
    ) VALUES (
        p_user_id,
        p_permission,
        p_resource_pattern,
        p_granted_by,
        p_limit_value,
        p_expires_at
    )
    ON CONFLICT (user_id, permission, resource_pattern) DO UPDATE
    SET is_active = TRUE,
        granted_at = NOW(),
        granted_by = p_granted_by,
        limit_value = p_limit_value,
        expires_at = p_expires_at,
        revoked_at = NULL,
        revoke_reason = NULL
    RETURNING permission_id INTO v_permission_id;

    RETURN v_permission_id;
END;
$$ LANGUAGE plpgsql;

-- Revoke permission from user
CREATE OR REPLACE FUNCTION revoke_permission(
    p_permission_id UUID,
    p_revoke_reason TEXT DEFAULT 'Manual revocation'
)
RETURNS BOOLEAN AS $$
BEGIN
    UPDATE user_permissions
    SET is_active = FALSE,
        revoked_at = NOW(),
        revoke_reason = p_revoke_reason
    WHERE permission_id = p_permission_id;

    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- PERMISSION GROUP FUNCTIONS
-- ================================================================

-- Create permission group
CREATE OR REPLACE FUNCTION create_permission_group(
    p_group_name VARCHAR(50),
    p_description TEXT DEFAULT NULL,
    p_parent_group_id UUID DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_group_id UUID;
BEGIN
    INSERT INTO permission_groups (
        group_name,
        description,
        parent_group_id
    ) VALUES (
        p_group_name,
        p_description,
        p_parent_group_id
    ) RETURNING group_id INTO v_group_id;

    RETURN v_group_id;
END;
$$ LANGUAGE plpgsql;

-- Add permission to group
CREATE OR REPLACE FUNCTION add_group_permission(
    p_group_id UUID,
    p_permission permission_type,
    p_resource_pattern TEXT DEFAULT NULL,
    p_limit_value INTEGER DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_mapping_id UUID;
BEGIN
    INSERT INTO group_permissions (
        group_id,
        permission,
        resource_pattern,
        limit_value
    ) VALUES (
        p_group_id,
        p_permission,
        p_resource_pattern,
        p_limit_value
    )
    ON CONFLICT (group_id, permission, resource_pattern) DO UPDATE
    SET limit_value = p_limit_value
    RETURNING mapping_id INTO v_mapping_id;

    RETURN v_mapping_id;
END;
$$ LANGUAGE plpgsql;

-- Add user to group
CREATE OR REPLACE FUNCTION add_user_to_group(
    p_user_id UUID,
    p_group_id UUID,
    p_assigned_by UUID DEFAULT NULL,
    p_expires_at TIMESTAMP DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_membership_id UUID;
BEGIN
    INSERT INTO user_group_membership (
        user_id,
        group_id,
        assigned_by,
        expires_at
    ) VALUES (
        p_user_id,
        p_group_id,
        p_assigned_by,
        p_expires_at
    )
    ON CONFLICT (user_id, group_id) DO UPDATE
    SET is_active = TRUE,
        assigned_at = NOW(),
        assigned_by = p_assigned_by,
        expires_at = p_expires_at
    RETURNING membership_id INTO v_membership_id;

    RETURN v_membership_id;
END;
$$ LANGUAGE plpgsql;

-- ================================================================
-- DEFAULT PERMISSION GROUPS
-- Create standard roles
-- ================================================================

DO $$
DECLARE
    v_free_group UUID;
    v_pro_group UUID;
    v_enterprise_group UUID;
BEGIN
    -- Free tier group
    v_free_group := create_permission_group(
        'free_tier',
        'Basic access for free users'
    );

    -- Add limited permissions for free tier
    PERFORM add_group_permission(v_free_group, 'api_access', NULL, 100); -- 100 API calls/day

    -- Pro tier group (inherits from free)
    v_pro_group := create_permission_group(
        'pro_tier',
        'Enhanced access for pro users',
        v_free_group
    );

    -- Add pro permissions
    PERFORM add_group_permission(v_pro_group, 'api_access', NULL, 10000); -- 10k API calls/day
    PERFORM add_group_permission(v_pro_group, 'file_read', '/allowed/*');
    PERFORM add_group_permission(v_pro_group, 'database_query', 'database:readonly');
    PERFORM add_group_permission(v_pro_group, 'webhook_create', NULL, 10);

    -- Enterprise tier group (inherits from pro)
    v_enterprise_group := create_permission_group(
        'enterprise_tier',
        'Full access for enterprise users',
        v_pro_group
    );

    -- Add enterprise permissions
    PERFORM add_group_permission(v_enterprise_group, 'file_read', '*');
    PERFORM add_group_permission(v_enterprise_group, 'file_write', '/workspace/*');
    PERFORM add_group_permission(v_enterprise_group, 'database_query', '*');
    PERFORM add_group_permission(v_enterprise_group, 'database_write', 'database:customers');
    PERFORM add_group_permission(v_enterprise_group, 'command_execute', 'cmd:safe_*');
    PERFORM add_group_permission(v_enterprise_group, 'agent_manage', NULL);

END $$;

-- ================================================================
-- VIEWS FOR PERMISSION AUDITING
-- ================================================================

-- User permissions summary (combines direct + group permissions)
CREATE VIEW user_permissions_summary AS
WITH direct_perms AS (
    SELECT
        user_id,
        permission,
        resource_pattern,
        limit_value,
        'direct' AS source
    FROM user_permissions
    WHERE is_active = TRUE
      AND (expires_at IS NULL OR expires_at > NOW())
),
group_perms AS (
    SELECT
        ugm.user_id,
        gp.permission,
        gp.resource_pattern,
        gp.limit_value,
        pg.group_name AS source
    FROM group_permissions gp
    JOIN permission_groups pg ON pg.group_id = gp.group_id
    JOIN user_group_membership ugm ON ugm.group_id = pg.group_id
    WHERE ugm.is_active = TRUE
      AND (ugm.expires_at IS NULL OR ugm.expires_at > NOW())
)
SELECT * FROM direct_perms
UNION ALL
SELECT * FROM group_perms;

-- Permission usage analytics
CREATE VIEW permission_usage_analytics AS
SELECT
    ua.user_id,
    ua.email,
    pu.permission,
    COUNT(*) AS usage_count,
    COUNT(*) FILTER (WHERE pu.access_granted = TRUE) AS granted_count,
    COUNT(*) FILTER (WHERE pu.access_granted = FALSE) AS denied_count,
    MAX(pu.access_timestamp) AS last_access
FROM permission_usage pu
JOIN user_accounts ua ON ua.user_id = pu.user_id
WHERE pu.access_timestamp > NOW() - INTERVAL '30 days'
GROUP BY ua.user_id, ua.email, pu.permission;

-- ================================================================
-- COMMENTS
-- ================================================================

COMMENT ON TABLE user_permissions IS 'Fine-grained permissions for users with resource patterns';
COMMENT ON TABLE permission_groups IS 'Named permission groups (roles) with hierarchy support';
COMMENT ON TABLE user_group_membership IS 'Assigns users to permission groups';
COMMENT ON TABLE permission_usage IS 'Audit log of all permission checks and usage';

COMMENT ON FUNCTION has_permission IS 'Checks if user has permission for resource, returns limit info';
COMMENT ON FUNCTION log_permission_usage IS 'Records permission usage attempt for audit and limits';
COMMENT ON FUNCTION grant_permission IS 'Grants permission to user with optional limits and expiry';
