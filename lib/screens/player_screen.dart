import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:balanced_text/balanced_text.dart';
import 'package:finamp/color_schemes.g.dart';
import 'package:finamp/components/AlbumScreen/song_menu.dart';
import 'package:finamp/components/Buttons/simple_button.dart';
import 'package:finamp/components/PlayerScreen/player_screen_appbar_title.dart';
import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/screens/lyrics_screen.dart';
import 'package:finamp/services/current_track_metadata_provider.dart';
import 'package:finamp/services/feedback_helper.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';
import 'package:flutter_vibrate/flutter_vibrate.dart';
import 'package:get_it/get_it.dart';
import 'package:simple_gesture_detector/simple_gesture_detector.dart';

import '../components/PlayerScreen/control_area.dart';
import '../components/PlayerScreen/player_screen_album_image.dart';
import '../components/PlayerScreen/player_split_screen_scaffold.dart';
import '../components/PlayerScreen/queue_button.dart';
import '../components/PlayerScreen/queue_list.dart';
import '../components/PlayerScreen/song_name_content.dart';
import '../components/finamp_app_bar_button.dart';
import 'blurred_player_screen_background.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static const routeName = "/nowplaying";

  final double _defaultToolbarHeight = 53.0;
  final int _defaultMaxToolbarLines = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageTheme =
        ref.watch(playerScreenThemeProvider(Theme.of(context).brightness));
    final settings = ref.watch(FinampSettingsHelper.finampSettingsProvider);
    final queueService = GetIt.instance<QueueService>();

    double toolbarHeight = _defaultToolbarHeight;
    int maxToolbarLines = _defaultMaxToolbarLines;

    // If in landscape, only show 2 lines in toolbar instead of 3
    if (MediaQuery.of(context).orientation == Orientation.landscape) {
      toolbarHeight = 36.0;
      maxToolbarLines = 1;
    }

    // close the player screen if the queue is empty
    StreamSubscription<FinampQueueInfo?>? listener;
    listener = queueService.getQueueStream().listen((currentQueue) {
      if (!context.mounted) {
        listener?.cancel();
        return;
      }
      if (currentQueue == null ||
          currentQueue.currentTrack == null && context.mounted) {
        Navigator.of(context).popUntil((route) {
          return ![
            PlayerScreen.routeName,
            QueueList.routeName,
            SongMenu.routeName,
            LyricsScreen.routeName,
          ].contains(route.settings.name);
        });
      }
    });

    return AnimatedTheme(
      duration: getThemeTransitionDuration(context),
      data: ThemeData(
        colorScheme: imageTheme.copyWith(
          brightness: Theme.of(context).brightness,
        ),
        iconTheme: Theme.of(context).iconTheme.copyWith(
              color: imageTheme.primary,
            ),
      ),
      child: StreamBuilder<FinampQueueInfo?>(
          stream: queueService.getQueueStream(),
          initialData: queueService.getQueue(),
          builder: (context, snapshot) {
            if (snapshot.hasData &&
                snapshot.data!.saveState == SavedQueueState.loading) {
              return buildLoadingScreen(context, null);
            } else if (snapshot.hasData &&
                snapshot.data!.saveState == SavedQueueState.failed) {
              return buildLoadingScreen(context, queueService.retryQueueLoad);
            } else if (snapshot.hasData &&
                snapshot.data!.currentTrack != null) {
              return _PlayerScreenContent(
                  airplayTheme: imageTheme.primary,
                  toolbarHeight: toolbarHeight,
                  maxToolbarLines: maxToolbarLines,
                  playerScreen: this);
            } else {
              return const SizedBox.shrink();
            }
          }),
    );
  }

  Widget buildLoadingScreen(BuildContext context, Function()? retryCallback) {
    double imageSize = min(MediaQuery.of(context).size.width,
            MediaQuery.of(context).size.height) /
        2;

    return SimpleGestureDetector(
      onTap: retryCallback,
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
            Theme.of(context).brightness == Brightness.dark
                ? IconTheme.of(context).color!.withOpacity(0.35)
                : IconTheme.of(context).color!.withOpacity(0.5),
            Theme.of(context).brightness == Brightness.dark
                ? Colors.black
                : Colors.white),
        // Required for sleep timer input
        resizeToAvoidBottomInset: false,
        extendBodyBehindAppBar: true,
        body: SafeArea(
          minimum: EdgeInsets.only(top: _defaultToolbarHeight),
          child: SizedBox.expand(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Spacer(),
                  (retryCallback != null)
                      ? Icon(
                          Icons.refresh,
                          size: imageSize,
                        )
                      : SizedBox(
                          width: imageSize,
                          height: imageSize,
                          child: const CircularProgressIndicator.adaptive()),
                  const Spacer(),
                  BalancedText(
                      (retryCallback != null)
                          ? AppLocalizations.of(context)!.queueRetryMessage
                          : AppLocalizations.of(context)!.queueLoadingMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        height: 26 / 20,
                      )),
                  const Spacer(flex: 2),
                ]),
          ),
        ),
      ),
    );
  }
}

