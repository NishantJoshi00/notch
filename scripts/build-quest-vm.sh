#!/bin/bash
set -euo pipefail

# Build a minimal ARM64 Linux VM image for Notch side-quests.
# Requires: Docker (for cross-platform rootfs build)
#
# Output:
#   ~/.notch/quests/vm/vmlinux     — ARM64 Linux kernel
#   ~/.notch/quests/vm/rootfs.ext4 — ext4 root filesystem with Python + Agent SDK
#   ~/.notch/quests/vm/runner.py   — the quest agent script

VM_DIR="$HOME/.notch/quests/vm"
ROOTFS_SIZE="512M"

echo "==> Building quest VM image..."
mkdir -p "$VM_DIR"

# --- Step 1: Build rootfs via Docker ---
echo "==> Building rootfs with Docker..."

DOCKERFILE=$(mktemp)
cat > "$DOCKERFILE" << 'DOCKERFILE_CONTENT'
FROM --platform=linux/arm64 python:3.12-slim

# Install agent SDK and poweroff capability
RUN pip install --no-cache-dir claude-agent-sdk && \
    apt-get update && apt-get install -y --no-install-recommends systemd && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Create quest directories
RUN mkdir -p /quest/shared

# Copy runner script
COPY runner.py /quest/runner.py

# Boot script: run the quest then poweroff
RUN echo '#!/bin/sh\n\
mount -t virtiofs shared /quest/shared 2>/dev/null || true\n\
if [ -f /quest/shared/goal.json ]; then\n\
    cd /quest\n\
    python3 /quest/runner.py 2>/quest/shared/stderr.log\n\
fi\n\
poweroff -f' > /quest/boot.sh && chmod +x /quest/boot.sh
DOCKERFILE_CONTENT

# Write the runner.py
RUNNER=$(mktemp)
cat > "$RUNNER" << 'RUNNER_CONTENT'
#!/usr/bin/env python3
"""Notch quest runner — executes inside a Linux VM."""

import asyncio
import json
import os
import sys
from pathlib import Path

async def main():
    shared = Path("/quest/shared")
    goal_file = shared / "goal.json"

    if not goal_file.exists():
        (shared / "result.md").write_text("Error: no goal.json found")
        return

    config = json.loads(goal_file.read_text())
    goal = config["goal"]
    model = config.get("model", "claude-opus-4-6")
    max_turns = config.get("max_turns", 20)
    max_budget = config.get("max_budget_usd", 0.50)
    api_key = config.get("api_key", os.environ.get("ANTHROPIC_API_KEY", ""))

    if not api_key:
        (shared / "result.md").write_text("Error: no API key provided")
        return

    os.environ["ANTHROPIC_API_KEY"] = api_key

    try:
        from claude_agent_sdk import query, ClaudeAgentOptions, ResultMessage

        options = ClaudeAgentOptions(
            allowed_tools=["Bash", "WebSearch", "Read", "Write", "Glob", "Grep"],
            permission_mode="bypassPermissions",
            max_turns=max_turns,
            max_budget_usd=max_budget,
            model=model,
            system_prompt=(
                "You are a research agent working on a specific quest for Notch. "
                "Work thoroughly toward the goal. Write your findings clearly. "
                "When done, provide a concise summary of what you found."
            ),
            cwd="/quest/workspace",
        )

        os.makedirs("/quest/workspace", exist_ok=True)
        result_text = ""

        async for message in query(prompt=goal, options=options):
            if isinstance(message, ResultMessage):
                result_text = message.result or "(no output)"
                cost_info = f"\n\n---\nTurns: {message.num_turns}"
                if message.total_cost_usd is not None:
                    cost_info += f" | Cost: ${message.total_cost_usd:.4f}"
                result_text += cost_info

        (shared / "result.md").write_text(result_text)

    except Exception as e:
        (shared / "result.md").write_text(f"Error: {e}")

asyncio.run(main())
RUNNER_CONTENT

# Build the Docker image
CONTEXT_DIR=$(mktemp -d)
cp "$RUNNER" "$CONTEXT_DIR/runner.py"
cp "$DOCKERFILE" "$CONTEXT_DIR/Dockerfile"

docker build --platform linux/arm64 -t notch-quest-vm "$CONTEXT_DIR"

# Export rootfs
echo "==> Exporting rootfs..."
CONTAINER_ID=$(docker create --platform linux/arm64 notch-quest-vm)
docker export "$CONTAINER_ID" > "$VM_DIR/rootfs.tar"
docker rm "$CONTAINER_ID" > /dev/null

# Create ext4 image from tar
echo "==> Creating ext4 image ($ROOTFS_SIZE)..."
dd if=/dev/zero of="$VM_DIR/rootfs.ext4" bs=1 count=0 seek="$ROOTFS_SIZE" 2>/dev/null
mkfs.ext4 -q "$VM_DIR/rootfs.ext4"

# Mount and extract (needs sudo for ext4 mount)
MOUNT_DIR=$(mktemp -d)
echo "==> Extracting rootfs (may require sudo for mount)..."
sudo mount -o loop "$VM_DIR/rootfs.ext4" "$MOUNT_DIR"
sudo tar xf "$VM_DIR/rootfs.tar" -C "$MOUNT_DIR"
sudo umount "$MOUNT_DIR"
rm -rf "$MOUNT_DIR" "$VM_DIR/rootfs.tar"

# --- Step 2: Get ARM64 Linux kernel ---
echo "==> Fetching ARM64 Linux kernel..."

# Extract kernel from the Docker image
docker run --rm --platform linux/arm64 notch-quest-vm cat /boot/vmlinuz-* > "$VM_DIR/vmlinux" 2>/dev/null || {
    # Fallback: download a pre-built kernel
    echo "==> Downloading pre-built kernel..."
    curl -sL "https://github.com/nicklarge/mac-linux-vm-kernels/releases/latest/download/vmlinux-arm64" -o "$VM_DIR/vmlinux"
}

# Cleanup
rm -f "$DOCKERFILE" "$RUNNER"
rm -rf "$CONTEXT_DIR"
docker rmi notch-quest-vm > /dev/null 2>&1 || true

echo ""
echo "==> Quest VM built successfully!"
echo "    Kernel: $VM_DIR/vmlinux"
echo "    Rootfs: $VM_DIR/rootfs.ext4"
echo ""
echo "    To test: swift build && .build/debug/Notch"
