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

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:pixez/fluent/component/pixez_button.dart';
import 'package:pixez/fluent/component/pixiv_image.dart';
import 'package:pixez/fluent/component/sort_group.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/task_persist.dart';
import 'package:pixez/fluent/page/picture/illust_lighting_page.dart';
import 'package:pixez/store/save_store.dart';

class JobPage extends StatefulWidget {
  @override
  _JobPageState createState() => _JobPageState();
}

class _JobPageState extends State<JobPage> with SingleTickerProviderStateMixin {
  List<TaskPersist> _list = [];
  Map<int, int> _counts = {};
  TaskPersistProvider taskPersistProvider = TaskPersistProvider();
  Timer? _timer;
  late AnimationController rotationController;
  ScrollController _scrollController = ScrollController();
  bool _itemSimple = true;
  int STATUS_ALL = 10;

  @override
  void initState() {
    rotationController = AnimationController(
        duration: const Duration(milliseconds: 500), vsync: this);
    _scrollController.addListener(() async {
      if (_scrollController.hasClients) {
        if (_scrollController.offset >=
            _scrollController.position.maxScrollExtent) {
          await _next();
        }
      }
    });
    super.initState();
    initMethod();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    rotationController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  initMethod() async {
    await taskPersistProvider.open();
    _refresh();
    _timer = Timer.periodic(Duration(seconds: 1), (time) {
      _fetchLocal();
    });
  }

  _fetchLocal() async {
    if (!mounted || currentIndex != 1) return;
    await _refreshRunning();
  }

  /// 「进行中」= 正在下载的（内存队列里在跑的）+ 正在写相册的（数据库里 status 1）。
  Future<void> _refreshRunning() async {
    final downloading = fetcher.queue
        .where((element) => fetcher.urlPool.contains(element.url))
        .map((e) => TaskPersist(
            userName: e.illusts?.user.name ?? "",
            title: e.illusts?.title ?? "",
            url: e.url ?? "",
            userId: e.illusts?.user.id ?? 0,
            illustId: e.illusts?.id ?? 0,
            fileName: e.fileName ?? "",
            status: 1))
        .toList();
    var saving = <TaskPersist>[];
    try {
      saving = await taskPersistProvider.getDownloadTask(0, 1, false,
          limit: 100);
    } catch (e) {
      print(e);
    }
    if (!mounted || currentIndex != 1) return;
    final urls = downloading.map((e) => e.url).toSet();
    setState(() {
      _list = [
        ...downloading,
        ...saving.where((e) => !urls.contains(e.url)),
      ];
    });
    _loadCounts();
  }

  _refresh() async {
    // 「进行中」是内存+数据库合并的实时列表，不能用 16 条的分页查询覆盖它。
    if (currentIndex == 1) {
      await _refreshRunning();
      return;
    }
    _page = 0;
    _endOfPage = false;
    final results = await taskPersistProvider.getDownloadTask(
        _page, toTaskStatus(currentIndex), asc);
    if (mounted) {
      setState(() {
        _list = results;
      });
    }
    _loadCounts();
  }

  _reQueryFilter() async {
    if (currentIndex == 1) {
      await _refreshRunning();
      return;
    }
    final results = await taskPersistProvider.getDownloadTask(
        _page, toTaskStatus(currentIndex), asc);
    if (mounted) {
      setState(() {
        _list = results;
      });
    }
    _loadCounts();
  }

  bool _nextLoading = false;
  bool _endOfPage = false;

  _next() async {
    // 「进行中」是实时列表，分页会把旧的 16 条又叠一遍。
    if (currentIndex == 1) return;
    if (_nextLoading || _endOfPage) return;
    _nextLoading = true;
    _page++;
    final results = await taskPersistProvider.getDownloadTask(
        _page, toTaskStatus(currentIndex), asc);
    _endOfPage = results.length < 16;
    _nextLoading = false;
    if (mounted) {
      setState(() {
        _list += results;
      });
    }
  }

  int toTaskStatus(int index) {
    switch (index) {
      case 1:
        return 1;
      case 2:
        return 2;
      case 3:
        return 3;
      default:
        return STATUS_ALL;
    }
  }

  String toMessage(int i) {
    switch (i) {
      case 0:
        return "seed";
      case 1:
        return I18n.of(context).running;
      case 2:
        return I18n.of(context).complete;
      case 3:
        return I18n.of(context).failed;
      default:
        return "seed";
    }
  }

  Widget _buildStatusWidget(int i) {
    switch (i) {
      case 0:
        return Text("seed",
            style: FluentTheme.of(context)
                .typography
                .body!
                .copyWith(fontSize: 12));
      case 1:
        return Text(I18n.of(context).running,
            style: FluentTheme.of(context)
                .typography
                .body!
                .copyWith(fontSize: 12));
      case 2:
        return Icon(
          FluentIcons.check_mark,
          color: Colors.green,
          size: 16,
        );
      case 3:
        return Icon(
          FluentIcons.error,
          size: 16,
        );
      default:
        return Text(
          "seed",
          style:
              FluentTheme.of(context).typography.body!.copyWith(fontSize: 16),
        );
    }
  }

  bool asc = false;

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: PageHeader(
        title: Text(I18n.of(context).task_progress),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              onPressed: () {
                setState(() {
                  _itemSimple = !_itemSimple;
                });
              },
              icon: (_itemSimple
                  ? Icon(FluentIcons.picture)
                  : Icon(FluentIcons.hide3)),
            ),
            CommandBarButton(
              onPressed: () {
                if (asc)
                  rotationController.forward();
                else
                  rotationController.reverse();
                setState(() {
                  asc = !asc;
                });
                _reQueryFilter();
              },
              icon: RotationTransition(
                turns: Tween(begin: 0.0, end: 0.5).animate(rotationController),
                child: Icon(FluentIcons.sort_down),
              ),
            ),
          ],
          secondaryItems: [
            CommandBarButton(
              label: Text(I18n.of(context).retry_failed_tasks),
              onPressed: () async {
                await _retryJobs(3);
              },
            ),
            CommandBarButton(
              label: Text(I18n.of(context).retry_seed_task),
              onPressed: () async {
                await _retryJobs(0);
              },
            ),
            CommandBarButton(
              label: Text(I18n.of(context).clear_completed_tasks),
              onPressed: () async {
                await _deleteJobs(2);
              },
            ),
            CommandBarButton(
              label: Text(I18n.of(context).clear_all_tasks),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => ContentDialog(
                    title: Text(I18n.of(context).clear_all_tasks),
                    content: Text(I18n.of(context).clear_all_tasks_message),
                    actions: [
                      Button(
                        child: Text(I18n.of(context).cancel),
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                      ),
                      FilledButton(
                        child: Text(I18n.of(context).ok),
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                _jobEpoch++;
                fetcher.clearAll();
                await taskPersistProvider.deleteAll();
                if (!mounted) return;
                setState(() {
                  _list = [];
                });
                _loadCounts();
              },
            )
          ],
        ),
      ),
      content: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSummary(),
            _buildTopChip(),
            Expanded(child: _body()),
          ],
        ),
      ),
      actions: [
        FilledButton(
          child: Text(I18n.of(context).ok),
          onPressed: Navigator.of(context).pop,
        ),
      ],
    );
  }

  int currentIndex = 0;
  int _page = 0;

  /// 批量重试/删除的批次号，清空任务时自增以中断正在跑的循环。
  int _jobEpoch = 0;

  Future<void> _loadCounts() async {
    try {
      final counts = await taskPersistProvider.countByStatus();
      if (!mounted) return;
      setState(() {
        _counts = counts;
      });
    } catch (e) {
      print(e);
    }
  }

  /// 任务统计：全部 / 完成 / 等待下载 / 进行中 / 失败。
  Widget _buildSummary() {
    final total = _counts.values.fold<int>(0, (sum, value) => sum + value);
    final style =
        FluentTheme.of(context).typography.body?.copyWith(fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(left: 16.0, right: 16.0, bottom: 4.0),
      child: Text(
        '${I18n.of(context).all} $total · '
        '${I18n.of(context).complete} ${_counts[2] ?? 0} · '
        '${I18n.of(context).waiting_download} ${_counts[0] ?? 0} · '
        '${I18n.of(context).running} ${_counts[1] ?? 0} · '
        '${I18n.of(context).failed} ${_counts[3] ?? 0}',
        style: style,
      ),
    );
  }

  Widget _buildTopChip() {
    return SortGroup(
      children: [
        I18n.of(context).all,
        I18n.of(context).running,
        I18n.of(context).complete,
        I18n.of(context).failed,
      ],
      onChange: (index) {
        _scrollController.jumpTo(0);
        setState(() {
          this.currentIndex = index;
        });
        if (index == 1) {
          _refreshRunning();
        } else {
          _refresh();
        }
      },
    );
  }

  Widget _body() {
    final trueList = asc ? _list.reversed.toList() : _list;
    return ListView.builder(
      controller: _scrollController,
      itemBuilder: (context, index) {
        if (trueList.isEmpty)
          return Container(
            height: MediaQuery.of(context).size.width,
            child: Center(
              child: Text(
                "[ ]",
                style: FluentTheme.of(context)
                    .typography
                    .body!
                    .copyWith(fontSize: 24),
              ),
            ),
          );
        return _buildItem(trueList[index], index);
      },
      itemCount: (trueList.isEmpty) ? 1 : trueList.length,
    );
  }

  Widget _buildItem(TaskPersist taskPersist, int index) {
    JobEntity? jobEntity = fetcher.jobMaps[taskPersist.url];
    if (currentIndex != 0) {
      if ((jobEntity?.status ?? taskPersist.status) != currentIndex)
        return Visibility(
          child: Container(
            height: 0,
          ),
          visible: false,
        );
    }
    return PixEzButton(
      onPressed: () {
        Leader.push(
          context,
          IllustLightingPage(id: taskPersist.illustId),
          icon: const Icon(FluentIcons.picture),
          title: Text(I18n.of(context).illust_id + ': ${taskPersist.illustId}'),
        );
      },
      child: Card(
        padding: EdgeInsets.zero,
        child: Stack(
          children: [
            Row(
              children: [
                (!_itemSimple)
                    ? Container(
                        child: Stack(
                          children: [
                            Container(
                              height: 100,
                              width: 100,
                              child: PixivImage(
                                taskPersist.medium ?? taskPersist.url,
                                fit: BoxFit.cover,
                                height: 100,
                                width: 100,
                              ),
                            ),
                            (jobEntity != null && jobEntity.status != 2)
                                ? Container(
                                    height: 100,
                                    width: 100,
                                    child: Center(
                                      child: ProgressRing(
                                        value: ((jobEntity.min ?? 0.0) /
                                                ((jobEntity.max ?? 0.0)))
                                            .toDouble(),
                                        backgroundColor: Colors.grey[200],
                                      ),
                                    ),
                                  )
                                : Container(
                                    height: 100,
                                    width: 100,
                                  ),
                          ],
                        ),
                        width: 100,
                        height: 100,
                      )
                    : Container(
                        width: 8,
                      ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: Text(
                                taskPersist.title,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                              ),
                            ),
                          ),
                          if (_itemSimple) ...[
                            PixEzButton(
                                onPressed: () {
                                  _retryJob(taskPersist, epoch: _jobEpoch);
                                },
                                child: Icon(FluentIcons.refresh)),
                            Padding(
                              padding: const EdgeInsets.all(8.0),
                              child: PixEzButton(
                                  onPressed: () {
                                    _deleteJob(taskPersist);
                                  },
                                  child: Icon(FluentIcons.delete)),
                            ),
                          ],
                          Padding(
                            padding: const EdgeInsets.only(right: 16.0),
                            child: _buildStatusWidget(
                                jobEntity?.status ?? taskPersist.status),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Text(
                          taskPersist.userName,
                          style:
                              FluentTheme.of(context).typography.body?.copyWith(
                                    color: FluentTheme.of(context).accentColor,
                                    fontSize: 12,
                                  ),
                        ),
                      ),
                      (!_itemSimple)
                          ? Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              mainAxisSize: MainAxisSize.max,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(" "),
                                Row(
                                  children: [
                                    PixEzButton(
                                        onPressed: () {
                                          _retryJob(taskPersist, epoch: _jobEpoch);
                                        },
                                        child: Icon(FluentIcons.refresh)),
                                    Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: PixEzButton(
                                          onPressed: () {
                                            _deleteJob(taskPersist);
                                          },
                                          child: Icon(FluentIcons.delete)),
                                    ),
                                  ],
                                )
                              ],
                            )
                          : Container(
                              height: 10,
                            ),
                    ],
                  ),
                ),
              ],
            ),
            (jobEntity != null && jobEntity.status != 2)
                ? Positioned(
                    left: 0.0,
                    right: 0.0,
                    bottom: 0.0,
                    child: ProgressBar(
                      value: ((jobEntity.min ?? 0.0) / ((jobEntity.max ?? 0.0)))
                          .toDouble(),
                      backgroundColor: Colors.grey[200],
                    ),
                  )
                : Container(),
          ],
        ),
      ),
    );
  }

  /// 按任务原始顺序（id 升序）一条一条重新入队，避免并发入队打乱顺序。
  Future<void> _retryJobs(int status) async {
    final epoch = _jobEpoch;
    final results = await taskPersistProvider.getAllAccount();
    results.sort((a, b) => (a.id ?? 0).compareTo(b.id ?? 0));
    for (final element in results) {
      // 循环期间如果用户清空了所有任务，就不要再把行写回去。
      if (epoch != _jobEpoch) return;
      if (element.status == status) {
        await _retryJob(element, notify: false, epoch: epoch);
      }
    }
    if (mounted) await _refresh();
  }

  Future<void> _deleteJobs(int status) async {
    final epoch = _jobEpoch;
    final results = await taskPersistProvider.getAllAccount();
    for (final element in results) {
      if (epoch != _jobEpoch) return;
      if (element.status == status) {
        await _deleteJob(element, notify: false);
      }
    }
    if (mounted) await _refresh();
  }

  Future _deleteJob(TaskPersist persist, {bool notify = true}) async {
    // 「进行中」里的行是内存里拼出来的，没有 id，按 url 回数据库找一次。
    var target = persist;
    if (target.id == null) {
      final found = await taskPersistProvider.getAccount(target.url);
      if (found == null) return;
      target = found;
    }
    if (fetcher.isSaving(target.url)) {
      // 正在写相册：原生导入取消不了，删掉再保存会把同一张图导两次。
      return;
    }
    final removed = await taskPersistProvider.remove(target.id!);
    if (removed == 0) {
      // 列表里的 id 可能是旧的（比如经「已在队列」气泡重新保存过），按 url 再删一次。
      final again = await taskPersistProvider.getAccount(target.url);
      if (again != null && again.id != null) {
        await taskPersistProvider.remove(again.id!);
      }
    }
    fetcher.jobMaps.remove(target.url);
    fetcher.queue.removeWhere((element) => element.url == target.url);
    fetcher.resetRetry(target.url);
    if (notify && mounted) {
      setState(() {
        _list.removeWhere((element) =>
            element.id == target.id || element.url == target.url);
      });
      _loadCounts();
    }
  }

  Future _retryJob(TaskPersist persist, {bool notify = true, int? epoch}) async {
    // 以数据库里的最新状态为准：列表里的对象可能是旧的（例如刚重试过的那条）。
    final latest = await taskPersistProvider.getAccount(persist.url);
    if (latest == null) return;
    // 2 = 已完成，1 = 正在下载 / 写相册 / 等自动重试；重试会重复导入同一张图。
    if (latest.status == 2 || latest.status == 1) return;
    if (fetcher.isActive(latest.url)) return;
    if (epoch != null && epoch != _jobEpoch) return;
    await _deleteJob(latest, notify: notify);
    // 删除是异步的：期间如果用户清空了任务，就不要再把行写回去。
    if (epoch != null && epoch != _jobEpoch) return;
    await taskPersistProvider.insert(latest..status = 0);
    if (epoch != null && epoch != _jobEpoch) return;
    fetcher.resetRetry(latest.url);
    // 单条手动重试插到队首尽快开始；批量重排（notify == false）保持原顺序。
    await fetcher.save(latest.url, latest.toIllusts(), latest.fileName,
        front: notify);
    if (notify) await _refresh();
  }
}
