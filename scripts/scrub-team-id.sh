#!/bin/bash
# Scrub DEVELOPMENT_TEAM values from project.pbxproj before committing.
# Run this from the repo root: ./scripts/scrub-team-id.sh

FILE="ABMate.xcodeproj/project.pbxproj"

if [ ! -f "$FILE" ]; then
    echo "Error: $FILE not found. Run this from the ABMate repo root."
    exit 1
fi

if grep -qE 'DEVELOPMENT_TEAM = "[A-Z0-9]{10}";' "$FILE"; then
    sed -i '' -E 's/DEVELOPMENT_TEAM = "[A-Z0-9]{10}";/DEVELOPMENT_TEAM = "";/' "$FILE"
    echo "Scrubbed DEVELOPMENT_TEAM from $FILE"
else
    echo "No team IDs found — already clean."
fi
