#!/bin/zsh
# Release build, install to ~/Applications, register the MCP server with Cursor, and (re)launch.
set -euo pipefail
cd "$(dirname "$0")/.."
export OUTPUT_DIR=${OUTPUT_DIR:-build}
scripts/bundle.sh release

DEST="$HOME/Applications/NativeGranola.app"
osascript -e 'tell application id "com.nativegranola.app" to quit' 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$OUTPUT_DIR/NativeGranola.app" "$DEST"

python3 - "$DEST/Contents/MacOS/NativeGranola" <<'EOF'
import json, os, sys
path = os.path.expanduser("~/.cursor/mcp.json")
config = json.load(open(path)) if os.path.exists(path) else {}
config.setdefault("mcpServers", {})["native-granola"] = {"command": sys.argv[1], "args": ["--mcp"]}
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(config, open(path, "w"), indent=2)
print(f"Registered native-granola MCP server in {path}")
EOF

open "$DEST"
echo "Installed $DEST"
