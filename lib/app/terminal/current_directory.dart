/// Validate shell reports as paths only. Never execute their contents or infer
/// a directory by parsing the user's commands (cd aliases/subshells can fail).
String? reportedDirectory(String value) {
  if (value.isEmpty ||
      value.length > 8192 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    return null;
  }
  var path = value;
  if (value.startsWith('file:')) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    try {
      path = uri.toFilePath(
        windows:
            RegExp(r'^/[A-Za-z]:/').hasMatch(uri.path) ||
            uri.host.isNotEmpty && uri.path.startsWith('//'),
      );
      // Remote OSC 7 commonly includes the remote hostname. It is not a UNC path.
    } catch (_) {
      try {
        path = Uri.decodeComponent(uri.path);
      } catch (_) {
        return null;
      }
    }
  }
  if (path.length >= 2 && path.startsWith('"') && path.endsWith('"')) {
    path = path.substring(1, path.length - 1);
  }
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) return null;
  return path.startsWith('/') ||
          path.startsWith(r'\\') ||
          RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)
      ? path
      : null;
}

/// One-session integration for interactive POSIX sh/bash/ash. Installed only by
/// an explicit UI action at a shell prompt, never injected automatically.
const posixDirectoryReporting =
    r'''PS1='$(printf "\033]1337;CurrentDir=%s\007" "$PWD")'"$PS1"''';

/// Out-of-band probe executed over a separate SSH exec channel when the remote
/// shell does not emit OSC 7 / OSC 9;9 / OSC 1337. Finds the sibling PTY shell
/// belonging to the same sshd session process (`$PPID`) and resolves the live
/// foreground process group's `cwd` (with fallback to the login shell's `cwd`).
const remoteShellDirectoryCommand = r'''sh -c '
if [ -d /proc ]; then
  find_pty_cwd() {
    d=$1
    [ -n "$d" ] && [ "$d" -gt 1 ] 2>/dev/null || return 1
    children=""
    if [ -r "/proc/$d/task/$d/children" ]; then
      read -r children < "/proc/$d/task/$d/children" || true
    fi
    if [ -z "$children" ]; then
      for s in /proc/[0-9]*/stat; do
        [ -r "$s" ] || continue
        read -r line < "$s" || continue
        rest=${line##*)}
        set -- $rest
        if [ "$2" = "$d" ]; then
          p=${s#/proc/}; p=${p%/stat}
          children="$children $p"
        fi
      done
    fi
    for c in $children; do
      [ "$c" = "$$" ] && continue
      [ "$c" = "$SELF_PARENT" ] && continue
      [ -r "/proc/$c/stat" ] || continue
      read -r line < "/proc/$c/stat" || continue
      rest=${line##*)}
      set -- $rest
      tty=$5
      tpgid=$6
      if [ -n "$tty" ] && [ "$tty" != "0" ]; then
        if [ -n "$tpgid" ] && [ "$tpgid" -gt 0 ] 2>/dev/null && cd -P "/proc/$tpgid/cwd" 2>/dev/null; then
          pwd -P
          return 0
        fi
        if cd -P "/proc/$c/cwd" 2>/dev/null; then
          pwd -P
          return 0
        fi
      fi
    done
    return 1
  }
  SELF_PARENT=$PPID
  find_pty_cwd "$PPID" && exit 0
  if [ -r "/proc/$PPID/stat" ]; then
    read -r pline < "/proc/$PPID/stat" || true
    prest=${pline##*)}
    set -- $prest
    find_pty_cwd "$2" && exit 0
  fi
elif [ -x /usr/sbin/lsof ]; then
  for c in $(ps -o pid=,ppid=,tty= -ax 2>/dev/null | awk -v p="$PPID" '\''$2==p && $3!="??" && $3!="?" {print $1}'\''); do
    out=$(/usr/sbin/lsof -a -p "$c" -d cwd -Fn 2>/dev/null | sed -n '\''s/^n//p'\'' | head -n 1)
    if [ -n "$out" ]; then
      printf "%s\n" "$out"
      exit 0
    fi
  done
fi
exit 1
' ''';
