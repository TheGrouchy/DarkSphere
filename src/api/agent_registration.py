"""
DarkSpere Agent Self-Registration API
Purpose: Allow agents to dynamically register with the platform
Security: API key authentication, rate limiting, validation
"""

import os
import json
import logging
import secrets
import hashlib
from typing import Dict, List, Optional, Any
from datetime import datetime

from flask import Flask, request, jsonify
from flask_cors import CORS
import psycopg2
from psycopg2.extras import RealDictCursor
import bcrypt

# ================================================================
# CONFIGURATION
# ================================================================

app = Flask(__name__)
CORS(app)

# Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Database configuration
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', '5432')),
    'database': os.getenv('DB_NAME', 'postgres'),
    'user': os.getenv('DB_USER', 'darkspere_worker'),
    'password': os.getenv('DB_PASSWORD', 'CHANGE_ME')
}

# Registration settings
REGISTRATION_SECRET = os.getenv('REGISTRATION_SECRET', 'CHANGE_ME_REGISTRATION_SECRET')
API_KEY_LENGTH = 32
ALLOWED_AGENT_TYPES = ['general', 'specialized', 'mcp', 'custom']

# ================================================================
# DATABASE UTILITIES
# ================================================================

def get_db_connection():
    """Get database connection"""
    return psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)

# ================================================================
# SECURITY UTILITIES
# ================================================================

def generate_api_key() -> str:
    """Generate secure API key"""
    return secrets.token_urlsafe(API_KEY_LENGTH)

def hash_api_key(api_key: str) -> str:
    """Hash API key with bcrypt"""
    return bcrypt.hashpw(api_key.encode('utf-8'), bcrypt.gensalt(10)).decode('utf-8')

def verify_registration_secret(provided_secret: str) -> bool:
    """Verify registration secret (constant-time comparison)"""
    import hmac
    return hmac.compare_digest(provided_secret, REGISTRATION_SECRET)

def validate_endpoint_url(url: str) -> bool:
    """Validate endpoint URL format"""
    import re
    # Must be http/https URL
    pattern = r'^https?://[a-zA-Z0-9][a-zA-Z0-9-._~:/?#\[\]@!$&\'()*+,;=]*$'
    return bool(re.match(pattern, url)) and len(url) < 500

# ================================================================
# VALIDATION FUNCTIONS
# ================================================================

def validate_agent_registration(data: Dict[str, Any]) -> tuple[bool, Optional[str]]:
    """Validate agent registration data"""
    required_fields = ['agent_name', 'agent_type', 'endpoint_url']

    # Check required fields
    for field in required_fields:
        if field not in data or not data[field]:
            return False, f"Missing required field: {field}"

    # Validate agent name
    agent_name = data['agent_name']
    if len(agent_name) < 3 or len(agent_name) > 100:
        return False, "Agent name must be between 3 and 100 characters"

    # Validate agent type
    agent_type = data['agent_type']
    if agent_type not in ALLOWED_AGENT_TYPES:
        return False, f"Invalid agent_type. Must be one of: {', '.join(ALLOWED_AGENT_TYPES)}"

    # Validate endpoint URL
    endpoint_url = data['endpoint_url']
    if not validate_endpoint_url(endpoint_url):
        return False, "Invalid endpoint_url format"

    # Validate max concurrent sessions
    max_sessions = data.get('max_concurrent_sessions', 10)
    if not isinstance(max_sessions, int) or max_sessions < 1 or max_sessions > 1000:
        return False, "max_concurrent_sessions must be between 1 and 1000"

    # Validate capabilities (if provided)
    capabilities = data.get('capabilities', [])
    if not isinstance(capabilities, list):
        return False, "capabilities must be an array"

    return True, None

