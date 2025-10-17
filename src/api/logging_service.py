"""
DarkSpere Structured Logging Service
Purpose: Centralized logging with correlation IDs, JSON formatting
Features: Request tracing, log aggregation, context propagation
"""

import os
import json
import logging
import sys
import traceback
from typing import Dict, Any, Optional
from datetime import datetime
from functools import wraps
from contextvars import ContextVar
import uuid

from flask import Flask, request, g, jsonify
from pythonjsonlogger import jsonlogger
import psycopg2
from psycopg2.extras import RealDictCursor

# ================================================================
# CONFIGURATION
# ================================================================

app = Flask(__name__)

# Context variables for request tracking
request_id_var: ContextVar[str] = ContextVar('request_id', default=None)
user_id_var: ContextVar[str] = ContextVar('user_id', default=None)
session_id_var: ContextVar[str] = ContextVar('session_id', default=None)

# Database configuration
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', '5432')),
    'database': os.getenv('DB_NAME', 'postgres'),
    'user': os.getenv('DB_USER', 'darkspere_worker'),
    'password': os.getenv('DB_PASSWORD', 'CHANGE_ME')
}

# ================================================================
# CUSTOM JSON FORMATTER
# ================================================================

class CustomJsonFormatter(jsonlogger.JsonFormatter):
    """Custom JSON formatter with context injection"""

    def add_fields(self, log_record, record, message_dict):
        super(CustomJsonFormatter, self).add_fields(log_record, record, message_dict)

        # Add timestamp
        log_record['timestamp'] = datetime.utcnow().isoformat() + 'Z'

        # Add log level
        log_record['level'] = record.levelname
        log_record['logger'] = record.name

        # Add context from context vars
        request_id = request_id_var.get()
        if request_id:
            log_record['request_id'] = request_id

        user_id = user_id_var.get()
        if user_id:
            log_record['user_id'] = user_id

        session_id = session_id_var.get()
        if session_id:
            log_record['session_id'] = session_id

        # Add source location
        log_record['source'] = {
            'file': record.filename,
            'line': record.lineno,
            'function': record.funcName
        }

        # Add exception info if present
        if record.exc_info:
            log_record['exception'] = {
                'type': record.exc_info[0].__name__,
                'message': str(record.exc_info[1]),
                'stacktrace': traceback.format_exception(*record.exc_info)
            }

# ================================================================
# LOGGER SETUP
# ================================================================

def setup_logger(name: str, level=logging.INFO) -> logging.Logger:
    """Setup a structured JSON logger"""
    logger = logging.getLogger(name)
    logger.setLevel(level)

    # Console handler with JSON formatting
    console_handler = logging.StreamHandler(sys.stdout)
    formatter = CustomJsonFormatter(
        '%(timestamp)s %(level)s %(message)s',
        rename_fields={
            'levelname': 'level',
            'name': 'logger',
            'msg': 'message'
        }
    )
    console_handler.setFormatter(formatter)
    logger.addHandler(console_handler)

    # File handler (optional)
    log_file = os.getenv('LOG_FILE', '/var/log/darkspere/app.log')
    if os.path.exists(os.path.dirname(log_file)):
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)

    return logger

# Application logger
logger = setup_logger('darkspere', level=logging.INFO)

# ================================================================
# DATABASE UTILITIES
# ================================================================

def get_db_connection():
    """Get database connection"""
    return psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)

def log_to_database(
    log_level: str,
    message: str,
    component: str,
    request_id: Optional[str] = None,
    user_id: Optional[str] = None,
    session_id: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None
):
    """Log entry to database for persistence"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            INSERT INTO application_logs (
                log_level,
                message,
                component,
                request_id,
                user_id,
                session_id,
                log_metadata
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
        """, (
            log_level,
            message,
            component,
            request_id,
            user_id,
            session_id,
            json.dumps(metadata or {})
        ))

        conn.commit()
        cursor.close()
        conn.close()
    except Exception as e:
        # Don't fail the application if database logging fails
        logger.error(f"Failed to log to database: {e}")

# ================================================================
# CONTEXT MANAGERS
# ================================================================

class LogContext:
    """Context manager for adding temporary log context"""

    def __init__(self, **kwargs):
        self.context = kwargs
        self.tokens = {}

    def __enter__(self):
        for key, value in self.context.items():
            if key == 'request_id':
                self.tokens['request_id'] = request_id_var.set(value)
            elif key == 'user_id':
                self.tokens['user_id'] = user_id_var.set(value)
            elif key == 'session_id':
                self.tokens['session_id'] = session_id_var.set(value)
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        for key, token in self.tokens.items():
            if key == 'request_id':
                request_id_var.reset(token)
            elif key == 'user_id':
                user_id_var.reset(token)
            elif key == 'session_id':
                session_id_var.reset(token)

