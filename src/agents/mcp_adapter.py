"""
DarkSpere MCP Protocol Adapter
Purpose: Enable agent communication via Model Context Protocol (MCP)
Usage: Connect external agents via standardized MCP protocol
"""

import asyncio
import json
import logging
import hashlib
import hmac
from typing import Dict, List, Optional, Any
from datetime import datetime
from dataclasses import dataclass, asdict
from enum import Enum

import aiohttp
from aiohttp import web
import psycopg2
from psycopg2.extras import RealDictCursor

# ================================================================
# CONFIGURATION
# ================================================================

# Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Database connection (from environment)
import os
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', '5432')),
    'database': os.getenv('DB_NAME', 'postgres'),
    'user': os.getenv('DB_USER', 'darkspere_worker'),
    'password': os.getenv('DB_PASSWORD', 'CHANGE_ME')
}

# MCP Protocol Settings
MCP_VERSION = "1.0.0"
MCP_TIMEOUT_SECONDS = 30
MAX_MESSAGE_SIZE_KB = 256

# ================================================================
# MCP MESSAGE TYPES
# ================================================================

class MCPMessageType(str, Enum):
    """MCP protocol message types"""
    # Client → Server
    CHAT_REQUEST = "chat.request"
    CAPABILITY_QUERY = "capability.query"
    CONTEXT_UPDATE = "context.update"
    SESSION_INIT = "session.init"
    SESSION_END = "session.end"
    HEALTH_CHECK = "health.check"

    # Server → Client
    CHAT_RESPONSE = "chat.response"
    CAPABILITY_RESPONSE = "capability.response"
    CONTEXT_ACK = "context.ack"
    SESSION_ACK = "session.ack"
    HEALTH_ACK = "health.ack"
    ERROR = "error"

# ================================================================
# MCP DATA CLASSES
# ================================================================

