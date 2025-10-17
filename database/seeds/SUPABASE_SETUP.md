# Supabase Setup Guide for DarkSpere

## 🚀 Quick Setup (10 minutes)

### Step 1: Deploy Database Schema

1. **Go to Supabase SQL Editor**:
   - Navigate to your project: https://supabase.com/dashboard/project/hgcqcwndnqawrcvzaknx
   - Click **SQL Editor** (left sidebar)

2. **Create New Query** (click "+ New Query")

3. **Copy/Paste Each Schema File** (in order):

#### A. Setup Extensions (00_setup.sql)
```sql
-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Set timezone
SET timezone = 'UTC';

-- Schema version tracking
CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(20) PRIMARY KEY,
    description TEXT,
    applied_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO schema_migrations (version, description)
VALUES ('1.0.0', 'Initial schema with agent_registry, agent_sessions, message_history')
ON CONFLICT (version) DO NOTHING;
```
**Click "Run"** → Should see "Success. No rows returned"

---

#### B. Agent Registry Table
**Open**: `schema/01_agent_registry.sql`
- Copy entire contents
- Paste into SQL Editor
- **Click "Run"**
- Should see: "Success. No rows returned"

---

#### C. Agent Sessions Table
**Open**: `schema/02_agent_sessions.sql`
- Copy entire contents
- Paste into SQL Editor
- **Click "Run"**
- Should see: "Success. No rows returned"

---

#### D. Message History Table
**Open**: `schema/03_message_history.sql`
- Copy entire contents
- Paste into SQL Editor
- **Click "Run"**
- Should see: "Success. No rows returned"

---

### Step 2: Verify Tables Created

Run this query in SQL Editor:

```sql
-- Check tables
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
```

**Expected output**:
- agent_registry ✓
- agent_sessions ✓
- message_history ✓
- schema_migrations ✓

---

### Step 3: Load Test Data

**Open**: `test-data/quick_test_inserts.sql`
- Copy entire contents
- Paste into SQL Editor
- **Click "Run"**

**Expected output**:
```
4 rows inserted into agent_registry
1 row inserted into agent_sessions
Multiple verification queries show data
```

---

### Step 4: Verify Data

```sql
-- Check agents
SELECT agent_name, agent_type, status
FROM agent_registry;

-- Check functions
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema = 'public'
AND routine_name LIKE '%session%';

-- Test routing function
SELECT * FROM get_or_create_session('+15551111111');
```

**Expected**:
- 4 agents listed
- Functions: get_or_create_session, get_conversation_history, etc.
- Session created with agent assignment

---

## ✅ Configuration for n8n

### Get Connection Details

1. **Supabase Dashboard** → **Settings** → **Database**

2. **Connection Info** tab shows:
   - Host: `aws-0-us-west-1.pooler.supabase.com` (example)
   - Database: `postgres`
   - Port: `5432`
   - User: `postgres.hgcqcwndnqawrcvzaknx` (example)

3. **Your saved password**: `J_mQm7cva6*3Y*$`

### Configure n8n Credential

**In n8n**: Credentials → Add Credential → **Postgres**

```
Name: DarkSpere PostgreSQL
Host: [your-host-from-above]
Database: postgres
User: [your-user-from-above]
Password: J_mQm7cva6*3Y*$
Port: 5432
SSL: Allow
```

**Click "Test Connection"** → Should be green ✓

---

## 📊 Monitoring Queries

### Check System Health
```sql
-- Active agents
SELECT COUNT(*) FROM agent_registry WHERE status = 'active';

-- Active sessions
SELECT COUNT(*) FROM agent_sessions WHERE is_active = TRUE;

-- Recent messages
SELECT COUNT(*) FROM message_history
WHERE timestamp > NOW() - INTERVAL '1 hour';
```

### View Active Sessions
```sql
SELECT * FROM active_sessions_summary;
```

### Transmission Metrics
```sql
SELECT * FROM get_transmission_metrics('1 hour');
```

---

## 🔧 Troubleshooting

### Issue: "relation does not exist"
**Solution**: Run schema files in order (00 → 01 → 02 → 03)

### Issue: "function does not exist"
**Solution**: Check schema/02_agent_sessions.sql ran completely

### Issue: Connection timeout from n8n
**Solution**:
- Verify SSL mode is "Allow" or "Require"
- Check Supabase project isn't paused
- Verify connection string is correct

### Issue: No active agents
**Solution**:
```sql
-- Check agent status
SELECT agent_name, status FROM agent_registry;

-- Activate an agent
UPDATE agent_registry
SET status = 'active'
WHERE agent_name = 'MockTestAgent';
```

---

## 🎯 Next Steps

After database is set up:

1. ✅ Configure n8n Postgres credential
2. ✅ Activate workflow in n8n
3. ✅ Copy webhook URL from n8n
4. ⏭️ Set up Twilio webhook
5. ⏭️ Create mock agent endpoint
6. ⏭️ Test end-to-end SMS flow

---

## 📁 File Locations

- **Schema Files**: `schema/*.sql`
- **Test Data**: `test-data/quick_test_inserts.sql`
- **CSV Import**: `test-data/agent_registry_sample.csv`
- **This Guide**: `test-data/SUPABASE_SETUP.md`

---

**Need Help?** Check `DEPLOYMENT_GUIDE.md` for full deployment instructions.
