#!/bin/sh
# Headless tests: run each test/unit/*.vt through build/vtest under vamos
# and compare with the matching .expected file.  vamos also reports
# memory that was not freed ("orphan"), which counts as a failure.
set -u
cd "$(dirname "$0")/.."
python3 test/unit/mkhttp.py build/http
rm -rf build/img
python3 test/unit/mkimages.py build/img
rm -rf build/svg && mkdir -p build/svg
fail=0
for t in test/unit/*.vt; do
	name=$(basename "$t" .vt)
	out=build/$name.out
	err=build/$name.err
	tools/venv/bin/vamos -C 68020 -m 8192 build/vtest "$t" >"$out" 2>"$err"
	rc=$?
	if [ $rc -ne 0 ]; then
		echo "FAIL $name: vamos exit code $rc"; cat "$err"; fail=1
	elif ! diff -u "test/unit/$name.expected" "$out"; then
		echo "FAIL $name"; fail=1
	elif grep -q orphan "$err"; then
		echo "FAIL $name: memory leak"; grep orphan "$err"; fail=1
	else
		echo "PASS $name"
	fi
done
# the pixels of the decoded images, against PIL
if python3 test/unit/cmpimages.py build/img >build/pixels.out; then
	echo "PASS pixels ($(grep -c PASS build/pixels.out) images)"
else
	grep -v '^PASS' build/pixels.out; echo "FAIL pixels"; fail=1
fi
# the SVG images drawn, against rsvg-convert
if python3 test/unit/cmpsvg.py build/svg >build/svgpixels.out; then
	echo "PASS svgpixels ($(grep -c PASS build/svgpixels.out) images)"
else
	grep -v '^PASS' build/svgpixels.out; echo "FAIL svgpixels"; fail=1
fi
exit $fail
