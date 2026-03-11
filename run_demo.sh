#!/usr/bin/env bash
set -e

# Export homebrew path in case it's not in the system PATH
export PATH="/opt/homebrew/bin:$PATH"

# Set DOCKER_HOST to use Colima
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

# Check if Colima is running, start if not
if ! colima status >/dev/null 2>&1; then
    echo "Starting colima..."
    colima start --cpu 2 --memory 4
fi

# ==========================================
# 1. Wait for StarRocks Docker Container
# ==========================================
echo "[1/3] Initializing StarRocks Database Container..."
# Clean up any existing container
docker rm -f starrocks 2>/dev/null || true
docker-compose down 2>/dev/null || true
docker-compose up -d

echo "Waiting for StarRocks to be ready on port 9030..."
while ! nc -z 127.0.0.1 9030; do
    sleep 1
done
echo "StarRocks is ready!"

# ==========================================
# 2. Generate Mock S3 Parquet Data
# ==========================================
echo "[2/3] Starting Moto (Local S3) and generating Mock Parquet Data..."

# Activate python environment
if [ ! -d "venv" ]; then
    echo "Creating python venv..."
    python3 -m venv venv
    source venv/bin/activate
    pip install "moto[server]" s3fs pyarrow pandas boto3
else
    source venv/bin/activate
fi

# Kill existing moto running on port 5001 if it exists
lsof -ti:5001 | xargs kill -9 2>/dev/null || true

# Start Moto server in the background
moto_server -p 5001 > moto.log 2>&1 &
MOTO_PID=$!
sleep 3

# Generate Data and Upload to Mock S3
python generate_data.py

# ==========================================
# 3. Integrate with StarRocks
# ==========================================
echo "[3/3] Setting up StarRocks tables & MV and querying data..."

# Give StarRocks a brief extra moment to fully initialize the MySQL service
sleep 5

# Run SQL Script natively using MySQL client with simple retry logic
MAX_RETRIES=5
RETRY_DELAY=3
ATTEMPT=1

while true; do
    if mysql -h 127.0.0.1 -P 9030 -u root < setup_starrocks.sql; then
        break
    fi

    if [ "$ATTEMPT" -ge "$MAX_RETRIES" ]; then
        echo "Failed to connect to StarRocks via MySQL after ${MAX_RETRIES} attempts."
        exit 1
    fi

    echo "MySQL connection failed, retrying in ${RETRY_DELAY}s... (attempt ${ATTEMPT}/${MAX_RETRIES})"
    ATTEMPT=$((ATTEMPT + 1))
    sleep "${RETRY_DELAY}"
done

echo "Refreshing Materialized View to build metrics..."
mysql -h 127.0.0.1 -P 9030 -u root -D lakehouse -e "REFRESH MATERIALIZED VIEW client_daily_metrics WITH SYNC MODE;"

echo "--------------------------------------------------------"
echo "✅ Data loaded securely into StarRocks Materialized View!"
echo "Running validation query:"
echo "--------------------------------------------------------"

mysql -h 127.0.0.1 -P 9030 -u root -e "SELECT * FROM lakehouse.client_daily_metrics LIMIT 10;"

echo "--------------------------------------------------------"
echo "You can now connect to your local StarRocks instance using any MySQL client!"
echo "Host: 127.0.0.1 | Port: 9030 | User: root | Database: lakehouse"

# Cleanup Moto trap
kill $MOTO_PID
echo "Shutting down mock S3."
