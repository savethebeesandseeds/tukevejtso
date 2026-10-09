#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${TUKEVEJTSO_ALARM_BUILD_DIR:-/opt/tukevejtso-alarm-build}"
if ! command -v mcs >/dev/null || ! command -v mono >/dev/null; then
  echo "Run setup-computer-alarm.sh inside the existing managed Debian container first." >&2
  exit 1
fi
mkdir -p -- "$build_dir"
mcs -warnaserror+ -target:library -r:System.Windows.Forms -r:System.Drawing \
  -out:"$build_dir/ComputerAlarm.dll" \
  "$source_dir/computer-alarm-native.cs" "$source_dir/computer-alarm-logic.cs" \
  "$source_dir/computer-alarm-speech.cs" "$source_dir/computer-alarm-audio-sequence.cs"
mcs -warnaserror+ -out:"$build_dir/AlarmLogicTests.exe" \
  "$source_dir/computer-alarm-logic.cs" "$source_dir/tests/test_computer_alarm.cs"
mono "$build_dir/AlarmLogicTests.exe"
mcs -warnaserror+ -out:"$build_dir/AlarmAudioSequenceTests.exe" \
  "$source_dir/computer-alarm-audio-sequence.cs" "$source_dir/tests/test_computer_alarm_audio_sequence.cs"
mono "$build_dir/AlarmAudioSequenceTests.exe"
echo "Compiled Windows helper and completed silent decision/sample-data tests in Debian. No SAPI, native Windows monitoring, or audio playback code was executed."