# ================================================================
# DECORATORS
# ================================================================

def with_logging(component: str = None):
    """Decorator to add logging to functions"""
    def decorator(f):
        @wraps(f)
        def decorated_function(*args, **kwargs):
            func_component = component or f.__module__

            # Generate request ID if not present
            req_id = request_id_var.get() or str(uuid.uuid4())
            request_id_var.set(req_id)

            start_time = datetime.utcnow()

            logger.info(
                f"Starting {f.__name__}",
                extra={
                    'component': func_component,
                    'function': f.__name__,
                    'args': str(args)[:200],  # Truncate long args
                    'kwargs': str(kwargs)[:200]
                }
            )

            try:
                result = f(*args, **kwargs)

                # Calculate duration
                duration_ms = int((datetime.utcnow() - start_time).total_seconds() * 1000)

                logger.info(
                    f"Completed {f.__name__}",
                    extra={
                        'component': func_component,
                        'function': f.__name__,
                        'duration_ms': duration_ms,
                        'success': True
                    }
                )

                return result

            except Exception as e:
                duration_ms = int((datetime.utcnow() - start_time).total_seconds() * 1000)

                logger.error(
                    f"Error in {f.__name__}: {str(e)}",
                    extra={
                        'component': func_component,
                        'function': f.__name__,
                        'duration_ms': duration_ms,
                        'success': False,
                        'error_type': type(e).__name__,
                        'error_message': str(e)
                    },
                    exc_info=True
                )
                raise

        return decorated_function
    return decorator

# ================================================================
# FLASK MIDDLEWARE
# ================================================================

@app.before_request
def before_request():
    """Setup logging context for each request"""
    # Generate or use existing request ID
    req_id = request.headers.get('X-Request-ID', str(uuid.uuid4()))
    request_id_var.set(req_id)
    g.request_id = req_id
    g.request_start_time = datetime.utcnow()

    # Extract user/session from headers or query params
    user_id = request.headers.get('X-User-ID')
    if user_id:
        user_id_var.set(user_id)
        g.user_id = user_id

    session_id = request.headers.get('X-Session-ID')
    if session_id:
        session_id_var.set(session_id)
        g.session_id = session_id

    # Log request
    logger.info(
        f"Incoming request: {request.method} {request.path}",
        extra={
            'component': 'http',
            'http_method': request.method,
            'http_path': request.path,
            'http_query': request.query_string.decode('utf-8'),
            'remote_addr': request.remote_addr,
            'user_agent': request.headers.get('User-Agent', '')
        }
    )

@app.after_request
def after_request(response):
    """Log response details"""
    if hasattr(g, 'request_start_time'):
        duration_ms = int((datetime.utcnow() - g.request_start_time).total_seconds() * 1000)

        logger.info(
            f"Request completed: {request.method} {request.path}",
            extra={
                'component': 'http',
                'http_method': request.method,
                'http_path': request.path,
                'http_status': response.status_code,
                'duration_ms': duration_ms
            }
        )

        # Add request ID to response headers
        if hasattr(g, 'request_id'):
            response.headers['X-Request-ID'] = g.request_id

        # Record performance metric
        try:
            conn = get_db_connection()
            cursor = conn.cursor()

            cursor.execute("""
                SELECT record_performance(%s, %s, %s, %s, %s, %s, %s)
            """, (
                'http',
                request.path,
                duration_ms,
                200 <= response.status_code < 400,
                g.request_id if hasattr(g, 'request_id') else None,
                response.status_code,
                json.dumps({'method': request.method})
            ))

            conn.commit()
            cursor.close()
            conn.close()
        except Exception as e:
            logger.error(f"Failed to record performance metric: {e}")

    return response

# ================================================================
# LOGGING API ENDPOINTS
# ================================================================