def validate_agent_update(data: Dict[str, Any]) -> tuple[bool, Optional[str]]:
    """Validate agent update data"""
    # At least one field must be provided
    updatable_fields = ['agent_name', 'endpoint_url', 'max_concurrent_sessions', 'capabilities', 'metadata']

    if not any(field in data for field in updatable_fields):
        return False, "At least one updatable field must be provided"

    # Validate endpoint URL if provided
    if 'endpoint_url' in data:
        if not validate_endpoint_url(data['endpoint_url']):
            return False, "Invalid endpoint_url format"

    # Validate max concurrent sessions if provided
    if 'max_concurrent_sessions' in data:
        max_sessions = data['max_concurrent_sessions']
        if not isinstance(max_sessions, int) or max_sessions < 1 or max_sessions > 1000:
            return False, "max_concurrent_sessions must be between 1 and 1000"

    # Validate capabilities if provided
    if 'capabilities' in data:
        if not isinstance(data['capabilities'], list):
            return False, "capabilities must be an array"

    return True, None

# ================================================================
# AGENT REGISTRATION ENDPOINTS
# ================================================================

@app.route('/api/agents/register', methods=['POST'])
def register_agent():
    """
    Register a new agent

    Request body:
    {
        "registration_secret": "your_secret",
        "agent_name": "My Agent",
        "agent_type": "general|specialized|mcp|custom",
        "endpoint_url": "https://agent.example.com",
        "max_concurrent_sessions": 10,
        "capabilities": ["chat", "code_generation"],
        "metadata": {"version": "1.0.0"}
    }

    Response:
    {
        "success": true,
        "agent_id": "uuid",
        "api_key": "generated_key",
        "message": "Agent registered successfully"
    }
    """
    try:
        data = request.json or {}

        # Verify registration secret
        registration_secret = data.get('registration_secret')
        if not registration_secret or not verify_registration_secret(registration_secret):
            return jsonify({
                'success': False,
                'error': 'Invalid registration secret'
            }), 403

        # Validate registration data
        is_valid, error = validate_agent_registration(data)
        if not is_valid:
            return jsonify({
                'success': False,
                'error': error
            }), 400

        # Generate API key
        api_key = generate_api_key()
        api_key_hash = hash_api_key(api_key)

        # Prepare agent data
        agent_name = data['agent_name']
        agent_type = data['agent_type']
        endpoint_url = data['endpoint_url']
        max_concurrent_sessions = data.get('max_concurrent_sessions', 10)
        capabilities = json.dumps(data.get('capabilities', []))
        metadata = json.dumps(data.get('metadata', {}))

        # Register agent in database
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT register_agent(%s, %s, %s, %s, %s::jsonb)
        """, (agent_name, agent_type, endpoint_url, api_key, capabilities))

        result = cursor.fetchone()
        agent_id = result['agent_id']

        # Update max concurrent sessions and metadata
        cursor.execute("""
            UPDATE agent_registry
            SET max_concurrent_sessions = %s,
                metadata = %s::jsonb
            WHERE agent_id = %s
        """, (max_concurrent_sessions, metadata, agent_id))

        conn.commit()
        cursor.close()
        conn.close()

        logger.info(f"Agent registered: {agent_name} (ID: {agent_id})")

        return jsonify({
            'success': True,
            'agent_id': str(agent_id),
            'api_key': api_key,
            'message': 'Agent registered successfully. Please store your API key securely - it will not be shown again.'
        }), 201

    except Exception as e:
        logger.error(f"Error registering agent: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

@app.route('/api/agents/<agent_id>', methods=['GET'])
def get_agent(agent_id: str):
    """
    Get agent details

    Headers: X-API-Key: your_api_key

    Response:
    {
        "success": true,
        "agent": {...}
    }
    """
    try:
        # Verify API key
        api_key = request.headers.get('X-API-Key')
        if not api_key:
            return jsonify({
                'success': False,
                'error': 'Missing API key'
            }), 401

        # Get agent from database and verify API key
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT agent_id, agent_name, agent_type, endpoint_url,
                   max_concurrent_sessions, current_sessions,
                   capabilities, metadata, status, created_at, last_seen
            FROM agent_registry
            WHERE agent_id = %s
        """, (agent_id,))

        agent = cursor.fetchone()

        if not agent:
            cursor.close()
            conn.close()
            return jsonify({
                'success': False,
                'error': 'Agent not found'
            }), 404

        # Verify API key
        cursor.execute("""
            SELECT verify_agent_api_key(%s, %s) AS is_valid
        """, (agent_id, api_key))

        is_valid = cursor.fetchone()['is_valid']

        cursor.close()
        conn.close()

        if not is_valid:
            return jsonify({
                'success': False,
                'error': 'Invalid API key'
            }), 403

        return jsonify({
            'success': True,
            'agent': dict(agent)
        })

    except Exception as e:
        logger.error(f"Error getting agent {agent_id}: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

@app.route('/api/agents/<agent_id>', methods=['PUT'])
def update_agent(agent_id: str):
    """
    Update agent configuration

    Headers: X-API-Key: your_api_key

    Request body:
    {
        "endpoint_url": "https://new-endpoint.com",
        "max_concurrent_sessions": 20,
        "capabilities": ["chat", "code", "images"],
        "metadata": {"version": "2.0.0"}
    }
    """
    try:
        data = request.json or {}

        # Verify API key
        api_key = request.headers.get('X-API-Key')
        if not api_key:
            return jsonify({
                'success': False,
                'error': 'Missing API key'
            }), 401

        # Validate update data
        is_valid, error = validate_agent_update(data)
        if not is_valid:
            return jsonify({
                'success': False,
                'error': error
            }), 400

        # Verify API key and update agent
        conn = get_db_connection()
        cursor = conn.cursor()

        # Verify API key
        cursor.execute("""
            SELECT verify_agent_api_key(%s, %s) AS is_valid
        """, (agent_id, api_key))

        is_valid = cursor.fetchone()['is_valid']

        if not is_valid:
            cursor.close()
            conn.close()
            return jsonify({
                'success': False,
                'error': 'Invalid API key'
            }), 403

        # Build update query
        update_fields = []
        update_values = []

        if 'agent_name' in data:
            update_fields.append('agent_name = %s')
            update_values.append(data['agent_name'])

        if 'endpoint_url' in data:
            update_fields.append('endpoint_url = %s')
            update_values.append(data['endpoint_url'])

        if 'max_concurrent_sessions' in data:
            update_fields.append('max_concurrent_sessions = %s')
            update_values.append(data['max_concurrent_sessions'])

        if 'capabilities' in data:
            update_fields.append('capabilities = %s::jsonb')
            update_values.append(json.dumps(data['capabilities']))

        if 'metadata' in data:
            update_fields.append('metadata = %s::jsonb')
            update_values.append(json.dumps(data['metadata']))

        update_fields.append('last_seen = NOW()')
        update_values.append(agent_id)

        cursor.execute(f"""
            UPDATE agent_registry
            SET {', '.join(update_fields)}
            WHERE agent_id = %s
            RETURNING agent_id, agent_name, agent_type, endpoint_url,
                      max_concurrent_sessions, capabilities, metadata
        """, update_values)

        updated_agent = cursor.fetchone()

        conn.commit()
        cursor.close()
        conn.close()

        logger.info(f"Agent updated: {agent_id}")

        return jsonify({
            'success': True,
            'agent': dict(updated_agent),
            'message': 'Agent updated successfully'
        })

    except Exception as e:
        logger.error(f"Error updating agent {agent_id}: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

@app.route('/api/agents/<agent_id>/deactivate', methods=['POST'])
def deactivate_agent(agent_id: str):
    """
    Deactivate agent (soft delete)

    Headers: X-API-Key: your_api_key
    """
    try:
        # Verify API key
        api_key = request.headers.get('X-API-Key')
        if not api_key:
            return jsonify({
                'success': False,
                'error': 'Missing API key'
            }), 401

        conn = get_db_connection()
        cursor = conn.cursor()

        # Verify API key
        cursor.execute("""
            SELECT verify_agent_api_key(%s, %s) AS is_valid
        """, (agent_id, api_key))

        is_valid = cursor.fetchone()['is_valid']

        if not is_valid:
            cursor.close()
            conn.close()
            return jsonify({
                'success': False,
                'error': 'Invalid API key'
            }), 403

        # Deactivate agent
        cursor.execute("""
            UPDATE agent_registry
            SET status = 'inactive',
                last_seen = NOW()
            WHERE agent_id = %s
        """, (agent_id,))

        # End all active sessions
        cursor.execute("""
            UPDATE agent_sessions
            SET is_active = FALSE
            WHERE agent_id = %s AND is_active = TRUE
        """, (agent_id,))

        conn.commit()
        cursor.close()
        conn.close()

        logger.info(f"Agent deactivated: {agent_id}")

        return jsonify({
            'success': True,
            'message': 'Agent deactivated successfully'
        })

    except Exception as e:
        logger.error(f"Error deactivating agent {agent_id}: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

@app.route('/api/agents/<agent_id>/heartbeat', methods=['POST'])
def agent_heartbeat(agent_id: str):
    """
    Agent heartbeat - update last_seen timestamp

    Headers: X-API-Key: your_api_key

    Request body (optional):
    {
        "current_sessions": 5,
        "health_status": "healthy",
        "metrics": {...}
    }
    """
    try:
        data = request.json or {}

        # Verify API key
        api_key = request.headers.get('X-API-Key')
        if not api_key:
            return jsonify({
                'success': False,
                'error': 'Missing API key'
            }), 401

        conn = get_db_connection()
        cursor = conn.cursor()

        # Verify API key
        cursor.execute("""
            SELECT verify_agent_api_key(%s, %s) AS is_valid
        """, (agent_id, api_key))

        is_valid = cursor.fetchone()['is_valid']

        if not is_valid:
            cursor.close()
            conn.close()
            return jsonify({
                'success': False,
                'error': 'Invalid API key'
            }), 403

        # Update last_seen and optional metrics
        cursor.execute("""
            UPDATE agent_registry
            SET last_seen = NOW(),
                current_sessions = COALESCE(%s, current_sessions)
            WHERE agent_id = %s
        """, (data.get('current_sessions'), agent_id))

        # Record health status if provided
        if 'health_status' in data:
            health_status = data['health_status']
            cursor.execute("""
                SELECT record_health_check(%s, %s::agent_health_status, NULL, NULL, NULL, %s)
            """, (agent_id, health_status, json.dumps(data.get('metrics', {}))))

        conn.commit()
        cursor.close()
        conn.close()

        return jsonify({
            'success': True,
            'message': 'Heartbeat recorded'
        })

    except Exception as e:
        logger.error(f"Error recording heartbeat for agent {agent_id}: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

# ================================================================
# HEALTH & STATUS ENDPOINTS
# ================================================================

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        # Test database connection
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.close()
        conn.close()

        return jsonify({
            'status': 'healthy',
            'service': 'agent-registration-api',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

@app.route('/api/agents/stats', methods=['GET'])
def get_agent_stats():
    """Get registration statistics"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                COUNT(*) FILTER (WHERE status = 'active') AS active_agents,
                COUNT(*) FILTER (WHERE status = 'inactive') AS inactive_agents,
                COUNT(DISTINCT agent_type) AS agent_types,
                SUM(current_sessions) AS total_sessions,
                SUM(max_concurrent_sessions) AS total_capacity
            FROM agent_registry
        """)

        stats = cursor.fetchone()
        cursor.close()
        conn.close()

        return jsonify({
            'success': True,
            'stats': dict(stats)
        })

    except Exception as e:
        logger.error(f"Error getting stats: {e}")
        return jsonify({
            'success': False,
            'error': 'Internal server error'
        }), 500

# ================================================================
# ERROR HANDLERS
# ================================================================

@app.errorhandler(404)
def not_found(error):
    return jsonify({'success': False, 'error': 'Not found'}), 404

@app.errorhandler(500)
def internal_error(error):
    return jsonify({'success': False, 'error': 'Internal server error'}), 500

# ================================================================
# MAIN ENTRY POINT
# ================================================================

if __name__ == '__main__':
    port = int(os.getenv('PORT', 8002))
    logger.info(f"Starting Agent Registration API on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
