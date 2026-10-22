#!/bin/sh
# Type regression check (new solver). Every line marked `expect-error` must produce an error and
# no other line may. Usage: ROBLOX_DEFS=/path/to/globalTypes.d.luau tests/types/check.sh
set -eu
cd "$(dirname "$0")/../.."
: "${ROBLOX_DEFS:?set ROBLOX_DEFS to a luau-lsp Roblox definitions file}"
sourcemap=$(mktemp)
trap 'rm -f "$sourcemap"' EXIT
rojo sourcemap dev.project.json -o "$sourcemap" >/dev/null

status=0
for file in tests/types/*.types.luau src/*.luau; do
	actual=$(luau-lsp analyze --flag:LuauSolverV2=true --platform roblox --defs "@roblox=$ROBLOX_DEFS" \
		--sourcemap "$sourcemap" --base-luaurc .luaurc "$file" 2>&1 \
		| grep -F "$file" | grep -E "\(([0-9]+),[0-9]+\): TypeError" \
		| sed -E 's/.*\(([0-9]+),[0-9]+\): TypeError.*/\1/' | sort -un)
	expected=$(grep -n "expect-error" "$file" | grep -v "^[0-9]*:--" | cut -d: -f1 | sort -un)
	if [ "$actual" != "$expected" ]; then
		status=1
		echo "FAIL $file"
		echo "  expected error lines: $(echo $expected)"
		echo "  actual error lines:   $(echo $actual)"
	else
		echo "ok   $file"
	fi
done
exit $status
