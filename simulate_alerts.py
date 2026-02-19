#!/usr/bin/env python3
"""
MongoDB Atlas Alert Simulator

This script simulates various conditions that can trigger MongoDB Atlas alerts.
Useful for testing and demonstrating that alert configurations are working.

WARNING: This script is for DEMO/TESTING purposes only.
         Do NOT run against production databases!

Usage:
    python3 simulate_alerts.py --connection-string "mongodb+srv://..." --simulation cpu
    python3 simulate_alerts.py --connection-string "mongodb+srv://..." --simulation query-targeting
    python3 simulate_alerts.py --connection-string "mongodb+srv://..." --simulation connections
    python3 simulate_alerts.py --connection-string "mongodb+srv://..." --simulation all --duration 60
"""

import argparse
import os
import sys
import time
import random
import string
import threading
from datetime import datetime

try:
    from pymongo import MongoClient
    from pymongo.errors import ConnectionFailure, OperationFailure
except ImportError:
    print("ERROR: pymongo is required. Install with: pip install pymongo")
    sys.exit(1)


# ============================================================================
# Configuration
# ============================================================================

DATABASE_NAME = "alert_simulator_test"
COLLECTION_NAME = "test_data"


# ============================================================================
# Utility Functions
# ============================================================================

def log(message, level="INFO"):
    """Print timestamped log message."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    prefix = {"INFO": "ℹ️ ", "WARN": "⚠️ ", "ERROR": "❌", "SUCCESS": "✅"}
    print(f"[{timestamp}] {prefix.get(level, '')} {message}")


def generate_random_string(length=100):
    """Generate a random string of specified length."""
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))


def generate_random_document():
    """Generate a random document for testing."""
    return {
        "name": generate_random_string(50),
        "email": f"{generate_random_string(10)}@example.com",
        "age": random.randint(18, 80),
        "balance": random.uniform(0, 100000),
        "status": random.choice(["active", "inactive", "pending"]),
        "tags": [generate_random_string(10) for _ in range(random.randint(1, 10))],
        "metadata": {
            "created_at": datetime.now(),
            "updated_at": datetime.now(),
            "version": random.randint(1, 100),
            "data": generate_random_string(500)
        },
        "description": generate_random_string(1000)
    }


# ============================================================================
# Alert Simulations
# ============================================================================

def simulate_cpu_load(client, duration_seconds=60):
    """
    Simulate high CPU usage by running compute-intensive aggregations.
    
    This can trigger:
    - System: CPU (User) % alerts
    """
    log(f"Starting CPU load simulation for {duration_seconds} seconds...")
    log("This simulates: System: CPU (User) % > threshold", "WARN")
    
    db = client[DATABASE_NAME]
    collection = db[COLLECTION_NAME]
    
    # Insert some data first
    log("Inserting test documents...")
    docs = [generate_random_document() for _ in range(10000)]
    collection.insert_many(docs)
    log(f"Inserted {len(docs)} documents")
    
    start_time = time.time()
    iterations = 0
    
    while time.time() - start_time < duration_seconds:
        # Run CPU-intensive aggregation
        pipeline = [
            {"$match": {"age": {"$gte": 20}}},
            {"$addFields": {
                "computed1": {"$multiply": ["$balance", "$age"]},
                "computed2": {"$concat": ["$name", " - ", "$email"]},
            }},
            {"$group": {
                "_id": "$status",
                "total": {"$sum": "$balance"},
                "avg_age": {"$avg": "$age"},
                "count": {"$sum": 1}
            }},
            {"$sort": {"total": -1}},
            {"$project": {
                "status": "$_id",
                "total": 1,
                "avg_age": 1,
                "count": 1,
                "ratio": {"$divide": ["$total", {"$add": ["$count", 1]}]}
            }}
        ]
        
        try:
            list(collection.aggregate(pipeline))
            iterations += 1
            if iterations % 100 == 0:
                elapsed = time.time() - start_time
                log(f"  Completed {iterations} aggregations ({elapsed:.1f}s elapsed)")
        except Exception as e:
            log(f"Aggregation error: {e}", "ERROR")
    
    log(f"CPU simulation complete. Ran {iterations} aggregations.", "SUCCESS")


def simulate_query_targeting(client, duration_seconds=60):
    """
    Simulate poor query targeting (collection scans without indexes).
    
    This can trigger:
    - Query Targeting: Scanned Objects / Returned > 1000
    - Host has index suggestions
    """
    log(f"Starting query targeting simulation for {duration_seconds} seconds...")
    log("This simulates: Query Targeting alerts (scanned/returned ratio)", "WARN")
    
    db = client[DATABASE_NAME]
    collection = db[COLLECTION_NAME]
    
    # Drop any existing indexes (except _id)
    for index in collection.list_indexes():
        if index['name'] != '_id_':
            collection.drop_index(index['name'])
    
    # Insert lots of documents
    log("Inserting test documents (this may take a moment)...")
    batch_size = 1000
    total_docs = 50000
    
    for i in range(0, total_docs, batch_size):
        docs = [generate_random_document() for _ in range(batch_size)]
        collection.insert_many(docs)
        if (i + batch_size) % 10000 == 0:
            log(f"  Inserted {i + batch_size} documents...")
    
    log(f"Inserted {total_docs} documents")
    
    start_time = time.time()
    query_count = 0
    
    while time.time() - start_time < duration_seconds:
        # Run queries on non-indexed fields (causes collection scans)
        queries = [
            {"balance": {"$gt": random.uniform(1000, 50000)}},
            {"age": {"$lt": random.randint(30, 60)}},
            {"status": random.choice(["active", "inactive", "pending"])},
            {"name": {"$regex": f"^{generate_random_string(3)}", "$options": "i"}},
            {"metadata.version": random.randint(1, 50)},
        ]
        
        for query in queries:
            try:
                # Find with limit to ensure we scan more than we return
                results = list(collection.find(query).limit(5))
                query_count += 1
            except Exception as e:
                log(f"Query error: {e}", "ERROR")
        
        if query_count % 500 == 0:
            elapsed = time.time() - start_time
            log(f"  Executed {query_count} queries ({elapsed:.1f}s elapsed)")
    
    log(f"Query targeting simulation complete. Ran {query_count} queries.", "SUCCESS")
    log("Check Atlas for 'Query Targeting' and 'Index Suggestions' alerts", "INFO")


def simulate_connections(client, connection_string, max_connections=100, duration_seconds=60):
    """
    Simulate many concurrent connections.
    
    This can trigger:
    - Connections % of configured limit alerts
    """
    log(f"Starting connections simulation: {max_connections} connections for {duration_seconds}s...")
    log("This simulates: Connections % of configured limit alerts", "WARN")
    
    connections = []
    
    def hold_connection(conn_id):
        """Open and hold a connection."""
        try:
            conn = MongoClient(connection_string, serverSelectionTimeoutMS=5000)
            conn.admin.command('ping')
            connections.append(conn)
            log(f"  Connection {conn_id} established")
        except Exception as e:
            log(f"  Connection {conn_id} failed: {e}", "ERROR")
    
    # Open connections gradually
    log("Opening connections...")
    threads = []
    for i in range(max_connections):
        t = threading.Thread(target=hold_connection, args=(i+1,))
        threads.append(t)
        t.start()
        time.sleep(0.1)  # Stagger connection attempts
    
    # Wait for all threads
    for t in threads:
        t.join()
    
    log(f"Established {len(connections)} connections")
    
    # Hold connections for duration
    log(f"Holding connections for {duration_seconds} seconds...")
    time.sleep(duration_seconds)
    
    # Close all connections
    log("Closing connections...")
    for conn in connections:
        try:
            conn.close()
        except:
            pass
    
    log("Connections simulation complete.", "SUCCESS")


def simulate_write_load(client, duration_seconds=60):
    """
    Simulate heavy write load.
    
    This can trigger:
    - Disk write IOPS alerts
    - Disk write latency alerts
    - Queues: Writers alerts
    """
    log(f"Starting write load simulation for {duration_seconds} seconds...")
    log("This simulates: Disk IOPS, Disk latency, Writer queue alerts", "WARN")
    
    db = client[DATABASE_NAME]
    collection = db[COLLECTION_NAME]
    
    start_time = time.time()
    total_writes = 0
    
    while time.time() - start_time < duration_seconds:
        # Batch inserts
        docs = [generate_random_document() for _ in range(100)]
        collection.insert_many(docs)
        total_writes += 100
        
        # Updates
        collection.update_many(
            {"status": "active"},
            {"$inc": {"metadata.version": 1}, "$set": {"metadata.updated_at": datetime.now()}}
        )
        
        # Deletes (to maintain collection size)
        if total_writes > 50000:
            collection.delete_many({"age": {"$lt": 25}})
        
        if total_writes % 5000 == 0:
            elapsed = time.time() - start_time
            log(f"  Written {total_writes} documents ({elapsed:.1f}s elapsed)")
    
    log(f"Write load simulation complete. Total writes: {total_writes}", "SUCCESS")


def simulate_read_load(client, duration_seconds=60):
    """
    Simulate heavy read load.
    
    This can trigger:
    - Disk read IOPS alerts
    - Disk read latency alerts
    - Queues: Readers alerts
    """
    log(f"Starting read load simulation for {duration_seconds} seconds...")
    log("This simulates: Disk read IOPS, read latency, Reader queue alerts", "WARN")
    
    db = client[DATABASE_NAME]
    collection = db[COLLECTION_NAME]
    
    # Ensure we have data
    count = collection.count_documents({})
    if count < 10000:
        log("Inserting test documents first...")
        docs = [generate_random_document() for _ in range(10000)]
        collection.insert_many(docs)
    
    start_time = time.time()
    total_reads = 0
    
    while time.time() - start_time < duration_seconds:
        # Random reads
        for _ in range(100):
            collection.find_one({"age": random.randint(18, 80)})
            total_reads += 1
        
        # Range scans
        list(collection.find({"balance": {"$gt": random.uniform(0, 50000)}}).limit(100))
        total_reads += 1
        
        # Full document reads
        list(collection.find().limit(50))
        total_reads += 1
        
        if total_reads % 5000 == 0:
            elapsed = time.time() - start_time
            log(f"  Completed {total_reads} reads ({elapsed:.1f}s elapsed)")
    
    log(f"Read load simulation complete. Total reads: {total_reads}", "SUCCESS")


# ============================================================================
# Cleanup
# ============================================================================

def cleanup(client):
    """Remove test database and collections."""
    log("Cleaning up test data...")
    client.drop_database(DATABASE_NAME)
    log("Cleanup complete.", "SUCCESS")


# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Simulate conditions that trigger MongoDB Atlas alerts",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Simulations available:
  cpu              - High CPU usage (aggregations)
  query-targeting  - Poor query targeting (collection scans)
  connections      - Many concurrent connections
  write-load       - Heavy write operations
  read-load        - Heavy read operations
  all              - Run all simulations

Examples:
  %(prog)s --connection-string "mongodb+srv://user:pass@cluster.mongodb.net" --simulation cpu
  %(prog)s --connection-string "mongodb+srv://..." --simulation all --duration 120
  %(prog)s --connection-string "mongodb+srv://..." --simulation query-targeting --cleanup
        """
    )
    
    parser.add_argument(
        "--connection-string",
        required=True,
        help="MongoDB connection string (mongodb+srv://...)"
    )
    parser.add_argument(
        "--simulation",
        choices=["cpu", "query-targeting", "connections", "write-load", "read-load", "all"],
        default="cpu",
        help="Type of simulation to run (default: cpu)"
    )
    parser.add_argument(
        "--duration",
        type=int,
        default=60,
        help="Duration in seconds (default: 60)"
    )
    parser.add_argument(
        "--max-connections",
        type=int,
        default=50,
        help="Max connections for connections simulation (default: 50)"
    )
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="Clean up test data after simulation"
    )
    parser.add_argument(
        "--cleanup-only",
        action="store_true",
        help="Only clean up test data (don't run simulation)"
    )
    
    args = parser.parse_args()
    
    print("=" * 80)
    print("  MongoDB Atlas Alert Simulator")
    print("  WARNING: For DEMO/TESTING purposes only!")
    print("=" * 80)
    print()
    
    # Connect to MongoDB
    log("Connecting to MongoDB Atlas...")
    try:
        client = MongoClient(args.connection_string, serverSelectionTimeoutMS=10000)
        client.admin.command('ping')
        log("Connected to MongoDB Atlas", "SUCCESS")
    except ConnectionFailure as e:
        log(f"Failed to connect: {e}", "ERROR")
        sys.exit(1)
    
    # Cleanup only
    if args.cleanup_only:
        cleanup(client)
        client.close()
        return
    
    # Run simulations
    try:
        if args.simulation == "cpu" or args.simulation == "all":
            simulate_cpu_load(client, args.duration)
            print()
        
        if args.simulation == "query-targeting" or args.simulation == "all":
            simulate_query_targeting(client, args.duration)
            print()
        
        if args.simulation == "connections" or args.simulation == "all":
            simulate_connections(client, args.connection_string, args.max_connections, args.duration)
            print()
        
        if args.simulation == "write-load" or args.simulation == "all":
            simulate_write_load(client, args.duration)
            print()
        
        if args.simulation == "read-load" or args.simulation == "all":
            simulate_read_load(client, args.duration)
            print()
        
    except KeyboardInterrupt:
        log("Simulation interrupted by user", "WARN")
    except Exception as e:
        log(f"Simulation error: {e}", "ERROR")
    
    # Cleanup if requested
    if args.cleanup:
        print()
        cleanup(client)
    
    client.close()
    
    print()
    print("=" * 80)
    print("  Simulation complete!")
    print("  Check MongoDB Atlas Alerts page for triggered alerts")
    print("  https://cloud.mongodb.com/v2/<project-id>#/alerts")
    print("=" * 80)


if __name__ == "__main__":
    main()
