#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# notes-append.sh - append ONE progress-note line to the autonomy loop's notes file under its lock (in supervisor mode
# several workers end at about the same time, so the notes file is written only through this script).
#
# Usage: /agent/notes-append.sh "<one line>"
#    or: /agent/notes-append.sh -f FILE        (the line is the file's content - for a long note written with a tool)
#
# The notes file is ${AUTONOMY_LOOP_DIR}/notes.md (default /wd/loop/notes.md; AUTONOMY_LOOP_NOTES overrides the path),
# the lock ${AUTONOMY_LOOP_DIR}/notes.lock, held only around the append (flock, up to NOTES_LOCK_WAIT s, default 60).
# Newlines, carriage returns and tabs in the text become spaces (one line per fire, as today), a missing leading "- "
# is added, the file gets its trailing newline first when it lacks one, and the new last line is read back before the
# script reports success.
#
# Exit codes: 0 appended (prints the line number and the line); 2 usage or an empty note; 5 the lock was not free
# within the wait; 6 the line did not read back as the last line. Nothing else is written - never the goals file, never
# the stop flag.

AUTONOMY_LOOP_DIR=${AUTONOMY_LOOP_DIR:-/wd/loop}
NOTES=${AUTONOMY_LOOP_NOTES:-${AUTONOMY_LOOP_DIR}/notes.md}
LOCK=${AUTONOMY_LOOP_DIR}/notes.lock
WAIT=${NOTES_LOCK_WAIT:-60}

err()
{
	echo "ERROR: $*" >&2
}

usage()
{
	cat << EOT
usage: $0 "<one line>"
   or: $0 -f FILE
Appends the line (newlines and tabs become spaces; "- " is added when missing) to ${NOTES} under ${LOCK}.
Exit: 0 appended, 2 usage/empty, 5 lock not free within ${WAIT} s, 6 the line did not read back.
EOT
}

case "$1" in
	-h|--help) usage; exit 0 ;;
	-f)
		[ -n "$2" ] && [ -r "$2" ] || { err "-f needs a readable file"; usage >&2; exit 2; }
		TEXT=$(cat -- "$2") ;;
	"") err "the note is empty"; usage >&2; exit 2 ;;
	*) TEXT=$1 ;;
esac

LINE=$(printf '%s' "${TEXT}" | tr '\n\r\t' '   ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[ -n "${LINE}" ] || { err "the note is empty"; exit 2; }
case "${LINE}" in
	"- "*) ;;
	*) LINE="- ${LINE}" ;;
esac

mkdir -p "${AUTONOMY_LOOP_DIR}" "$(dirname "${NOTES}")" || { err "cannot create ${AUTONOMY_LOOP_DIR}"; exit 2; }

exec 9>> "${LOCK}" || { err "cannot open the lock ${LOCK}"; exit 5; }
if ! flock -w "${WAIT}" 9; then
	err "the notes lock ${LOCK} was not free within ${WAIT} s; nothing written"
	exit 5
fi
touch "${NOTES}" || { err "cannot write ${NOTES}"; exit 6; }
# the file ends without a newline (a killed writer): complete it first, so the note never joins the previous line
if [ -s "${NOTES}" ] && [ -n "$(tail -c1 "${NOTES}")" ]; then
	echo >> "${NOTES}"
fi
printf '%s\n' "${LINE}" >> "${NOTES}"
LAST=$(tail -n 1 "${NOTES}")
COUNT=$(wc -l < "${NOTES}")
flock -u 9

if [ "${LAST}" != "${LINE}" ]; then
	err "the line did not read back as the last line of ${NOTES}"
	exit 6
fi
echo "appended line ${COUNT} of ${NOTES} (${#LINE} chars): ${LINE:0:160}"
