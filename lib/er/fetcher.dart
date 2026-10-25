/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful, but WITHOUT ANY
 *  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 *  FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with
 *  this program. If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:io';

import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio_compatibility_layer/dio_compatibility_layer.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_cache_manager_dio/flutter_cache_manager_dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/er/pixiv_image_source.dart';
import 'package:pixez/er/toaster.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/illust.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/network/network_mode.dart';
import 'package:pixez/network/pixez_network_settings.dart';
import 'package:pixez/store/save_store.dart';
import 'package:pixez/utils/haptic_util.dart';
import 'package:quiver/collection.dart';
import 'package:rhttp/rhttp.dart' as r;

enum IsoTaskState { INIT, APPEND, PROGRESS, ERROR, COMPLETE, RELOAD, CANCEL_ALL }

class IsoContactBean {
  final IsoTaskState state;
  final dynamic data;

  IsoContactBean({required this.state, required this.data});
}

class IsoProgressBean {
  final int min, total;
  final String url;

  IsoProgressBean({required this.min, required this.total, required this.url});
}

class TaskBean {
  String? url;
  Illusts? illusts;
  String? fileName;
  String? savePath;
  String? source;
  String? host;
  NetworkMode? networkMode;

  TaskBean({
    required this.url,
    required this.illusts,
    required this.fileName,
    required this.savePath,
    this.networkMode,
    this.host,
    this.source,
  });
}

class NetworkReloadMessage {
  final NetworkMode networkMode;
  final String? source;

  NetworkReloadMessage({required this.networkMode, required this.source});
}

class Fetcher {
  BuildContext? context;
  List<TaskBean> queue = [];
  ReceivePort receivePort = ReceivePort();
  SendPort? sendPortToChild;
  Isolate? isolate;
  TaskPersistProvider taskPersistProvider = TaskPersistProvider();
  LruMap<String, JobEntity> jobMaps = LruMap();

  /// 相册保存串行执行：一次只把一张图交给 PhotoKit，确认它真的写进相册后
  /// 再处理下一张。这样不会一次灌入上千个导入请求，也能拿到真实的成功/失败。
  Future<void> _saveChain = Future.value();

  /// 「清空所有任务」时自增，用来丢弃已经排队但还没保存的任务。
  int _saveGeneration = 0;

  Fetcher() {}

  start(String pictureSource) async {
    if (receivePort.isBroadcast) return;
    await taskPersistProvider.open();
    await taskPersistProvider.getAllAccount();
    // 上次进程被杀时留在"保存中"的任务退回 seed，否则它们再也不会被重试。
    await taskPersistProvider.resetRunning();
    LPrinter.d("Fetcher start");
    receivePort.listen((message) {
      try {
        IsoContactBean isoContactBean = message;
        switch (isoContactBean.state) {
          case IsoTaskState.INIT:
            sendPortToChild = isoContactBean.data;
            // 等 isolate 就绪后再派发一次，避免启动瞬间 save()/重试把任务卡在队列里。
            nextJob();
            break;
          case IsoTaskState.PROGRESS:
            IsoProgressBean isoProgressBean = isoContactBean.data;
            var job = fetcher.jobMaps[isoProgressBean.url];
            if (job != null) {
              job
                ..min = isoProgressBean.min
                ..status = 1
                ..max = isoProgressBean.total;
            } else {
              fetcher.jobMaps[isoProgressBean.url] = JobEntity()
                ..status = 1
                ..min = isoProgressBean.min
                ..max = isoProgressBean.total;
            }
            break;
          case IsoTaskState.COMPLETE:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            // 同一个下载重复上报（例如缓存过期时先给旧文件再给新文件），忽略后面的。
            if (_savingUrls.contains(taskBean.url!)) break;
            // 这个 URL 从现在起归"保存"管：在导入结束前不允许再被重排/重新保存，
            // 否则旧保存会把同一张图再导一次。
            _savingUrls.add(taskBean.url!);
            // 先把它排进保存队列（会占掉一个 pending 额度）再放行下一个下载，
            // 否则下一张会在计数更新前被派发，实际同时在途的临时文件会超过上限。
            _complete(
              taskBean.url!,
              taskBean.savePath!,
              taskBean.fileName!,
              taskBean.illusts!,
            ).catchError((e) {
              _savingUrls.remove(taskBean.url!);
              LPrinter.d(e);
            }).whenComplete(nextJob);
            break;
          case IsoTaskState.ERROR:
            TaskBean taskBean = isoContactBean.data;
            urlPool.remove(taskBean.url);
            if (queue.isNotEmpty) {
              queue.removeWhere((element) => element.url == taskBean.url);
              LPrinter.d("c ${queue.length}");
            }
            fetcher.jobMaps.removeWhere((key, value) => key == taskBean.url);
            nextJob();
            _handleDownloadError(taskBean).catchError((e) {
              LPrinter.d(e);
            });
            break;
          default:
            break;
        }
      } catch (e) {}
    });
    isolate = await Isolate.spawn(
      entryPoint,
      SendMessage(
        receivePort.sendPort,
        pictureSource,
        userSetting.networkMode,
        RootIsolateToken.instance!,
      ),
      debugName: 'childIsolate',
    );
  }

