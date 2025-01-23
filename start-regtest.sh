#!/bin/bash

set -e  # Exit on error

# Function to show usage
usage() {
    echo "Start a Bitcoin regtest node with automatic mining and fund a faucet address"
    echo
    echo "Usage: $0 <faucet_address> [amount_btc] [mining_interval_seconds]"
    echo
    echo "Arguments:"
    echo "  faucet_address             Address to receive test BTC"
    echo "  amount_btc                 Amount of BTC to send (default: 100)"
    echo "  mining_interval_seconds    Block mining interval in seconds (default: 30)"
    echo
    echo "Example:"
    echo "  $0 bcrt1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo "  $0 bcrt1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx 50 60"
    exit 1
}

# Show usage if no args or help flag
case "$1" in
    ""|"-h"|"--help")
        usage
        ;;
esac

# Check if docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker is not running"
    exit 1
fi

# Check if faucet address is provided
if [ -z "$1" ]; then
    usage
fi

FAUCET_ADDRESS=$1
AMOUNT_BTC=${2:-100}  # Default to 100 if not provided
MINING_INTERVAL=${3:-30}  # Default to 30 seconds if not provided
BITCOIN_CLI="/srv/explorer/bitcoin/bin/bitcoin-cli -conf=/data/.bitcoin.conf -datadir=/data/bitcoin -regtest"

# Start the container and capture its ID
echo "Starting container..."
CONTAINER_ID=$(docker run -d -p 50004:50001 -p 8094:80 \
    --volume $PWD/data_bitcoin_regtest:/data \
    --rm -i -t esplora \
    bash -c "/srv/explorer/run.sh bitcoin-regtest explorer") || {
        echo "Error: Failed to start container"
        exit 1
    }

echo "Container started with ID: $CONTAINER_ID"

# Wait for container to initialize
echo "Waiting for bitcoin node to initialize..."
sleep 10

# Initialize wallet, generate blocks, and send coins to faucet
if ! docker exec $CONTAINER_ID bash -c "
    # Load the default wallet
    $BITCOIN_CLI loadwallet 'default' || $BITCOIN_CLI createwallet 'default' || exit 1;
    
    # Generate 101 blocks to a new address
    echo 'Generating initial blocks...'
    MINING_ADDRESS=\$($BITCOIN_CLI getnewaddress) || exit 1;
    $BITCOIN_CLI generatetoaddress 101 \$MINING_ADDRESS || exit 1;
    
    # Send BTC to faucet address
    echo 'Sending $AMOUNT_BTC BTC to faucet...'
    TXID=\$($BITCOIN_CLI sendtoaddress $FAUCET_ADDRESS $AMOUNT_BTC) || exit 1;
    echo \"Successfully sent $AMOUNT_BTC BTC to faucet. Transaction ID: \$TXID\";
    
    # Generate one block to confirm the transaction
    $BITCOIN_CLI generatetoaddress 1 \$MINING_ADDRESS || exit 1;"; then
    echo "Error: Failed to initialize wallet or send funds"
    docker stop $CONTAINER_ID > /dev/null
    exit 1
fi

# Start continuous block generation in background
echo "Starting automatic block generation..."
if ! docker exec -d $CONTAINER_ID bash -c "
    MINING_ADDRESS=\$($BITCOIN_CLI getnewaddress);
    while true; do 
        $BITCOIN_CLI generatetoaddress 1 \$MINING_ADDRESS || exit 1;
        sleep $MINING_INTERVAL;
    done"; then
    echo "Error: Failed to start automatic mining"
    docker stop $CONTAINER_ID > /dev/null
    exit 1
fi

# Verify mining is working
echo "Verifying automatic mining..."
INITIAL_HEIGHT=$(docker exec $CONTAINER_ID $BITCOIN_CLI getblockcount) || {
    echo "Error: Failed to get initial block height"
    docker stop $CONTAINER_ID > /dev/null
    exit 1
}

sleep $(($MINING_INTERVAL + 5))

NEW_HEIGHT=$(docker exec $CONTAINER_ID $BITCOIN_CLI getblockcount) || {
    echo "Error: Failed to get new block height"
    docker stop $CONTAINER_ID > /dev/null
    exit 1
}

if [ $NEW_HEIGHT -gt $INITIAL_HEIGHT ]; then
    echo "Automatic mining verified - blocks are being generated every $MINING_INTERVAL seconds"
    echo "Initial block height: $INITIAL_HEIGHT"
    echo "Current block height: $NEW_HEIGHT"
else
    echo "Error: Automatic mining is not working properly"
    docker stop $CONTAINER_ID > /dev/null
    exit 1
fi

echo "Container is running at http://localhost:8094"
echo "To stop, run: docker stop $CONTAINER_ID"