class _PlayerScreenContent extends ConsumerWidget {
  const _PlayerScreenContent(
      {super.key,
      required this.airplayTheme,
      required this.toolbarHeight,
      required this.maxToolbarLines,
      required this.playerScreen});

  final Color airplayTheme;
  final double toolbarHeight;
  final int maxToolbarLines;
  final Widget playerScreen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var controller = PlayerHideableController();

    final metadata = ref.watch(currentTrackMetadataProvider).unwrapPrevious();

    final isLyricsLoading = metadata.isLoading || metadata.isRefreshing;
    final isLyricsAvailable = (metadata.valueOrNull?.hasLyrics ?? false) &&
        (metadata.valueOrNull?.lyrics != null || metadata.isLoading) &&
        !metadata.hasError;

    return SimpleGestureDetector(
      onVerticalSwipe: (direction) {
        if (direction == SwipeDirection.down) {
          if (!FinampSettingsHelper.finampSettings.disableGesture) {
            Navigator.of(context).pop();
          }
        } else if (direction == SwipeDirection.up) {
          // This should never actually be called until widget finishes build and controller is initialized
          if (!FinampSettingsHelper.finampSettings.disableGesture ||
              !controller.shouldShow(PlayerHideable.queueButton)) {
            showQueueBottomSheet(context);
          }
        }
      },
      onHorizontalSwipe: (direction) {
        if (direction == SwipeDirection.left && isLyricsAvailable) {
          if (!FinampSettingsHelper.finampSettings.disableGesture) {
            Navigator.of(context).push(_buildSlideRouteTransition(
                playerScreen, const LyricsScreen(),
                routeSettings:
                    const RouteSettings(name: LyricsScreen.routeName)));
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation:
              0.0, // disable tint/shadow when content is scrolled under the app bar
          centerTitle: true,
          toolbarHeight: toolbarHeight,
          title: PlayerScreenAppBarTitle(
            maxLines: maxToolbarLines,
          ),
          leading: usingPlayerSplitScreen
              ? null
              : FinampAppBarButton(
                  onPressed: () => Navigator.of(context).pop(),
                ),
          actions: [
            if (Platform.isIOS)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 1000),
                  switchOutCurve: const Threshold(0.0),
                  child: AirPlayRoutePickerView(
                    key: ValueKey(airplayTheme),
                    tintColor: airplayTheme,
                    activeTintColor: jellyfinBlueColor,
                    onShowPickerView: () =>
                        FeedbackHelper.feedback(FeedbackType.selection),
                  ),
                ),
              ),
          ],
        ),
        // Required for sleep timer input
        resizeToAvoidBottomInset: false, extendBodyBehindAppBar: true,
        body: Stack(
          children: [
            if (FinampSettingsHelper.finampSettings.useCoverAsBackground)
              const BlurredPlayerScreenBackground(),
            SafeArea(
              minimum: EdgeInsets.only(top: toolbarHeight),
              child: LayoutBuilder(builder: (context, constraints) {
                if (MediaQuery.of(context).orientation ==
                    Orientation.landscape) {
                  controller.updateLayoutLandscape(
                      Size(constraints.maxWidth, constraints.maxHeight));
                  return Row(
                    children: [
                      Expanded(
                        child: Padding(
                            padding:
                                EdgeInsets.all(constraints.maxHeight * 0.03),
                            child: const PlayerScreenAlbumImage()),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                            maxWidth: controller.getTarget().width),
                        child: Column(
                          children: [
                            const Spacer(flex: 4),
                            SongNameContent(controller),
                            const Spacer(flex: 4),
                            ControlArea(controller),
                            if (controller
                                .shouldShow(PlayerHideable.queueButton))
                              const Spacer(flex: 10),
                            if (controller
                                .shouldShow(PlayerHideable.queueButton))
                              _buildBottomActions(context, controller),
                            const Spacer(
                              flex: 4,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                } else {
                  controller.updateLayoutPortrait(
                      Size(constraints.maxWidth, constraints.maxHeight));
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SizedBox(
                          height: min(
                              constraints.maxHeight -
                                  controller.getTarget().height,
                              constraints.maxWidth),
                          width: constraints.maxWidth,
                          child: const PlayerScreenAlbumImage()),
                      SongNameContent(controller),
                      ControlArea(controller),
                      if (controller.shouldShow(PlayerHideable.queueButton))
                        _buildBottomActions(
                          context,
                          controller,
                          isLyricsLoading: isLyricsLoading,
                          isLyricsAvailable: isLyricsAvailable,
                        ),
                      if (!controller.shouldShow(PlayerHideable.queueButton))
                        const SizedBox(
                          height: 5,
                        )
                    ],
                  );
                }
              }),
            ),
          ],
        ),
      ),
    );
  }

