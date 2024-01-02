import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:collection/collection.dart';
import 'package:finamp/components/global_snackbar.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:isar/isar.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path_helper;
import 'package:rxdart/rxdart.dart';

import '../models/finamp_models.dart';
import '../models/jellyfin_models.dart';
import 'backgroundDownloaderStorage.dart';
import 'finamp_settings_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';

class IsarDownloads {
  IsarDownloads() {
    for (var state in DownloadItemState.values) {
      downloadStatuses[state] = _isar.downloadItems
          .where()
          .typeEqualTo(DownloadItemType.song)
          .or()
          .typeEqualTo(DownloadItemType.image)
          .filter()
          .stateEqualTo(state)
          .countSync();
    }
    downloadStatusesStream = _downloadStatusesStreamController.stream
        .throttleTime(const Duration(seconds: 1),
            leading: false, trailing: true);

    FileDownloader().addTaskQueue(_downloadTaskQueue);

    // TODO use database instead of listener?
    FileDownloader().updates.listen((event) {
      if (event is TaskStatusUpdate) {
        _isar.writeTxn(() async {
          DownloadItem? listener =
              await _isar.downloadItems.get(int.parse(event.task.taskId));
          if (listener != null) {
            var newState = DownloadItemState.fromTaskStatus(event.status);
            if (!listener.state.isFinal) {
              if (event.status == TaskStatus.complete) {
                _downloadsLogger.fine("Downloaded ${listener.name}");
                assert(listener.file.path == await event.task.filePath());
                String? extension;
                switch (event.mimeType) {
                  case "image/jpeg":
                    extension = ".jpg";
                  case "image/bmp":
                    extension = ".bmp";
                  case "image/png":
                    extension = ".png";
                  case "image/gif":
                    extension = ".gif";
                  case "image/webp":
                    extension = ".webp";
                }
                if (extension != null &&
                    !listener.file.path.endsWith(extension)) {
                  await File(listener.file.path)
                      .rename(listener.file.path + extension);
                  listener.path = listener.path! + extension;
                }
              }
              await _updateItemStateAndPut(listener, newState);
              if (event.exception is TaskFileSystemException ||
                  (event.exception?.description
                          .contains(RegExp(r'No space left on device')) ??
                      false)) {
                if (_allowDownloads) {
                  _allowDownloads = false;
                  GlobalSnackbar.message((scaffold) =>
                      AppLocalizations.of(scaffold)!.filesystemFull);
                }
              } else if (event.exception != null) {
                _downloadsLogger.warning(
                    "Exception ${event.exception} when downloading ${listener.name}");
              }
            } else {
              _downloadsLogger.info(
                  "Recieved status event ${event.status} for finalized download ${listener.name}.  Ignoring.");
            }
          } else {
            _downloadsLogger.severe(
                "Could not determine item for id ${event.task.taskId}, event:${event.toString()}");
          }
        });
      }
    });
  }

  final _downloadsLogger = Logger("IsarDownloads");

  final _jellyfinApiData = GetIt.instance<JellyfinApiHelper>();
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _isar = GetIt.instance<Isar>();

  final _anchor =
      DownloadStub.fromId(id: "Anchor", type: DownloadItemType.anchor);
  final _downloadTaskQueue = IsarTaskQueue();
  final _deleteBuffer = IsarDeleteBuffer();

  final Map<DownloadItemState, int> downloadStatuses = {};
  late final Stream<Map<DownloadItemState, int>> downloadStatusesStream;
  final StreamController<Map<DownloadItemState, int>>
      _downloadStatusesStreamController = StreamController.broadcast();

  bool _allowDownloads = true;
  bool get allowDownloads => _allowDownloads;

  Map<String, Future<DownloadStub>> _metadataCache = {};
  Map<String, Future<List<BaseItemDto>>> _childCache = {};
  Future<void> childThrottle = Future.value();

  Future<void> startQueues() async {
    try {
      await _deleteBuffer.executeDeletes(_syncDelete);
      await _downloadTaskQueue.startQueue();
    } catch (e) {
      _downloadsLogger.severe(
          "Error $e while restarting download/delete queues on startup.");
    }
  }

  Future<DownloadStub?> _getCollectionInfo(String id) async {
    if (_metadataCache.containsKey(id)) {
      return _metadataCache[id];
    }
    Completer<DownloadStub> itemFetch = Completer();
    try {
      _metadataCache[id] = itemFetch.future;

      DownloadStub? item;
      item = await _isar.downloadItems
          .get(DownloadStub.getHash(id, DownloadItemType.collection));
      item ??= await _jellyfinApiData.getItemByIdBatched(id).then((value) =>
          value == null
              ? null
              : DownloadStub.fromItem(
                  item: value, type: DownloadItemType.collection));
      itemFetch.complete(item);
      return itemFetch.future;
    } catch (e) {
      itemFetch.completeError(e);
      return itemFetch.future;
    }
  }

  Future<List<DownloadStub>> _getCollectionChildren(DownloadStub parent) async {
    DownloadItemType childType;
    BaseItemDtoType childFilter;
    assert(parent.type == DownloadItemType.collection);
    switch (parent.baseItemType) {
      case BaseItemDtoType.playlist || BaseItemDtoType.album:
        childType = DownloadItemType.song;
        childFilter = BaseItemDtoType.song;
      case BaseItemDtoType.artist ||
            BaseItemDtoType.genre ||
            BaseItemDtoType.library:
        childType = DownloadItemType.collection;
        childFilter = BaseItemDtoType.album;
      case _:
        throw StateError("Unknown collection type ${parent.baseItemType}");
    }
    var item = parent.baseItem!;

    if (_childCache.containsKey(item.id)) {
      var children = await _childCache[item.id]!;
      return children
          .map((e) => DownloadStub.fromItem(type: childType, item: e))
          .toList();
    }
    Completer<List<BaseItemDto>> itemFetch = Completer();
    // This prevents errors in itemFetch being reported as unhandled.
    // They are handled by original caller in rethrow.
    unawaited(itemFetch.future.then((_) => null, onError: (_) => null));
    try {
      _childCache[item.id] = itemFetch.future;
      // Rate limit server item requests to 3 per second
      var nextSlot = childThrottle;
      childThrottle = childThrottle
          .then((value) => Future.delayed(const Duration(milliseconds: 300)));
      await nextSlot;
      var childItems = await _jellyfinApiData.getItems(
              parentItem: item, includeItemTypes: childFilter.idString) ??
          [];
      itemFetch.complete(childItems);
      return childItems
          .map((e) => DownloadStub.fromItem(type: childType, item: e))
          .toList();
    } catch (e) {
      itemFetch.completeError("replaced!");
      rethrow;
    }
  }