  /// 把任务加进下载队列。
  ///
  /// [front] 为 true 时插到队首：失败重试和用户手动重试应该尽快重新开始，
  /// 而不是排到一千个任务后面去。批量重排（重试所有 seed）仍用队尾，保证顺序。
  save(String url, Illusts illusts, String fileName, {bool front = false}) async {
    LPrinter.d(sendPortToChild.toString() + url);
    var taskBean = TaskBean(
      url: url,
      illusts: illusts,
      fileName: fileName,
      networkMode: userSetting.networkMode,
      source: userSetting.pictureSource,
      host: splashStore.host,
      savePath: (await getTemporaryDirectory()).path,
    );
    if (front) {
      // 同一个 URL 只留一条：连点重试时不要把同一个任务插两次。
      queue.removeWhere((e) => e.url == url);
      queue.insert(0, taskBean);
    } else {
      queue.add(taskBean);
    }
    nextJob();
  }

  List<String> urlPool = [];

  /// 已下载完但还没确认写进相册的任务数。
  /// 限制它可以让下载不要跑得太超前，避免临时目录里堆几十 G 的图。
  int _pendingSaves = 0;
  static const int _maxPendingSaves = 3;

  /// 下载失败后的自动重试：同一张图最多再试 3 次，间隔 2s / 6s / 15s。
  static const List<int> _retryDelays = [2, 6, 15];
  final Map<String, int> _retryAttempts = {};

  /// 已下载完、正在排队或执行写入相册的 URL。
  final Set<String> _savingUrls = {};

  /// 每个 URL 的重试代次，用来作废还在倒计时里的重试
  /// （手动重试 / 清空任务 / 重新保存都会让它失效）。
  final Map<String, int> _retryEpoch = {};
  int _retryEpochSeq = 0;

  /// 这张图是否已经在队列里、正在下载，或正在写相册。
  bool isActive(String url) =>
      urlPool.contains(url) ||
      _savingUrls.contains(url) ||
      queue.any((e) => e.url == url);

  /// 已经下载完、正在排队/执行写入相册的 URL。
  bool isSaving(String url) => _savingUrls.contains(url);

  nextJob() {
    if (_pendingSaves >= _maxPendingSaves) return;
    if (queue.isNotEmpty && urlPool.length < userSetting.maxRunningTask) {
      // isolate 还没就绪时不要占用 urlPool/改状态，等 INIT 再派发。
      final sendPort = sendPortToChild;
      if (sendPort == null) return;
      TaskBean? first = null;
      for (var i in queue) {
        // 同一个 URL 还在写相册时先别重新下载：两次尝试会抢同一个临时文件。
        if (!urlPool.contains(i.url) && !_savingUrls.contains(i.url)) {
          first = i;
          break;
        }
      }
      if (first == null) return;
      first.networkMode = userSetting.networkMode;
      first.source = userSetting.pictureSource;
      first.host = splashStore.host;
      IsoContactBean isoContactBean = IsoContactBean(
        state: IsoTaskState.APPEND,
        data: first,
      );
      sendPort.send(isoContactBean);
      if (first.url != null) {
        urlPool.add(first.url!);
        // 派发时就标成"进行中"：统计里能看到它在下载，
        // 重试入口也不会在这段时间把它当成 seed 再排一遍。
        taskPersistProvider.markRunning(first.url!).then((_) {}, onError: (e) {
          LPrinter.d(e);
        });
      }
    }
  }

