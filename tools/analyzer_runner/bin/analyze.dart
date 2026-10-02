// 独立跑 Dart 静态分析，绕开 `dart analyze` 需要命名管道的限制
// （本项目环境里会报 CreateFile failed 231）。
//
// 用法：
//   cd tools/analyzer_runner
//   dart pub get
//   dart run bin/analyze.dart ../..        # 参数是项目根目录
//
// 它会读取项目自己的 analysis_options.yaml，因此 lint 规则与
// `flutter analyze` 一致（analyzer 版本也刻意对齐）。
//
// 退出码：有问题为 1，干净为 0 —— 可以直接串进批处理判断。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('用法: dart run bin/analyze.dart <项目根目录>');
    exit(2);
  }

  // analyzer 只接受「绝对的、已规范化的」路径；Windows 下必须是全反斜杠形式，
  // 传 D:/xxx、混用斜杠、或带 `..` 未展开，都会抛
  // Only absolute normalized paths are supported。
  // 而 Git Bash 还会把参数里的 \ 弄成混合形式，所以这里统一处理两件事：
  // ① 交给 resolveSymbolicLinksSync 展开 `..` 并归一化；② 全转成反斜杠。
  String root;
  try {
    root = Directory(args[0]).resolveSymbolicLinksSync();
  } catch (_) {
    root = Directory(args[0]).absolute.path;
  }
  root = root.replaceAll('/', r'\');
  while (root.contains(r'\\')) {
    root = root.replaceAll(r'\\', r'\');
  }
  if (!Directory(root).existsSync()) {
    print('目录不存在：$root');
    exit(2);
  }

  final Stopwatch sw = Stopwatch()..start();

  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: <String>[root],
    excludedPaths: <String>[
      '$root\\build',
      '$root\\.dart_tool',
      // 本 runner 自己所在的小包不参与主项目的分析
      '$root\\tools\\analyzer_runner',
    ],
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );

  int errors = 0;
  int warnings = 0;
  int infos = 0;
  int scanned = 0;
  final List<String> lines = <String>[];

  for (final ctx in collection.contexts) {
    final List<String> files = ctx.contextRoot
        .analyzedFiles()
        .where((String p) => p.endsWith('.dart'))
        .toList()
      ..sort();

    for (final String path in files) {
      final SomeErrorsResult result = await ctx.currentSession.getErrors(path);
      if (result is! ErrorsResult) continue;
      scanned++;

      final String rel = path
          .replaceFirst(root, '')
          .replaceAll(r'\', '/')
          .replaceFirst('/', '');

      for (final AnalysisError e in result.errors) {
        final location = result.lineInfo.getLocation(e.offset);
        switch (e.severity) {
          case Severity.error:
            errors++;
          case Severity.warning:
            warnings++;
          case Severity.info:
            infos++;
        }
        lines.add('  ${e.severity.name.padRight(7)} '
            '$rel:${location.lineNumber}:${location.columnNumber}'
            ' - ${e.message} - ${e.errorCode.name}');
      }
    }
  }

  lines.sort();
  for (final String line in lines) {
    print(line);
  }

  final int total = errors + warnings + infos;
  print('');
  print('已分析 $scanned 个文件，用时 ${sw.elapsedMilliseconds} ms');
  print('error $errors  warning $warnings  info $infos  →  合计 $total');
  exit(total > 0 ? 1 : 0);
}