@dataclass
class MCPMessage:
    """Base MCP message structure"""
    type: str
    message_id: str
    timestamp: str
    payload: Dict[str, Any]
    metadata: Optional[Dict[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            'type': self.type,
            'message_id': self.message_id,
            'timestamp': self.timestamp,
            'payload': self.payload,
            'metadata': self.metadata or {}
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> 'MCPMessage':
        return cls(
            type=data['type'],
            message_id=data['message_id'],
            timestamp=data['timestamp'],
            payload=data['payload'],
            metadata=data.get('metadata')
        )

@dataclass
class AgentCapability:
    """Agent capability descriptor"""
    capability_id: str
    capability_type: str  # e.g., 'text_generation', 'image_analysis', 'code_execution'
    description: str
    parameters: Dict[str, Any]
    constraints: Optional[Dict[str, Any]] = None

@dataclass
class ChatContext:
    """Conversation context"""
    session_id: str
    phone_number: str
    conversation_history: List[Dict[str, str]]
    user_preferences: Optional[Dict[str, Any]] = None
    session_state: Optional[Dict[str, Any]] = None

# ================================================================
# MCP ADAPTER CLASS
# ================================================================

class MCPAdapter:
    """Adapter for MCP protocol communication with agents"""

    def __init__(self):
        self.db_pool = None
        self.active_sessions: Dict[str, ChatContext] = {}
        self.agent_capabilities: Dict[str, List[AgentCapability]] = {}

    # ================================================================
    # DATABASE OPERATIONS
    # ================================================================

    def get_db_connection(self):
        """Get database connection from pool"""
        return psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)

    async def get_agent_by_id(self, agent_id: str) -> Optional[Dict[str, Any]]:
        """Retrieve agent details from database"""
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()

            cursor.execute("""
                SELECT agent_id, agent_name, agent_type, endpoint_url,
                       api_key_hash, capabilities, status
                FROM agent_registry
                WHERE agent_id = %s AND status = 'active'
            """, (agent_id,))

            result = cursor.fetchone()
            cursor.close()
            conn.close()

            return dict(result) if result else None
        except Exception as e:
            logger.error(f"Database error retrieving agent {agent_id}: {e}")
            return None

    async def get_session_context(self, session_id: str) -> Optional[ChatContext]:
        """Retrieve session context from database"""
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()

            cursor.execute("""
                SELECT session_id, phone_number, session_state, conversation_context
                FROM agent_sessions
                WHERE session_id = %s AND is_active = TRUE
            """, (session_id,))

            result = cursor.fetchone()
            cursor.close()
            conn.close()

            if result:
                return ChatContext(
                    session_id=result['session_id'],
                    phone_number=result['phone_number'],
                    conversation_history=[
                        {'role': 'user' if i % 2 == 0 else 'assistant', 'content': msg}
                        for i, msg in enumerate(result.get('conversation_context', []))
                    ],
                    session_state=result.get('session_state', {})
                )
            return None
        except Exception as e:
            logger.error(f"Database error retrieving session {session_id}: {e}")
            return None

    async def update_session_context(self, session_id: str, new_messages: List[Dict[str, str]]):
        """Update session conversation context in database"""
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()

            # Extract message contents for array storage
            message_contents = [msg['content'] for msg in new_messages]

            cursor.execute("""
                UPDATE agent_sessions
                SET conversation_context = conversation_context || %s::TEXT[],
                    last_activity = NOW(),
                    total_messages_received = total_messages_received + %s
                WHERE session_id = %s
            """, (message_contents, len(new_messages), session_id))

            conn.commit()
            cursor.close()
            conn.close()

            logger.info(f"Updated session {session_id} with {len(new_messages)} messages")
        except Exception as e:
            logger.error(f"Database error updating session {session_id}: {e}")

    # ================================================================
    # MCP MESSAGE HANDLING
    # ================================================================

    def generate_message_id(self, content: str) -> str:
        """Generate unique message ID"""
        timestamp = datetime.utcnow().isoformat()
        return hashlib.sha256(f"{timestamp}:{content}".encode()).hexdigest()[:16]

    def create_mcp_message(
        self,
        msg_type: MCPMessageType,
        payload: Dict[str, Any],
        metadata: Optional[Dict[str, Any]] = None
    ) -> MCPMessage:
        """Create an MCP message"""
        return MCPMessage(
            type=msg_type.value,
            message_id=self.generate_message_id(json.dumps(payload)),
            timestamp=datetime.utcnow().isoformat(),
            payload=payload,
            metadata=metadata
        )

    async def send_mcp_message(
        self,
        agent_endpoint: str,
        message: MCPMessage,
        api_key: Optional[str] = None
    ) -> Optional[MCPMessage]:
        """Send MCP message to agent and receive response"""
        headers = {
            'Content-Type': 'application/json',
            'X-MCP-Version': MCP_VERSION
        }

        if api_key:
            headers['X-API-Key'] = api_key

        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{agent_endpoint}/mcp",
                    json=message.to_dict(),
                    headers=headers,
                    timeout=aiohttp.ClientTimeout(total=MCP_TIMEOUT_SECONDS)
                ) as response:
                    if response.status == 200:
                        data = await response.json()
                        return MCPMessage.from_dict(data)
                    else:
                        logger.error(f"Agent returned status {response.status}")
                        return None
        except asyncio.TimeoutError:
            logger.error(f"Timeout sending MCP message to {agent_endpoint}")
            return None
        except Exception as e:
            logger.error(f"Error sending MCP message: {e}")
            return None

    # ================================================================
    # AGENT COMMUNICATION METHODS
    # ================================================================

    async def send_chat_request(
        self,
        agent_id: str,
        session_id: str,
        message: str,
        context: Optional[ChatContext] = None
    ) -> Optional[str]:
        """Send chat request to agent via MCP"""
        # Get agent details
        agent = await self.get_agent_by_id(agent_id)
        if not agent:
            logger.error(f"Agent {agent_id} not found or inactive")
            return None

        # Get or create session context
        if not context:
            context = await self.get_session_context(session_id)

        if not context:
            logger.error(f"Session {session_id} not found")
            return None

        # Build MCP chat request
        mcp_request = self.create_mcp_message(
            MCPMessageType.CHAT_REQUEST,
            payload={
                'session_id': session_id,
                'message': message,
                'conversation_history': context.conversation_history[-10:],  # Last 10 messages
                'session_state': context.session_state or {}
            },
            metadata={
                'phone_number': context.phone_number,
                'agent_id': agent_id,
                'agent_type': agent.get('agent_type')
            }
        )

        # Send to agent
        logger.info(f"Sending MCP chat request to agent {agent['agent_name']}")
        response = await self.send_mcp_message(
            agent['endpoint_url'],
            mcp_request,
            api_key=None  # API key verification handled by agent
        )

        if response and response.type == MCPMessageType.CHAT_RESPONSE.value:
            agent_reply = response.payload.get('response')

            # Update session context
            await self.update_session_context(session_id, [
                {'role': 'user', 'content': message},
                {'role': 'assistant', 'content': agent_reply}
            ])

            return agent_reply
        else:
            logger.error(f"Invalid or missing chat response from agent")
            return None

    async def query_agent_capabilities(self, agent_id: str) -> List[AgentCapability]:
        """Query agent capabilities via MCP"""
        agent = await self.get_agent_by_id(agent_id)
        if not agent:
            return []

        # Check cache first
        if agent_id in self.agent_capabilities:
            return self.agent_capabilities[agent_id]

        # Build capability query
        mcp_request = self.create_mcp_message(
            MCPMessageType.CAPABILITY_QUERY,
            payload={'agent_id': agent_id}
        )

        # Send to agent
        response = await self.send_mcp_message(
            agent['endpoint_url'],
            mcp_request
        )

        if response and response.type == MCPMessageType.CAPABILITY_RESPONSE.value:
            capabilities = [
                AgentCapability(**cap)
                for cap in response.payload.get('capabilities', [])
            ]

            # Cache capabilities
            self.agent_capabilities[agent_id] = capabilities

            # Update database
            await self.update_agent_capabilities(agent_id, capabilities)

            return capabilities

        return []

    async def update_agent_capabilities(self, agent_id: str, capabilities: List[AgentCapability]):
        """Update agent capabilities in database"""
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()

            capabilities_json = json.dumps([asdict(cap) for cap in capabilities])

            cursor.execute("""
                UPDATE agent_registry
                SET capabilities = %s::jsonb,
                    last_seen = NOW()
                WHERE agent_id = %s
            """, (capabilities_json, agent_id))

            conn.commit()
            cursor.close()
            conn.close()

            logger.info(f"Updated capabilities for agent {agent_id}")
        except Exception as e:
            logger.error(f"Error updating agent capabilities: {e}")

    async def send_health_check(self, agent_id: str) -> bool:
        """Send health check to agent via MCP"""
        agent = await self.get_agent_by_id(agent_id)
        if not agent:
            return False

        mcp_request = self.create_mcp_message(
            MCPMessageType.HEALTH_CHECK,
            payload={'agent_id': agent_id, 'timestamp': datetime.utcnow().isoformat()}
        )

        start_time = datetime.utcnow()
        response = await self.send_mcp_message(
            agent['endpoint_url'],
            mcp_request
        )
        response_time_ms = int((datetime.utcnow() - start_time).total_seconds() * 1000)

        # Record health check in database
        try:
            conn = self.get_db_connection()
            cursor = conn.cursor()

            if response and response.type == MCPMessageType.HEALTH_ACK.value:
                cursor.execute("""
                    SELECT record_health_check(%s, 'healthy', %s, 200, NULL, %s)
                """, (agent_id, response_time_ms, json.dumps({'mcp_protocol': True})))

                conn.commit()
                cursor.close()
                conn.close()
                return True
            else:
                cursor.execute("""
                    SELECT record_health_check(%s, 'unhealthy', NULL, NULL, 'No valid MCP response', %s)
                """, (agent_id, json.dumps({'mcp_protocol': True})))

                conn.commit()
                cursor.close()
                conn.close()
                return False
        except Exception as e:
            logger.error(f"Error recording health check: {e}")
            return False

    async def initialize_session(
        self,
        agent_id: str,
        session_id: str,
        phone_number: str
    ) -> bool:
        """Initialize MCP session with agent"""
        agent = await self.get_agent_by_id(agent_id)
        if not agent:
            return False

        mcp_request = self.create_mcp_message(
            MCPMessageType.SESSION_INIT,
            payload={
                'session_id': session_id,
                'phone_number': phone_number,
                'agent_id': agent_id
            },
            metadata={
                'protocol_version': MCP_VERSION
            }
        )

        response = await self.send_mcp_message(
            agent['endpoint_url'],
            mcp_request
        )

        return response and response.type == MCPMessageType.SESSION_ACK.value

    async def end_session(self, agent_id: str, session_id: str) -> bool:
        """End MCP session with agent"""
        agent = await self.get_agent_by_id(agent_id)
        if not agent:
            return False

        mcp_request = self.create_mcp_message(
            MCPMessageType.SESSION_END,
            payload={'session_id': session_id}
        )

        response = await self.send_mcp_message(
            agent['endpoint_url'],
            mcp_request
        )

        return response and response.type == MCPMessageType.SESSION_ACK.value

