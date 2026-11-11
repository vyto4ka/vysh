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
    if (uri == null || uri.scheme != 'file' || uri.hasQuery || uri.hasFragment) {
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
