#!/bin/bash
# POC: Teams network connection monitoring
TEAMS_PID=$(pgrep -x MSTeams)
if [ -z "$TEAMS_PID" ]; then
    echo "Teams not running"; exit 1
fi
echo "=== Teams PID: $TEAMS_PID ==="
echo "=== Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo ""
echo "--- UDP Connections ---"
lsof -i UDP -n -P -a -p "$TEAMS_PID" 2>/dev/null
echo ""
UDP_COUNT=$(lsof -i UDP -n -P -a -p "$TEAMS_PID" 2>/dev/null | grep -v "^COMMAND" | wc -l | tr -d ' ')
UDP_CONNECTED=$(lsof -i UDP -n -P -a -p "$TEAMS_PID" 2>/dev/null | grep -v "^COMMAND" | grep -v "\*:" | wc -l | tr -d ' ')
echo "Total UDP: $UDP_COUNT, Connected: $UDP_CONNECTED"
[ "$UDP_CONNECTED" -gt 0 ] && echo ">>> CALL LIKELY ACTIVE <<<" || echo ">>> NO CALL <<<"
