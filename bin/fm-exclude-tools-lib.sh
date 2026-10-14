#!/usr/bin/env bash
# fm-exclude-tools-lib.sh - shared parsing and runtime-support checks for
# config/crew-exclude-tools and config/worker-mcp-deny, sourced by
# bin/fm-spawn.sh and bin/fm-control.sh.
#
# docs/configuration.md "Worker tool exclusions" and "Worker MCP server deny
# list" own the file formats and operator contracts; bin/fm-spawn.sh's header
# owns launch-flag mechanics.
# Name verification belongs inside the worker's loaded-tool registry, never
# in an out-of-band server connection from these launch-time checks.

# fm_exclude_tools_names <config-dir> [file-name]: print the comma-joined
# names in config/<file-name> (default crew-exclude-tools), empty when the file
# is absent or lists nothing. Non-zero with the reason on stderr when the file
# or an entry is invalid.
fm_exclude_tools_names() {
  local config=$1 base=${2:-crew-exclude-tools} file line names='' present
  file=$config/$base
  present=$(perl -MErrno=ENOENT -e '
    if (lstat $ARGV[0]) { print 1 }
    elsif ($! == ENOENT) { print 0 }
    else { die "error: cannot inspect config/$ARGV[1]: $!\n" }
  ' -- "$file" "$base") || return 1
  [ "$present" = 1 ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/$base must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
    '' | '#'*) continue ;;
    esac
    if [ -n "${line//[A-Za-z0-9_.-]/}" ]; then
      echo "error: config/$base has a malformed entry '$line'; expected one name per line using only letters, digits, _ . and - (blank lines and # comment lines are allowed)" >&2
      return 1
    fi
    names="${names:+$names,}$line"
  done <"$file" || {
    echo "error: cannot read config/$base" >&2
    return 1
  }
  printf '%s' "$names"
}

# fm_exclude_tools_check <harness> <raw-launch 0|1> <config-dir>: succeed when
# this launch can honor the home's list (empty list, or a runtime that hides
# tools); otherwise refuse naming the file. Prints the names on stdout.
fm_exclude_tools_check() {
  local harness=$1 raw=$2 config=$3 names
  names=$(fm_exclude_tools_names "$config") || return 1
  if [ -n "$names" ]; then
    if [ "$raw" = 1 ]; then
      echo "error: config/crew-exclude-tools lists tools to hide, but a raw launch command cannot hide tools; remove the entries or launch a runtime that supports them (pi, pi-signed)" >&2
      return 1
    fi
    case "$harness" in
    pi | pi-signed) ;;
    *)
      echo "error: config/crew-exclude-tools lists tools to hide, but the $harness runtime cannot hide tools, so this launch is refused rather than running with them available; empty the file or launch a runtime that supports exclusion (pi, pi-signed)" >&2
      return 1
      ;;
    esac
  fi
  printf '%s' "$names"
}

# fm_worker_mcp_deny_json <config-dir>: print config/worker-mcp-deny as Claude
# Code's deniedMcpServers array, empty when nothing is listed. Non-zero with
# the reason on stderr when the file or an entry is invalid. The entry charset
# needs no JSON escaping.
fm_worker_mcp_deny_json() {
  local names name json=''
  names=$(fm_exclude_tools_names "$1" worker-mcp-deny) || return 1
  [ -n "$names" ] || return 0
  for name in ${names//,/ }; do
    json="${json:+$json,}{\"serverName\":\"$name\"}"
  done
  printf '[%s]' "$json"
}
