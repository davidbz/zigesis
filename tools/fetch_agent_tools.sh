#!/bin/bash

echo "Installing RTK"
curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh

echo "Installing UV"
curl -LsSf https://astral.sh/uv/install.sh | sh

echo "Installing Headroom"
uv tool install "headroom-ai[all]"

echo "Installing Claude"
curl -fsSL https://claude.ai/install.sh | bash
