"""
DarkSpere Stripe Webhook Integration
Purpose: Handle Stripe subscription events (payments, cancellations, etc.)
Security: Webhook signature verification, event deduplication
"""

import os
import json
import logging
from typing import Dict, Any, Optional
from datetime import datetime, timedelta

from flask import Flask, request, jsonify
import stripe
import psycopg2
from psycopg2.extras import RealDictCursor

# ================================================================
# CONFIGURATION
# ================================================================

app = Flask(__name__)

# Logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Stripe configuration
STRIPE_API_KEY = os.getenv('STRIPE_API_KEY', 'sk_test_...')
STRIPE_WEBHOOK_SECRET = os.getenv('STRIPE_WEBHOOK_SECRET', 'whsec_...')
stripe.api_key = STRIPE_API_KEY

# Database configuration
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', '5432')),
    'database': os.getenv('DB_NAME', 'postgres'),
    'user': os.getenv('DB_USER', 'darkspere_worker'),
    'password': os.getenv('DB_PASSWORD', 'CHANGE_ME')
}

# ================================================================
# DATABASE UTILITIES
# ================================================================

def get_db_connection():
    """Get database connection"""
    return psycopg2.connect(**DB_CONFIG, cursor_factory=RealDictCursor)

# ================================================================
# STRIPE EVENT HANDLERS
# ================================================================