  // Make sure the parent and all children are in the metadata collection,
  // and downloaded.
  // TODO add comment warning about require loops
  // returns set of items that need _syncDelete run
  Future<void> _syncDownload(
      DownloadStub parent,
      bool asRequired,
      List<DownloadStub> requireCompleted,
      List<DownloadStub> infoCompleted,
      String? viewId) async {
    if (parent.type == DownloadItemType.image ||
        parent.type == DownloadItemType.anchor) {
      asRequired = true; // Always download images, don't process twice.
    }
    if (parent.baseItemType == BaseItemDtoType.playlist) {
      // Playlists show in all libraries, do not apply library info
      viewId = null;
    } else if (parent.baseItemType == BaseItemDtoType.library) {
      // Update view id for children of downloaded library
      viewId = parent.id;
    }
    if (requireCompleted.contains(parent)) {
      return;
    } else if (infoCompleted.contains(parent) && !asRequired) {
      return;
    } else {
      if (asRequired) {
        requireCompleted.add(parent);
      } else {
        infoCompleted.add(parent);
      }
    }
    // Throttle sync speed to preserve responsiveness and limit server load
    //await Future.delayed(const Duration(milliseconds: 30));
    _downloadsLogger.finer("Syncing ${parent.name}");

    bool updateChildren = true;
    Set<DownloadStub> requiredChildren = {};
    Set<DownloadStub> infoChildren = {};
    List<DownloadStub>? orderedChildItems;
    switch (parent.type) {
      case DownloadItemType.collection:
        var item = parent.baseItem!;
        if (item.blurHash != null) {
          infoChildren.add(
              DownloadStub.fromItem(type: DownloadItemType.image, item: item));
        }
        try {
          if (asRequired) {
            orderedChildItems = await _getCollectionChildren(parent);
            requiredChildren.addAll(orderedChildItems);
          }
          if (parent.baseItemType == BaseItemDtoType.album ||
              parent.baseItemType == BaseItemDtoType.playlist) {
            orderedChildItems ??= await _getCollectionChildren(parent);
            infoChildren.addAll(orderedChildItems);
          }
        } catch (e) {
          _downloadsLogger
              .info("Error downloading children for ${item.name}: $e");
          updateChildren = false;
        }
      case DownloadItemType.song:
        var item = parent.baseItem!;
        if (item.blurHash != null) {
          requiredChildren.add(
              DownloadStub.fromItem(type: DownloadItemType.image, item: item));
        }
        if (asRequired) {
          List<String> collectionIds = [];
          collectionIds.addAll(item.genreItems?.map((e) => e.id) ?? []);
          collectionIds.addAll(item.artistItems?.map((e) => e.id) ?? []);
          collectionIds.addAll(item.albumArtists?.map((e) => e.id) ?? []);
          if (item.albumId != null) {
            collectionIds.add(item.albumId!);
          }
          try {
            var collectionChildren =
                await Future.wait(collectionIds.map(_getCollectionInfo));
            infoChildren.addAll(collectionChildren.whereNotNull());
          } catch (e) {
            _downloadsLogger
                .info("Failed to download metadata for ${item.name}: $e");
            updateChildren = false;
          }
        }
      case DownloadItemType.image:
        break;
      case DownloadItemType.anchor:
        updateChildren = false;
    }

    //if (updateChildren) {
    //  _downloadsLogger.finest(
    //      "Updating children of ${parent.name} to ${children.map((e) => e.name)}");
    //}

    DownloadLocation? downloadLocation;
    if (updateChildren) {
      await _isar.writeTxn(() async {
        DownloadItem? canonParent =
            await _isar.downloadItems.get(parent.isarId);
        if (canonParent == null) {
          throw StateError("_syncDownload called on missing node ${parent.id}");
        }
        var newParent = canonParent.copyWith(
            item: parent.baseItem,
            viewId: viewId,
            orderedChildItems: orderedChildItems);
        if (newParent == null) {
          _downloadsLogger.warning(
              "Could not update ${canonParent.name} - incompatible new item ${parent.baseItem}");
        } else {
          await _isar.downloadItems.put(canonParent);
        }
        downloadLocation = canonParent.downloadLocation;

        if (asRequired) {
          await _updateChildren(
              canonParent, canonParent.requires, requiredChildren);
          await _updateChildren(canonParent, canonParent.info, infoChildren);
        } else if (canonParent.type == DownloadItemType.song) {
          // For info only songs, we put image link into required so that we can delete
          // all info links in _syncDelete, so process that
          await _updateChildren(
              canonParent, canonParent.requires, requiredChildren);
        } else {
          await _updateChildren(canonParent, canonParent.info, infoChildren);
        }
      });
    } else {
      await _isar.txn(() async {
        downloadLocation =
            (await _isar.downloadItems.get(parent.isarId))?.downloadLocation;
        // Only children in links we would update should be gathered
        if (asRequired) {
          requiredChildren = (await _isar.downloadItems
                  .filter()
                  .requiredBy((q) => q.isarIdEqualTo(parent.isarId))
                  .findAll())
              .toSet();
          infoChildren = (await _isar.downloadItems
                  .filter()
                  .infoFor((q) => q.isarIdEqualTo(parent.isarId))
                  .findAll())
              .toSet();
        } else if (parent.type == DownloadItemType.song) {
          requiredChildren = (await _isar.downloadItems
                  .filter()
                  .requiredBy((q) => q.isarIdEqualTo(parent.isarId))
                  .findAll())
              .toSet();
        } else {
          infoChildren = (await _isar.downloadItems
                  .filter()
                  .infoFor((q) => q.isarIdEqualTo(parent.isarId))
                  .findAll())
              .toSet();
        }
      });
    }

    if (parent.type.hasFiles && asRequired) {
      if (downloadLocation == null) {
        _downloadsLogger.severe(
            "could not download ${parent.id}, no download location found.");
      } else {
        await _initiateDownload(parent, downloadLocation!);
      }
    }

    List<Future<void>> futures = [];
    for (var child in requiredChildren) {
      futures.add(
          _syncDownload(child, true, requireCompleted, infoCompleted, viewId));
    }
    for (var child in infoChildren.difference(requiredChildren)) {
      futures.add(
          _syncDownload(child, false, requireCompleted, infoCompleted, viewId));
    }
    await Future.wait(futures);
  }

