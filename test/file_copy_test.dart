import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/sftp/file_copy.dart';
import 'package:vysh/domain/ports/sftp.dart';
import 'package:vysh/infra/platform/local_file_session.dart';

void main() {
  late Directory temp;
  const fs = LocalFileSession();
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('vysh-copy-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<FileCopy> copier(
    ResolveCopyConflict resolve, {
    CancelToken? cancel,
  }) async => FileCopy(
    source: fs,
    target: fs,
    resolve: resolve,
    cancel: cancel ?? CancelToken(),
    progress: (_) {},
  );
  Future<void> write(String path, String content) async {
    await File('${temp.path}/$path').parent.create(recursive: true);
    await File('${temp.path}/$path').writeAsString(content);
  }

  test('identical contents are skipped even with different dates', () async {
    await write('source', 'same');
    await write('target', 'same');
    await File('${temp.path}/target').setLastModified(DateTime(2001));
    final c = await copier((_) async => throw StateError('must not prompt'));
    await c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target');
    expect(c.skipped, 1);
    expect(c.copied, 0);
  });
  test(
    'same size with different contents prompts and skip preserves destination',
    () async {
      await write('source', 'aaaa');
      await write('target', 'bbbb');
      var prompts = 0;
      final c = await copier((_) async {
        prompts++;
        return const CopyDecision(CopyChoice.skip);
      });
      await c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target');
      expect(prompts, 1);
      expect(await File('${temp.path}/target').readAsString(), 'bbbb');
    },
  );
  test('recursive conflicts honor apply to all', () async {
    await write('source/a', 'new-a');
    await write('source/b', 'new-b');
    await write('target/a', 'old-a');
    await write('target/b', 'old-b');
    var prompts = 0;
    final c = await copier((_) async {
      prompts++;
      return const CopyDecision(CopyChoice.replace, applyToAll: true);
    });
    await c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target');
    expect(prompts, 1);
    expect(c.copied, 2);
    expect(await File('${temp.path}/target/a').readAsString(), 'new-a');
    expect(await File('${temp.path}/target/b').readAsString(), 'new-b');
  });
  test('keep both allocates an unused destination', () async {
    await write('source', 'new');
    await write('target', 'old');
    await write('target (1)', 'older');
    final c = await copier(
      (_) async => const CopyDecision(CopyChoice.keepBoth),
    );
    await c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target');
    expect(await File('${temp.path}/target').readAsString(), 'old');
    expect(await File('${temp.path}/target (2)').readAsString(), 'new');
  });
  test('cancellation while resolving does not overwrite', () async {
    await write('source', 'new');
    await write('target', 'old');
    final token = CancelToken();
    final c = await copier((_) async {
      token.cancel();
      return const CopyDecision(CopyChoice.replace);
    }, cancel: token);
    await expectLater(
      c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target'),
      throwsA(isA<TransferCancelled>()),
    );
    expect(await File('${temp.path}/target').readAsString(), 'old');
  });
  test('folder cannot be copied into its descendant', () async {
    await write('source/a', 'data');
    final c = await copier((_) async => const CopyDecision(CopyChoice.replace));
    await expectLater(
      c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/source/child'),
      throwsA(isA<SftpFailure>()),
    );
  });
  test('file/folder replacement preserves the folder', () async {
    await write('source', 'new');
    await write('target/keep', 'old');
    final c = await copier((_) async => const CopyDecision(CopyChoice.replace));
    await expectLater(
      c.copy(await fs.stat('${temp.path}/source'), '${temp.path}/target'),
      throwsA(isA<SftpFailure>()),
    );
    expect(await File('${temp.path}/target/keep').readAsString(), 'old');
  });
}
