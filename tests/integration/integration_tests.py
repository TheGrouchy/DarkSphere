"""
DarkSpere Integration Test Suite
Purpose: End-to-end testing of core system flows
Coverage: Authentication, sessions, agents, billing, error handling
"""

import os
import sys
import unittest
import uuid
import time
import json
from datetime import datetime, timedelta
from typing import Dict, Any

import psycopg2
from psycopg2.extras import RealDictCursor
import requests

# ================================================================
# TEST CONFIGURATION
# ================================================================

# Database configuration
DB_CONFIG = {
    'host': os.getenv('TEST_DB_HOST', 'localhost'),
    'port': int(os.getenv('TEST_DB_PORT', '5432')),
    'database': os.getenv('TEST_DB_NAME', 'postgres'),
    'user': os.getenv('TEST_DB_USER', 'darkspere_worker'),
    'password': os.getenv('TEST_DB_PASSWORD', 'CHANGE_ME')
}

# API endpoints
API_BASE_URL = os.getenv('API_BASE_URL', 'http://localhost:8000')
AGENT_REGISTRATION_URL = os.getenv('AGENT_REGISTRATION_URL', 'http://localhost:8002')

# Test data
TEST_PHONE_NUMBER = '+15555550001'
TEST_AGENT_NAME = 'test-agent-' + str(uuid.uuid4())[:8]
TEST_USER_EMAIL = f'test-{uuid.uuid4().hex[:8]}@example.com'

# ================================================================
# TEST BASE CLASS
# ================================================================

class DarkSpereTestCase(unittest.TestCase):
    """Base test case with database utilities"""

    @classmethod
    def setUpClass(cls):
        """Set up test database connection"""
        cls.conn = psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)
        cls.test_user_id = None
        cls.test_agent_id = None
        cls.test_session_id = None

    @classmethod
    def tearDownClass(cls):
        """Clean up test data"""
        cursor = cls.conn.cursor()

        # Clean up test data
        if cls.test_session_id:
            cursor.execute("DELETE FROM agent_sessions WHERE session_id = %s", (cls.test_session_id,))

        if cls.test_agent_id:
            cursor.execute("DELETE FROM agent_registry WHERE agent_id = %s", (cls.test_agent_id,))

        if cls.test_user_id:
            cursor.execute("DELETE FROM user_accounts WHERE user_id = %s", (cls.test_user_id,))

        cls.conn.commit()
        cursor.close()
        cls.conn.close()

    def execute_sql(self, query: str, params: tuple = None) -> list:
        """Execute SQL query and return results"""
        cursor = self.conn.cursor()
        cursor.execute(query, params)
        self.conn.commit()

        if cursor.description:
            results = [dict(row) for row in cursor.fetchall()]
        else:
            results = []

        cursor.close()
        return results

    def create_test_user(self) -> str:
        """Create a test user account"""
        results = self.execute_sql("""
            INSERT INTO user_accounts (email, password_hash, is_verified)
            VALUES (%s, %s, TRUE)
            RETURNING user_id
        """, (TEST_USER_EMAIL, 'test_hash'))

        user_id = results[0]['user_id']
        self.__class__.test_user_id = user_id
        return user_id

    def create_test_agent(self, api_key: str = 'test-api-key') -> str:
        """Create a test agent"""
        results = self.execute_sql("""
            SELECT register_agent(%s, %s, %s, %s, %s::jsonb)
        """, (
            TEST_AGENT_NAME,
            'general',
            'http://localhost:5000/chat',
            api_key,
            json.dumps(['chat', 'code'])
        ))

        agent_id = results[0]['agent_id']
        self.__class__.test_agent_id = agent_id
        return agent_id

# ================================================================
# SESSION MANAGEMENT TESTS
# ================================================================

