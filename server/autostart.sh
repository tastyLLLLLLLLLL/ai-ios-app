#!/usr/bin/env bash
# Pod start command for RunPod ("Container Start Command"):
#
#   bash /workspace/ai-server/autostart.sh
#
# Starts RunPod's own services (SSH, web terminal) and the Pocket AI server,
# so nothing has to be run by hand after the pod is switched on.
mkdir -p /workspace/ai-server/logs
if [ -x /start.sh ]; then
  /start.sh &
fi
sleep 5
bash /workspace/ai-server/start.sh > /workspace/ai-server/logs/autostart.log 2>&1
sleep infinity