def handle_customer_subscription_created(event: Dict[str, Any]) -> bool:
    """Handle subscription.created event"""
    try:
        subscription = event['data']['object']

        customer_id = subscription['customer']
        subscription_id = subscription['id']
        price_id = subscription['items']['data'][0]['price']['id']

        # Get user by Stripe customer ID
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT user_id FROM user_accounts
            WHERE stripe_customer_id = %s
        """, (customer_id,))

        user_result = cursor.fetchone()

        if not user_result:
            logger.error(f"User not found for Stripe customer {customer_id}")
            cursor.close()
            conn.close()
            return False

        user_id = user_result['user_id']

        # Get plan by Stripe price ID
        cursor.execute("""
            SELECT plan_id FROM subscription_plans
            WHERE stripe_price_id = %s AND is_active = TRUE
        """, (price_id,))

        plan_result = cursor.fetchone()

        if not plan_result:
            logger.error(f"Plan not found for Stripe price {price_id}")
            cursor.close()
            conn.close()
            return False

        plan_id = plan_result['plan_id']

        # Create subscription in database
        period_start = datetime.fromtimestamp(subscription['current_period_start'])
        period_end = datetime.fromtimestamp(subscription['current_period_end'])

        cursor.execute("""
            INSERT INTO user_subscriptions (
                user_id,
                plan_id,
                current_period_start,
                current_period_end,
                status,
                stripe_subscription_id,
                stripe_customer_id
            ) VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (stripe_subscription_id) DO UPDATE
            SET status = EXCLUDED.status,
                current_period_start = EXCLUDED.current_period_start,
                current_period_end = EXCLUDED.current_period_end,
                updated_at = NOW()
            RETURNING subscription_id
        """, (
            user_id,
            plan_id,
            period_start,
            period_end,
            subscription['status'],
            subscription_id,
            customer_id
        ))

        result = cursor.fetchone()
        db_subscription_id = result['subscription_id']

        conn.commit()
        cursor.close()
        conn.close()

        logger.info(f"Created subscription {db_subscription_id} for user {user_id}")
        return True

    except Exception as e:
        logger.error(f"Error handling subscription.created: {e}")
        return False

def handle_customer_subscription_updated(event: Dict[str, Any]) -> bool:
    """Handle subscription.updated event"""
    try:
        subscription = event['data']['object']
        subscription_id = subscription['id']

        conn = get_db_connection()
        cursor = conn.cursor()

        # Update subscription status and period
        period_start = datetime.fromtimestamp(subscription['current_period_start'])
        period_end = datetime.fromtimestamp(subscription['current_period_end'])

        cursor.execute("""
            UPDATE user_subscriptions
            SET status = %s,
                current_period_start = %s,
                current_period_end = %s,
                cancel_at_period_end = %s,
                updated_at = NOW()
            WHERE stripe_subscription_id = %s
            RETURNING subscription_id, user_id
        """, (
            subscription['status'],
            period_start,
            period_end,
            subscription.get('cancel_at_period_end', False),
            subscription_id
        ))

        result = cursor.fetchone()

        if result:
            conn.commit()
            logger.info(f"Updated subscription {result['subscription_id']}")
        else:
            logger.warning(f"Subscription {subscription_id} not found in database")

        cursor.close()
        conn.close()

        return True

    except Exception as e:
        logger.error(f"Error handling subscription.updated: {e}")
        return False

def handle_customer_subscription_deleted(event: Dict[str, Any]) -> bool:
    """Handle subscription.deleted event"""
    try:
        subscription = event['data']['object']
        subscription_id = subscription['id']

        conn = get_db_connection()
        cursor = conn.cursor()

        # Mark subscription as canceled
        cursor.execute("""
            UPDATE user_subscriptions
            SET status = 'canceled',
                updated_at = NOW()
            WHERE stripe_subscription_id = %s
            RETURNING subscription_id, user_id
        """, (subscription_id,))

        result = cursor.fetchone()

        if result:
            # Downgrade to free tier
            cursor.execute("""
                SELECT plan_id FROM subscription_plans
                WHERE tier = 'free' AND is_active = TRUE
                LIMIT 1
            """)

            free_plan = cursor.fetchone()

            if free_plan:
                cursor.execute("""
                    INSERT INTO user_subscriptions (
                        user_id,
                        plan_id,
                        current_period_start,
                        current_period_end,
                        status
                    ) VALUES (%s, %s, NOW(), NOW() + INTERVAL '1 month', 'active')
                """, (result['user_id'], free_plan['plan_id']))

            conn.commit()
            logger.info(f"Canceled subscription {result['subscription_id']}, downgraded to free")

        cursor.close()
        conn.close()

        return True

    except Exception as e:
        logger.error(f"Error handling subscription.deleted: {e}")
        return False

def handle_invoice_paid(event: Dict[str, Any]) -> bool:
    """Handle invoice.paid event"""
    try:
        invoice = event['data']['object']
        subscription_id = invoice.get('subscription')

        if not subscription_id:
            logger.warning("Invoice has no subscription_id")
            return True

        conn = get_db_connection()
        cursor = conn.cursor()

        # Get our subscription ID
        cursor.execute("""
            SELECT subscription_id, user_id, current_period_start, current_period_end
            FROM user_subscriptions
            WHERE stripe_subscription_id = %s
        """, (subscription_id,))

        sub_result = cursor.fetchone()

        if not sub_result:
            logger.warning(f"Subscription {subscription_id} not found")
            cursor.close()
            conn.close()
            return True

        # Generate invoice in our system
        cursor.execute("""
            SELECT generate_invoice(%s, %s, %s)
        """, (
            sub_result['subscription_id'],
            sub_result['current_period_start'],
            sub_result['current_period_end']
        ))

        db_invoice_id = cursor.fetchone()['generate_invoice']

        # Update invoice with Stripe details
        cursor.execute("""
            UPDATE invoices
            SET stripe_invoice_id = %s,
                stripe_charge_id = %s,
                status = 'paid',
                amount_paid_cents = %s,
                paid_at = %s
            WHERE invoice_id = %s
        """, (
            invoice['id'],
            invoice.get('charge'),
            invoice['amount_paid'],
            datetime.fromtimestamp(invoice['status_transitions']['paid_at']),
            db_invoice_id
        ))

        conn.commit()
        cursor.close()
        conn.close()

        logger.info(f"Marked invoice {db_invoice_id} as paid")
        return True

    except Exception as e:
        logger.error(f"Error handling invoice.paid: {e}")
        return False

def handle_invoice_payment_failed(event: Dict[str, Any]) -> bool:
    """Handle invoice.payment_failed event"""
    try:
        invoice = event['data']['object']
        subscription_id = invoice.get('subscription')

        if not subscription_id:
            return True

        conn = get_db_connection()
        cursor = conn.cursor()

        # Update subscription status to past_due
        cursor.execute("""
            UPDATE user_subscriptions
            SET status = 'past_due',
                updated_at = NOW()
            WHERE stripe_subscription_id = %s
            RETURNING user_id
        """, (subscription_id,))

        result = cursor.fetchone()

        if result:
            # TODO: Send payment failed notification to user
            logger.warning(f"Payment failed for subscription {subscription_id}")

        conn.commit()
        cursor.close()
        conn.close()

        return True

    except Exception as e:
        logger.error(f"Error handling invoice.payment_failed: {e}")
        return False

def handle_checkout_session_completed(event: Dict[str, Any]) -> bool:
    """Handle checkout.session.completed event"""
    try:
        session = event['data']['object']

        # Update user with Stripe customer ID
        customer_id = session['customer']
        client_reference_id = session.get('client_reference_id')  # Our user_id

        if client_reference_id:
            conn = get_db_connection()
            cursor = conn.cursor()

            cursor.execute("""
                UPDATE user_accounts
                SET stripe_customer_id = %s
                WHERE user_id = %s
            """, (customer_id, client_reference_id))

            conn.commit()
            cursor.close()
            conn.close()

            logger.info(f"Updated user {client_reference_id} with Stripe customer {customer_id}")

        return True

    except Exception as e:
        logger.error(f"Error handling checkout.session.completed: {e}")
        return False

# ================================================================
# WEBHOOK ENDPOINT
# ================================================================

@app.route('/webhooks/stripe', methods=['POST'])
def stripe_webhook():
    """Handle Stripe webhook events"""
    payload = request.data
    sig_header = request.headers.get('Stripe-Signature')

    # Verify webhook signature
    try:
        event = stripe.Webhook.construct_event(
            payload, sig_header, STRIPE_WEBHOOK_SECRET
        )
    except ValueError as e:
        logger.error(f"Invalid payload: {e}")
        return jsonify({'error': 'Invalid payload'}), 400
    except stripe.error.SignatureVerificationError as e:
        logger.error(f"Invalid signature: {e}")
        return jsonify({'error': 'Invalid signature'}), 400

    # Log event
    logger.info(f"Received Stripe event: {event['type']}")

    # Check for duplicate events (idempotency)
    event_id = event['id']

    conn = get_db_connection()
    cursor = conn.cursor()

    cursor.execute("""
        SELECT event_id FROM webhook_events
        WHERE provider = 'stripe' AND event_id = %s
    """, (event_id,))

    if cursor.fetchone():
        cursor.close()
        conn.close()
        logger.info(f"Duplicate event {event_id}, ignoring")
        return jsonify({'status': 'duplicate'}), 200

    # Record event
    cursor.execute("""
        INSERT INTO webhook_events (
            provider,
            event_id,
            event_type,
            payload,
            received_at
        ) VALUES ('stripe', %s, %s, %s, NOW())
    """, (event_id, event['type'], json.dumps(event)))

    conn.commit()
    cursor.close()
    conn.close()

    # Route to appropriate handler
    event_type = event['type']
    success = False

    if event_type == 'customer.subscription.created':
        success = handle_customer_subscription_created(event)
    elif event_type == 'customer.subscription.updated':
        success = handle_customer_subscription_updated(event)
    elif event_type == 'customer.subscription.deleted':
        success = handle_customer_subscription_deleted(event)
    elif event_type == 'invoice.paid':
        success = handle_invoice_paid(event)
    elif event_type == 'invoice.payment_failed':
        success = handle_invoice_payment_failed(event)
    elif event_type == 'checkout.session.completed':
        success = handle_checkout_session_completed(event)
    else:
        logger.info(f"Unhandled event type: {event_type}")
        success = True  # Don't fail on unknown events

    if success:
        return jsonify({'status': 'success'}), 200
    else:
        return jsonify({'status': 'error'}), 500

# ================================================================
# STRIPE API HELPERS
# ================================================================

@app.route('/api/stripe/create-checkout-session', methods=['POST'])
def create_checkout_session():
    """Create Stripe checkout session for subscription"""
    try:
        data = request.json or {}

        user_id = data.get('user_id')
        price_id = data.get('price_id')

        if not user_id or not price_id:
            return jsonify({
                'success': False,
                'error': 'Missing user_id or price_id'
            }), 400

        # Create checkout session
        session = stripe.checkout.Session.create(
            client_reference_id=user_id,
            mode='subscription',
            line_items=[{
                'price': price_id,
                'quantity': 1
            }],
            success_url=data.get('success_url', 'https://darkspere.com/success'),
            cancel_url=data.get('cancel_url', 'https://darkspere.com/cancel'),
            automatic_tax={'enabled': True}
        )

        return jsonify({
            'success': True,
            'session_id': session.id,
            'checkout_url': session.url
        })

    except Exception as e:
        logger.error(f"Error creating checkout session: {e}")
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/stripe/create-portal-session', methods=['POST'])
def create_portal_session():
    """Create Stripe customer portal session"""
    try:
        data = request.json or {}
        user_id = data.get('user_id')

        if not user_id:
            return jsonify({
                'success': False,
                'error': 'Missing user_id'
            }), 400

        # Get Stripe customer ID
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT stripe_customer_id FROM user_accounts
            WHERE user_id = %s
        """, (user_id,))

        result = cursor.fetchone()
        cursor.close()
        conn.close()

        if not result or not result['stripe_customer_id']:
            return jsonify({
                'success': False,
                'error': 'No Stripe customer found'
            }), 404

        # Create portal session
        session = stripe.billing_portal.Session.create(
            customer=result['stripe_customer_id'],
            return_url=data.get('return_url', 'https://darkspere.com/account')
        )

        return jsonify({
            'success': True,
            'portal_url': session.url
        })

    except Exception as e:
        logger.error(f"Error creating portal session: {e}")
        return jsonify({
            'success': False,
            'error': str(e)
        }), 500

