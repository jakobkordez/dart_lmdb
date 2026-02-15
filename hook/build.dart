import 'dart:io' show Platform;

import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final cbuilder = CBuilder.library(
      name: packageName,
      language: Language.c,
      assetName: 'src/generated_bindings.dart',
      sources: [
        'src/lmdb/libraries/liblmdb/mdb.c',
        'src/lmdb/libraries/liblmdb/midl.c',
      ],
      includes: ['src/lmdb/libraries/liblmdb/'],
      forcedIncludes: [if (Platform.isWindows) 'src/lmdb_exports.h'],
      libraries: [if (Platform.isWindows) 'advapi32'],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