@app.route('/api/logs/query', methods=['POST'])
def query_logs():
    """Query application logs"""
    try:
        data = request.json or {}

        # Build query filters
        filters = []
        params = []

        if 'log_level' in data:
            filters.append("log_level = %s")
            params.append(data['log_level'])

        if 'component' in data:
            filters.append("component = %s")
            params.append(data['component'])

        if 'request_id' in data:
            filters.append("request_id = %s")
            params.append(data['request_id'])

        if 'user_id' in data:
            filters.append("user_id = %s")
            params.append(data['user_id'])

        if 'start_time' in data:
            filters.append("created_at >= %s")
            params.append(data['start_time'])

        if 'end_time' in data:
            filters.append("created_at <= %s")
            params.append(data['end_time'])

        where_clause = " AND ".join(filters) if filters else "TRUE"

        # Query logs
        conn = get_db_connection()
        cursor = conn.cursor()

        limit = min(data.get('limit', 100), 1000)
        offset = data.get('offset', 0)

        cursor.execute(f"""
            SELECT log_id, log_level, message, component,
                   request_id, user_id, session_id,
                   log_metadata, created_at
            FROM application_logs
            WHERE {where_clause}
            ORDER BY created_at DESC
            LIMIT %s OFFSET %s
        """, params + [limit, offset])

        logs = [dict(row) for row in cursor.fetchall()]

        cursor.close()
        conn.close()

        return jsonify({
            'success': True,
            'logs': logs,
            'count': len(logs)
        })

    except Exception as e:
        logger.error(f"Error querying logs: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/logs/trace/<request_id>', methods=['GET'])
def trace_request(request_id: str):
    """Trace all logs for a specific request ID"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        # Get all logs for request
        cursor.execute("""
            SELECT log_id, log_level, message, component,
                   user_id, session_id, log_metadata, created_at
            FROM application_logs
            WHERE request_id = %s
            ORDER BY created_at ASC
        """, (request_id,))

        logs = [dict(row) for row in cursor.fetchall()]

        # Get performance metrics
        cursor.execute("""
            SELECT component, endpoint, response_time_ms,
                   success, status_code
            FROM performance_metrics
            WHERE request_id = %s
            ORDER BY recorded_at ASC
        """, (request_id,))

        performance = [dict(row) for row in cursor.fetchall()]

        # Get any errors
        cursor.execute("""
            SELECT error_id, error_code, error_category,
                   error_severity, error_message
            FROM error_log
            WHERE request_id = %s
            ORDER BY occurred_at ASC
        """, (request_id,))

        errors = [dict(row) for row in cursor.fetchall()]

        cursor.close()
        conn.close()

        return jsonify({
            'success': True,
            'request_id': request_id,
            'logs': logs,
            'performance': performance,
            'errors': errors
        })

    except Exception as e:
        logger.error(f"Error tracing request: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/logs/stats', methods=['GET'])
def log_stats():
    """Get logging statistics"""
    try:
        hours = int(request.args.get('hours', 24))

        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                COUNT(*) AS total_logs,
                COUNT(*) FILTER (WHERE log_level = 'ERROR') AS error_count,
                COUNT(*) FILTER (WHERE log_level = 'WARNING') AS warning_count,
                COUNT(*) FILTER (WHERE log_level = 'INFO') AS info_count,
                COUNT(DISTINCT component) AS components_count,
                COUNT(DISTINCT request_id) AS unique_requests
            FROM application_logs
            WHERE created_at > NOW() - INTERVAL '%s hours'
        """, (hours,))

        stats = dict(cursor.fetchone())

        # Top components by log volume
        cursor.execute("""
            SELECT component, COUNT(*) as log_count
            FROM application_logs
            WHERE created_at > NOW() - INTERVAL '%s hours'
            GROUP BY component
            ORDER BY log_count DESC
            LIMIT 10
        """, (hours,))

        top_components = [dict(row) for row in cursor.fetchall()]

        cursor.close()
        conn.close()

        return jsonify({
            'success': True,
            'stats': stats,
            'top_components': top_components,
            'time_window_hours': hours
        })

    except Exception as e:
        logger.error(f"Error getting log stats: {e}", exc_info=True)
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

# ================================================================
# HEALTH CHECK
# ================================================================

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.close()
        conn.close()

        return jsonify({
            'status': 'healthy',
            'service': 'logging-service',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

# ================================================================
# EXAMPLE USAGE
# ================================================================

@app.route('/api/example/log-demo', methods=['POST'])
@with_logging(component='example')
def log_demo():
    """Demo endpoint showing logging features"""
    data = request.json or {}

    # Different log levels
    logger.debug("Debug message", extra={'data': data})
    logger.info("Processing request", extra={'action': 'demo'})
    logger.warning("This is a warning", extra={'warning_type': 'demo'})

    # Log with context
    with LogContext(user_id='demo-user-123', session_id='demo-session-456'):
        logger.info("Message with context")

    # Simulate error logging
    if data.get('simulate_error'):
        try:
            raise ValueError("Simulated error for demo")
        except ValueError as e:
            logger.error("Caught demo error", exc_info=True)

    return jsonify({
        'success': True,
        'message': 'Check logs for demo output',
        'request_id': g.request_id
    })

# ================================================================
# MAIN ENTRY POINT
# ================================================================

if __name__ == '__main__':
    port = int(os.getenv('PORT', 8004))
    logger.info(f"Starting Logging Service on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