  // This should only be called inside an isar write transaction.
  // returns list of unlinked children
  Future<void> _updateChildren(DownloadItem parent,
      IsarLinks<DownloadItem> links, Set<DownloadStub> children) async {
    var oldChildren = await links.filter().findAll();
    // anyOf filter allows all objects when given empty list, but we want no objects
    var childrenToLink = (children.isEmpty)
        ? <DownloadItem>[]
        : await _isar.downloadItems
            .where()
            .anyOf(children.map((e) => e.isarId),
                (q, int id) => q.isarIdEqualTo(id))
            .findAll();
    var childrenToPutAndLink = children
        .difference(childrenToLink.toSet())
        .map((e) => e.asItem(parent.downloadLocationId));
    var childrenToUnlink = oldChildren.toSet().difference(children);
    assert((childrenToLink + childrenToPutAndLink.toList()).length ==
        children.length);
    await _isar.downloadItems.putAll(childrenToPutAndLink.toList());
    await links.update(
        link: childrenToLink + childrenToPutAndLink.toList(),
        unlink: childrenToUnlink);
    if (childrenToLink.length != oldChildren.length ||
        childrenToUnlink.isNotEmpty) {
      await _syncItemState(parent);
    }
    await _deleteBuffer.addAll(childrenToUnlink);
  }

  Future<void> _syncDelete(int isarId) async {
    DownloadItem? canonItem;
    int requiredByCount = -1;
    int infoForCount = -1;
    await _isar.txn(() async {
      canonItem = await _isar.downloadItems.get(isarId);
      requiredByCount = await canonItem?.requiredBy.filter().count() ?? -1;
      infoForCount = await canonItem?.infoFor.filter().count() ?? -1;
    });
    _downloadsLogger.finer("Sync deleting ${canonItem?.name ?? isarId}");
    if (canonItem == null ||
        requiredByCount > 0 ||
        canonItem!.type == DownloadItemType.anchor) {
      return;
    }
    if (canonItem!.type == DownloadItemType.image && infoForCount > 0) {
      return;
    }

    // images should always be downloaded, even if they only have info links
    // This allows deleting all require links for collections but retaining associated images
    if (canonItem!.type.hasFiles) {
      await _deleteDownload(canonItem!);
    }

    Set<DownloadItem> children = {};
    await _isar.writeTxn(() async {
      DownloadItem? transactionItem =
          await _isar.downloadItems.get(canonItem!.isarId);
      if (transactionItem == null) {
        return;
      }
      if (transactionItem.type == DownloadItemType.image ||
          transactionItem.type == DownloadItemType.song) {
        if (transactionItem.state != DownloadItemState.notDownloaded) {
          _downloadsLogger.severe(
              "Could not delete ${transactionItem.name}, may still have files");
          return;
        }
      }
      var infoForCount = await canonItem?.infoFor.filter().count();
      requiredByCount = await canonItem?.requiredBy.filter().count() ?? -1;
      if (requiredByCount != 0) {
        _downloadsLogger.severe(
            "Node ${transactionItem.id} became required during file deletion");
        return;
      }
      if (infoForCount! > 0) {
        if (transactionItem.type == DownloadItemType.song) {
          // Non-required songs cannot info link collection, but they can still
          // require their images.
          children.addAll(await transactionItem.info.filter().findAll());
          await _deleteBuffer.addAll(children);
          await transactionItem.info.reset();
        } else {
          children.addAll(await transactionItem.requires.filter().findAll());
          await _deleteBuffer.addAll(children);
          await transactionItem.requires.reset();
        }
      } else {
        children.addAll(await transactionItem.info.filter().findAll());
        children.addAll(await transactionItem.requires.filter().findAll());
        await _deleteBuffer.addAll(children);
        await _isar.downloadItems.delete(transactionItem.isarId);
      }
    });
  }

  // TODO use download groups to send notification when item fully downloaded?
  Future<void> addDownload({
    required DownloadStub stub,
    required DownloadLocation downloadLocation,
    required String viewId,
  }) async {
    // TODO flutter will never actually make a request here according to issue commenter
    // Do it ourselves?  Just assume file picker handled everything we need?
    /*if (downloadLocation.needsPermission) {
      if (await Permission.accessMediaLocation.isGranted) {
        _downloadsLogger.severe("Storage permission is not granted, exiting");
        return Future.error(
            "Storage permission is required for external storage");
      }
    }*/

    await _isar.writeTxn(() async {
      DownloadItem canonItem = await _isar.downloadItems.get(stub.isarId) ??
          stub.asItem(downloadLocation.id);
      canonItem.downloadLocationId = downloadLocation.id;
      await _isar.downloadItems.put(canonItem);
      var anchorItem = _anchor.asItem(null);
      // This is required to trigger status recalculation
      await _isar.downloadItems.put(anchorItem);
      await anchorItem.requires.update(link: [canonItem]);
    });

    await resync(stub, viewId);
  }

  Future<void> deleteDownload({required DownloadStub stub}) async {
    await _isar.writeTxn(() async {
      var anchorItem = _anchor.asItem(null);
      // This is required to trigger status recalculation
      await _isar.downloadItems.put(anchorItem);
      await anchorItem.requires.update(unlink: [stub.asItem(null)]);
      await _deleteBuffer.addAll([stub]);
    });
    try {
      await _deleteBuffer.executeDeletes(_syncDelete);
    } catch (error, stackTrace) {
      _downloadsLogger.severe("Isar failure $error", error, stackTrace);
      rethrow;
    }
  }

  Future<void> resyncAll() => resync(_anchor, null);

  Future<void> resync(DownloadStub stub, String? viewId) async {
    _allowDownloads = true;
    var requiredByCount = await _isar.downloadItems
        .filter()
        .requires((q) => q.isarIdEqualTo(stub.isarId))
        .count();
    try {
      await _syncDownload(stub, requiredByCount != 0, [], [], viewId);
      _metadataCache = {};
      _childCache = {};
      await _deleteBuffer.executeDeletes(_syncDelete);
    } catch (error, stackTrace) {
      _downloadsLogger.severe("Isar failure $error", error, stackTrace);
      rethrow;
    }
  }