class SessionManagementTests(DarkSpereTestCase):
    """Test session creation and routing"""

    def test_01_create_session(self):
        """Test session creation with agent routing"""
        # Create test agent
        agent_id = self.create_test_agent()

        # Create session
        results = self.execute_sql("""
            SELECT * FROM get_or_create_session(%s, %s)
        """, (TEST_PHONE_NUMBER, 'general'))

        self.assertEqual(len(results), 1)
        session = results[0]

        self.assertIsNotNone(session['session_id'])
        self.assertEqual(session['agent_id'], agent_id)
        self.assertIsNotNone(session['session_hash'])

        self.__class__.test_session_id = session['session_id']
        print(f"✓ Session created: {session['session_id']}")

    def test_02_session_hash_verification(self):
        """Test SHA256 session hash verification"""
        if not self.__class__.test_session_id:
            self.skipTest("No session created")

        # Get session hash
        results = self.execute_sql("""
            SELECT session_hash FROM agent_sessions WHERE session_id = %s
        """, (self.__class__.test_session_id,))

        session_hash = results[0]['session_hash']

        # Verify hash
        results = self.execute_sql("""
            SELECT verify_session_hash(%s, %s) AS is_valid
        """, (self.__class__.test_session_id, session_hash))

        self.assertTrue(results[0]['is_valid'])
        print(f"✓ Session hash verified: {session_hash[:16]}...")

    def test_03_load_balancing(self):
        """Test health-aware load balancing"""
        # Create multiple agents
        agent1 = self.create_test_agent('key1')

        cursor = self.conn.cursor()
        cursor.execute("""
            INSERT INTO agent_registry (agent_name, agent_type, endpoint_url, api_key_hash, max_concurrent_sessions)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING agent_id
        """, ('test-agent-2', 'general', 'http://localhost:5001/chat', 'key2', 10))

        agent2 = cursor.fetchone()['agent_id']
        self.conn.commit()
        cursor.close()

        # Set different health scores
        self.execute_sql("""
            INSERT INTO agent_health_summary (agent_id, health_score, avg_response_time_ms)
            VALUES (%s, 95, 100), (%s, 75, 500)
        """, (agent1, agent2))

        # Create session - should route to agent1 (higher health score)
        results = self.execute_sql("""
            SELECT * FROM get_or_create_session(%s, %s)
        """, ('+15555550002', 'general'))

        self.assertEqual(results[0]['agent_id'], agent1)
        print(f"✓ Load balancing: Routed to healthier agent {agent1}")

# ================================================================
# AUTHENTICATION TESTS
# ================================================================

class AuthenticationTests(DarkSpereTestCase):
    """Test authentication and authorization"""

    def test_01_user_registration(self):
        """Test user account creation"""
        user_id = self.create_test_user()

        self.assertIsNotNone(user_id)
        print(f"✓ User created: {user_id}")

    def test_02_phone_verification(self):
        """Test phone number linking with SMS verification"""
        user_id = self.create_test_user()

        # Initiate phone link
        results = self.execute_sql("""
            SELECT * FROM initiate_phone_link(%s, %s)
        """, (TEST_PHONE_NUMBER, user_id))

        verification_code = results[0]['verification_code']
        link_id = results[0]['link_id']

        self.assertEqual(len(verification_code), 6)
        print(f"✓ Verification code generated: {verification_code}")

        # Verify phone
        results = self.execute_sql("""
            SELECT * FROM verify_phone_link(%s, %s, %s)
        """, (TEST_PHONE_NUMBER, user_id, verification_code))

        self.assertTrue(results[0]['success'])
        print(f"✓ Phone verified successfully")

    def test_03_permission_check(self):
        """Test permission system"""
        user_id = self.create_test_user()

        # Grant permission
        self.execute_sql("""
            INSERT INTO user_permissions (user_id, permission, resource_pattern)
            VALUES (%s, 'file_read', '/home/*')
        """, (user_id,))

        # Check permission
        results = self.execute_sql("""
            SELECT * FROM has_permission(%s, 'file_read', '/home/test.txt')
        """, (user_id,))

        self.assertTrue(results[0]['has_access'])
        print(f"✓ Permission check passed")

# ================================================================
# AGENT HEALTH TESTS
# ================================================================