  void stop() {
    isolate?.kill(priority: Isolate.immediate);
  }

  /// 清空所有任务：丢掉内存里排队/正在下载的任务，并通知下载 isolate
  /// 放弃当前正在传输的文件。数据库里的任务记录由调用方负责删除。
  void clearAll() {
    _saveGeneration++;
    _retryAttempts.clear();
    _retryEpoch.clear();
    _savingUrls.clear();
    // 旧的一批保存会让 _pendingSaves 慢慢回落，这里直接归零，
    // 免得清空后新一批被上一批的保存额度卡住。
    _pendingSaves = 0;
    queue.clear();
    urlPool.clear();
    jobMaps.clear();
    sendPortToChild?.send(
      IsoContactBean(state: IsoTaskState.CANCEL_ALL, data: null),
    );
  }

  void reloadNetwork() {
    sendPortToChild?.send(
      IsoContactBean(
        state: IsoTaskState.RELOAD,
        data: NetworkReloadMessage(
          networkMode: userSetting.networkMode,
          source: userSetting.pictureSource,
        ),
      ),
    );
  }

  void _deleteTempFile(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (e) {
      LPrinter.d(e);
    }
  }

  Future<void> _complete(
    String url,
    String savePath,
    String fileName,
    Illusts illusts,
  ) async {
    // 先占额度再 await：clearAll 会把 _pendingSaves 一起归零，
    // 这样不会出现"计数加在归零之后、减的时候又因代次不同被跳过"的泄漏。
    final generation = _saveGeneration;
    _pendingSaves++;
    final file = File(savePath + Platform.pathSeparator + fileName);
    var taskPersist = await taskPersistProvider.getAccount(url);
    if (taskPersist == null) {
      // 任务已被删除（清空所有任务）：把下载好的临时文件一并清掉。
      _savingUrls.remove(url);
      _deleteTempFile(file);
      if (generation == _saveGeneration && _pendingSaves > 0) _pendingSaves--;
      return;
    }
    _retryAttempts.remove(url);
    _retryEpoch.remove(url);
    // 先标成"保存中"，这样在相册真正写进去之前不会被当成 seed 再重试一遍。
    try {
      await taskPersistProvider.update(taskPersist..status = 1);
    } catch (e) {
      _savingUrls.remove(url);
      if (generation == _saveGeneration && _pendingSaves > 0) _pendingSaves--;
      rethrow;
    }
    _saveChain = _saveChain
        .then((_) async {
          try {
            if (generation != _saveGeneration) {
              // 任务已被「清空所有任务」丢弃，删掉临时文件直接跳过。
              _deleteTempFile(file);
              return;
            }
            final current = await taskPersistProvider.getAccount(url);
            if (current == null || current.id != taskPersist.id) {
              // 排队等保存期间任务被删除，或者被重新保存成了新的一行：
              // 这张旧文件不能再导进去，否则会和新的那次保存重复。
              _deleteTempFile(file);
              return;
            }
            var saved = false;
            try {
              // 直接把临时文件路径交给原生层，避免把整张图读进内存再过一遍平台通道。
              // 兜底超时：正常单张导入远快于 1 分钟，只有回调彻底丢了才会触发。
              saved = await saveStore
                  .saveFileToGallery(file.path, illusts, fileName, sourceUrl: url)
                  .timeout(const Duration(minutes: 1));
            } catch (e) {
              LPrinter.d(e);
            }
            if (generation != _saveGeneration) {
              // 保存期间任务被清空了：不写状态、不弹提示。
              _deleteTempFile(file);
              return;
            }
            final after = await taskPersistProvider.getAccount(url);
            if (after == null || after.id != taskPersist.id) {
              // 导入期间这一行被删掉/换新了，不要覆盖新记录、也不要弹提示。
              return;
            }
            if (!saved) _deleteTempFile(file);
            await taskPersistProvider.update(taskPersist..status = saved ? 2 : 3);
            final job = jobMaps[url];
            if (job != null) {
              job.status = saved ? 2 : 3;
            } else {
              jobMaps[url] = JobEntity()
                ..status = saved ? 2 : 3
                ..min = 1
                ..max = 1;
            }
            if (saved) {
              Toaster.downloadOk("${illusts.title} ${I18n.of(context!).saved}");
            } else {
              HapticUtil.error();
            }
          } finally {
            _savingUrls.remove(url);
            // 只减自己这一代的数量，避免清空任务后旧链条把新一批的额度一起减掉。
            if (generation == _saveGeneration && _pendingSaves > 0) {
              _pendingSaves--;
            }
            nextJob();
          }
        })
        .catchError((e) {
          LPrinter.d(e);
        });
  }