  Future<void> _initiateDownload(
      DownloadStub item, DownloadLocation downloadLocation) async {
    DownloadItem? canonItem;
    int requiredByCount = -1;
    int infoForCount = -1;
    await _isar.txn(() async {
      canonItem = await _isar.downloadItems.get(item.isarId);
      requiredByCount = await canonItem?.requiredBy.filter().count() ?? -1;
      infoForCount = await canonItem?.infoFor.filter().count() ?? -1;
    });
    if (canonItem == null || requiredByCount < 0 || infoForCount < 0) {
      _downloadsLogger.severe(
          "Download metadata ${item.id} missing before download starts");
      return;
    }

    if (!item.type.hasFiles ||
        !_allowDownloads ||
        (requiredByCount == 0 && infoForCount == 0) ||
        (requiredByCount == 0 && canonItem!.type != DownloadItemType.image)) {
      return;
    }

    switch (canonItem!.state) {
      case DownloadItemState.complete:
        return;
      case DownloadItemState.notDownloaded:
        break;
      case DownloadItemState.enqueued: //fall through
      case DownloadItemState.downloading:
        if (await _downloadTaskQueue.validateQueued(canonItem!)) {
          // advance queue just in case
          _downloadTaskQueue.advanceQueue();
          return;
        }
        await _deleteDownload(canonItem!);
      case DownloadItemState.failed:
        await _deleteDownload(canonItem!);
    }

    // Refresh canonItem due to possible changes
    canonItem = await _isar.downloadItems.get(item.isarId);
    if (canonItem == null ||
        canonItem!.state != DownloadItemState.notDownloaded) {
      throw StateError(
          "Bad state beginning download for ${item.name}: $canonItem");
    }

    //if (FinampSettingsHelper.finampSettings.isOffline){
    //  _downloadsLogger.info("Aborting download of ${item.name}, we are offline.");
    //  return;
    //}

    switch (canonItem!.type) {
      case DownloadItemType.song:
        return _downloadSong(canonItem!, downloadLocation);
      case DownloadItemType.image:
        return _downloadImage(canonItem!, downloadLocation);
      case _:
        throw StateError("???");
    }
  }

  String? _filesystemSafe(String? unsafe) =>
      unsafe?.replaceAll(RegExp('[/?<>\\:*|"]'), "_");

  Future<void> _downloadSong(
      DownloadItem downloadItem, DownloadLocation downloadLocation) async {
    assert(downloadItem.type == DownloadItemType.song);
    var item = downloadItem.baseItem!;

    // Base URL shouldn't be null at this point (user has to be logged in
    // to get to the point where they can add downloads).
    String songUrl =
        "${_finampUserHelper.currentUser!.baseUrl}/Items/${item.id}/File";

    List<MediaSourceInfo>? mediaSourceInfo =
        await _jellyfinApiData.getPlaybackInfo(item.id);

    String fileName;
    String subDirectory;
    if (downloadLocation.useHumanReadableNames) {
      if (mediaSourceInfo == null) {
        _downloadsLogger.warning(
            "Media source info for ${item.id} returned null, filename may be weird.");
      }
      subDirectory =
          path_helper.join("finamp", _filesystemSafe(item.albumArtist));
      // We use a regex to filter out bad characters from song/album names.
      fileName = _filesystemSafe(
          "${item.album} - ${item.indexNumber ?? 0} - ${item.name}.${mediaSourceInfo?[0].container}")!;
    } else {
      fileName = "${item.id}.${mediaSourceInfo?[0].container}";
      subDirectory = "songs";
    }

    String? tokenHeader = _jellyfinApiData.getTokenHeader();

    if (downloadLocation.baseDirectory.needsPath) {
      subDirectory =
          path_helper.join(downloadLocation.currentPath, subDirectory);
    }

    // TODO allow pausing?  When to resume?
    BaseDirectory;
    _downloadTaskQueue.add(DownloadTask(
        taskId: downloadItem.isarId.toString(),
        url: songUrl,
        // requiresWifi will be set when enqueueing by IsarTaskQueue
        displayName: downloadItem.name,
        directory: subDirectory,
        baseDirectory: downloadLocation.baseDirectory.baseDirectory,
        retries: 3,
        headers: {
          if (tokenHeader != null) "X-Emby-Token": tokenHeader,
        },
        filename: fileName));

    await _isar.writeTxn(() async {
      DownloadItem? canonItem =
          await _isar.downloadItems.get(downloadItem.isarId);
      if (canonItem == null) {
        _downloadsLogger.severe(
            "Download metadata ${downloadItem.id} missing after download starts");
        throw StateError("Could not save download task id");
      }
      canonItem.downloadLocationId = downloadLocation.id;
      canonItem.path = path_helper.join(subDirectory, fileName);
      canonItem.mediaSourceInfo = mediaSourceInfo![0];
      await _updateItemStateAndPut(canonItem, DownloadItemState.enqueued);
    });
  }

  Future<void> _downloadImage(
      DownloadItem downloadItem, DownloadLocation downloadLocation) async {
    assert(downloadItem.type == DownloadItemType.image);
    var item = downloadItem.baseItem!;

    String subDirectory;
    if (downloadLocation.useHumanReadableNames) {
      subDirectory =
          path_helper.join("finamp", _filesystemSafe(item.albumArtist));
    } else {
      subDirectory = "images";
    }

    final imageUrl = _jellyfinApiData.getImageUrl(
      item: item,
      // Download original file
      quality: null,
      format: null,
    );
    final tokenHeader = _jellyfinApiData.getTokenHeader();

    if (downloadLocation.baseDirectory.needsPath) {
      subDirectory =
          path_helper.join(downloadLocation.currentPath, subDirectory);
    }

    // We still use imageIds for filenames despite switching to blurhashes as
    // blurhashes can include characters that filesystems don't support
    final fileName = _filesystemSafe(item.imageId);

    BaseDirectory;
    _downloadTaskQueue.add(DownloadTask(
        taskId: downloadItem.isarId.toString(),
        url: imageUrl.toString(),
        // requiresWifi will be set when enqueueing by IsarTaskQueue
        displayName: downloadItem.name,
        baseDirectory: downloadLocation.baseDirectory.baseDirectory,
        retries: 3,
        directory: subDirectory,
        headers: {
          if (tokenHeader != null) "X-Emby-Token": tokenHeader,
        },
        filename: fileName));

    await _isar.writeTxn(() async {
      DownloadItem? canonItem =
          await _isar.downloadItems.get(downloadItem.isarId);
      if (canonItem == null) {
        _downloadsLogger.severe(
            "Download metadata ${downloadItem.id} missing after download starts");
        throw StateError("Could not save download task id");
      }
      canonItem.downloadLocationId = downloadLocation.id;
      canonItem.path = path_helper.join(subDirectory, fileName);
      await _updateItemStateAndPut(canonItem, DownloadItemState.enqueued);
      Database;
    });
  }

  Future<void> _deleteDownload(DownloadItem item) async {
    assert(item.type.hasFiles);
    if (item.state == DownloadItemState.notDownloaded) {
      return;
    }

    await _downloadTaskQueue.remove(item);
    if (item.downloadLocation != null) {
      try {
        await item.file.delete();
      } on PathNotFoundException {
        _downloadsLogger.finer(
            "File ${item.file.path} for ${item.name} missing during delete.");
      }
    }

    if (item.downloadLocation != null &&
        item.downloadLocation!.useHumanReadableNames) {
      Directory songDirectory = item.file.parent;
      try {
        if (await songDirectory.list().isEmpty) {
          _downloadsLogger.info("${songDirectory.path} is empty, deleting");
          await songDirectory.delete();
        }
      } on PathNotFoundException {
        _downloadsLogger
            .finer("Directory ${songDirectory.path} missing during delete.");
      }
    }

    await _isar.writeTxn(() async {
      var transactionItem = await _isar.downloadItems.get(item.isarId);
      if (transactionItem != null) {
        await _updateItemStateAndPut(
            transactionItem, DownloadItemState.notDownloaded);
      }
    });
  }