  // This causes the source widget to blink if it does not have a key set.
  PageRouteBuilder _buildSlideRouteTransition(
    Widget sourceWidget,
    Widget targetWidget, {
    RouteSettings? routeSettings,
  }) {
    return PageRouteBuilder(
      settings: routeSettings,
      pageBuilder: (context, animation, secondaryAnimation) => targetWidget,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        const curve = Curves.ease;
        const beginEnter = Offset(1.0, 0.0);
        const endEnter = Offset.zero;
        const beginExit = Offset(0.0, 0.0);
        const endExit = Offset(-1.0, 0.0);

        final tweenEnter = Tween(begin: beginEnter, end: endEnter);
        final tweenExit = Tween(begin: beginExit, end: endExit);
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: curve.flipped,
        );

        return Stack(
          children: [
            SlideTransition(
              position: tweenExit.animate(curvedAnimation),
              child: sourceWidget,
            ),
            SlideTransition(
              position: tweenEnter.animate(curvedAnimation),
              child: child,
            ),
          ],
        );
      },
    );
  }

  Widget _buildBottomActions(
    BuildContext context,
    PlayerHideableController controller, {
    bool isLyricsLoading = true,
    bool isLyricsAvailable = false,
  }) {
    IconData getLyricsIcon() {
      if (!isLyricsLoading && !isLyricsAvailable) {
        return TablerIcons.microphone_2_off;
      } else {
        return TablerIcons.microphone_2;
      }
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Spacer(
          flex: 1,
        ),
        Expanded(
            flex: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const SizedBox(
                  width: 80,
                  // child: Text("Output")
                  child: SizedBox.shrink(),
                ),
                const SizedBox(width: 80, child: QueueButton()),
                SizedBox(
                  width: 80,
                  child: SimpleButton(
                    inactive: !isLyricsAvailable,
                    text: "Lyrics",
                    icon: getLyricsIcon(),
                    onPressed: () {
                      Navigator.of(context).push(_buildSlideRouteTransition(
                          playerScreen, const LyricsScreen(),
                          routeSettings: const RouteSettings(
                              name: LyricsScreen.routeName)));
                    },
                  ),
                ),
              ],
            )),
        const Spacer(
          flex: 1,
        ),
      ],
    );
  }
}

enum PlayerHideable {
  bigPlayButton(14, 14, 1),
  queueButton(0, 27, 2),
  progressSlider(0, 14, 4),
  twoLineTitle(0, 27, 3),
  codecInfo(0, 20, 3),
  loopShuffleButtons(96, 0, 0),
  unhideableElements(144, 162, 0),
  controlsPaddingSmall(0, 8, 2),
  controlsPaddingBig(0, 12, 1);

  // The width/height added to the overall player screen when this item is shown.
  // Calculated by shrinking player screen control area until overflow both with
  // element shown and with element hidden, and then comparing those values.  These
  // are added together to predict the size of a player screen layout before it actually
  // gets built.
  final double width;
  final double height;

  // The maximum amount to shrink the cover image, per side, in order to show this element.
  // Needs to be multiplied by finampSettings.prioritizeCoverFactor.
  final double maxShrink;

  const PlayerHideable(this.width, this.height, this.maxShrink);
}

/// Controls what elements of the player screen are shown/hidden.
class PlayerHideableController {
  final verticalHideOrder = [
    PlayerHideable.controlsPaddingBig,
    PlayerHideable.bigPlayButton,
    PlayerHideable.queueButton,
    PlayerHideable.controlsPaddingSmall,
    PlayerHideable.codecInfo,
    PlayerHideable.twoLineTitle,
    PlayerHideable.progressSlider
  ];

  List<PlayerHideable> _visible = [];
  Size _target = const Size(0, 0);

