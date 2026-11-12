import '../../domain/models/host.dart';
import '../../domain/models/session_tab.dart';
import '../../domain/ports/sftp.dart';

typedef WindowRpc =
    Future<dynamic> Function(String method, Map<String, Object?> data);

Map<String, Object?> encodeTab(SessionTab tab) => {
  'id': tab.id,
  'host': tab.host.toJson(),
  'title': tab.title,
  'status': tab.status.name,
  'local': tab.isLocal,
};

SessionTab decodeTab(Map data) => SessionTab(
  id: data['id'],
  host: Host.fromJson(Map<String, Object?>.from(data['host'])),
  title: data['title'],
  status: SessionStatus.values.byName(data['status']),
  isLocal: data['local'] == true,
);

Map<String, Object?> encodeEntry(RemoteEntry entry) => {
  'name': entry.name,
  'path': entry.path,
  'directory': entry.isDir,
  'link': entry.isLink,
  'size': entry.size,
  'modified': entry.modified?.millisecondsSinceEpoch,
  'mode': entry.mode,
};

RemoteEntry decodeEntry(Map data) => RemoteEntry(
  name: data['name'],
  path: data['path'],
  isDir: data['directory'],
  isLink: data['link'],
  size: data['size'],
  mode: data['mode'],
  modified: data['modified'] == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(data['modified']),
);
