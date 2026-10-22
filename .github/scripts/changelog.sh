#!/usr/bin/env bash
# Maintains CHANGELOG.md for releases.
#   changelog.sh has-section VERSION   exit 0 if CHANGELOG.md already has a "## VERSION" section
#   changelog.sh notes VERSION         print that section (release notes)
#   changelog.sh draft VERSION         print a draft section from commits since the last v* tag
#   changelog.sh insert VERSION        add the draft above the existing entries
set -euo pipefail

file=CHANGELOG.md
command=${1:?usage: changelog.sh <has-section|notes|draft|insert> VERSION}
version=${2:?usage: changelog.sh <has-section|notes|draft|insert> VERSION}

section() {
	[ -f "$file" ] || return 0
	awk -v v="$version" '/^## /{ if (found) exit; if ($2 == v) found = 1 } found' "$file"
}

draft() {
	local previous range
	previous=$(git tag -l 'v*' --sort=-v:refname | head -n 1)
	range=HEAD
	if [ -n "$previous" ]; then
		range="$previous..HEAD"
	fi

	echo "## $version — $(date -u +%F)"
	echo
	git log --no-merges --format='- %s' "$range" -- . ':(exclude)CHANGELOG.md'
}

insert() {
	local body=""
	if [ -f "$file" ]; then
		body=$(tail -n +3 "$file")
	fi
	{
		echo "# Changelog"
		echo
		draft
		echo
		printf '%s\n' "$body"
	} > "$file.tmp"
	mv "$file.tmp" "$file"
}

case "$command" in
	has-section)
		section | grep -q .
		;;
	notes)
		section
		;;
	draft)
		draft
		;;
	insert)
		insert
		;;
	*)
		echo "unknown command: $command" >&2
		exit 2
		;;
esac