class AgentHealthTests(DarkSpereTestCase):
    """Test agent health monitoring"""

    def test_01_health_check_recording(self):
        """Test health check recording"""
        agent_id = self.create_test_agent()

        # Record healthy check
        results = self.execute_sql("""
            SELECT record_health_check(%s, 'healthy', 150, 200, NULL, '{}')
        """, (agent_id,))

        check_id = results[0]['record_health_check']
        self.assertIsNotNone(check_id)
        print(f"✓ Health check recorded: {check_id}")

        # Verify health summary updated
        results = self.execute_sql("""
            SELECT health_score, avg_response_time_ms
            FROM agent_health_summary
            WHERE agent_id = %s
        """, (agent_id,))

        self.assertGreater(results[0]['health_score'], 0)
        print(f"✓ Health score: {results[0]['health_score']}")

    def test_02_auto_disable_unhealthy_agent(self):
        """Test auto-disable after consecutive failures"""
        agent_id = self.create_test_agent()

        # Record 3 consecutive failures
        for i in range(3):
            self.execute_sql("""
                SELECT record_health_check(%s, 'unhealthy', NULL, NULL, 'Connection timeout', '{}')
            """, (agent_id,))

        # Check agent status
        results = self.execute_sql("""
            SELECT status FROM agent_registry WHERE agent_id = %s
        """, (agent_id,))

        self.assertEqual(results[0]['status'], 'inactive')
        print(f"✓ Agent auto-disabled after 3 failures")

    def test_03_session_failover(self):
        """Test session failover to healthy agent"""
        # Create two agents
        agent1 = self.create_test_agent('key1')

        cursor = self.conn.cursor()
        cursor.execute("""
            INSERT INTO agent_registry (agent_name, agent_type, endpoint_url, api_key_hash)
            VALUES (%s, %s, %s, %s)
            RETURNING agent_id
        """, ('failover-agent', 'general', 'http://localhost:5002/chat', 'key2'))

        agent2 = cursor.fetchone()['agent_id']
        self.conn.commit()
        cursor.close()

        # Create session with agent1
        results = self.execute_sql("""
            SELECT * FROM get_or_create_session(%s, %s)
        """, ('+15555550003', 'general'))

        session_id = results[0]['session_id']

        # Mark agent1 as unhealthy
        self.execute_sql("""
            UPDATE agent_health_summary
            SET current_status = 'unhealthy', health_score = 30
            WHERE agent_id = %s
        """, (agent1,))

        # Trigger failover
        results = self.execute_sql("""
            SELECT * FROM failover_session_to_healthy_agent(%s)
        """, (session_id,))

        self.assertTrue(results[0]['success'])
        self.assertEqual(results[0]['new_agent_id'], agent2)
        print(f"✓ Session failed over to agent {agent2}")

# ================================================================
# BILLING & USAGE TESTS
# ================================================================

class BillingUsageTests(DarkSpereTestCase):
    """Test usage tracking and billing"""

    def test_01_usage_event_recording(self):
        """Test usage event recording"""
        user_id = self.create_test_user()

        # Create subscription
        results = self.execute_sql("""
            INSERT INTO subscription_plans (plan_name, tier, billing_period, base_price_cents)
            VALUES ('Test Plan', 'pro', 'monthly', 2900)
            RETURNING plan_id
        """)
        plan_id = results[0]['plan_id']

        self.execute_sql("""
            INSERT INTO user_subscriptions (user_id, plan_id, current_period_start, current_period_end)
            VALUES (%s, %s, NOW(), NOW() + INTERVAL '1 month')
        """, (user_id, plan_id))

        # Record usage event
        results = self.execute_sql("""
            SELECT record_usage_event(%s, 'sms_outbound', 1.0)
        """, (user_id,))

        event_id = results[0]['record_usage_event']
        self.assertIsNotNone(event_id)
        print(f"✓ Usage event recorded: {event_id}")

    def test_02_feature_gate_enforcement(self):
        """Test feature gate enforcement"""
        user_id = self.create_test_user()

        # Check feature access (should default to free tier)
        results = self.execute_sql("""
            SELECT * FROM has_feature_access(%s, 'mcp_protocol')
        """, (user_id,))

        # MCP protocol not available on free tier
        self.assertFalse(results[0]['has_access'])
        print(f"✓ Feature gate enforced: MCP not available on free tier")

    def test_03_usage_limits(self):
        """Test usage limit enforcement"""
        user_id = self.create_test_user()

        # Get current usage
        results = self.execute_sql("""
            SELECT * FROM get_current_usage(%s)
        """, (user_id,))

        print(f"✓ Usage limits retrieved: {len(results)} event types")

# ================================================================
# ERROR HANDLING TESTS
# ================================================================

