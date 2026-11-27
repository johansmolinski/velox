#!/bin/sh
# The reference renders for test/unit/svg.vt: rsvg-convert's, at the
# widths the test draws at (NAME.W.png; W 0: the image's own size)
cd "$(dirname "$0")/svg" || exit 1
grep '^decode' ../svg.vt | while read -r _ src out w; do
	name=$(basename "$out" .argb)
	if [ -z "$w" ]; then
		rsvg-convert "$(basename "$src")" -o "$name.png"
	else
		rsvg-convert -w "$w" "$(basename "$src")" -o "$name.png"
	fi
done