  /// Update player screen hidden elements based on usable area in portrait mode.
  void updateLayoutPortrait(Size size) {
    _reset();
    var minAlbumPadding =
        FinampSettingsHelper.finampSettings.playerScreenCoverMinimumPadding;

    var targetWidth = size.width;
    _updateLayoutFromWidth(targetWidth);

    // Update _visible based on a target height.  Removes elements in order of priority
    // until target is met.
    for (var element in verticalHideOrder) {
      // Allow shrinking album by up to (element.maxShrink)% of screen width per side beyond the user specified minimum value
      // if it allows us to show more controls.
      var maxDesiredPadding = minAlbumPadding +
          element.maxShrink *
              FinampSettingsHelper.finampSettings.prioritizeCoverFactor;
      // Calculate max allowable control height to avoid shrinking album cover beyond maxPadding.
      var targetHeight =
          size.height - size.width * (1 - (maxDesiredPadding / 100.0) * 2);
      if (_getSize().height < targetHeight) {
        break;
      }
      _visible.remove(element);
    }
    var desiredHeight =
        size.height - size.width * (1 - (minAlbumPadding / 100.0) * 2);
    _target = Size(targetWidth, max(_getSize().height, desiredHeight));
  }

  /// Update player screen hidden elements based on usable area in landscape mode.
  void updateLayoutLandscape(Size size) {
    _reset();
    // We never want to allocate extra width to album covers while some controls
    // are hidden.
    var desiredControlsWidth =
        min(max(_getSize().width, size.width / 2), size.width - size.height);

    // Never expand the controls beyond 65% unless the remaining space is just album padding
    var widthPercent =
        FinampSettingsHelper.finampSettings.prioritizeCoverFactor * 2 + 49;
    var maxControlsWidth =
        max(size.width * (widthPercent / 100), size.width - size.height);
    _updateLayoutFromWidth(maxControlsWidth);

    var targetHeight = size.height;
    // Prevent allocating extra space between 50% and maxControlsWidth if we're just
    // going to shrink the play button anyway.
    if (_getSize().height >= targetHeight) {
      _visible.remove(PlayerHideable.bigPlayButton);
    }
    // Force controls width to always be at least 50% of screen.
    var minPercent =
        FinampSettingsHelper.finampSettings.prioritizeCoverFactor * 2 + 34;
    var minControlsWidth = max(_getSize().width, (minPercent / 100));
    // If the minimum and maximum sizes do not form a valid range, prioritize the minimum
    // and shrink the album to avoid the controls clipping.
    double targetWidth = desiredControlsWidth.clamp(
        minControlsWidth, max(minControlsWidth, maxControlsWidth));
    _target = Size(targetWidth, targetHeight);

    // Update _visible based on a target height.  Removes elements in order of priority
    // until target is met.
    for (var element in verticalHideOrder) {
      if (_getSize().height < targetHeight) {
        return;
      }
      _visible.remove(element);
    }
  }

  /// Update _visible based on a target width.  Only shrink player button if it would fit the constraints,
  /// otherwise only hide loop & shuffle buttons if that would fit the constraints, otherwise do both.
  void _updateLayoutFromWidth(double target) {
    var maxWidth = _getSize().width;
    if (maxWidth >= target) {
      if (maxWidth - PlayerHideable.bigPlayButton.width < target) {
        _visible.remove(PlayerHideable.bigPlayButton);
      } else if (maxWidth - PlayerHideable.loopShuffleButtons.width < target) {
        _visible.remove(PlayerHideable.loopShuffleButtons);
      } else {
        _visible.remove(PlayerHideable.bigPlayButton);
        _visible.remove(PlayerHideable.loopShuffleButtons);
      }
    }
  }

  /// Reset to use maximum size
  void _reset() {
    _visible = List.from(PlayerHideable.values);
    _target = const Size(0, 0);
    if (FinampSettingsHelper.finampSettings.hideQueueButton) {
      _visible.remove(PlayerHideable.queueButton);
    }
    if (FinampSettingsHelper.finampSettings.suppressPlayerPadding) {
      _visible.remove(PlayerHideable.controlsPaddingSmall);
      _visible.remove(PlayerHideable.controlsPaddingBig);
    }
  }

  /// Gets predicted size of player controls based on current _visible items.
  Size _getSize() {
    double height = 0;
    double width = 0;
    for (var element in _visible) {
      height += element.height;
      width += element.width;
    }
    return Size(width, height);
  }

  /// Get player controls target size
  Size getTarget() {
    return _target;
  }

  /// Get whether a player control element should be shown or hidden based on screen size.
  bool shouldShow(PlayerHideable element) {
    assert(_target.width > 0 && _target.height > 0);
    return _visible.contains(element);
  }
}
