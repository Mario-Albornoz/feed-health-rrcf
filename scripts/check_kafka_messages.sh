#!/bin/bash
# Check if Kafka still has messages that can be re-consumed by detector

echo "============================================================"
echo "Kafka Message Check"
echo "============================================================"
echo ""

# Check if Kafka is running
if ! docker ps | grep thesis-kafka | grep -q "Up"; then
    echo "✗ Kafka is not running"
    echo ""
    echo "Start Kafka with: make kafka-up"
    exit 1
fi

echo "Checking Kafka consumer group status..."
echo ""

# Check multi-model consumer group
docker exec -it thesis-kafka kafka-consumer-groups \
    --bootstrap-server localhost:9092 \
    --describe --group multi-model-group 2>/dev/null | grep -v "^$"

echo ""
echo "============================================================"
echo "Interpretation:"
echo "============================================================"
echo ""
echo "CURRENT-OFFSET: Messages already consumed"
echo "LOG-END-OFFSET: Total messages in topic"
echo "LAG:            Unconsumed messages"
echo ""
echo "If LAG > 0:"
echo "  ✓ You can re-run JUST the detector to consume remaining messages"
echo "  ✓ Run: make stop-detector && rm -f rrcf-detector/data/scores*.parquet && make run-detector"
echo ""
echo "If LAG = 0 or topic doesn't exist:"
echo "  ✗ All messages consumed or topic cleaned"
echo "  ✗ Must re-run full pipeline: make clean-output-files && make thesis-full"
echo ""
