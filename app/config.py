"""Configuration, read from the environment.

In development these come from .env (exported by the Makefile). On an
image-mode host they come from the systemd unit.
"""
import os

DB_URL = os.environ.get("IM_TRAIN_DB_URL", "")
HOST = os.environ.get("IM_TRAIN_HOST", "0.0.0.0")
PORT = int(os.environ.get("IM_TRAIN_PORT", "8080"))

# Which tier this process is. Only ever "app" in this demo, but the Status
# page reports it so a viewer can tell the two VMs apart on screen.
TIER = os.environ.get("IM_TRAIN_TIER", "app")