  /// 下载失败时先按退避自动重试几次，次数用尽才标记失败。
  ///
  /// 之前失败一次就直接 status 3，只能手动点「重试失败任务」；网络抖动、
  /// 429 限流这种情况重试基本都能过。
  Future<void> _handleDownloadError(TaskBean taskBean) async {
    final url = taskBean.url!;
    try {
      final attempt = _retryAttempts[url] ?? 0;
      if (attempt >= _retryDelays.length) {
        _retryAttempts.remove(url);
        _retryEpoch.remove(url);
        await _errorD(url);
        return;
      }
      _retryAttempts[url] = attempt + 1;
      final seconds = _retryDelays[attempt];
      LPrinter.d(
          "retry $url in ${seconds}s (${attempt + 1}/${_retryDelays.length})");
      final persist = await taskPersistProvider.getAccount(url);
      if (persist == null || persist.status == 2) {
        _retryAttempts.remove(url);
        return;
      }
      // 先标成"进行中"，免得被「重试所有 seed 任务」再排一遍。
      await taskPersistProvider.update(persist..status = 1);
      // 记住这次重试的代次：倒计时期间如果用户手动重试、重新保存或清空任务，
      // 代次会变，这次重试就直接作废，避免重复入队。
      final epoch = ++_retryEpochSeq;
      _retryEpoch[url] = epoch;
      await Future.delayed(Duration(seconds: seconds));
      if (_retryEpoch[url] != epoch) {
        _retryAttempts.remove(url);
        return;
      }
      final again = await taskPersistProvider.getAccount(url);
      if (again == null || again.status == 2 || isActive(url)) {
        _retryAttempts.remove(url);
        _retryEpoch.remove(url);
        return;
      }
      // 倒计时结束后再确认一次：期间如果被「清空所有任务」或手动重试过，就放弃这次重排。
      if (_retryEpoch[url] != epoch) {
        _retryAttempts.remove(url);
        return;
      }
      await taskPersistProvider.update(again..status = 0);
      if (_retryEpoch[url] != epoch) {
        _retryAttempts.remove(url);
        return;
      }
      await save(url, again.toIllusts(), again.fileName, front: true);
      _retryEpoch.remove(url);
    } catch (e) {
      LPrinter.d(e);
      _retryAttempts.remove(url);
      _retryEpoch.remove(url);
      try {
        await _errorD(url);
      } catch (e) {
        LPrinter.d(e);
      }
    }
  }

  /// 用户手动重试 / 重新保存时清掉自动重试计数，并作废还在倒计时的重试。
  void resetRetry(String url) {
    _retryAttempts.remove(url);
    _retryEpoch.remove(url);
  }

  Future<void> _errorD(String url) async {
    var taskPersist = await taskPersistProvider.getAccount(url);
    if (taskPersist == null) return;
    await taskPersistProvider.update(taskPersist..status = 3);
    HapticUtil.error();
    var job = jobMaps[url];
    if (job != null) {
      job.status = 3;
    } else {
      jobMaps[url] = JobEntity()
        ..status = 3
        ..min = 1
        ..max = 1;
    }
  }
}

class SendMessage {
  final SendPort sendPort;
  final String pictureSource;
  final NetworkMode networkMode;
  final RootIsolateToken rootIsolateToken;

  SendMessage(
    this.sendPort,
    this.pictureSource,
    this.networkMode,
    this.rootIsolateToken,
  );
}