@app.route('/api/stripe/cancel-subscription', methods=['POST'])
def cancel_subscription():
    """Cancel subscription at period end"""
    try:
        data = request.json or {}
        user_id = data.get('user_id')

        if not user_id:
            return jsonify({
                'success': False,
                'error': 'Missing user_id'
            }), 400

        # Get active subscription
        conn = get_db_connection()
        cursor = conn.cursor()

        cursor.execute("""
            SELECT stripe_subscription_id FROM user_subscriptions
            WHERE user_id = %s AND status = 'active'
            ORDER BY created_at DESC
            LIMIT 1
        """, (user_id,))

        result = cursor.fetchone()
        cursor.close()
        conn.close()

        if not result:
            return jsonify({
                'success': False,
                'error': 'No active subscription found'
            }), 404

        # Cancel at period end
        subscription = stripe.Subscription.modify(
            result['stripe_subscription_id'],
            cancel_at_period_end=True
        )

        return jsonify({
            'success': True,
            'cancel_at': subscription['cancel_at']
        })

    except Exception as e:
        logger.error(f"Error canceling subscription: {e}")
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
        # Test Stripe API
        stripe.Plan.list(limit=1)

        # Test database
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT 1")
        cursor.close()
        conn.close()

        return jsonify({
            'status': 'healthy',
            'service': 'stripe-webhooks',
            'timestamp': datetime.utcnow().isoformat()
        })
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            'status': 'unhealthy',
            'error': str(e)
        }), 503

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
    port = int(os.getenv('PORT', 8003))
    logger.info(f"Starting Stripe Webhook Server on port {port}")
    app.run(host='0.0.0.0', port=port, debug=False)