# ================================================================
# HTTP API FOR MCP ADAPTER
# ================================================================

class MCPAdapterAPI:
    """HTTP API for MCP adapter"""

    def __init__(self, adapter: MCPAdapter):
        self.adapter = adapter
        self.app = web.Application()
        self._setup_routes()

    def _setup_routes(self):
        self.app.router.add_post('/mcp/chat', self.handle_chat)
        self.app.router.add_post('/mcp/capabilities', self.handle_capabilities)
        self.app.router.add_post('/mcp/health', self.handle_health)
        self.app.router.add_get('/mcp/status', self.handle_status)

    async def handle_chat(self, request: web.Request) -> web.Response:
        """Handle chat request via MCP"""
        try:
            data = await request.json()

            agent_id = data.get('agent_id')
            session_id = data.get('session_id')
            message = data.get('message')

            if not all([agent_id, session_id, message]):
                return web.json_response(
                    {'error': 'Missing required fields'},
                    status=400
                )

            response = await self.adapter.send_chat_request(
                agent_id, session_id, message
            )

            if response:
                return web.json_response({'response': response})
            else:
                return web.json_response(
                    {'error': 'Failed to get agent response'},
                    status=500
                )
        except Exception as e:
            logger.error(f"Error handling chat request: {e}")
            return web.json_response({'error': str(e)}, status=500)

    async def handle_capabilities(self, request: web.Request) -> web.Response:
        """Query agent capabilities"""
        try:
            data = await request.json()
            agent_id = data.get('agent_id')

            if not agent_id:
                return web.json_response(
                    {'error': 'Missing agent_id'},
                    status=400
                )

            capabilities = await self.adapter.query_agent_capabilities(agent_id)

            return web.json_response({
                'agent_id': agent_id,
                'capabilities': [asdict(cap) for cap in capabilities]
            })
        except Exception as e:
            logger.error(f"Error querying capabilities: {e}")
            return web.json_response({'error': str(e)}, status=500)

    async def handle_health(self, request: web.Request) -> web.Response:
        """Send health check to agent"""
        try:
            data = await request.json()
            agent_id = data.get('agent_id')

            if not agent_id:
                return web.json_response(
                    {'error': 'Missing agent_id'},
                    status=400
                )

            is_healthy = await self.adapter.send_health_check(agent_id)

            return web.json_response({
                'agent_id': agent_id,
                'healthy': is_healthy
            })
        except Exception as e:
            logger.error(f"Error sending health check: {e}")
            return web.json_response({'error': str(e)}, status=500)

    async def handle_status(self, request: web.Request) -> web.Response:
        """Get MCP adapter status"""
        return web.json_response({
            'status': 'operational',
            'version': MCP_VERSION,
            'active_sessions': len(self.adapter.active_sessions),
            'cached_capabilities': len(self.adapter.agent_capabilities)
        })

    def run(self, host: str = '0.0.0.0', port: int = 8001):
        """Run the MCP adapter API"""
        logger.info(f"Starting MCP Adapter API on {host}:{port}")
        web.run_app(self.app, host=host, port=port)

# ================================================================
# MAIN ENTRY POINT
# ================================================================

if __name__ == '__main__':
    # Initialize adapter
    adapter = MCPAdapter()

    # Create and run API
    api = MCPAdapterAPI(adapter)
    api.run(host='0.0.0.0', port=8001)