  // TODO add clear download metadata option in settings?  Add some option to clear all links in settings??
  // or maybe clear all links but add warning to user about deletes occuring if server connection fails
  // or maybe provide list of nodes to be deleted to user and ask for delete confirmation?
  Future<void> repairAllDownloads() async {
    //TODO add more error checking so that one very broken item can't block general repairs.
    // Step 1 - Get all items into correct state matching filesystem and downloader.
    _downloadsLogger.fine("Starting downloads repair step 1");
    var itemsWithFiles = await _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.song)
        .or()
        .typeEqualTo(DownloadItemType.image)
        .findAll();
    for (var item in itemsWithFiles) {
      switch (item.state) {
        case DownloadItemState.complete:
          await _verifyDownload(item);
        case DownloadItemState.notDownloaded:
          break;
        case DownloadItemState.enqueued: // fall through
        case DownloadItemState.downloading:
          if (await _downloadTaskQueue.validateQueued(item)) {
            // advance queue just in case
            _downloadTaskQueue.advanceQueue();
            return;
          }
          await _deleteDownload(item);
        case DownloadItemState.failed:
          await _deleteDownload(item);
      }
    }
    var itemsWithChildren = await _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.collection)
        .findAll();
    await _isar.writeTxn(() async {
      for (var item in itemsWithChildren) {
        await _syncItemState(item);
      }
    });

    // Step 2 - Make sure all items are linked up to correct children.
    _downloadsLogger.fine("Starting downloads repair step 2");
    await _isar.writeTxn(() async {
      List<
          (
            DownloadItemType,
            QueryBuilder<DownloadItem, DownloadItem, QAfterFilterCondition> Function(
                QueryBuilder<DownloadItem, DownloadItem, QFilterCondition>)?
          )> requireFilters = [
        (DownloadItemType.anchor, null),
        (
          DownloadItemType.collection,
          (q) => q.allOf([BaseItemDtoType.album, BaseItemDtoType.playlist],
              (q, element) => q.not().baseItemTypeEqualTo(element))
        ),
        (
          DownloadItemType.collection,
          (q) => q.anyOf([BaseItemDtoType.album, BaseItemDtoType.playlist],
              (q, element) => q.baseItemTypeEqualTo(element))
        ),
        (DownloadItemType.song, null),
        (DownloadItemType.image, null),
      ];
      // Objects matching a require filter cannot require elements matching earlier filters or the current filter.
      // This enforces a strict object hierarchy with no possibility of loops.
      for (int i = 0; i < requireFilters.length; i++) {
        var items = await _isar.downloadItems
            .where()
            .typeEqualTo(requireFilters[i].$1)
            .filter()
            .optional(
                requireFilters[i].$2 != null, (q) => requireFilters[i].$2!(q))
            .requires((q) => q.anyOf(
                requireFilters.slice(0, i + 1),
                (q, element) => q
                    .typeEqualTo(element.$1)
                    .optional(element.$2 != null, (q) => element.$2!(q))))
            .findAll();
        for (var item in items) {
          _downloadsLogger
              .severe("Unlinking invalid requires on node ${item.name}.");
          _downloadsLogger.severe(
              "Current children: ${await item.requires.filter().findAll()}.");
          await item.requires.reset();
        }
      }
      List<
          QueryBuilder<DownloadItem, DownloadItem, QAfterFilterCondition> Function(
              QueryBuilder<DownloadItem, DownloadItem,
                  QFilterCondition>)> infoFilters = [
        (q) => q
            .typeEqualTo(DownloadItemType.collection)
            .anyOf([BaseItemDtoType.album, BaseItemDtoType.playlist],
                (q, element) => q.baseItemTypeEqualTo(element))
            .not()
            .info((q) => q.not().group((q) => q
                .typeEqualTo(DownloadItemType.song)
                .or()
                .typeEqualTo(DownloadItemType.image))),
        (q) => q
            .typeEqualTo(DownloadItemType.song)
            .requiredByIsNotEmpty()
            .not()
            .info((q) => q.not().group((q) => q
                .typeEqualTo(DownloadItemType.collection)
                .or()
                .typeEqualTo(DownloadItemType.image))),
        (q) => q.not().info((q) => q.not().typeEqualTo(DownloadItemType.image)),
      ];
      // albums/playlist can require info on songs.  required songs can require info on
      // collections.  Anyone can require info on an image.
      // All other info links are disallowed.
      var badInfoItems = await _isar.downloadItems
          .filter()
          .not()
          .anyOf(infoFilters, (q, element) => element(q))
          .findAll();
      for (var item in badInfoItems) {
        _downloadsLogger.severe("Unlinking invalid info on node ${item.name}.");
        _downloadsLogger
            .severe("Current children: ${await item.info.filter().findAll()}.");
        await item.info.reset();
      }
    });
    await resyncAll();

    // Step 3 - Make sure there are no unanchored nodes in metadata.
    _downloadsLogger.fine("Starting downloads repair step 3");
    var allIds = await _isar.downloadItems.where().isarIdProperty().findAll();
    for (var id in allIds) {
      await _syncDelete(id);
    }

    // Step 4 - Make sure there are no orphan files in song directory.
    _downloadsLogger.fine("Starting downloads repair step 4");
    // This cleans internalSupport/images
    var imageFilePaths = Directory(path_helper.join(
            FinampSettingsHelper.finampSettings.internalSongDir.currentPath,
            "images"))
        .list()
        .handleError((e) =>
            _downloadsLogger.info("Error while cleaning image directories: $e"))
        .where((event) => event is File)
        .map((event) => path_helper.normalize(event.path));
    var filePaths = await imageFilePaths.toList();
    // This cleans internalSupport/songs and internalDocuments/songs
    for (var songBasePath in FinampSettingsHelper
        .finampSettings.downloadLocationsMap.values
        .where((element) => !element.baseDirectory.needsPath)
        .map((e) => e.currentPath)) {
      var songFilePaths = Directory(path_helper.join(songBasePath, "songs"))
          .list()
          .handleError((e) => _downloadsLogger
              .info("Error while cleaning song directories: $e"))
          .where((event) => event is File)
          .map((event) => path_helper.normalize(event.path));
      filePaths.addAll(await songFilePaths.toList());
    }
    for (var item in await _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.song)
        .or()
        .typeEqualTo(DownloadItemType.image)
        .filter()
        .stateEqualTo(DownloadItemState.complete)
        .findAll()) {
      filePaths.remove(path_helper.normalize(item.file.path));
    }
    for (var filePath in filePaths) {
      _downloadsLogger.info("Deleting orphan file $filePath");
      try {
        await File(filePath).delete();
      } catch (e) {
        _downloadsLogger.info("Error while cleaning directories: $e");
      }
    }

    _downloadsLogger.fine("Downloads repair complete.");
  }

  Future<bool> _verifyDownload(DownloadItem item) async {
    assert(item.type.hasFiles);
    if (item.state != DownloadItemState.complete) return false;
    if (item.downloadLocation != null && await item.file.exists()) return true;
    if (item.path != null) {
      for (var location
          in FinampSettingsHelper.finampSettings.downloadLocationsMap.values) {
        var path = path_helper.join(location.currentPath, item.path);
        if (await File(path).exists()) {
          await _isar.writeTxn(() async {
            var canonItem = await _isar.downloadItems.get(item.isarId);
            canonItem!.downloadLocationId = location.id;
            await _isar.downloadItems.put(canonItem);
          });
          _downloadsLogger.info(
              "${item.name} found in unexpected location ${location.name}");
          return true;
        }
      }
    }
    await _isar.writeTxn(() async {
      await _updateItemStateAndPut(item, DownloadItemState.notDownloaded);
    });
    _downloadsLogger.info(
        "${item.name} failed download verification, not located at ${item.file.path}.");
    return false;
  }

  // - first go through boxes and create nodes for all downloaded images/songs
  // then go through all downloaded parents and create anchor-attached nodes, and stitch to children/image.
  // then run standard verify all command - if it fails due to networking the
  Future<void> migrateFromHive() async {
    if (FinampSettingsHelper.finampSettings.downloadLocationsMap.values
        .where((element) =>
            element.baseDirectory == DownloadLocationType.internalSupport)
        .isEmpty) {
      final downloadLocation = await DownloadLocation.create(
        name: "Internal Storage",
        baseDirectory: DownloadLocationType.internalSupport,
      );
      FinampSettingsHelper.addDownloadLocation(downloadLocation);
    }
    await Future.wait([
      Hive.openBox<DownloadedParent>("DownloadedParents"),
      Hive.openBox<DownloadedSong>("DownloadedItems"),
      Hive.openBox<DownloadedImage>("DownloadedImages"),
    ]);
    _migrateImages();
    _migrateSongs();
    _migrateParents();
    try {
      // TODO wrap whole migration in error catching?
      await repairAllDownloads();
    } catch (error) {
      _downloadsLogger
          .severe("Error $error in hive migration downloads repair.");
      // TODO this should still be fine, the user can re-run verify manually later.
      // TODO we should display this somehow.
    }
    //TODO decide if we want to delete metadata here
  }

  void _migrateImages() {
    final downloadedItemsBox = Hive.box<DownloadedSong>("DownloadedItems");
    final downloadedParentsBox =
        Hive.box<DownloadedParent>("DownloadedParents");
    final downloadedImagesBox = Hive.box<DownloadedImage>("DownloadedImages");

    List<DownloadItem> nodes = [];

    for (final image in downloadedImagesBox.values) {
      BaseItemDto baseItem;
      var hiveSong = downloadedItemsBox.get(image.requiredBy.first);
      if (hiveSong != null) {
        baseItem = hiveSong.song;
      } else {
        var hiveParent = downloadedParentsBox.get(image.requiredBy.first);
        if (hiveParent != null) {
          baseItem = hiveParent.item;
        } else {
          _downloadsLogger.severe(
              "Could not find item associated with image during migration to isar.");
          continue;
        }
      }

      var isarItem =
          DownloadStub.fromItem(type: DownloadItemType.image, item: baseItem)
              .asItem(image.downloadLocationId);
      isarItem.path = (image.downloadLocationId ==
              FinampSettingsHelper.finampSettings.downloadLocationsMap.values
                  .where((element) =>
                      element.baseDirectory ==
                      DownloadLocationType.internalDocuments)
                  .first
                  .id)
          ? path_helper.join("songs", image.path)
          : image.path;
      isarItem.state = DownloadItemState.complete;
      nodes.add(isarItem);
      downloadStatuses[DownloadItemState.complete] =
          downloadStatuses[DownloadItemState.complete]! + 1;
    }

    _isar.writeTxnSync(() {
      _isar.downloadItems.putAllSync(nodes);
    });
  }

  void _migrateSongs() {
    final downloadedItemsBox = Hive.box<DownloadedSong>("DownloadedItems");

    List<DownloadItem> nodes = [];

    for (final song in downloadedItemsBox.values) {
      var isarItem =
          DownloadStub.fromItem(type: DownloadItemType.song, item: song.song)
              .asItem(song.downloadLocationId);
      String? newPath;
      if (song.downloadLocationId == null) {
        for (MapEntry<String, DownloadLocation> entry in FinampSettingsHelper
            .finampSettings.downloadLocationsMap.entries) {
          if (song.path.contains(entry.value.currentPath)) {
            isarItem.downloadLocationId = entry.key;
            newPath =
                path_helper.relative(song.path, from: entry.value.currentPath);
            break;
          }
        }
        if (newPath == null) {
          _downloadsLogger
              .severe("Could not find ${song.path} during migration to isar.");
          continue;
        }
      } else if (song.downloadLocationId ==
          FinampSettingsHelper.finampSettings.downloadLocationsMap.values
              .where((element) =>
                  element.baseDirectory ==
                  DownloadLocationType.internalDocuments)
              .first
              .id) {
        newPath = path_helper.join("songs", song.path);
      } else {
        newPath = song.path;
      }
      isarItem.path = newPath;
      isarItem.mediaSourceInfo = song.mediaSourceInfo;
      isarItem.state = DownloadItemState.complete;
      isarItem.viewId = song.viewId;
      nodes.add(isarItem);
      downloadStatuses[DownloadItemState.complete] =
          downloadStatuses[DownloadItemState.complete]! + 1;
    }

    _isar.writeTxnSync(() {
      _isar.downloadItems.putAllSync(nodes);
      for (var node in nodes) {
        if (node.baseItem?.blurHash != null) {
          var image = _isar.downloadItems.getSync(DownloadStub.getHash(
              node.baseItem!.blurHash!, DownloadItemType.image));
          if (image != null) {
            node.requires.updateSync(link: [image]);
          }
        }
      }
    });
  }

  void _migrateParents() {
    final downloadedParentsBox =
        Hive.box<DownloadedParent>("DownloadedParents");
    final downloadedItemsBox = Hive.box<DownloadedSong>("DownloadedItems");

    for (final parent in downloadedParentsBox.values) {
      var songId = parent.downloadedChildren.values.firstOrNull?.id;
      if (songId == null) {
        _downloadsLogger.severe(
            "Could not find item associated with parent during migration to isar.");
        continue;
      }
      var song = downloadedItemsBox.get(songId);
      if (song == null) {
        _downloadsLogger.severe(
            "Could not find item associated with parent during migration to isar.");
        continue;
      }
      var isarItem = DownloadStub.fromItem(
              type: DownloadItemType.collection, item: parent.item)
          .asItem(song.downloadLocationId);
      List<DownloadItem> required = parent.downloadedChildren.values
          .map((e) =>
              DownloadStub.fromItem(type: DownloadItemType.song, item: e)
                  .asItem(song.downloadLocationId))
          .toList();
      isarItem.orderedChildren = required.map((e) => e.isarId).toList();
      required.add(
          DownloadStub.fromItem(type: DownloadItemType.image, item: parent.item)
              .asItem(song.downloadLocationId));
      isarItem.state = DownloadItemState.complete;
      isarItem.viewId = parent.viewId;

      _isar.writeTxnSync(() {
        _isar.downloadItems.putSync(isarItem);
        var anchorItem = _anchor.asItem(null);
        _isar.downloadItems.putSync(anchorItem);
        anchorItem.requires.updateSync(link: [isarItem]);
        var existing = _isar.downloadItems
            .getAllSync(required.map((e) => e.isarId).toList());
        _isar.downloadItems
            .putAllSync(required.toSet().difference(existing.toSet()).toList());
        isarItem.requires.addAll(required);
        isarItem.requires.saveSync();
        isarItem.info.addAll(required);
        isarItem.info.saveSync();
      });
    }
  }

  // These are used to show items on downloads screen
  Future<List<DownloadStub>> getUserDownloaded() => getVisibleChildren(_anchor);
  Future<List<DownloadStub>> getVisibleChildren(DownloadStub stub) {
    return _isar.downloadItems
        .where()
        .typeNotEqualTo(DownloadItemType.image)
        .filter()
        .requiredBy((q) => q.isarIdEqualTo(stub.isarId))
        .findAll();
  }

  // This is for album/playlist screen
  Future<List<BaseItemDto>> getCollectionSongs(BaseItemDto item,
      {bool playable = true}) async {
    var stub =
        DownloadStub.fromItem(type: DownloadItemType.collection, item: item);
    assert(stub.baseItemType == BaseItemDtoType.playlist ||
        stub.baseItemType == BaseItemDtoType.album);

    var id = DownloadStub.getHash(item.id, DownloadItemType.collection);
    var query = _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.song)
        .filter()
        .infoFor((q) => q.isarIdEqualTo(id))
        .optional(playable, (q) => q.stateEqualTo(DownloadItemState.complete));

    if (BaseItemDtoType.fromItem(item) == BaseItemDtoType.playlist) {
      List<DownloadItem> playlist = await query.findAll();
      var canonItem = await _isar.downloadItems.get(stub.isarId);
      if (canonItem?.orderedChildren == null) {
        return playlist.map((e) => e.baseItem).whereNotNull().toList();
      } else {
        Map<int, DownloadItem> childMap =
            Map.fromIterable(playlist, key: (e) => e.isarId);
        return canonItem!.orderedChildren!
            .map((e) => childMap[e]?.baseItem)
            .whereNotNull()
            .toList();
      }
    } else {
      var items = await query
          .sortByParentIndexNumber()
          .thenByBaseIndexNumber()
          .thenByName()
          .findAll();
      return items.map((e) => e.baseItem).whereNotNull().toList();
    }
  }

  // TODO allow paging in songs tab somehow?
  // This is for music screen songs tab and artists/genre screen
  Future<List<DownloadStub>> getAllSongs(
      {String? nameFilter, BaseItemDto? relatedTo, String? viewFilter}) {
    return _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.song)
        .filter()
        .stateEqualTo(DownloadItemState.complete)
        .optional(nameFilter != null,
            (q) => q.nameContains(nameFilter!, caseSensitive: false))
        .optional(
            relatedTo != null,
            (q) => q.info((q) => q.isarIdEqualTo(DownloadStub.getHash(
                relatedTo!.id, DownloadItemType.collection))))
        .optional(viewFilter != null, (q) => q.viewIdEqualTo(viewFilter))
        .findAll();
  }

  // This is for music screen album/artist/genre tabs + artist/genre screens
  Future<List<DownloadStub>> getAllCollections(
      {String? nameFilter,
      BaseItemDtoType? baseTypeFilter,
      BaseItemDto? relatedTo,
      bool fullyDownloaded = false,
      String? viewFilter,
      String? childViewFilter}) {
    return _isar.downloadItems
        .where()
        .typeEqualTo(DownloadItemType.collection)
        .filter()
        .optional(nameFilter != null,
            (q) => q.nameContains(nameFilter!, caseSensitive: false))
        .optional(baseTypeFilter != null,
            (q) => q.baseItemTypeEqualTo(baseTypeFilter!))
        .optional(
            relatedTo != null,
            (q) => q.infoFor((q) => q.info((q) => q.isarIdEqualTo(
                DownloadStub.getHash(
                    relatedTo!.id, DownloadItemType.collection)))))
        .optional(fullyDownloaded,
            (q) => q.not().stateEqualTo(DownloadItemState.notDownloaded))
        .optional(viewFilter != null, (q) => q.viewIdEqualTo(viewFilter))
        .optional(childViewFilter != null,
            (q) => q.infoFor((q) => q.viewIdEqualTo(childViewFilter)))
        .findAll();
  }

  // This is used during queue restoration
  Future<DownloadStub?> getSongInfo({BaseItemDto? item, String? id}) {
    assert((item == null) != (id == null));
    return _getInfoByID(id ?? item!.id, DownloadItemType.song);
  }

  // This is used by song menu
  Future<DownloadStub?> getCollectionInfo({BaseItemDto? item, String? id}) {
    assert((item == null) != (id == null));
    return _getInfoByID(id ?? item!.id, DownloadItemType.collection);
  }

  Future<DownloadStub?> _getInfoByID(String id, DownloadItemType type) async {
    assert(
        type == DownloadItemType.song || type == DownloadItemType.collection);
    return _isar.downloadItems.getSync(DownloadStub.getHash(id, type));
  }

  // These are for actually playing/viewing downloaded files
  // TODO add documentation saying use info methods if possible.
  Future<DownloadItem?> getSongDownload({BaseItemDto? item, String? id}) {
    assert((item == null) != (id == null));
    return _getDownloadByID(id ?? item!.id, DownloadItemType.song);
  }

  Future<DownloadItem?> getImageDownload({BaseItemDto? item, String? id}) {
    assert((item?.blurHash == null) != (id == null));
    return _getDownloadByID(id ?? item!.blurHash!, DownloadItemType.image);
  }

  Future<DownloadItem?> _getDownloadByID(
      String id, DownloadItemType type) async {
    assert(type.hasFiles);
    var item = _isar.downloadItems.getSync(DownloadStub.getHash(id, type));
    if (item != null && await _verifyDownload(item)) {
      return item;
    }
    return null;
  }

  // this is for part of statuses in downloads screen
  Future<int> getDownloadCount(
      {DownloadItemType? type, DownloadItemState? state}) {
    return _isar.downloadItems
        .where()
        .optional(type != null, (q) => q.typeEqualTo(type!))
        .filter()
        .optional(state != null, (q) => q.stateEqualTo(state!))
        .count();
  }

  // This is for download error list
  Stream<List<DownloadStub>> getDownloadList(
      {DownloadItemType? type, DownloadItemState? state}) {
    return _isar.downloadItems
        .where()
        .optional(type != null, (q) => q.typeEqualTo(type!))
        .filter()
        .optional(state != null, (q) => q.stateEqualTo(state!))
        .watch(fireImmediately: true);
  }

  // This should only be called inside an isar write transaction
  Future<void> _updateItemStateAndPut(
      DownloadItem item, DownloadItemState newState) async {
    if (item.state == newState) {
      await _isar.downloadItems.put(item);
    } else {
      if (item.type.hasFiles) {
        downloadStatuses[item.state] = downloadStatuses[item.state]! - 1;
        downloadStatuses[newState] = downloadStatuses[newState]! + 1;
        _downloadStatusesStreamController.add(downloadStatuses);
      }
      item.state = newState;
      await _isar.downloadItems.put(item);
      Set<DownloadItem> parents = {};
      parents.addAll(await item.requiredBy.filter().findAll());
      parents.addAll(await item.infoFor.filter().findAll());
      for (var parent in parents) {
        await _syncItemState(parent);
      }
    }
  }

  // This should only be called inside an isar write transaction
  Future<void> _syncItemState(DownloadItem item) async {
    if (item.type.hasFiles) return;
    Set<DownloadItem> children = {};
    if (item.baseItemType == BaseItemDtoType.album ||
        item.baseItemType == BaseItemDtoType.playlist) {
      // Use full list of songs in info links for album/playlist
      children.addAll(await item.info.filter().findAll());
    } else {
      // Non-required artists/genres have unknown children and should never be considered downloaded.
      if (await item.requiredBy.filter().count() == 0) {
        await _updateItemStateAndPut(item, DownloadItemState.notDownloaded);
        return;
      }
      children.addAll(await item.requires.filter().findAll());
      // add dependency on image in info links
      children.addAll(await item.info.filter().findAll());
    }
    if (children
        .any((element) => element.state == DownloadItemState.notDownloaded)) {
      await _updateItemStateAndPut(item, DownloadItemState.notDownloaded);
    } else if (children
        .any((element) => element.state == DownloadItemState.failed)) {
      await _updateItemStateAndPut(item, DownloadItemState.failed);
    } else if (children
        .any((element) => element.state != DownloadItemState.complete)) {
      await _updateItemStateAndPut(item, DownloadItemState.downloading);
    } else {
      await _updateItemStateAndPut(item, DownloadItemState.complete);
    }
  }

  // This is for downloads screen
  Future<int> getFileSize(DownloadStub item) async {
    var canonItem = await _isar.downloadItems.get(item.isarId);
    if (canonItem == null) return 0;
    return _getFileSize(canonItem, []);
  }

  Future<int> _getFileSize(
      DownloadItem item, List<DownloadStub> completed) async {
    if (completed.contains(item)) {
      return 0;
    } else {
      completed.add(item);
    }
    int size = 0;
    for (var child in item.requires.toList()) {
      size += await _getFileSize(child, completed);
    }
    if (item.type == DownloadItemType.song &&
        item.state == DownloadItemState.complete) {
      size += item.mediaSourceInfo?.size ?? 0;
    }
    if (item.type == DownloadItemType.image &&
        item.downloadLocation != null &&
        item.state == DownloadItemState.complete) {
      var statSize =
          await item.file.stat().then((value) => value.size).catchError((e) {
        _downloadsLogger
            .fine("No file for image ${item.name} when calculating size.");
        return 0;
      });
      size += statSize;
    }

    return size;
  }

  // This is for getting file state of songs
  final stateProvider = StreamProvider.family
      .autoDispose<DownloadItemState, DownloadStub>((ref, stub) {
    assert(stub.type == DownloadItemType.song ||
        stub.type == DownloadItemType.collection);
    final isar = GetIt.instance<Isar>();
    return isar.downloadItems
        .watchObject(stub.isarId, fireImmediately: true)
        .map((event) => event?.state ?? DownloadItemState.notDownloaded)
        .distinct();
  });

