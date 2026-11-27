import 'dart:io';

import 'package:flutter/services.dart';

enum DownloadStorageProblem { permission, unavailable, noSpace, busy, name, io }

/// Safe destination-only errors. A script/network error must never be
/// classified as a directory permission problem simply because it is I/O.
final class DownloadStorageException implements Exception {
  const DownloadStorageException(this.problem, [this.osCode]);
  final DownloadStorageProblem problem;
  final int? osCode;

  factory DownloadStorageException.from(Object error) {
    if (error is DownloadStorageException) return error;
    if (error is PlatformException) {
      return DownloadStorageException(switch (error.code) {
        'download_permission' => DownloadStorageProblem.permission,
        'download_unavailable' => DownloadStorageProblem.unavailable,
        'download_space' => DownloadStorageProblem.noSpace,
        _ => DownloadStorageProblem.io,
      });
    }
    final code = error is FileSystemException ? error.osError?.errorCode : null;
    return DownloadStorageException(
      Platform.isWindows
          ? switch (code) {
              5 || 19 || 65 => DownloadStorageProblem.permission,
              2 ||
              3 ||
              15 ||
              21 ||
              53 ||
              67 => DownloadStorageProblem.unavailable,
              39 || 112 => DownloadStorageProblem.noSpace,
              32 || 33 => DownloadStorageProblem.busy,
              123 || 206 => DownloadStorageProblem.name,
              _ => DownloadStorageProblem.io,
            }
          : DownloadStorageProblem.io,
      code,
    );
  }

  String message(String action) => switch (problem) {
    DownloadStorageProblem.permission => '$action失败：没有所需的目录权限，请重新选择可写的保存目录。',
    DownloadStorageProblem.unavailable =>
      '$action失败：目录已不存在或暂不可用，请连接存储设备或重新选择目录。',
    DownloadStorageProblem.noSpace => '$action失败：存储空间不足，请释放空间后重试。',
    DownloadStorageProblem.busy => '$action失败：文件正被占用，请关闭占用它的程序后重试。',
    DownloadStorageProblem.name => '$action失败：文件名或路径不可用，请选择较短的目录或检查同名文件。',
    DownloadStorageProblem.io => '$action失败。请确认保存目录可用，或换一个目录重试。',
  };
}