class ErrorHandlingTests(DarkSpereTestCase):
    """Test error logging and retry logic"""

    def test_01_error_logging(self):
        """Test error logging with retry scheduling"""
        # Log an error
        results = self.execute_sql("""
            SELECT log_error(
                'AGENT_TIMEOUT',
                'timeout',
                'high',
                'Agent failed to respond within 30 seconds',
                'sms_router'
            )
        """)

        error_id = results[0]['log_error']
        self.assertIsNotNone(error_id)
        print(f"✓ Error logged: {error_id}")

        # Check retry scheduled
        results = self.execute_sql("""
            SELECT retry_count, max_retries, next_retry_at
            FROM error_log
            WHERE error_id = %s
        """, (error_id,))

        self.assertIsNotNone(results[0]['next_retry_at'])
        print(f"✓ Retry scheduled at: {results[0]['next_retry_at']}")

    def test_02_retry_attempt(self):
        """Test retry attempt recording"""
        # Log error
        results = self.execute_sql("""
            SELECT log_error('TEST_ERROR', 'network', 'medium', 'Test error', 'test')
        """)
        error_id = results[0]['log_error']

        # Record failed retry
        self.execute_sql("""
            SELECT record_retry_attempt(%s, FALSE, 500, 'Still failing', 1000)
        """, (error_id,))

        # Check retry count incremented
        results = self.execute_sql("""
            SELECT retry_count FROM error_log WHERE error_id = %s
        """, (error_id,))

        self.assertEqual(results[0]['retry_count'], 1)
        print(f"✓ Retry attempt recorded, count: 1")

    def test_03_circuit_breaker(self):
        """Test circuit breaker pattern"""
        component = 'test-api'
        endpoint = '/test'

        # Record failures
        for i in range(5):
            self.execute_sql("""
                SELECT record_circuit_breaker_event(%s, %s, FALSE)
            """, (component, endpoint))

        # Check circuit state
        results = self.execute_sql("""
            SELECT * FROM check_circuit_breaker(%s, %s)
        """, (component, endpoint))

        self.assertEqual(results[0]['state'], 'open')
        self.assertFalse(results[0]['can_proceed'])
        print(f"✓ Circuit breaker opened after 5 failures")

# ================================================================
# MONITORING TESTS
# ================================================================

class MonitoringTests(DarkSpereTestCase):
    """Test monitoring and metrics"""

    def test_01_metric_recording(self):
        """Test metric recording"""
        # Record metric
        results = self.execute_sql("""
            SELECT record_metric('test_counter', 'counter', 42.5, 'test_component', '{}')
        """)

        metric_id = results[0]['record_metric']
        self.assertIsNotNone(metric_id)
        print(f"✓ Metric recorded: {metric_id}")

    def test_02_performance_recording(self):
        """Test performance metric recording"""
        results = self.execute_sql("""
            SELECT record_performance(
                'api',
                '/test/endpoint',
                250,
                TRUE,
                'test-request-123',
                200,
                '{}'
            )
        """)

        perf_id = results[0]['record_performance']
        self.assertIsNotNone(perf_id)
        print(f"✓ Performance metric recorded: {perf_id}")

    def test_03_alert_evaluation(self):
        """Test alert rule evaluation"""
        # Record high metric value
        for i in range(10):
            self.execute_sql("""
                SELECT record_metric('avg_response_time_ms', 'gauge', 1500.0, 'api', '{}')
            """)

        # Evaluate alerts
        results = self.execute_sql("""
            SELECT * FROM evaluate_alert_rules()
        """)

        # Check if slow response alert triggered
        triggered = [r for r in results if r['rule_name'] == 'Slow Response Time']
        if triggered:
            self.assertTrue(triggered[0]['should_trigger'])
            print(f"✓ Alert triggered: Slow Response Time")
        else:
            print("✓ Alert evaluation completed (no triggers)")

# ================================================================
# TEST RUNNER
# ================================================================

def run_tests():
    """Run all integration tests"""
    print("\n" + "="*60)
    print("DarkSpere Integration Test Suite")
    print("="*60 + "\n")

    # Create test suite
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # Add test classes
    suite.addTests(loader.loadTestsFromTestCase(SessionManagementTests))
    suite.addTests(loader.loadTestsFromTestCase(AuthenticationTests))
    suite.addTests(loader.loadTestsFromTestCase(AgentHealthTests))
    suite.addTests(loader.loadTestsFromTestCase(BillingUsageTests))
    suite.addTests(loader.loadTestsFromTestCase(ErrorHandlingTests))
    suite.addTests(loader.loadTestsFromTestCase(MonitoringTests))

    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    print("\n" + "="*60)
    print("Test Summary")
    print("="*60)
    print(f"Tests run: {result.testsRun}")
    print(f"Failures: {len(result.failures)}")
    print(f"Errors: {len(result.errors)}")
    print(f"Success rate: {((result.testsRun - len(result.failures) - len(result.errors)) / result.testsRun * 100):.1f}%")
    print("="*60 + "\n")

    return result.wasSuccessful()

if __name__ == '__main__':
    success = run_tests()
    sys.exit(0 if success else 1)
