#!/bin/bash

# Capture full input
input="$*"

# 1. Check for empty input
if [[ -z "$input" ]]; then
    exit 0
fi

# 2. Try to execute as local command
if command -v "$1" &>/dev/null; then
    "$@" &
    exit 0
fi

# 3. Improved URL encoding (handles special characters)
if command -v python3 &>/dev/null; then
    encoded_query=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote_plus(sys.argv[1]))" "$input")
elif command -v perl &>/dev/null; then
    encoded_query=$(perl -MURI::Escape -e "print uri_escape(\"$input\");")
else
    encoded_query=$(echo "$input" | sed 's/ /+/g; s/[^a-zA-Z0-9_+~.-]/\\&/g')
fi

# 4. Fallback to browser search
SEARCH_URL="https://www.google.com/search?q=${encoded_query}"

# 5. Browser detection with fallbacks
if command -v xdg-open &>/dev/null; then
    xdg-open "$SEARCH_URL"
elif command -v sensible-browser &>/dev/null; then
    sensible-browser "$SEARCH_URL"
else
    firefox "$SEARCH_URL" || chromium "$SEARCH_URL" || \
    echo "ERROR: No browser found!" >&2
fi