// This is for getting requirement status of collections
  late final statusProvider = StreamProvider.family
      .autoDispose<DownloadItemStatus, (DownloadStub, int?)>((ref, record) {
    var (stub, childCount) = record;
    assert(stub.type == DownloadItemType.collection ||
        stub.type == DownloadItemType.song);
    final isar = GetIt.instance<Isar>();
    // We re-insert the anchor on every download/delete.  This triggers recalculation.
    return isar.downloadItems
        .watchObject(_anchor.isarId, fireImmediately: true)
        .map((event) {
      return getStatus(stub, childCount);
    }).distinct();
  });

  DownloadItemStatus getStatus(DownloadStub stub, int? children) {
    assert(stub.type == DownloadItemType.collection ||
        stub.type == DownloadItemType.song);
    var item = _isar.downloadItems
        .where()
        .isarIdEqualTo(stub.isarId)
        .findAllSync()
        .firstOrNull;
    if (item == null) return DownloadItemStatus.notNeeded;
    item.requiredBy.loadSync();
    if (item.requiredBy.filter().countSync() == 0) {
      return DownloadItemStatus.notNeeded;
    }
    var outdated = (children != null &&
            item.requires
                    .filter()
                    .not()
                    .typeEqualTo(DownloadItemType.image)
                    .countSync() !=
                children) ||
        item.state == DownloadItemState.failed ||
        item.state == DownloadItemState.notDownloaded;
    if (item.requiredBy.toList().contains(_anchor)) {
      return outdated
          ? DownloadItemStatus.requiredOutdated
          : DownloadItemStatus.required;
    } else {
      return outdated
          ? DownloadItemStatus.incidentalOutdated
          : DownloadItemStatus.incidental;
    }
  }
}
