#!/usr/bin/env python3
"""
UPS Power Monitor
Monitors a Zigbee smart plug via Home Assistant API to detect power outages.
Orchestrates graceful shutdown of Kubernetes nodes when UPS is running on battery.
"""

import os
import sys
import time
import logging
import requests
import subprocess
from datetime import datetime
from kubernetes import client, config
from typing import Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class PowerMonitor:
    def __init__(self):
        # Home Assistant configuration
        self.ha_url = os.getenv('HA_URL', 'http://localhost:8123')
        self.ha_token = os.getenv('HA_TOKEN')
        self.power_sensor = os.getenv('POWER_SENSOR', 'sensor.smart_plug_power')
        self.poll_interval = int(os.getenv('POLL_INTERVAL', '15'))  # seconds

        # Shutdown timing configuration (in seconds)
        self.shutdown_pi5_01_delay = int(os.getenv('SHUTDOWN_PI5_01_DELAY', '180'))  # 3 min
        self.shutdown_others_delay = int(os.getenv('SHUTDOWN_OTHERS_DELAY', '420'))  # 7 min

        # Node configuration
        self.critical_node = os.getenv('CRITICAL_NODE', 'pi4-02')  # Never shutdown
        self.priority_shutdown_nodes = os.getenv('PRIORITY_NODES', 'pi5-01').split(',')
        self.secondary_shutdown_nodes = os.getenv('SECONDARY_NODES', 'pi4-01,pi5-02').split(',')

        # SSH configuration for shutdowns
        self.ssh_user = os.getenv('SSH_USER', 'jarrodservilla')
        self.ssh_key_path = os.getenv('SSH_KEY_PATH', '/root/.ssh/id_rsa')

        # Testing and dry-run configuration
        self.dry_run = os.getenv('DRY_RUN', 'false').lower() == 'true'
        self.test_mode = os.getenv('TEST_MODE', 'none').lower()  # none, simulate_outage, full
        self.skip_shutdown = os.getenv('SKIP_SHUTDOWN', 'false').lower() == 'true'

        # State tracking
        self.power_outage_start: Optional[datetime] = None
        self.shutdown_initiated = False
        self.nodes_shutdown = set()

        # Validate configuration
        if not self.ha_token:
            logger.error("HA_TOKEN environment variable is required")
            sys.exit(1)

        # Initialize Kubernetes client
        try:
            config.load_incluster_config()
            self.k8s_core = client.CoreV1Api()
            logger.info("Kubernetes client initialized (in-cluster)")
        except Exception as e:
            logger.error(f"Failed to initialize Kubernetes client: {e}")
            sys.exit(1)

    def get_power_status(self) -> Optional[dict]:
        """Query Home Assistant for power sensor status."""
        try:
            headers = {
                'Authorization': f'Bearer {self.ha_token}',
                'Content-Type': 'application/json',
            }
            url = f'{self.ha_url}/api/states/{self.power_sensor}'
            response = requests.get(url, headers=headers, timeout=10)
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Failed to query Home Assistant: {e}")
            return None

    def is_power_available(self, sensor_data: dict) -> bool:
        """Check if AC power is available based on sensor state."""
        # Test mode: simulate power outage
        if self.test_mode == 'simulate_outage':
            logger.warning("[TEST MODE] Simulating power outage")
            return False

        if not sensor_data:
            return False

        state = sensor_data.get('state', '').lower()

        # If sensor is unavailable or unknown, power is likely out
        if state in ['unavailable', 'unknown', 'none']:
            return False

        # If we can read power value and it's > 0, power is available
        try:
            power = float(state)
            return power > 0  # Any power reading means plug is online
        except (ValueError, TypeError):
            return False

    def cordon_node(self, node_name: str) -> bool:
        """Mark node as unschedulable."""
        if self.dry_run:
            logger.info(f"[DRY RUN] Would cordon node: {node_name}")
            return True

        try:
            body = {
                "spec": {
                    "unschedulable": True
                }
            }
            self.k8s_core.patch_node(node_name, body)
            logger.info(f"✓ Cordoned node: {node_name}")
            return True
        except Exception as e:
            logger.error(f"Failed to cordon node {node_name}: {e}")
            return False

    def uncordon_node(self, node_name: str) -> bool:
        """Mark node as schedulable."""
        if self.dry_run:
            logger.info(f"[DRY RUN] Would uncordon node: {node_name}")
            return True

        try:
            body = {
                "spec": {
                    "unschedulable": False
                }
            }
            self.k8s_core.patch_node(node_name, body)
            logger.info(f"✓ Uncordoned node: {node_name}")
            return True
        except Exception as e:
            logger.error(f"Failed to uncordon node {node_name}: {e}")
            return False

    def drain_node(self, node_name: str) -> bool:
        """Drain pods from node using kubectl."""
        if self.dry_run:
            logger.info(f"[DRY RUN] Would drain node: {node_name}")
            return True

        try:
            cmd = [
                'kubectl', 'drain', node_name,
                '--ignore-daemonsets',
                '--delete-emptydir-data',
                '--force',
                '--grace-period=30',
                '--timeout=120s'
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
            if result.returncode == 0:
                logger.info(f"✓ Drained node: {node_name}")
                return True
            else:
                logger.error(f"Failed to drain node {node_name}: {result.stderr}")
                return False
        except Exception as e:
            logger.error(f"Exception draining node {node_name}: {e}")
            return False

    def shutdown_node(self, node_name: str) -> bool:
        """Shutdown node via SSH."""
        if self.dry_run or self.skip_shutdown:
            mode = "DRY RUN" if self.dry_run else "SKIP_SHUTDOWN"
            logger.warning(f"[{mode}] Would shutdown node: {node_name}")
            self.nodes_shutdown.add(node_name)
            return True

        try:
            # Get node IP from Kubernetes
            node = self.k8s_core.read_node(node_name)
            node_ip = None
            for address in node.status.addresses:
                if address.type == 'InternalIP':
                    node_ip = address.address
                    break

            if not node_ip:
                logger.error(f"Could not find IP for node {node_name}")
                return False

            # Use key-based SSH authentication
            cmd = [
                'ssh',
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'UserKnownHostsFile=/dev/null',
                '-i', self.ssh_key_path,
                f'{self.ssh_user}@{node_ip}',
                'sudo shutdown -h now'
            ]

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            logger.info(f"✓ Initiated shutdown on node: {node_name} ({node_ip})")
            self.nodes_shutdown.add(node_name)
            return True
        except Exception as e:
            logger.error(f"Failed to shutdown node {node_name}: {e}")
            return False

    def execute_shutdown_sequence(self, elapsed_time: float):
        """Execute phased shutdown based on elapsed outage time."""

        # Phase 1: Shutdown priority nodes (pi5-01 with hard drive)
        if elapsed_time >= 30 and not self.shutdown_initiated:
            logger.warning(f"⚡ Phase 1: Shutting down priority nodes")
            self.shutdown_initiated = True

            for node in self.priority_shutdown_nodes:
                node = node.strip()
                if node == self.critical_node:
                    continue
                logger.info(f"Processing priority node: {node}")
                self.cordon_node(node)

        # Phase 2: Drain priority nodes
        if elapsed_time >= 60:
            for node in self.priority_shutdown_nodes:
                node = node.strip()
                if node == self.critical_node or node in self.nodes_shutdown:
                    continue
                logger.info(f"Draining priority node: {node}")
                self.drain_node(node)

        # Phase 3: Shutdown priority nodes
        if elapsed_time >= self.shutdown_pi5_01_delay:
            for node in self.priority_shutdown_nodes:
                node = node.strip()
                if node == self.critical_node or node in self.nodes_shutdown:
                    continue
                logger.warning(f"🔌 Shutting down priority node: {node}")
                self.shutdown_node(node)

        # Phase 4: Cordon and drain secondary nodes
        if elapsed_time >= 300:  # 5 minutes
            for node in self.secondary_shutdown_nodes:
                node = node.strip()
                if node == self.critical_node or node in self.nodes_shutdown:
                    continue
                logger.info(f"Processing secondary node: {node}")
                self.cordon_node(node)
                self.drain_node(node)

        # Phase 5: Shutdown secondary nodes
        if elapsed_time >= self.shutdown_others_delay:
            for node in self.secondary_shutdown_nodes:
                node = node.strip()
                if node == self.critical_node or node in self.nodes_shutdown:
                    continue
                logger.warning(f"🔌 Shutting down secondary node: {node}")
                self.shutdown_node(node)

    def restore_power_procedures(self):
        """Execute procedures when power is restored."""
        logger.info("🔋 Power restored! Initiating recovery procedures...")

        # Wait a bit for nodes to boot up
        logger.info("Waiting 60 seconds for nodes to boot...")
        time.sleep(60)

        # Check which nodes are back online and uncordon them
        try:
            nodes = self.k8s_core.list_node()
            for node in nodes.items:
                node_name = node.metadata.name

                # Skip the critical node (it never shut down)
                if node_name == self.critical_node:
                    continue

                # Check if node is ready
                is_ready = False
                for condition in node.status.conditions:
                    if condition.type == 'Ready' and condition.status == 'True':
                        is_ready = True
                        break

                # If node is ready and was shut down, uncordon it
                if is_ready and node.spec.unschedulable:
                    logger.info(f"Node {node_name} is back online, uncordoning...")
                    self.uncordon_node(node_name)
        except Exception as e:
            logger.error(f"Error during power restoration: {e}")

        # Reset state
        self.power_outage_start = None
        self.shutdown_initiated = False
        self.nodes_shutdown.clear()
        logger.info("✓ Recovery procedures complete")

    def run(self):
        """Main monitoring loop."""
        logger.info("🔍 Power Monitor starting...")
        logger.info(f"Monitoring sensor: {self.power_sensor}")
        logger.info(f"Home Assistant URL: {self.ha_url}")
        logger.info(f"Poll interval: {self.poll_interval}s")
        logger.info(f"Critical node (never shutdown): {self.critical_node}")
        logger.info(f"Priority shutdown nodes: {self.priority_shutdown_nodes}")
        logger.info(f"Secondary shutdown nodes: {self.secondary_shutdown_nodes}")

        # Log test/dry-run modes
        if self.dry_run:
            logger.warning("=" * 60)
            logger.warning("DRY RUN MODE ENABLED - No actions will be taken!")
            logger.warning("All operations will be logged but not executed")
            logger.warning("=" * 60)
        if self.skip_shutdown:
            logger.warning("=" * 60)
            logger.warning("SKIP_SHUTDOWN ENABLED - Nodes will be cordoned/drained")
            logger.warning("but NOT shut down. Useful for testing without rebooting.")
            logger.warning("=" * 60)
        if self.test_mode == 'simulate_outage':
            logger.warning("=" * 60)
            logger.warning("TEST MODE: SIMULATE_OUTAGE")
            logger.warning("Power will always appear to be OUT")
            logger.warning("Shutdown sequence will execute continuously")
            logger.warning("=" * 60)
        elif self.test_mode == 'full':
            logger.warning("=" * 60)
            logger.warning("TEST MODE: FULL")
            logger.warning("Testing all functions without restrictions")
            logger.warning("=" * 60)

        while True:
            try:
                # Query power status
                sensor_data = self.get_power_status()
                power_available = self.is_power_available(sensor_data)

                if power_available:
                    # Power is available
                    if self.power_outage_start:
                        # Power was out, now restored
                        outage_duration = (datetime.now() - self.power_outage_start).total_seconds()
                        logger.info(f"✓ Power restored after {outage_duration:.0f}s outage")

                        # Only run restoration if we actually shut down nodes
                        if self.shutdown_initiated or self.nodes_shutdown:
                            self.restore_power_procedures()
                        else:
                            # Just reset state
                            self.power_outage_start = None
                            self.shutdown_initiated = False

                    # All is well, log periodically
                    if int(time.time()) % 300 == 0:  # Every 5 minutes
                        state = sensor_data.get('state', 'unknown') if sensor_data else 'error'
                        logger.info(f"✓ Power OK - {self.power_sensor}: {state}W")

                else:
                    # Power is OUT
                    if not self.power_outage_start:
                        # New outage detected
                        self.power_outage_start = datetime.now()
                        logger.warning(f"⚠️  POWER OUTAGE DETECTED! Running on UPS battery")
                        logger.warning(f"⚠️  Sensor state: {sensor_data.get('state') if sensor_data else 'unavailable'}")

                    # Calculate elapsed outage time
                    elapsed = (datetime.now() - self.power_outage_start).total_seconds()
                    logger.warning(f"⚠️  Power outage: {elapsed:.0f}s elapsed")

                    # Execute shutdown sequence
                    self.execute_shutdown_sequence(elapsed)

                # Sleep until next poll
                time.sleep(self.poll_interval)

            except KeyboardInterrupt:
                logger.info("Shutting down power monitor...")
                break
            except Exception as e:
                logger.error(f"Unexpected error in main loop: {e}", exc_info=True)
                time.sleep(self.poll_interval)

if __name__ == '__main__':
    monitor = PowerMonitor()
    monitor.run()