entryPoint(SendMessage message) async {
  String pictureSource = message.pictureSource;
  var currentPictureSource = pictureSource;
  var currentNetworkMode = message.networkMode;
  RootIsolateToken rootIsolateToken = message.rootIsolateToken;
  SendPort sendPort = message.sendPort;
  // 由主 isolate 的「清空所有任务」置位，正在下载的循环看到后立刻放弃。
  var cancelCurrent = false;
  LPrinter.d("entryPoint ====== $pictureSource");
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  await r.Rhttp.init();
  await Hoster.initMap();
  Hoster.dnsQueryFetcher();
  final dio = Dio();
  final client = await r.RhttpCompatibleClient.createSync(
    settings: PixezNetworkSettings.forImages(
      currentPictureSource,
      currentNetworkMode,
    ),
  );
  dio.interceptors.add(
    PixivImageSourceInterceptor(
      networkMode: () => currentNetworkMode,
      pictureSource: () => currentPictureSource,
    ),
  );
  dio.httpClientAdapter = ConversionLayerAdapter(client);
  DioCacheManager.initialize(dio);
  ReceivePort receivePort = ReceivePort();
  sendPort.send(
    IsoContactBean(state: IsoTaskState.INIT, data: receivePort.sendPort),
  );

  receivePort.listen((message) async {
    try {
      IsoContactBean isoContactBean = message;
      if (isoContactBean.state == IsoTaskState.RELOAD) {
        final reload = isoContactBean.data as NetworkReloadMessage;
        currentNetworkMode = reload.networkMode;
        currentPictureSource = reload.source ?? PixezNetworkSettings.imageHost;
        final newClient = await r.RhttpCompatibleClient.createSync(
          settings: PixezNetworkSettings.forImages(
            currentPictureSource,
            currentNetworkMode,
          ),
        );
        dio.httpClientAdapter = ConversionLayerAdapter(newClient);
        return;
      }
      if (isoContactBean.state == IsoTaskState.CANCEL_ALL) {
        cancelCurrent = true;
        return;
      }
      TaskBean taskBean = isoContactBean.data;
      switch (isoContactBean.state) {
        case IsoTaskState.ERROR:
          break;
        case IsoTaskState.APPEND:
          try {
            cancelCurrent = false;
            currentPictureSource = taskBean.source ?? pictureSource;
            currentNetworkMode = taskBean.networkMode ?? message.networkMode;
            print("========taskBean.savePath: ${taskBean.savePath}");
            var savePath =
                taskBean.savePath! +
                Platform.pathSeparator +
                taskBean.fileName!;
            var fileReady = false;
            await for (final response in pixivCacheManager!.getFileStream(
              taskBean.url!,
              headers: {
                "referer": "https://app-api.pixiv.net/",
                "User-Agent": "PixivIOSApp/5.8.0",
              },
              withProgress: true,
            )) {
              if (cancelCurrent) break;
              if (response is DownloadProgress) {
                sendPort.send(
                  IsoContactBean(
                    state: IsoTaskState.PROGRESS,
                    data: IsoProgressBean(
                      min: response.downloaded,
                      total: response.totalSize ?? 1,
                      url: taskBean.url!,
                    ),
                  ),
                );
              } else if (response is FileInfo) {
                // 缓存过期时 getFileStream 会先吐一次旧缓存、下载完再吐一次新文件。
                // 每次下载只处理第一个，否则同一个 URL 会发两次 COMPLETE、导两次相册。
                if (fileReady) continue;
                fileReady = true;
                File file = File(savePath);
                if (!file.parent.existsSync()) {
                  file.parent.createSync(recursive: true);
                }
                await response.file.copy(file.path);
                sendPort.send(
                  IsoContactBean(state: IsoTaskState.COMPLETE, data: taskBean),
                );
              }
            }
          } catch (e) {
            LPrinter.d("fetcher=======");
            LPrinter.d(e);
            sendPort.send(
              IsoContactBean(state: IsoTaskState.ERROR, data: taskBean),
            );
          }
          break;
        default:
          break;
      }
    } catch (e) {
      LPrinter.d(e);
    }
  });
}
