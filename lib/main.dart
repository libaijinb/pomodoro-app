import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:refresh_rate/refresh_rate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 番茄钟 — Liquid Glass 版：玻璃外观全部来自 liquid_glass_widgets 1.16.1
// （GlassContainer.card / GlassButton / GlassIconButton /
// GlassSegmentedControl / GlassSwitch / GlassSlider / GlassTextField /
// GlassModalSheet），自写 BackdropFilter 玻璃、Pressable、_PhysicalPlayButton
// 的自绘圆形、_SourceSheet 已全部删除。计时每秒只刷新计时面板。
const Color kTomato = Color(0xFFFF5340);
const Color kShortBreak = Color(0xFF34C759);
const Color kLongBreak = Color(0xFF5E9BFF);

/// 主题集中定义：深色（当前这套，一字不动）与谷歌白。
/// 所有页面、卡片、浮窗、dock 都读这里，不再各自硬编码白字/深底。
/// light 时主文字 #202124、次要 #5F6368、底 #FFFFFF、次级 #F8F9FA；
/// dark 时主文字白、次要白 0.7、底 #160F2E。切换通过 notifier 让
/// CupertinoApp 重建，设置页 setState 让首页重建，浮窗打开时读当前值。
class _AppTheme {
  static bool isLight = false;
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);
  static void setLight(bool v) {
    if (isLight == v) return;
    isLight = v;
    notifier.value = v;
  }
  static Color get text => isLight ? const Color(0xFF202124) : CupertinoColors.white;
  static Color get sub => isLight ? const Color(0xFF5F6368) : CupertinoColors.white.withValues(alpha: 0.7);
  static Color get track => isLight ? const Color(0xFF000000).withValues(alpha: 0.12) : CupertinoColors.white.withValues(alpha: 0.22);
  static Color get divider => isLight ? const Color(0xFF000000).withValues(alpha: 0.08) : CupertinoColors.white.withValues(alpha: 0.15);
  static Color get scaffold => isLight ? CupertinoColors.white : const Color(0xFF160F2E);
  static List<Color> get bgGradient => isLight
      ? const [Color(0xFFFFFFFF), Color(0xFFF8F9FA), Color(0xFFF1F3F4)]
      : const [Color(0xFF1A0B33), Color(0xFF100821), Color(0xFF070716)];
  static List<Color> get cardGradient => isLight
      ? [CupertinoColors.white.withValues(alpha: 0.85), CupertinoColors.white.withValues(alpha: 0.70)]
      : [CupertinoColors.white.withValues(alpha: 0.14), CupertinoColors.white.withValues(alpha: 0.06)];
  static Color pastel(Color c) => isLight ? Color.lerp(c, CupertinoColors.white, 0.45)! : c;
  static double blob(double a) => isLight ? a * 0.42 : a;
  static Color get lensBorder => isLight ? const Color(0xFF000000).withValues(alpha: 0.12) : CupertinoColors.white.withValues(alpha: 0.45);
}


enum Phase { focus, shortBreak, longBreak }

extension PhaseInfo on Phase {
  String get label {
    switch (this) {
      case Phase.focus:
        return '专注中';
      case Phase.shortBreak:
        return '短休息';
      case Phase.longBreak:
        return '长休息';
    }
  }

  String get nextLabel {
    switch (this) {
      case Phase.focus:
        return '专注';
      case Phase.shortBreak:
        return '短休息';
      case Phase.longBreak:
        return '长休息';
    }
  }

  Color get color {
    switch (this) {
      case Phase.focus:
        return kTomato;
      case Phase.shortBreak:
        return kShortBreak;
      case Phase.longBreak:
        return kLongBreak;
    }
  }

  /// 每阶段的动态背景配色:专注是番茄红/珊瑚/琥珀,短休息是薄荷绿,
  /// 长休息是蓝紫。背景圆点随阶段整体变色,这就是“动态”玻璃的底色。
  List<Color> get palette {
    switch (this) {
      case Phase.focus:
        return const [Color(0xFFFF5340), Color(0xFFFF8A5C), Color(0xFFFFB347), Color(0xFFFF5C8A)];
      case Phase.shortBreak:
        return const [Color(0xFF34C759), Color(0xFF5EEAD4), Color(0xFFA3E635), Color(0xFF22D3EE)];
      case Phase.longBreak:
        return const [Color(0xFF5E9BFF), Color(0xFF8B5CF6), Color(0xFF22D3EE), Color(0xFF818CF8)];
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();
  runApp(LiquidGlassWidgets.wrap(
    adaptiveQuality: true,
    theme: GlassThemeData.simple(blur: 6, thickness: 24, quality: GlassQuality.standard, lightIntensity: 0.7, saturation: 1.4),
    child: const PomodoroApp(),
  ));
  // 高刷(Dart 层):refresh_rate 2.0.1 的 enable() 会向 Android 系统提交最高
  // 刷新率偏好(preferredDisplayModeId 机制)。注意:它只是“请求”,最终速率由
  // 系统决定——省电/发热/静止时 LTPO 会降频,这是 Android 的正常机制;有动画
  // 或触摸时系统才会把 vsync 拉到 120Hz。原生层 MainActivity.onResume 里
  // 还有一层同样的窗口模式请求,两者互为保障。iOS 侧无需 Dart 设置:
  // Info.plist 已有 CADisableMinimumFrameDurationOnPhone=true,ProMotion
  // 机型本来就能到 120Hz。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (Platform.isAndroid) {
      try {
        await RefreshRate.enable();
      } catch (_) {}
    }
  });
}

class PomodoroApp extends StatefulWidget {
  const PomodoroApp({super.key});
  @override
  State<PomodoroApp> createState() => _PomodoroAppState();
}
class _PomodoroAppState extends State<PomodoroApp> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _AppTheme.notifier,
      builder: (context, light, _) {
        return CupertinoApp(
          debugShowCheckedModeBanner: false,
          title: '番茄钟',
          theme: CupertinoThemeData(
            brightness: light ? Brightness.light : Brightness.dark,
            primaryColor: kTomato,
            scaffoldBackgroundColor: _AppTheme.scaffold,
            textTheme: CupertinoTextThemeData(
              textStyle: TextStyle(color: _AppTheme.text),
              navTitleTextStyle: TextStyle(color: _AppTheme.text, fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          initialRoute: '/',
          onGenerateRoute: (settings) => _MorphPageRoute(builder: (_) => const PomodoroHomePage()),
        );
      },
    );
  }
}

class Settings {
  int focusMinutes;
  int shortBreakMinutes;
  int longBreakMinutes;
  Settings({this.focusMinutes = 25, this.shortBreakMinutes = 5, this.longBreakMinutes = 15});
  int minutesFor(Phase p) {
    switch (p) {
      case Phase.focus:
        return focusMinutes;
      case Phase.shortBreak:
        return shortBreakMinutes;
      case Phase.longBreak:
        return longBreakMinutes;
    }
  }
}

/// 自写 Glass / GlassLite 已删除：下面两个类只是参数翻译薄层，渲染
/// 100% 来自 liquid_glass_widgets，不再自绘 BackdropFilter、渐变填充、
/// 渐变边框、顶部高光或 Stack 内层——之前截图里的直角内层矩形正是
/// 自写内层画出来的，换成包组件后由包的 shape 裁剪保证圆角。
/// _LiquidGlassCard = 包的玻璃卡（计时主卡、dock 外壳）；
/// _LiquidCard = 原来是包的 solid 卡（深色不透明 #1C1C1E、不采样背景，
/// 正是它把背景光斑整张挡住的原因），现按用户要求一律改成玻璃卡，
/// 让光斑透过所有卡片——刻意偏离包的 iOS 列表惯例（包建议列表用 solid）。
class _LiquidGlassCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  const _LiquidGlassCard({super.key, required this.child, this.radius = 24, this.padding});
  @override
  Widget build(BuildContext context) {
    // 焦点卡（计时主卡、dock 外壳）保留包的标准玻璃，但包进 RepaintBoundary：
    // 背景光斑平时不动时，这层会被缓存复用，不再每帧重算折射。
    return RepaintBoundary(
      child: GlassContainer.card(
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        padding: padding ?? const EdgeInsets.all(16),
        quality: GlassQuality.standard,
        child: child,
      ),
    );
  }
}

class _LiquidCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  const _LiquidCard({super.key, required this.child, this.radius = 24, this.padding});
  @override
  Widget build(BuildContext context) {
    // 静态玻璃（性能核心）：次要/列表卡一律不走实时 shader、不走 BackdropFilter。
    // 只留一层：ClipRRect 裁剪 + 半透明渐变填充，内容直接贴在填充上。
    // 删掉的两层（真机矩形框的来源）：
    //  1) Border.all 白 0.22 边：BoxDecoration 上没写 borderRadius，边是按
    //     直角画的，ClipRRect 只在卡片外缘把它裁圆，边线本身仍是直角矩形；
    //  2) Stack 顶部高光层：Positioned 高 40、无圆角的纯矩形容器，铺满整个
    //     内容宽度，放大截图里内容区那条带淡边的直角带子就是它（带子宽度 =
    //     内容宽度，高度约等于高光层 40pt，左边/右边/上边都是直边）。
    // 删掉后卡片里再没有任何带背景/带边的内层容器，不可能再露出矩形边。
    // 光斑仍透得出来：填充只是半透明，底下明亮的光斑会透过它显色。
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _AppTheme.cardGradient,
          ),
          border: _AppTheme.isLight ? Border.all(color: const Color(0x14000000)) : null,
          boxShadow: _AppTheme.isLight
              ? const [BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 4))]
              : null,
        ),
        child: child,
      ),
    );
  }
}

/// 全局震动开关：原来挂在 Pressable 上的静态开关，Pressable 删除后
/// 改挂在这里，首页 build 时仍同步设置里的震动开关。
class _Haptic {
  static bool enabled = true;
}

/// 卡片/行级点按手势薄层：只负责点按/长按/震动，不再画任何玻璃或
/// 缩放压暗——玻璃外观全部来自包组件，点按的可见反馈由包按钮的
/// stretch/glow 或浮窗 morph 提供。真正的按钮一律用包按钮，不走这里。
class _TapArea extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final bool pressHaptic;
  final bool strongHaptic;
  const _TapArea({super.key, required this.child, this.onPressed, this.onLongPress, this.pressHaptic = true, this.strongHaptic = false});
  void _buzz(bool strong) {
    if (!pressHaptic || !_Haptic.enabled) return;
    if (strong) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
  }
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _buzz(strongHaptic),
      onTap: onPressed,
      onLongPressStart: (_) {
        if (onLongPress == null) return;
        _buzz(true);
        onLongPress!();
      },
      child: child,
    );
  }
}

/// 包按钮 + 长按组合：liquid_glass_widgets 的 GlassButton/GlassIconButton
/// 经仓库代码核对没有 onLongPress 参数，所以长按必须由外层
/// GestureDetector 补，点按动画/拉伸/光晕全部来自包按钮本身。
class _LiquidIconBtn extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final double size;
  final Color? glowColor;
  const _LiquidIconBtn({super.key, required this.icon, this.onPressed, this.onLongPress, this.size = 56, this.glowColor});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) {
        if (onLongPress == null) return;
        if (_Haptic.enabled) HapticFeedback.mediumImpact();
        onLongPress!();
      },
      child: GlassIconButton(
        icon: icon,
        onPressed: () {
          if (_Haptic.enabled) HapticFeedback.lightImpact();
          onPressed?.call();
        },
        size: size,
        shape: GlassIconButtonShape.roundedSquare,
        borderRadius: 16,
        glowColor: glowColor,
      ),
    );
  }
}

/// 整张卡即包按钮：点按走 GlassButton.custom 的 stretch/glow，
/// 长按走外层 GestureDetector（包按钮无长按参数），卡片内容就是
/// 按钮的 child，形状用包的 LiquidRoundedSuperellipse(24)。
class _CardButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  const _CardButton({super.key, required this.child, this.onTap, this.onLongPress});
  @override
  Widget build(BuildContext context) {
    // 卡按钮不再叠一层 GlassButton shader：它里面已经包了一张静态卡，
    // 再叠一层按钮 shader 就是一张卡算两遍。点按/长按/震动走 _TapArea，
    // 真正的按钮（开始键、图标键、阶段分段）仍用包按钮，动效不受影响。
    return _TapArea(
      onPressed: onTap,
      onLongPress: onLongPress,
      child: child,
    );
  }
}

/// 标签页 morph:根据 PageController 的当前页偏移,旧页缩小淡出、新页从
/// 0.96 放大淡入(离场页透明度最低 0.4),与水滴 lens 的 400ms 弹簧同步,
/// 而不是之前 0.35 透明度 + 0.05 缩放的轻微淡入。
class _PageMorph extends StatelessWidget {
  final int index;
  final PageController controller;
  final Widget child;
  const _PageMorph({required this.index, required this.controller, required this.child});
  @override
  Widget build(BuildContext context) {
    // 性能：页面子树通过 AnimatedBuilder 的 child 参数只建一次，切换动画
    // 每帧只改透明度/缩放这两个合成属性，不再每帧重建整页的玻璃卡。
    // 之前 builder 里直接用 widget.child，每帧 tick 都会重建四页。
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        double page = index.toDouble();
        if (controller.hasClients && controller.page != null) page = controller.page!;
        final delta = (index - page).abs().clamp(0.0, 1.0);
        return Opacity(
          opacity: 0.4 + 0.6 * (1 - delta),
          child: Transform.scale(scale: 0.96 + 0.04 * (1 - delta), child: child),
        );
      },
    );
  }
}

/// 统一立体按压按钮:按下 90ms easeOut 缩到 0.95 并下沉 2px、颜色压暗约 8%
/// (ColorFiltered 只改已有像素亮度,不改形状、不改布局尺寸,周围不会跳动),
/// 按下瞬间给轻震(仅 pressHaptic 为真时,受调用方震动开关控制);松开 350ms
/// 弹簧回弹。之前的 SpringButton 只有 320ms elasticOut 的 0.93 缩放 + 轻微
/// 倾斜、阴影静止,所以看起来像平面图在缩放,而不是被按下去。
/// 统一立体按压按钮(浮窗版):按下 90ms easeOut 缩到 0.92、下沉 3px、
/// 压暗约 15%,松开 350ms 弹簧弹回;缩放会连带把子组件的阴影一起
/// 缩小下移,所以阴影是同步塌下去的,不是静止的。pressHaptic 默认
/// 为真,受全局开关 globalHapticEnabled 控制(首页 build 时同步
/// 设置里的震动开关,关了全关);strongHaptic 为真时用中等强度震动
/// (开始键),其余用轻震。onLongPress 在长按识别瞬间触发并给中等
/// 强度长按反馈,点按与长按互斥(长按后不触发点按动作)。
/// 物理开始键(浮窗版):按下时阴影同步塌下去(模糊 28→8、偏移 10→3、光晕 0.55→0.25)、
/// 渐变压暗约 18%、顶部高光变弱、整体下沉 3px 缩到 0.92,松开弹簧弹回;
/// 点按用中等强度震动,长按用中等强度长按反馈并回调(长按出专注浮窗)。
/// 开始键：自绘圆形渐变 + 阴影 + 脉冲控制器已删除，改为包按钮。
/// GlassButton（prominent，阶段色 glow，LiquidOval，88×88）负责点按
/// 拉伸/光晕动画；图标切换仍用 200ms AnimatedSwitcher 淡入淡出加缩放；
/// 包按钮经仓库代码核对没有 onLongPress，所以长按出专注浮窗由外层
/// GestureDetector 补，点按中等强度震动保留。
class _PhysicalPlayButton extends StatelessWidget {
  final Color color;
  final bool running;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final bool pressHaptic;
  const _PhysicalPlayButton({required this.color, required this.running, required this.onPressed, this.onLongPress, this.pressHaptic = true});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) {
        if (onLongPress == null) return;
        if (pressHaptic && _Haptic.enabled) HapticFeedback.mediumImpact();
        onLongPress!();
      },
      child: GlassButton(
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: Tween<double>(begin: 0.8, end: 1.0).animate(animation), child: child),
          ),
          child: Icon(running ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill, key: ValueKey(running), color: CupertinoColors.white, size: 34),
        ),
        onTap: () {
          if (pressHaptic && _Haptic.enabled) HapticFeedback.mediumImpact();
          onPressed();
        },
        width: 88,
        height: 88,
        iconSize: 34,
        iconColor: CupertinoColors.white,
        style: GlassButtonStyle.prominent,
        glowColor: color,
        // 包按钮没有 backgroundColor：它的玻璃面只能折射身后内容，身后
        // 是深色底时就会发灰。按包的 LiquidGlassSettings.glassColor 给
        // 它阶段色 tint，让玻璃本身带阶段色，而不是在外面再画一个
        // 实心圆（那样就又回到自写按钮了）。
        settings: LiquidGlassSettings(glassColor: color.withValues(alpha: 0.55), thickness: 30),
      ),
    );
  }
}

/// 详情页 morph 路由:不做横向平移。进入时新页从 0.96 放大淡入(淡入区间
/// 0.15-0.55 easeOutCubic,缩放用 easeInOutCubicEmphasized,450ms,与 FlClash
/// SharedXPageTransition 的时长/曲线档位一致,但去掉 0.25 平移);被上层页盖住
/// 时本页缩小到 0.94 并变暗到 0.6,弹出时反向 morph 回来。opaque=false 才能
/// 在 morph/拖动过程中画出下层页。
class _MorphPageRoute<T> extends PageRoute<T> {
  _MorphPageRoute({required this.builder});
  final WidgetBuilder builder;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 450);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 450);
  @override
  bool get opaque => false;
  @override
  bool get maintainState => true;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => builder(context);
  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondaryAnimation]),
      builder: (_, __) {
        final enter = Curves.easeInOutCubicEmphasized.transform(animation.value);
        final fadeIn = const Interval(0.15, 0.55, curve: Curves.easeOutCubic).transform(animation.value);
        final scale = (0.96 + 0.04 * enter) * (1 - 0.06 * secondaryAnimation.value);
        final opacity = (fadeIn * (1 - 0.4 * secondaryAnimation.value)).clamp(0.0, 1.0);
        return Opacity(
          opacity: opacity,
          child: Transform.scale(scale: scale, child: _DragBack(child: child)),
        );
      },
    );
  }
}

/// 边缘拖动关闭:只有从屏幕左沿 28pt 内开始、向右拖才激活,避免与横向滑块
/// (目标滑块、音量滑块)抢手势;拖过 35% 或速度超 600pt/s 松手才关闭,
/// 没拖到就 200ms 弹回。首页不可 pop 时不激活。
class _DragBack extends StatefulWidget {
  final Widget child;
  const _DragBack({required this.child});
  @override
  State<_DragBack> createState() => _DragBackState();
}

class _DragBackState extends State<_DragBack> {
  double _drag = 0;
  bool _dragging = false;
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (d) {
        if (d.globalPosition.dx < 28 && Navigator.of(context).canPop()) {
          _active = true;
          _dragging = true;
        }
      },
      onHorizontalDragUpdate: (d) {
        if (!_active) return;
        final w = context.size?.width ?? 390.0;
        setState(() => _drag = (d.globalPosition.dx / w).clamp(0.0, 1.0));
      },
      onHorizontalDragEnd: (d) {
        if (!_active) return;
        final commit = _drag > 0.35 || d.velocity.pixelsPerSecond.dx > 600;
        _active = false;
        _dragging = false;
        if (commit) {
          Navigator.of(context).maybePop();
        } else {
          setState(() => _drag = 0);
        }
      },
      onHorizontalDragCancel: () {
        _active = false;
        _dragging = false;
        setState(() => _drag = 0);
      },
      child: AnimatedOpacity(
        opacity: 1 - 0.4 * _drag,
        duration: _dragging ? Duration.zero : const Duration(milliseconds: 200),
        child: AnimatedScale(
          scale: 1 - 0.04 * _drag,
          duration: _dragging ? Duration.zero : const Duration(milliseconds: 200),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 动态背景:深色底 + 4 个放射渐变彩色圆点,以 28 秒为周期缓慢漂移,
/// 颜色随当前阶段整体切换(带 800ms 颜色过渡)。玻璃卡片盖在它上面,
/// 模糊后就是能透出色彩的动态玻璃。
class AnimatedBackground extends StatefulWidget {
  final Phase phase;
  const AnimatedBackground({super.key, required this.phase});
  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    // 光斑平时冻结、零逐帧计算：控制器不再 75 秒循环全速跑（每帧 tick
    // 都会让上面所有玻璃重新采样背景，这是卡顿的主因之一）。只有阶段
    // 切换时 forward 一次、漂移 1.5 秒，跑完即停；平时光斑位置固定，
    // 亮度/颜色照样透过玻璃看得见。每个光点仍包 RepaintBoundary。
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  }

  @override
  void didUpdateWidget(covariant AnimatedBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _ctrl.forward(from: 0.0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.phase.palette;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value * 2 * math.pi;
          final size = MediaQuery.of(context).size;
          return Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: _AppTheme.bgGradient,
                  ),
                ),
              ),
              // 光点 1:慢速平移 + 形变缩放(0.92-1.10),视差速度 1.0。
              Transform.translate(
                offset: Offset(math.sin(t) * 30, math.cos(t * 0.7) * 36),
                child: RepaintBoundary(
                  child: Transform.scale(
                    scale: 1.0 + 0.08 * math.sin(t * 1.3),
                    child: Container(
                      width: 460,
                      height: 460,
                      margin: EdgeInsets.only(left: size.width * 0.02, top: size.height * 0.02),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [_AppTheme.pastel(colors[0]).withValues(alpha: _AppTheme.blob(0.95)), _AppTheme.pastel(colors[0]).withValues(alpha: _AppTheme.blob(0.50)), const Color(0x00000000)],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 光点 2:更慢的视差速度 0.55,位置与大小与光点 1 错开,形成前后景深。
              Transform.translate(
                offset: Offset(math.sin(t * 0.55 + 2.0) * 42, math.cos(t * 0.45 + 1.0) * 30),
                child: RepaintBoundary(
                  child: Transform.scale(
                    scale: 1.0 + 0.10 * math.sin(t * 0.8 + 1.5),
                    child: Container(
                      width: 430,
                      height: 430,
                      margin: EdgeInsets.only(left: size.width * 0.55, top: size.height * 0.55),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [_AppTheme.pastel(colors[1]).withValues(alpha: _AppTheme.blob(0.92)), _AppTheme.pastel(colors[2]).withValues(alpha: _AppTheme.blob(0.45)), const Color(0x00000000)],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 光点 3:位于计时卡正后方(顶部居中),让主卡片模糊后能透出
              // 阶段色,而不是盖在纯深色底上显得实色;边缘用放射渐变收尾,
              // 不会在卡片上沿切出硬边。
              Transform.translate(
                offset: Offset(math.sin(t * 0.4 + 4.0) * 24, math.cos(t * 0.6) * 20),
                child: RepaintBoundary(
                  child: Container(
                    width: 470,
                    height: 470,
                    margin: EdgeInsets.only(left: size.width * 0.12, top: size.height * 0.08),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [_AppTheme.pastel(colors[2]).withValues(alpha: _AppTheme.blob(0.95)), _AppTheme.pastel(colors[3]).withValues(alpha: _AppTheme.blob(0.50)), const Color(0x00000000)],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // 光点 4:左下大光斑，让滚动到下方的任务/目标/统计卡也有光可透，
              // 之前光斑只集中在顶部和右中，下方卡片后面是一片暗底。
              Transform.translate(
                offset: Offset(math.sin(t * 0.5 + 1.0) * 28, math.cos(t * 0.5) * 24),
                child: RepaintBoundary(
                  child: Container(
                    width: 420,
                    height: 420,
                    margin: EdgeInsets.only(left: size.width * 0.0, top: size.height * 0.72),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [_AppTheme.pastel(colors[1]).withValues(alpha: _AppTheme.blob(0.90)), _AppTheme.pastel(colors[1]).withValues(alpha: _AppTheme.blob(0.40)), const Color(0x00000000)],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // 光点 5:中右光斑，补滚动区中段（曲线/噪音卡一带）的空白。
              Transform.translate(
                offset: Offset(math.sin(t * 0.6 + 3.0) * 26, math.cos(t * 0.55 + 0.5) * 22),
                child: RepaintBoundary(
                  child: Container(
                    width: 390,
                    height: 390,
                    margin: EdgeInsets.only(left: size.width * 0.58, top: size.height * 0.34),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [_AppTheme.pastel(colors[3]).withValues(alpha: _AppTheme.blob(0.88)), _AppTheme.pastel(colors[3]).withValues(alpha: _AppTheme.blob(0.40)), const Color(0x00000000)],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


/// 底部水滴 dock(FlClash navigation_dock 对标,不是照搬 liquid glass):
/// 边距 21、高度 62、内边距 4、图标 28、标签 10、间距 2;选中 lens 宽度 =
/// pitch + 8(FlClash _dockLayout: pitch=(span-8)/count, lens=pitch+8, inset=4),
/// lens 中心用 pitch 数学算出,正好落在每个标签图标中心;lens 位置走 400ms
/// 回弹 0.15 的弹簧,速度越快横向拉长越多(最大 0.2 倍)、纵向按 1.4 纵横比压扁,
/// 到站后弹簧收回圆块,这就是水滴拉伸,不是固定方块平移。
/// 底部导航格子:FlClash 式 Listener 直触,而非 GestureDetector 竞技。
/// 原因:GestureDetector 的点按要进手势竞技场,反馈会晚约 100ms 的
/// kPressTimeout,且默认 deferToChild 只命中图标+文字那一小块,格子
/// 上下空白和 lens 盖住的条带点了没反应,看着就“玄学”。Listener 在
/// onPointerDown 瞬间就给反馈,不进竞技场;子 widget 撑满整个格子
/// (宽 = Expanded 格子宽,高 = 54pt,远超 44pt 触摸目标),behavior
/// opaque 让格子空白也响应;松手时只有指针仍在格子内(含 8pt 容差)
/// 才触发选择,拖出格子松手只取消,不误切。
class _DockCell extends StatefulWidget {
  final Widget child;
  final VoidCallback onSelect;
  const _DockCell({required this.child, required this.onSelect});
  @override
  State<_DockCell> createState() => _DockCellState();
}

class _DockCellState extends State<_DockCell> {
  bool _down = false;
  void _buzz() {
    if (_Haptic.enabled) HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        setState(() => _down = true);
        _buzz();
      },
      onPointerUp: (e) {
        final wasDown = _down;
        setState(() => _down = false);
        if (!wasDown) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        final local = box.globalToLocal(e.position);
        final hit = (Offset.zero & box.size).inflate(8).contains(local);
        if (hit) widget.onSelect();
      },
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedContainer(
        duration: Duration(milliseconds: _down ? 120 : 300),
        curve: _down ? Curves.easeOut : Curves.easeOutCubic,
        transformAlignment: Alignment.center,
        transform: Matrix4.identity()
          ..translate(0.0, _down ? 1.0 : 0.0)
          ..scale(_down ? 0.94 : 1.0),
        child: ColorFiltered(
          colorFilter: _down
              ? const ColorFilter.matrix(<double>[
                  0.88, 0, 0, 0, 0,
                  0, 0.88, 0, 0, 0,
                  0, 0, 0.88, 0, 0,
                  0, 0, 0, 1, 0,
                ])
              : const ColorFilter.matrix(<double>[
                  1, 0, 0, 0, 0,
                  0, 1, 0, 0, 0,
                  0, 0, 1, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
          child: SizedBox.expand(child: widget.child),
        ),
      ),
    );
  }
}

class _DropletTabBar extends StatefulWidget {
  final int selected;
  final Color phaseColor;
  final ValueChanged<int> onSelect;
  const _DropletTabBar({required this.selected, required this.phaseColor, required this.onSelect});
  @override
  State<_DropletTabBar> createState() => _DropletTabBarState();
}

class _DropletTabBarState extends State<_DropletTabBar> with SingleTickerProviderStateMixin {
  late final AnimationController _lens = AnimationController(
    vsync: this, lowerBound: -0.5, upperBound: 3.5, value: widget.selected.toDouble());
  @override
  void didUpdateWidget(covariant _DropletTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      _lens.animateWith(SpringSimulation(
        SpringDescription.withDurationAndBounce(duration: const Duration(milliseconds: 400), bounce: 0.15),
        _lens.value, widget.selected.toDouble(), 0));
    }
  }

  @override
  void dispose() {
    _lens.dispose();
    super.dispose();
  }

  double _saturate(double x) => 1 - 2 / (math.exp(2 * x) + 1);

  @override
  Widget build(BuildContext context) {
    const tabs = [
      (CupertinoIcons.timer, CupertinoIcons.timer_fill, '计时'),
      (CupertinoIcons.square_list, CupertinoIcons.square_list_fill, '任务'),
      (CupertinoIcons.chart_bar, CupertinoIcons.chart_bar_fill, '统计'),
      (CupertinoIcons.settings, CupertinoIcons.settings_solid, '设置'),
    ];
    return _LiquidGlassCard(
      radius: 24,
      child: SizedBox(
        height: 62,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final span = constraints.maxWidth;
              final pitch = (span - 8) / tabs.length;
              final lensW = pitch + 8;
              const inset = 4.0;
              final lensH = constraints.maxHeight;
              return Stack(
                children: [
                  // lens 只画不接手势:之前它在 Stack 下层、带 BoxDecoration
                  // 会命中测试,Row 格子上下 5pt 空白点的就是它,点了没反应。
                  // 注意 IgnorePointer 必须包在 Positioned 里面,包在外面会
                  // 让 Positioned 不再是 Stack 的直接子级而报错。
                  AnimatedBuilder(
                    animation: _lens,
                    builder: (_, __) {
                      final stretch = 0.2 * _saturate(_lens.velocity.abs() / 3);
                      final w = lensW * (1 + stretch);
                      final h = lensH * (1 - stretch * 1.4);
                      final left = inset + (_lens.value + 0.5) * pitch - w / 2;
                      return Positioned(
                        left: left,
                        top: (constraints.maxHeight - h) / 2,
                        width: w,
                        height: h,
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(h / 2),
                              color: _AppTheme.isLight ? _AppTheme.pastel(widget.phaseColor).withValues(alpha: 0.22) : widget.phaseColor.withValues(alpha: 0.38),
                              border: Border.all(color: _AppTheme.lensBorder),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List.generate(tabs.length, (i) {
                      final active = widget.selected == i;
                      return Expanded(
                        child: _DockCell(
                          onSelect: () => widget.onSelect(i),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              AnimatedScale(
                                scale: active ? 1.18 : 1.0,
                                duration: const Duration(milliseconds: 400),
                                curve: Curves.easeInOutCubicEmphasized,
                                child: Icon(active ? tabs[i].$2 : tabs[i].$1,
                                    color: active ? _AppTheme.text : _AppTheme.sub, size: 28),
                              ),
                              const SizedBox(height: 2),
                              Text(tabs[i].$3,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: active ? _AppTheme.text : _AppTheme.sub,
                                      fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class PomodoroHomePage extends StatefulWidget {
  const PomodoroHomePage({super.key});
  @override
  State<PomodoroHomePage> createState() => _PomodoroHomePageState();
}

class _PomodoroHomePageState extends State<PomodoroHomePage> {
  Settings _settings = Settings();
  Phase _phase = Phase.focus;
  int _remainingSeconds = 25 * 60;
  bool _isRunning = false;
  // 本阶段是否开始过:只有点过开始才为 true,切换/跳过/重置/阶段结束
  // 后都回到 false。未开始时三处状态文案一律显示“未开始”,绝不
  // 出现“已暂停/专注中”与“准备好了就按开始”互相矛盾的情况。
  bool _phaseStarted = false;
  Timer? _timer;
  int _cycleCompleted = 0;
  int _todayCompleted = 0;
  int _todayFocusSeconds = 0;
  bool _loaded = false;
  int _tab = 0;
  // 切换进行中的目标页:跨页 jump 触发的中间页 onPageChanged 会先到,
  // 必须忽略它,否则 _tab 会被中间页覆盖,lens 会先跳中间页再跳目标页。
  int? _pendingTab;
  String _task = '';
  late final TextEditingController _taskCtrl;
  bool _soundEnabled = true;
  bool _vibrationEnabled = true;
  int _dailyGoalMinutes = 120;
  List<Map<String, dynamic>> _tasks = [];
  String? _currentTaskId;
  List<Map<String, dynamic>> _historyRecords = [];
  String _noiseName = 'off';
  double _noiseVolume = 0.5;
  bool _noisePlaying = false;
  final AudioPlayer _noisePlayer = AudioPlayer();
  late final TextEditingController _newTaskCtrl;
  late final PageController _pageController;
  // 来源 morph 用:第一屏每张卡的 GlobalKey,打开浮窗时取其全局 Rect。
  final GlobalKey _timerPanelKey = GlobalKey();
  final GlobalKey _taskCardKey = GlobalKey();
  final GlobalKey _goalCardKey = GlobalKey();
  final GlobalKey _curveCardKey = GlobalKey();
  final GlobalKey _miniStatsCardKey = GlobalKey();
  final GlobalKey _noiseCardKey = GlobalKey();
  final Map<String, GlobalKey> _taskKeys = {};
  // 计时隔离:每秒只改这些 Notifier,计时面板监听它们刷新,首页 build 不会被每秒触发。
  late final ValueNotifier<int> _remainingNotifier;
  late final ValueNotifier<bool> _runningNotifier;
  late final ValueNotifier<bool> _startedNotifier;
  late final ValueNotifier<Phase> _phaseNotifier;
  late final ValueNotifier<int> _todayFocusNotifier;
  late final ValueNotifier<int> _todayCompletedNotifier;
  late final ValueNotifier<int> _cycleNotifier;
  void _syncTimerNotifiers() {
    _remainingNotifier.value = _remainingSeconds;
    _runningNotifier.value = _isRunning;
    _startedNotifier.value = _phaseStarted;
    _phaseNotifier.value = _phase;
    _todayFocusNotifier.value = _todayFocusSeconds;
    _todayCompletedNotifier.value = _todayCompleted;
    _cycleNotifier.value = _cycleCompleted;
  }
  // 最近 7 天(最旧 -> 最新):完成番茄数与专注分钟数。
  List<int> _weekCompleted = List.filled(7, 0);
  List<int> _weekFocusMin = List.filled(7, 0);
  List<DateTime> _weekDates = [];


  @override
  void initState() {
    super.initState();
    _taskCtrl = TextEditingController();
    _newTaskCtrl = TextEditingController();
    _pageController = PageController();
    _remainingNotifier = ValueNotifier<int>(25 * 60);
    _runningNotifier = ValueNotifier<bool>(false);
    _startedNotifier = ValueNotifier<bool>(false);
    _phaseNotifier = ValueNotifier<Phase>(Phase.focus);
    _todayFocusNotifier = ValueNotifier<int>(0);
    _todayCompletedNotifier = ValueNotifier<int>(0);
    _cycleNotifier = ValueNotifier<int>(0);
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _noisePlayer.dispose();
    _taskCtrl.dispose();
    _newTaskCtrl.dispose();
    _pageController.dispose();
    _remainingNotifier.dispose();
    _runningNotifier.dispose();
    _startedNotifier.dispose();
    _phaseNotifier.dispose();
    _todayFocusNotifier.dispose();
    _todayCompletedNotifier.dispose();
    _cycleNotifier.dispose();
    super.dispose();
  }

  String _dateKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  String _todayKey() => _dateKey(DateTime.now());

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now();
    final todayKey = _dateKey(today);
    final savedDate = prefs.getString('today_date') ?? '';
    final s = Settings(
      focusMinutes: prefs.getInt('focus_minutes') ?? 25,
      shortBreakMinutes: prefs.getInt('short_break_minutes') ?? 5,
      longBreakMinutes: prefs.getInt('long_break_minutes') ?? 15,
    );
    final dates = List.generate(7, (i) => today.subtract(Duration(days: 6 - i)));
    if (!mounted) return;
    setState(() {
      _settings = s;
      _todayCompleted = savedDate == todayKey ? (prefs.getInt('today_completed') ?? 0) : 0;
      _todayFocusSeconds = savedDate == todayKey ? (prefs.getInt('today_focus_seconds') ?? 0) : 0;
      _cycleCompleted = prefs.getInt('cycle_completed') ?? 0;
      if (_cycleCompleted > 4) _cycleCompleted = 0;
      _remainingSeconds = _settings.minutesFor(_phase) * 60;
      _task = prefs.getString('current_task') ?? '';
      _taskCtrl.text = _task;
      _soundEnabled = prefs.getBool('sound_enabled') ?? true;
      _vibrationEnabled = prefs.getBool('vibration_enabled') ?? true;
      _dailyGoalMinutes = prefs.getInt('daily_goal_minutes') ?? 120;
      _noiseName = prefs.getString('noise_name') ?? 'off';
      _noiseVolume = prefs.getDouble('noise_volume') ?? 0.5;
      _AppTheme.setLight(prefs.getBool('app_theme_light') ?? false);
      try {
        final tj = prefs.getString('tasks_json');
        if (tj != null) _tasks = (jsonDecode(tj) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
      _currentTaskId = prefs.getString('current_task_id');
      try {
        final hj = prefs.getString('pomodoro_history_json');
        if (hj != null) _historyRecords = (jsonDecode(hj) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (_) {}
      _weekDates = dates;
      _weekCompleted = dates.map((d) => prefs.getInt('hist_completed_${_dateKey(d)}') ?? 0).toList();
      _weekFocusMin = dates.map((d) => prefs.getInt('hist_focus_${_dateKey(d)}') ?? 0).toList();
      // 今天的历史以今日统计为准,避免旧缓存覆盖。
      if (_weekDates.isNotEmpty) {
        _weekCompleted[6] = _todayCompleted;
        _weekFocusMin[6] = (_todayFocusSeconds / 60).floor();
      }
      _loaded = true;
    });
    _syncTimerNotifiers();
    if (savedDate != todayKey) {
      await prefs.setString('today_date', todayKey);
      await prefs.setInt('today_completed', 0);
      await prefs.setInt('today_focus_seconds', 0);
    }
  }

  Future<void> _saveStats() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('today_date', _todayKey());
    await p.setInt('today_completed', _todayCompleted);
    await p.setInt('today_focus_seconds', _todayFocusSeconds);
    await p.setInt('cycle_completed', _cycleCompleted);
    await p.setInt('hist_completed_${_todayKey()}', _todayCompleted);
    await p.setInt('hist_focus_${_todayKey()}', (_todayFocusSeconds / 60).floor());
    await p.setString('current_task', _task);
    await p.setBool('sound_enabled', _soundEnabled);
    await p.setBool('vibration_enabled', _vibrationEnabled);
    await p.setInt('daily_goal_minutes', _dailyGoalMinutes);
    await p.setString('tasks_json', jsonEncode(_tasks));
    if (_currentTaskId != null) await p.setString('current_task_id', _currentTaskId!);
    await p.setString('pomodoro_history_json', jsonEncode(_historyRecords));
    await p.setString('noise_name', _noiseName);
    await p.setDouble('noise_volume', _noiseVolume);
    await p.setBool('app_theme_light', _AppTheme.isLight);
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('focus_minutes', _settings.focusMinutes);
    await p.setInt('short_break_minutes', _settings.shortBreakMinutes);
    await p.setInt('long_break_minutes', _settings.longBreakMinutes);
  }

  void _setTheme(bool light) {
    if (_AppTheme.isLight == light) return;
    setState(() { _AppTheme.setLight(light); });
    _saveStats();
  }

  void _lightTap() { if (_vibrationEnabled) HapticFeedback.lightImpact(); }
  void _selectTap() { if (_vibrationEnabled) HapticFeedback.selectionClick(); }
  // 阶段结束:两次中等震动,间隔约 180ms —— 明显、能感知,但不像单次重震那样刺耳。
  Future<void> _phaseEndFeedback() async {
    if (!_vibrationEnabled) return;
    HapticFeedback.mediumImpact();
    await Future.delayed(const Duration(milliseconds: 180));
    if (mounted && _vibrationEnabled) HapticFeedback.mediumImpact();
  }

  String _statusLabel(bool run) {
    if (run) {
      switch (_phase) {
        case Phase.focus:
          return '专注中';
        case Phase.shortBreak:
          return '短休息中';
        case Phase.longBreak:
          return '长休息中';
      }
    }
    return _phaseStarted ? '已暂停' : '未开始';
  }

  String _subtitleFor(bool run) {
    if (run) return _phase == Phase.focus ? '正在专注,别碰手机' : '正在休息,放松一下';
    if (!_phaseStarted) return '准备好了就按开始';
    return '已暂停,按开始继续';
  }

  void _startPause() {
    // 点按震动只由开始键按下时给(中等强度),这里不再补一次轻震,
    // 避免按下+松手动作两次震动叠在一起发闷。
    if (_isRunning) {
      _timer?.cancel();
      setState(() {
        _isRunning = false;
      });
      _syncTimerNotifiers();
      return;
    }
    setState(() {
      _isRunning = true;
      _phaseStarted = true;
    });
    _syncTimerNotifiers();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      // 每秒只刷新 Notifier(计时面板),不触发首页 build;每满 1 分钟才 setState
      // 一次,刷新今日目标/统计等次要区域,59/60 的秒数不再全屏重建。
      if (_phase == Phase.focus) _todayFocusSeconds += 1;
      if (_remainingSeconds > 0) _remainingSeconds -= 1;
      _syncTimerNotifiers();
      if (_remainingSeconds % 60 == 0) {
        if (mounted) setState(() {});
      }
      if (_remainingSeconds <= 0) {
        _timer?.cancel();
        _isRunning = false;
        _syncTimerNotifiers();
        _onPhaseFinished();
      }
      if (_todayFocusSeconds % 30 == 0) _saveStats();
    });
  }

  void _onPhaseFinished() {
    final finished = _phase;
    Phase next;
    String msg;
    if (finished == Phase.focus) {
      _todayCompleted += 1;
      _cycleCompleted += 1;
      if (_cycleCompleted >= 4) {
        next = Phase.longBreak;
        msg = '完成 4 个番茄,来一次长休息吧!';
      } else {
        next = Phase.shortBreak;
        msg = '专注完成,短休息一下吧!';
      }
    } else {
      if (finished == Phase.longBreak) _cycleCompleted = 0;
      next = Phase.focus;
      msg = '休息结束,开始下一个专注吧!';
    }
    if (finished == Phase.focus) {
      if (_currentTaskId != null) {
        for (final t in _tasks) {
          if (t['id'] == _currentTaskId) t['pomodoros'] = (t['pomodoros'] as int? ?? 0) + 1;
        }
      }
      _historyRecords.add({'date': _todayKey(), 'time': DateTime.now().toIso8601String(), 'task': _currentTaskTitle, 'minutes': _settings.focusMinutes});
      if (_historyRecords.length > 50) _historyRecords.removeRange(0, _historyRecords.length - 50);
    }
    if (_soundEnabled) SystemSound.play(SystemSoundType.alert);
    _phaseEndFeedback();
    _saveStats();
    setState(() {
      _phase = next;
      _remainingSeconds = _settings.minutesFor(next) * 60;
      _phaseStarted = false;
      if (_weekCompleted.isNotEmpty) {
        _weekCompleted[6] = _todayCompleted;
        _weekFocusMin[6] = (_todayFocusSeconds / 60).floor();
      }
    });
    _syncTimerNotifiers();
    if (mounted) {
      showCupertinoDialog<void>(
        context: context,
        builder: (c) => CupertinoAlertDialog(
          title: const Text('时间到'),
          content: Padding(padding: const EdgeInsets.only(top: 8), child: Text(msg)),
          actions: [
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.of(c).pop(),
              child: Text('开始${next.nextLabel}'),
            ),
          ],
        ),
      );
    }
  }

  void _reset() {
    _lightTap();
    _timer?.cancel();
    setState(() {
      _isRunning = false;
      _phaseStarted = false;
      _remainingSeconds = _settings.minutesFor(_phase) * 60;
    });
    _syncTimerNotifiers();
  }

  void _skip() {
    _selectTap();
    _timer?.cancel();
    final cur = _phase;
    Phase next;
    if (cur == Phase.focus) {
      next = _cycleCompleted >= 3 ? Phase.longBreak : Phase.shortBreak;
    } else {
      if (cur == Phase.longBreak) {
        _cycleCompleted = 0;
        _saveStats();
      }
      next = Phase.focus;
    }
    setState(() {
      _isRunning = false;
      _phaseStarted = false;
      _phase = next;
      _remainingSeconds = _settings.minutesFor(next) * 60;
    });
    _syncTimerNotifiers();
  }

  void _switchPhase(Phase p) {
    _selectTap();
    _timer?.cancel();
    setState(() {
      _isRunning = false;
      _phaseStarted = false;
      _phase = p;
      _remainingSeconds = _settings.minutesFor(p) * 60;
    });
    _syncTimerNotifiers();
  }

  void _updateSettings(Settings u) {
    setState(() {
      _settings = u;
      _remainingSeconds = _settings.minutesFor(_phase) * 60;
    });
    _saveSettings();
    _syncTimerNotifiers();
  }

  String get _currentTaskTitle {
    for (final t in _tasks) {
      if (t['id'] == _currentTaskId) return t['title'] as String? ?? '未命名任务';
    }
    return _task.isNotEmpty ? _task : '未选择任务';
  }

  Future<void> _setNoise(String name) async {
    setState(() { _noiseName = name; _noisePlaying = name != 'off'; });
    _saveStats();
    try {
      if (name == 'off') { await _noisePlayer.stop(); return; }
      await _noisePlayer.setReleaseMode(ReleaseMode.loop);
      await _noisePlayer.setVolume(_noiseVolume);
      await _noisePlayer.play(AssetSource('audio/$name.wav'));
    } catch (_) { if (mounted) setState(() => _noisePlaying = false); }
  }

  Future<void> _toggleNoisePlay() async {
    _selectTap();
    try {
      if (_noisePlaying) { await _noisePlayer.pause(); setState(() => _noisePlaying = false); }
      else if (_noiseName != 'off') { await _noisePlayer.resume(); setState(() => _noisePlaying = true); }
    } catch (_) {}
  }

  void _addTask(String title) {
    final v = title.trim();
    if (v.isEmpty) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() { _tasks.insert(0, {'id': id, 'title': v, 'done': false, 'pomodoros': 0}); _currentTaskId ??= id; });
    _saveStats();
  }

  void _toggleTaskDone(Map<String, dynamic> t) {
    _selectTap();
    setState(() => t['done'] = !(t['done'] as bool? ?? false));
    _saveStats();
  }

  void _deleteTask(Map<String, dynamic> t) {
    _selectTap();
    setState(() { _tasks.remove(t); if (_currentTaskId == t['id']) _currentTaskId = _tasks.isNotEmpty ? _tasks.first['id'] as String? : null; });
    _saveStats();
  }

  void _selectTask(Map<String, dynamic> t) {
    _selectTap();
    setState(() { _currentTaskId = t['id'] as String?; _task = t['title'] as String? ?? ''; _taskCtrl.text = _task; });
    _saveStats();
  }

  String _format(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  int get _streak {
    int streak = 0;
    // 从今天往回数:今天还没完成不中断,往前连续有完成的天数即为连续纪录。
    for (int i = _weekCompleted.length - 1; i >= 0; i--) {
      if (i == _weekCompleted.length - 1 && _weekCompleted[i] == 0) continue;
      if (_weekCompleted[i] > 0) {
        streak++;
      } else {
        break;
      }
    }
    return streak;
  }

  @override
  Widget build(BuildContext context) {
    // 按压震动总开关:设置里关了,所有点按/开始键都不震。
    _Haptic.enabled = _vibrationEnabled;
    final pc = _phase.color;
    return CupertinoPageScaffold(
      backgroundColor: _AppTheme.scaffold,
      child: Stack(
        children: [
          AnimatedBackground(phase: _phase),
          SafeArea(
            child: !_loaded
                ? Center(child: CupertinoActivityIndicator(color: _AppTheme.text))
                : PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(),
                    onPageChanged: (i) {
                      if (_pendingTab != null) {
                        if (i == _pendingTab) {
                          _pendingTab = null;
                        } else {
                          return;
                        }
                      }
                      if (_tab != i) setState(() => _tab = i);
                    },
                    children: [
                      _PageMorph(index: 0, controller: _pageController, child: _timerTab(pc)),
                      _PageMorph(index: 1, controller: _pageController, child: _tasksTab()),
                      _PageMorph(index: 2, controller: _pageController, child: _statsTab()),
                      _PageMorph(index: 3, controller: _pageController, child: _settingsTab()),
                    ],
                  ),
          ),
          // 悬浮玻璃标签栏:包在 SafeArea 里,底部留 12pt 边距 + 系统
          // 安全区,不再用 padding.bottom * 0.2 这种折半算法贴着底边;
          // 阴影因此完整落在屏内,不会被底边裁出一截深色双层感。
          Positioned(
            left: 21,
            right: 21,
            bottom: math.max(21, MediaQuery.of(context).padding.bottom),
            child: _DropletTabBar(selected: _tab, phaseColor: _phase.color, onSelect: _selectTab),
          ),
        ],
      ),
    );
  }

  void _selectTab(int i) {
    // 已选中再点:不重播页面动画,但 _DockCell 按下时已给轻震+缩放,
    // 这里再补一次 selectionClick,让“点到了”明确,而不是没反应。
    if (_vibrationEnabled) HapticFeedback.selectionClick();
    if (_tab == i) return;
    // 可打断:animateToPage 会替换掉正在进行的滚动动画,所以中途再点
    // 不会丢响应;但起点必须用控制器当前实际页位置,不能用 _tab——
    // _tab 在上一次切换开始时就已经是旧目标,中途再点按它算 jump
    // 会跳错页,这就是跨页连点时“玄学”跳页/丢响应的根因之一。
    final current = _pageController.hasClients && _pageController.page != null
        ? _pageController.page!.round()
        : _tab;
    _pendingTab = i;
    setState(() => _tab = i);
    // 跨页时先 jumpToPage 到当前页的相邻页,再 animateToPage 目标页,
    // 避免中间页被构建和绘制;400ms easeInOutCubicEmphasized,与
    // 水滴 lens 的 400ms 弹簧(bounce 0.15)同步,页面 morph 同步。
    if ((i - current).abs() > 1) {
      _pageController.jumpToPage(current + (i > current ? 1 : -1));
    }
    _pageController.animateToPage(i, duration: const Duration(milliseconds: 400), curve: Curves.easeInOutCubicEmphasized);
  }

  Widget _timerTab(Color pc) {
    final focusMinToday = (_todayFocusSeconds / 60).floor();
    // 计时区固定在顶部:标题、圆环、按钮、阶段切换不再随下方卡片
    // 一起滚出视野,用户任何时候都看得到还剩多久;只有下方
    // 任务/目标/曲线/噪音/统计卡片可以滚动。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('番茄钟', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _AppTheme.text)),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LiquidCard(
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: pc, boxShadow: [BoxShadow(color: pc.withValues(alpha: 0.8), blurRadius: 10)])),
                    const SizedBox(width: 6),
                    Text(_statusLabel(_isRunning), style: TextStyle(color: _AppTheme.text, fontSize: 13, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
                  const SizedBox(width: 8),
                  _LiquidIconBtn(icon: Icon(CupertinoIcons.ellipsis, color: _AppTheme.text, size: 18), onPressed: _showTopMenu, onLongPress: _showTopMenu, size: 36),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          ValueListenableBuilder<bool>(
            valueListenable: _runningNotifier,
            builder: (_, run, __) => Text(_subtitleFor(run), style: TextStyle(fontSize: 14, color: _AppTheme.sub)),
          ),
            ],
          ),
        ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _timerPanel(),
          ),
          const SizedBox(height: 16),
          // 阶段切换紧贴计时卡下方:滑块 pill 在三个分段间滑动形变,
          // 切换带轻触震动;颜色与圆环、开始键同用阶段色。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _PhaseSegment(
              phase: _phase,
              onSelect: _switchPhase,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 124),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
          // 任务区(合并):原来“新增任务”和“当前任务”两张全宽卡上下叠着,
          // 现合并成同一张卡——上行是当前任务,下行是新增入口,功能不变,
          // 主界面不再平铺两张任务卡。
          Hero(
            tag: 'current-task',
            child: _LiquidCard(
              key: _taskCardKey, radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(CupertinoIcons.checkmark_circle, color: _AppTheme.text, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: GestureDetector(onTap: () { _selectTap(); _openCurrentTaskDetail(); }, onLongPress: () { if (_vibrationEnabled) HapticFeedback.mediumImpact(); _openCurrentTaskDetail(); }, child: Text('当前任务: $_currentTaskTitle', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _AppTheme.text), overflow: TextOverflow.ellipsis))),
                      GlassButton.custom(onTap: _openCurrentTaskDetail, shape: const LiquidRoundedSuperellipse(borderRadius: 18), style: GlassButtonStyle.transparent, child: Text('查看详情', style: TextStyle(fontSize: 13, color: _AppTheme.text))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(height: 1, color: _AppTheme.divider),
                  const SizedBox(height: 4),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _selectTap();
                      _selectTab(1);
                    },
                    child: Row(
                      children: [
                        Icon(CupertinoIcons.add_circled, color: _AppTheme.text, size: 20),
                        SizedBox(width: 8),
                        Text('新增任务', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text)),
                        Spacer(),
                        Icon(CupertinoIcons.chevron_right, color: _AppTheme.text, size: 16),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Hero(
            tag: 'goal-card',
            child: _CardButton(
              onTap: () => _openGoalDetail(sourceKey: _goalCardKey),
              onLongPress: () => _openGoalDetail(sourceKey: _goalCardKey),
              child: _LiquidCard(
            key: _goalCardKey, radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('今日专注目标', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _AppTheme.text)), Text('$focusMinToday / $_dailyGoalMinutes 分钟', style: TextStyle(fontSize: 13, color: _AppTheme.sub))]),
                const SizedBox(height: 10),
                ClipRRect(borderRadius: BorderRadius.circular(5), child: Container(height: 10, decoration: BoxDecoration(color: _AppTheme.track), child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: (_dailyGoalMinutes == 0 ? 0 : (focusMinToday / _dailyGoalMinutes).clamp(0.0, 1.0)), child: Container(color: pc))))),
              ],
            ),
          ),
            ),
          ),
          const SizedBox(height: 12),
          _CardButton(
            onTap: () => _openStatsDetail(sourceKey: _curveCardKey),
            onLongPress: () => _openStatsDetail(sourceKey: _curveCardKey),
            child: _LiquidCard(
              key: _curveCardKey, radius: 24,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('本周专注曲线', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                      Text('${_weekFocusMin.fold<int>(0, (x, y) => x + y)} 分钟', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  RepaintBoundary(
                    child: SizedBox(
                      height: 72,
                      width: double.infinity,
                      child: CustomPaint(painter: _SparklinePainter(points: _weekFocusMin.map((e) => e.toDouble()).toList(), color: _phase.color)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('7 天前', style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
                      Text('今天', style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Hero(
            tag: 'noise-card',
            child: _CardButton(
              onTap: _openNoiseSheet,
              onLongPress: _openNoiseSheet,
              child: _LiquidCard(
                key: _noiseCardKey, radius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(CupertinoIcons.music_note, color: _AppTheme.text, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('白噪音', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                          const SizedBox(height: 2),
                          Text(_noisePlaying ? '正在播放: ${_noiseName == 'white' ? '白噪音' : _noiseName == 'rain' ? '雨声' : '篝火'}' : '点开从底部弹窗选声音', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
                        ],
                      ),
                    ),
                    Icon(CupertinoIcons.chevron_up_chevron_down, color: _AppTheme.text, size: 16),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Hero(
            tag: 'stats-card',
            child: _CardButton(
              onTap: () => _openStatsDetail(sourceKey: _miniStatsCardKey),
              onLongPress: () => _openStatsDetail(sourceKey: _miniStatsCardKey),
              child: _LiquidCard(
            key: _miniStatsCardKey, radius: 24,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            child: Row(
              children: [
                Expanded(child: _MiniStat(label: '今日专注', value: '$focusMinToday', unit: '分钟')),
                Container(width: 1, height: 40, color: _AppTheme.divider),
                Expanded(child: _MiniStat(label: '今日完成', value: '$_todayCompleted', unit: '个番茄')),
                Container(width: 1, height: 40, color: _AppTheme.divider),
                Expanded(child: _MiniStat(label: '连续纪录', value: '$_streak', unit: '天')),
              ],
            ),
          ),
                ),
              ),
            ],
          ),
        ),
          ),
      ],
    );
  }

  // ---- 来源 morph 浮窗:第一屏的组件不再单开整页,全部从来源卡片
  // morph 出底部浮窗(顶部圆角 28、拖动条、左上 X,见 GlassModalSheet)。
  Rect? _rectOf(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  // 来源浮窗统一标准（全部浮窗同一套，不许有的透、有的不透）：
  // 1) 拖动条只留包原生的那一条（showDragIndicator 默认 true，36×4，
  //    顶部 8pt）：之前这里又自写了一条 40×5，叠在包的那条下面，
  //    就是截图里“两条杠”的根因——自写那条已删，标题行上留 28pt
  //    避让包拖动条（拖动条在 8~12pt，标题从 28pt 起不重叠）。
  // 2) 档位只用 medium 玻璃档：包文档写明 large 档就是“全屏不透明”
  //    （Maps/Music 式），之前非噪音浮窗用的正是 large，才导致统计
  //    浮窗底近乎不透明深黑、和半档的白噪音完全不是一个质感。
  //    现在全部浮窗 initialState=half + detents={medium} + halfSize=
  //    fraction（其余 0.88、噪音 0.66），永远停在玻璃态，绝不转不透明。
  // 3) 进出统一 MorphSpeed.slow + morphFromRect 来源 morph；下滑跟手、
  //    松手超阈值才关、没超阈值弹回，都是包的 0.4/700/0.08 机制。
  // 4) 遮罩由包 morph 驱动的 scrim 统一控制，不再各写各的 barrier。
  void _openSheet({required GlobalKey sourceKey, required String title, required Widget child, double fraction = 0.88}) {
    final rect = _rectOf(sourceKey);
    GlassModalSheet.show(
      context: context,
      morphFromRect: rect,
      morphSpeed: MorphSpeed.slow,
      initialState: GlassSheetState.half,
      halfSize: fraction,
      detents: const {GlassSheetDetent.medium},
      builder: (sheetContext) => Column(
        children: [
          // 注意：这里不再画拖动条——包的原生拖动条已在浮窗顶部，
          // 再画一条就是截图里的“两条杠”。28pt 是给包拖动条留的空。
          const SizedBox(height: 28),
          Row(
            children: [
              _LiquidIconBtn(icon: Icon(CupertinoIcons.xmark, color: _AppTheme.text, size: 20), onPressed: () => Navigator.of(sheetContext).pop(), size: 36),
              Expanded(child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _AppTheme.text))),
              const SizedBox(width: 36),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: child),
        ],
      ),
    );
  }

  void _openFocusDetail() {
    _openSheet(
      sourceKey: _timerPanelKey,
      title: '专注详情',
      child: _FocusDetailPage(
        remainingNotifier: _remainingNotifier,
        runningNotifier: _runningNotifier,
        startedNotifier: _startedNotifier,
        phaseNotifier: _phaseNotifier,
        cycleNotifier: _cycleNotifier,
        minutesFor: (ph) => _settings.minutesFor(ph),
        onStartPause: _startPause,
        onReset: _reset,
        onSkip: _skip,
        inSheet: true,
      ),
    );
  }

  void _openTaskDetail(Map<String, dynamic> t, {GlobalKey? sourceKey, String? heroTag}) {
    _openSheet(
      sourceKey: sourceKey ?? _taskCardKey,
      title: '任务详情',
      child: _TaskDetailPage(
        task: t,
        heroTag: heroTag,
        isCurrent: _currentTaskId == t['id'],
        onToggleDone: (v) {
          if ((t['done'] as bool? ?? false) != v) _toggleTaskDone(t);
        },
        onDelete: () => _deleteTask(t),
        onSelect: () => _selectTask(t),
        inSheet: true,
      ),
    );
  }

  void _openCurrentTaskDetail() {
    Map<String, dynamic>? cur;
    for (final t in _tasks) {
      if (t['id'] == _currentTaskId) cur = t;
    }
    if (cur != null) {
      _openTaskDetail(cur, sourceKey: _taskCardKey, heroTag: 'current-task');
    } else {
      _openSheet(
        sourceKey: _taskCardKey,
        title: '选择任务',
        child: _TaskPickerPage(
          tasks: _tasks,
          currentTaskId: _currentTaskId,
          onSelect: (t) => _selectTask(t),
          inSheet: true,
        ),
      );
    }
  }

  // 白噪音浮窗:本身已是浮窗,现在统一走来源 morph(从白噪音卡展开),
  // 头部/下滑/遮罩/反向 morph 由 GlassModalSheet 提供,_NoiseSheet 只剩内容。
  void _openNoiseSheet() {
    _openSheet(
      sourceKey: _noiseCardKey,
      title: '白噪音',
      fraction: 0.66,
      child: _NoiseSheet(
        noiseName: _noiseName,
        volume: _noiseVolume,
        playing: _noisePlaying,
        vibrationEnabled: _vibrationEnabled,
        onSelect: _setNoise,
        onTogglePlay: _toggleNoisePlay,
        onVolumeChanged: _onNoiseVolumeChanged,
      ),
    );
  }

  // 右上角小菜单(FlClash +/菜单对标):淡入 + 从右上角轻微缩放出现,点遮罩收起。
  void _showTopMenu() {
    _selectTap();
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        barrierColor: CupertinoColors.black.withValues(alpha: 0.40),
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondaryAnimation) {
          return Stack(
            children: [
              Positioned(
                top: MediaQuery.of(context).padding.top + 58,
                right: 20,
                child: _TopMenuCard(
                  vibrationEnabled: _vibrationEnabled,
                  onAddTask: () {
                    Navigator.of(context).pop();
                    _selectTab(1);
                  },
                  onNoise: () {
                    Navigator.of(context).pop();
                    _openNoiseSheet();
                  },
                  onGoal: () {
                    Navigator.of(context).pop();
                    _openGoalDetail(sourceKey: _goalCardKey);
                  },
                  onReset: () {
                    Navigator.of(context).pop();
                    _updateSettings(Settings());
                    _switchPhase(Phase.focus);
                  },
                ),
              ),
            ],
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final scale = Tween<double>(begin: 0.92, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
          return FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: scale, alignment: Alignment.topRight, child: child),
          );
        },
      ),
    );
  }

  Future<void> _onNoiseVolumeChanged(double v) async {
    _noiseVolume = v;
    await _noisePlayer.setVolume(v);
    _saveStats();
  }

  void _openGoalDetail({GlobalKey? sourceKey}) {
    _openSheet(
      sourceKey: sourceKey ?? _goalCardKey,
      title: '今日目标',
      child: _GoalDetailPage(
        focusTodayMin: (_todayFocusSeconds / 60).floor(),
        goalMin: _dailyGoalMinutes,
        onGoalChanged: (v) {
          _dailyGoalMinutes = v;
          _saveStats();
        },
        inSheet: true,
      ),
    );
  }

  void _openStatsDetail({GlobalKey? sourceKey}) {
    _openSheet(
      sourceKey: sourceKey ?? _curveCardKey,
      title: '统计详情',
      child: _StatsDetailPage(
        weekCompleted: _weekCompleted,
        weekFocusMin: _weekFocusMin,
        history: _historyRecords,
        streak: _streak,
        todayCompleted: _todayCompleted,
        todayFocusMin: (_todayFocusSeconds / 60).floor(),
        inSheet: true,
      ),
    );
  }

  /// 计时面板(隔离重建的核心):只监听计时 Notifier,每秒只重建这一小块
  /// (计时环 + 圆点 + 控制按钮),背景、标签栏、任务、统计、目标卡都不动。
  /// 入场时做一次缩放 + 淡入;阶段切换时卡片圆角与环颜色做 700ms 形变过渡。
  // 计时面板（性能隔离版）：外壳只在首页 build 时建一次，玻璃卡、按钮、
  // dock 不参与每秒重建。每秒 tick 只重建下面三个小范围 builder：
  // 圆环+时间（听剩余/运行/开始过/阶段）、圆点（听组进度/阶段）、按钮行
  // （听运行/阶段）。阶段色切换不再做 700ms 颜色补间——颜色随阶段直接
  // 切换（光斑会在阶段切换时漂移 1.5 秒作过渡），换来每秒不再重建整张卡。
  Widget _timerPanel() {
    return Column(
      children: [
        _LiquidGlassCard(
          key: _timerPanelKey,
          radius: 24,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            children: [
              // 计时环不再包 Hero：首屏显示绝不依赖共享元素飞行，
              // 浮窗本身已从来源卡 morph，Hero 只会带来飞行动画
              // 卡住后源端变空白占位的一类风险。
              AnimatedBuilder(
                animation: Listenable.merge([_remainingNotifier, _runningNotifier, _startedNotifier, _phaseNotifier]),
                builder: (context, _) {
                  final rem = _remainingNotifier.value;
                  final run = _runningNotifier.value;
                  final ph = _phaseNotifier.value;
                  final total = _settings.minutesFor(ph) * 60;
                  final prog = total == 0 ? 0.0 : (rem / total);
                  return GestureDetector(
                    onTap: () { _selectTap(); _openFocusDetail(); },
                    onLongPress: () { if (_vibrationEnabled) HapticFeedback.mediumImpact(); _openFocusDetail(); },
                    child: RepaintBoundary(
                      child: _BreathingRing(
                        progress: prog,
                        color: ph.color,
                        running: run,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_format(rem), style: TextStyle(fontSize: 58, fontWeight: FontWeight.w200, color: _AppTheme.text, letterSpacing: 1)),
                            const SizedBox(height: 4),
                            Text(_statusLabel(run), style: TextStyle(fontSize: 14, color: _AppTheme.sub, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('${_settings.minutesFor(ph)} 分钟 · ${ph.nextLabel}', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: Listenable.merge([_cycleNotifier, _phaseNotifier]),
                builder: (context, _) {
                  final cycle = _cycleNotifier.value;
                  final c = _phaseNotifier.value.color;
                  return Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(4, (i) {
                          final done = i < cycle;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 450),
                            curve: Curves.easeOutCubic,
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            width: done ? 16 : 12,
                            height: done ? 16 : 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: done ? c : _AppTheme.track,
                              border: Border.all(color: _AppTheme.isLight ? const Color(0xFF000000).withValues(alpha: 0.15) : CupertinoColors.white.withValues(alpha: done ? 0.7 : 0.35)),
                              boxShadow: done ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 12)] : null,
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 4),
                      Text('本组已完成 $cycle / 4 个番茄', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        AnimatedBuilder(
          animation: Listenable.merge([_runningNotifier, _phaseNotifier]),
          builder: (context, _) {
            final run = _runningNotifier.value;
            final c = _phaseNotifier.value.color;
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _LiquidIconBtn(icon: Icon(CupertinoIcons.refresh, color: _AppTheme.text, size: 22), onPressed: _reset, onLongPress: _openFocusDetail, glowColor: c),
                const SizedBox(width: 22),
                _PhysicalPlayButton(color: c, running: run, onPressed: _startPause, onLongPress: _openFocusDetail, pressHaptic: true),
                const SizedBox(width: 22),
                _LiquidIconBtn(icon: Icon(CupertinoIcons.forward_fill, color: _AppTheme.text, size: 22), onPressed: _skip, onLongPress: _openFocusDetail, glowColor: c),
              ],
            );
          },
        ),
      ],
    );
  }


  Widget _tasksTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 124),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('任务', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _AppTheme.text)),
          const SizedBox(height: 4),
          Text('点任务设为当前任务,完成一个番茄会计入该任务', style: TextStyle(fontSize: 14, color: _AppTheme.sub)),
          const SizedBox(height: 18),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Expanded(child: CupertinoTextField(controller: _newTaskCtrl, placeholder: '新增一个学习任务,例如:背 50 个单词', placeholderStyle: TextStyle(color: _AppTheme.sub, fontSize: 14), style: TextStyle(color: _AppTheme.text, fontSize: 14), decoration: null, onSubmitted: (v) { _addTask(v); _newTaskCtrl.clear(); })),
                _LiquidIconBtn(icon: Icon(CupertinoIcons.add_circled_solid, color: _AppTheme.text, size: 26), onPressed: () { _addTask(_newTaskCtrl.text); _newTaskCtrl.clear(); }, size: 40),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_tasks.isEmpty) _LiquidCard(radius: 24, padding: EdgeInsets.all(20), child: Center(child: Text('还没有任务,先在上面加一个吧', style: TextStyle(color: _AppTheme.text)))),
          for (final t in _tasks)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Hero(
                tag: 'task-${t['id']}',
                child: _LiquidCard(
                key: _taskKeys.putIfAbsent(t['id'] as String? ?? '', () => GlobalKey()),
                radius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    _LiquidIconBtn(icon: Icon((t['done'] as bool? ?? false) ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, color: (t['done'] as bool? ?? false) ? kShortBreak : _AppTheme.text, size: 26), onPressed: () => _toggleTaskDone(t), size: 40, glowColor: kShortBreak),
                    const SizedBox(width: 8),
                    Expanded(child: GestureDetector(onTap: () { _selectTap(); _openTaskDetail(t, sourceKey: _taskKeys[t['id'] as String? ?? '']); }, onLongPress: () { if (_vibrationEnabled) HapticFeedback.mediumImpact(); _openTaskDetail(t, sourceKey: _taskKeys[t['id'] as String? ?? '']); }, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t['title'] as String? ?? '', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text, decoration: (t['done'] as bool? ?? false) ? TextDecoration.lineThrough : null)), const SizedBox(height: 2), Text('已完成 ${t['pomodoros'] ?? 0} 个番茄${_currentTaskId == t['id'] ? ' · 当前任务' : ''}', style: TextStyle(fontSize: 12, color: _AppTheme.sub))]))),
                    GlassButton.custom(onTap: () => _selectTask(t), shape: const LiquidRoundedSuperellipse(borderRadius: 18), child: Text(_currentTaskId == t['id'] ? '当前' : '设为当前', style: TextStyle(fontSize: 13, color: _AppTheme.text))),
                    const SizedBox(width: 8),
                    _LiquidIconBtn(icon: const Icon(CupertinoIcons.trash, color: Color(0xFFFF6B6B), size: 20), onPressed: () => _deleteTask(t), size: 40, glowColor: const Color(0xFFFF6B6B)),
                  ],
                ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statsTab() {
    final weekTotal = _weekCompleted.fold<int>(0, (a, b) => a + b);
    final weekFocus = _weekFocusMin.fold<int>(0, (a, b) => a + b);
    final maxDay = _weekCompleted.fold<int>(1, (a, b) => math.max(a, b));
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 124),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('统计', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _AppTheme.text)),
          const SizedBox(height: 4),
          Text('你的专注都留在了这里,全部存在本机', style: TextStyle(fontSize: 14, color: _AppTheme.sub)),
          const SizedBox(height: 16),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('今日专注目标', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.text)), Text('${(_todayFocusSeconds / 60).floor()} / $_dailyGoalMinutes 分钟', style: TextStyle(fontSize: 13, color: _AppTheme.sub))]),
                const SizedBox(height: 10),
                ClipRRect(borderRadius: BorderRadius.circular(5), child: Container(height: 10, decoration: BoxDecoration(color: _AppTheme.track), child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: (_dailyGoalMinutes == 0 ? 0 : ((_todayFocusSeconds / 60).floor() / _dailyGoalMinutes).clamp(0.0, 1.0)), child: Container(color: kShortBreak))))),
                const SizedBox(height: 6),
                Text(_todayFocusSeconds / 60 >= _dailyGoalMinutes ? '今日目标已达成,很棒!' : '再专注 ${(_dailyGoalMinutes - (_todayFocusSeconds / 60).floor()).clamp(0, 999)} 分钟就达成今日目标', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('最近番茄记录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                const SizedBox(height: 10),
                if (_historyRecords.isEmpty) Text('还没有完成的番茄,完成一个就会出现在这里', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                for (final r in _historyRecords.reversed.take(10))
                  Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [Expanded(child: Text(r['task'] as String? ?? '专注', style: TextStyle(fontSize: 14, color: _AppTheme.text), overflow: TextOverflow.ellipsis)), Text('${r['date'] ?? ''} · ${r['minutes'] ?? 25} 分钟', style: TextStyle(fontSize: 12, color: _AppTheme.sub))])),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: _LiquidCard(radius: 24, padding: const EdgeInsets.all(18), child: _BigStat(label: '本周完成', value: '$weekTotal', unit: '个番茄', color: kTomato))),
              const SizedBox(width: 12),
              Expanded(child: _LiquidCard(radius: 24, padding: const EdgeInsets.all(18), child: _BigStat(label: '本周专注', value: '$weekFocus', unit: '分钟', color: kLongBreak))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _LiquidCard(radius: 24, padding: const EdgeInsets.all(18), child: _BigStat(label: '连续纪录', value: '$_streak', unit: '天', color: kShortBreak))),
              const SizedBox(width: 12),
              Expanded(child: _LiquidCard(radius: 24, padding: const EdgeInsets.all(18), child: _BigStat(label: '今日完成', value: '$_todayCompleted', unit: '个番茄', color: const Color(0xFFFFB347)))),
            ],
          ),
          const SizedBox(height: 18),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('最近 7 天', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                const SizedBox(height: 16),
                SizedBox(
                  height: 110,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: List.generate(7, (i) {
                      final v = _weekCompleted[i];
                      final h = 16.0 + (maxDay == 0 ? 0 : (v / maxDay) * 78);
                      final isToday = i == 6;
                      return Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text('$v', style: TextStyle(fontSize: 11, color: _AppTheme.sub, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: h),
                              duration: Duration(milliseconds: 500 + i * 90),
                              curve: Curves.easeOutBack,
                              builder: (context, height, _) => Container(
                                height: height,
                                margin: const EdgeInsets.symmetric(horizontal: 5),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [isToday ? kTomato : kTomato.withValues(alpha: 0.65), kTomato.withValues(alpha: 0.25)]),
                                  border: Border.all(color: _AppTheme.isLight ? const Color(0xFF000000).withValues(alpha: 0.12) : CupertinoColors.white.withValues(alpha: 0.3)),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(weekdays[(_weekDates[i].weekday - 1) % 7], style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每日明细', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                const SizedBox(height: 12),
                for (int i = 6; i >= 0; i--)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Text('${_weekDates[i].month}月${_weekDates[i].day}日', style: TextStyle(fontSize: 14, color: _AppTheme.text)),
                        const Spacer(),
                        Text('${_weekCompleted[i]} 个番茄', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                        const SizedBox(width: 12),
                        Text('${_weekFocusMin[i]} 分钟', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 124),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设置', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _AppTheme.text)),
          const SizedBox(height: 4),
          Text('拖动滑块即可调整,设置会自动保存', style: TextStyle(fontSize: 14, color: _AppTheme.sub)),
          const SizedBox(height: 18),
          _GlassSliderCard(title: '专注时长', value: _settings.focusMinutes, min: 5, max: 60, color: kTomato, onChanged: (v) => _updateSettings(Settings(focusMinutes: v.round(), shortBreakMinutes: _settings.shortBreakMinutes, longBreakMinutes: _settings.longBreakMinutes))),
          const SizedBox(height: 12),
          _GlassSliderCard(title: '短休息时长', value: _settings.shortBreakMinutes, min: 1, max: 30, color: kShortBreak, onChanged: (v) => _updateSettings(Settings(focusMinutes: _settings.focusMinutes, shortBreakMinutes: v.round(), longBreakMinutes: _settings.longBreakMinutes))),
          const SizedBox(height: 12),
          _GlassSliderCard(title: '长休息时长', value: _settings.longBreakMinutes, min: 5, max: 30, color: kLongBreak, onChanged: (v) => _updateSettings(Settings(focusMinutes: _settings.focusMinutes, shortBreakMinutes: _settings.shortBreakMinutes, longBreakMinutes: v.round()))),
          const SizedBox(height: 12),
          _GlassSliderCard(title: '今日专注目标', value: _dailyGoalMinutes, min: 30, max: 480, color: kShortBreak, onChanged: (v) => setState(() { _dailyGoalMinutes = v.round(); _saveStats(); })),
          const SizedBox(height: 12),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('主题', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _CardButton(
                        onTap: () { _setTheme(false); },
                        child: _LiquidCard(
                          radius: 16,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: Text('深色', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.isLight ? _AppTheme.sub : _AppTheme.text))),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _CardButton(
                        onTap: () { _setTheme(true); },
                        child: _LiquidCard(
                          radius: 16,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(child: Text('谷歌白', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.isLight ? _AppTheme.text : _AppTheme.sub))),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(_AppTheme.isLight ? '当前：谷歌白，白底深字，光斑更柔和' : '当前：深色，和原来一样', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('阶段结束提示音', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text)), SizedBox(height: 2), Text('用系统提示音提醒你', style: TextStyle(fontSize: 12, color: _AppTheme.text))]),
                    GlassSwitch(value: _soundEnabled, activeColor: kShortBreak, onChanged: (v) => setState(() { _soundEnabled = v; _saveStats(); })),
                  ],
                ),
                ),
                Container(height: 1, color: _AppTheme.divider),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('震动提醒', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text)), SizedBox(height: 2), Text('开始与结束时轻震一下', style: TextStyle(fontSize: 12, color: _AppTheme.text))]),
                    GlassSwitch(value: _vibrationEnabled, activeColor: kShortBreak, onChanged: (v) { setState(() { _vibrationEnabled = v; _saveStats(); }); if (v) HapticFeedback.selectionClick(); }),
                  ],
                ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _LiquidCard(
            radius: 24,
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('默认节奏', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                SizedBox(height: 8),
                Text('专注 25 分钟 → 短休息 5 分钟\n完成 4 个番茄 → 长休息 15 分钟', style: TextStyle(fontSize: 14, color: _AppTheme.text, height: 1.6)),
                SizedBox(height: 8),
                Text('本地保存,无登录、无网络、无后端。签名密钥保留在本机项目中,供后续更新使用同一签名。', style: TextStyle(fontSize: 12, color: _AppTheme.text, height: 1.5)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _CardButton(
            onTap: () {
              _updateSettings(Settings());
              _switchPhase(Phase.focus);
            },
            child: _LiquidCard(
              radius: 20,
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: const Center(child: Text('恢复默认设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFFF6B6B)))),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  const _MiniStat({required this.label, required this.value, required this.unit});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: _AppTheme.text)),
            const SizedBox(width: 2),
            Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(unit, style: TextStyle(fontSize: 10, color: _AppTheme.sub))),
          ],
        ),
      ],
    );
  }
}

class _BigStat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  const _BigStat({required this.label, required this.value, required this.unit, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(value, style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: _AppTheme.text)),
            const SizedBox(width: 4),
            Padding(padding: const EdgeInsets.only(bottom: 5), child: Text(unit, style: TextStyle(fontSize: 12, color: _AppTheme.sub))),
          ],
        ),
        const SizedBox(height: 6),
        Container(height: 4, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: color.withValues(alpha: 0.7))),
      ],
    );
  }
}

/// 呼吸进度环:运行时辉光随正弦脉动,颜色由阶段决定。
class _BreathingRing extends StatefulWidget {
  final double progress;
  final Color color;
  final bool running;
  final Widget child;
  const _BreathingRing({required this.progress, required this.color, required this.running, required this.child});
  @override
  State<_BreathingRing> createState() => _BreathingRingState();
}

class _BreathingRingState extends State<_BreathingRing> with TickerProviderStateMixin {
  late final AnimationController _ctrl;
  // 启动提亮:从未运行切到运行时触发,600ms 内衰减到 0,让“启动”在
  // 圆环上也看得见,而不是只在按钮上。
  late final AnimationController _flash = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
  @override
  void initState() {
    super.initState();
    // 脉冲只在运行时跑：不运行时控制器是停的，AnimatedBuilder 不 tick，
    // 圆环一帧都不重绘；之前是不管跑没跑都 repeat，空转每帧重绘。
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 4));
    if (widget.running) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _BreathingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.running && widget.running) {
      _flash.forward(from: 0.0);
      _ctrl.repeat();
    } else if (oldWidget.running && !widget.running) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_ctrl, _flash]),
      builder: (context, _) {
        final pulse = widget.running ? (0.5 + 0.5 * math.sin(_ctrl.value * 2 * math.pi)) : 0.0;
        final flash = _flash.isAnimating || _flash.value > 0 ? (1.0 - _flash.value) * 0.5 : 0.0;
        return SizedBox(
          width: 230,
          height: 230,
          child: CustomPaint(
            painter: _GlassRingPainter(progress: widget.progress, color: widget.color, glow: 0.25 + pulse * 0.45 + flash),
            child: Center(child: widget.child),
          ),
        );
      },
    );
  }
}

class _GlassRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double glow;
  _GlassRingPainter({required this.progress, required this.color, required this.glow});
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 16;
    final track = Paint()
      ..color = _AppTheme.track
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, track);
    final halo = Paint()
      ..color = color.withValues(alpha: glow * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 26
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * progress.clamp(0.0, 1.0), false, halo);
    // 进度弧用阶段色渐变(阶段色 -> 阶段色提亮 35%):倒计时环在开始时
    // 是满圈阶段色,随剩余时间缩短,而不是开始时只有灰色轨道。
    final fg = Paint()
      ..shader = SweepGradient(
        colors: [color, Color.lerp(color, CupertinoColors.white, 0.35)!, color],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2, 2 * math.pi * progress.clamp(0.0, 1.0), false, fg);
  }

  @override
  bool shouldRepaint(covariant _GlassRingPainter o) => o.progress != progress || o.color != color || o.glow != glow;
}

class _GlassSliderCard extends StatelessWidget {
  final String title;
  final int value;
  final double min;
  final double max;
  final Color color;
  final ValueChanged<double> onChanged;
  const _GlassSliderCard({required this.title, required this.value, required this.min, required this.max, required this.color, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return _LiquidCard(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
              Text('$value 分钟', style: TextStyle(fontSize: 15, color: _AppTheme.text, fontWeight: FontWeight.w700)),
            ],
          ),
          GlassSlider(
            value: value.toDouble().clamp(min, max),
            min: min,
            max: max,
            divisions: (max - min).toInt(),
            activeColor: color,
            thumbColor: CupertinoColors.white,
            onChanged: onChanged,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${min.toInt()} 分钟', style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
              Text('${max.toInt()} 分钟', style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// iOS 导航式详情页:全部用 CupertinoPageRoute 从右滑入,退出左滑返回。
// 导航栏自带返回按钮;iOS 上 CupertinoPageRoute 支持侧滑返回手势,
// Android 上用系统返回键与导航栏返回按钮返回,滑入/滑出动画相同。
// 共享元素:详情页顶卡与主界面卡片用同一 Hero tag,点开/退出时卡片会
// 飞行、缩放、形变,而不是瞬间出现/消失。
// ============================================================================

String _fmtSec(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

/// 专注详情:用同一批 Notifier 驱动,主界面计时变化会实时同步到这里,
/// 不需要把计时状态复制一份;点开时计时环以 Hero 共享元素飞入。
class _FocusDetailPage extends StatelessWidget {
  final ValueNotifier<int> remainingNotifier;
  final ValueNotifier<bool> runningNotifier;
  final ValueNotifier<bool> startedNotifier;
  final ValueNotifier<Phase> phaseNotifier;
  final ValueNotifier<int> cycleNotifier;
  final int Function(Phase) minutesFor;
  final VoidCallback onStartPause;
  final VoidCallback onReset;
  final VoidCallback onSkip;
  final bool inSheet;
  const _FocusDetailPage({
    required this.remainingNotifier,
    required this.runningNotifier,
    required this.startedNotifier,
    required this.phaseNotifier,
    required this.cycleNotifier,
    required this.minutesFor,
    required this.onStartPause,
    required this.onReset,
    required this.onSkip,
    this.inSheet = false,
  });
  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      // 浮窗内页必须透明:否则 CupertinoPageScaffold 会继承主题的实心
      // scaffoldBackgroundColor(0xFF160F2E 深紫),把浮窗玻璃整块盖住。
      // 非浮窗路径传 null,保持原来的主题底色不变。
      backgroundColor: inSheet ? CupertinoColors.transparent : null,
      navigationBar: inSheet ? null : const CupertinoNavigationBar(middle: Text('专注详情'), previousPageTitle: '计时'),
      child: SafeArea(top: !inSheet, bottom: !inSheet,
        child: AnimatedBuilder(
          animation: Listenable.merge([remainingNotifier, runningNotifier, startedNotifier, phaseNotifier, cycleNotifier]),
          builder: (context, _) {
            final rem = remainingNotifier.value;
            final run = runningNotifier.value;
            final started = startedNotifier.value;
            final ph = phaseNotifier.value;
            final c = ph.color;
            final total = minutesFor(ph) * 60;
            final prog = total == 0 ? 0.0 : (rem / total);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                children: [
                  // 与首屏一致:计时环不包 Hero,详情里的环直接渲染。
                  RepaintBoundary(
                      child: _BreathingRing(
                        progress: prog,
                        color: c,
                        running: run,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_fmtSec(rem), style: TextStyle(fontSize: 58, fontWeight: FontWeight.w200, color: _AppTheme.text, letterSpacing: 1)),
                            const SizedBox(height: 4),
                            Text(run ? (ph == Phase.focus ? '专注中' : ph == Phase.shortBreak ? '短休息中' : '长休息中') : started ? '已暂停' : '未开始', style: TextStyle(fontSize: 14, color: _AppTheme.sub, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text('${minutesFor(ph)} 分钟 · ${ph.nextLabel}', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
                          ],
                        ),
                      ),
                  ),
                  const SizedBox(height: 12),
                  Text('本组已完成 ${cycleNotifier.value} / 4 个番茄', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _LiquidIconBtn(icon: Icon(CupertinoIcons.refresh, color: _AppTheme.text, size: 22), onPressed: onReset, glowColor: c),
                      const SizedBox(width: 22),
                      _PhysicalPlayButton(color: c, running: run, onPressed: onStartPause, pressHaptic: true),
                      const SizedBox(width: 22),
                      _LiquidIconBtn(icon: Icon(CupertinoIcons.forward_fill, color: _AppTheme.text, size: 22), onPressed: onSkip, glowColor: c),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('点左上角返回,计时不会中断', style: TextStyle(fontSize: 12, color: _AppTheme.text)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 任务详情:标题、番茄数、完成状态、设为当前、删除,全部在本页可操作。
class _TaskDetailPage extends StatefulWidget {
  final Map<String, dynamic> task;
  final String? heroTag;
  final bool isCurrent;
  final ValueChanged<bool> onToggleDone;
  final VoidCallback onDelete;
  final VoidCallback onSelect;
  final bool inSheet;
  const _TaskDetailPage({required this.task, this.heroTag, required this.isCurrent, required this.onToggleDone, required this.onDelete, required this.onSelect, this.inSheet = false});
  @override
  State<_TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<_TaskDetailPage> {
  late bool _done;
  late bool _isCurrent;
  @override
  void initState() {
    super.initState();
    _done = widget.task['done'] as bool? ?? false;
    _isCurrent = widget.isCurrent;
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.task['id'] as String? ?? '';
    return CupertinoPageScaffold(
      backgroundColor: widget.inSheet ? CupertinoColors.transparent : null,
      navigationBar: widget.inSheet ? null : const CupertinoNavigationBar(middle: Text('任务详情'), previousPageTitle: '返回'),
      child: SafeArea(top: !widget.inSheet, bottom: !widget.inSheet,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            // 全宽:与统计详情页同因,短标题卡若用 start 会缩到文本宽,必须 stretch。
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Hero(
                tag: widget.heroTag ?? 'task-$id',
                child: _LiquidCard(
                  radius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(widget.task['title'] as String? ?? '', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _AppTheme.text, decoration: _done ? TextDecoration.lineThrough : null)),
                      const SizedBox(height: 8),
                      Text('已完成 ${widget.task['pomodoros'] ?? 0} 个番茄${_isCurrent ? ' · 当前任务' : ''}', style: TextStyle(fontSize: 14, color: _AppTheme.sub)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _LiquidCard(
                radius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('已完成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _AppTheme.text)),
                    GlassSwitch(
                      value: _done,
                      activeColor: kShortBreak,
                      onChanged: (v) {
                        setState(() => _done = v);
                        widget.onToggleDone(v);
                        if (v) HapticFeedback.selectionClick();
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: GlassButton.custom(onTap: () { widget.onSelect(); setState(() => _isCurrent = true); }, shape: const LiquidRoundedSuperellipse(borderRadius: 24), child: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Center(child: Text(_isCurrent ? '已是当前任务' : '设为当前任务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text))))),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: GlassButton.custom(onTap: () { widget.onDelete(); Navigator.of(context).pop(); }, shape: const LiquidRoundedSuperellipse(borderRadius: 24), child: const Padding(padding: EdgeInsets.symmetric(vertical: 14), child: Center(child: Text('删除任务', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFFFF6B6B)))))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 无当前任务时点开的选择页:点一条即设为当前并返回。
class _TaskPickerPage extends StatelessWidget {
  final List<Map<String, dynamic>> tasks;
  final String? currentTaskId;
  final ValueChanged<Map<String, dynamic>> onSelect;
  final bool inSheet;
  const _TaskPickerPage({required this.tasks, required this.currentTaskId, required this.onSelect, this.inSheet = false});
  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: inSheet ? CupertinoColors.transparent : null,
      navigationBar: inSheet ? null : const CupertinoNavigationBar(middle: Text('选择任务'), previousPageTitle: '计时'),
      child: SafeArea(top: !inSheet, bottom: !inSheet,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            if (tasks.isEmpty) Text('还没有任务,先回到任务页新增一个吧', style: TextStyle(color: _AppTheme.text)),
            for (final t in tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _CardButton(
                  onTap: () {
                    onSelect(t);
                    Navigator.of(context).pop();
                  },
                  child: _LiquidCard(
                    radius: 24,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(child: Text(t['title'] as String? ?? '', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _AppTheme.text))),
                        Text(currentTaskId == t['id'] ? '当前' : '设为当前', style: TextStyle(fontSize: 13, color: _AppTheme.text)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 白噪音不再用整页详情,统一走底部弹窗 _NoiseSheet(见 _openNoiseSheet)。

/// 今日目标详情:进度、目标滑块,改动同步回主界面。
class _GoalDetailPage extends StatefulWidget {
  final int focusTodayMin;
  final int goalMin;
  final ValueChanged<int> onGoalChanged;
  final bool inSheet;
  const _GoalDetailPage({required this.focusTodayMin, required this.goalMin, required this.onGoalChanged, this.inSheet = false});
  @override
  State<_GoalDetailPage> createState() => _GoalDetailPageState();
}

class _GoalDetailPageState extends State<_GoalDetailPage> {
  late int _goal;
  @override
  void initState() {
    super.initState();
    _goal = widget.goalMin;
  }

  @override
  Widget build(BuildContext context) {
    final pct = _goal == 0 ? 0.0 : (widget.focusTodayMin / _goal).clamp(0.0, 1.0);
    return CupertinoPageScaffold(
      backgroundColor: widget.inSheet ? CupertinoColors.transparent : null,
      navigationBar: widget.inSheet ? null : const CupertinoNavigationBar(middle: Text('今日目标'), previousPageTitle: '计时'),
      child: SafeArea(top: !widget.inSheet, bottom: !widget.inSheet,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            children: [
              Hero(
                tag: 'goal-card',
                child: _LiquidCard(
                  radius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('今日专注目标', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)), Text('${widget.focusTodayMin} / $_goal 分钟', style: TextStyle(fontSize: 14, color: _AppTheme.sub))]),
                      const SizedBox(height: 12),
                      ClipRRect(borderRadius: BorderRadius.circular(6), child: Container(height: 12, decoration: BoxDecoration(color: _AppTheme.track), child: Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: pct, child: Container(color: kTomato))))),
                      const SizedBox(height: 8),
                      Text(pct >= 1.0 ? '今日目标已达成,很棒!' : '再专注 ${(_goal - widget.focusTodayMin).clamp(0, 999)} 分钟就达成今日目标', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _LiquidCard(
                radius: 24,
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('调整目标', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)), Text('$_goal 分钟', style: TextStyle(fontSize: 15, color: _AppTheme.text, fontWeight: FontWeight.w700))]),
                    GlassSlider(
                      value: _goal.toDouble().clamp(30, 480),
                      min: 30,
                      max: 480,
                      divisions: 450,
                      activeColor: kShortBreak,
                      thumbColor: CupertinoColors.white,
                      onChanged: (v) {
                        setState(() => _goal = v.round());
                        widget.onGoalChanged(v.round());
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 统计详情:本周、连续纪录、今日、最近记录,点开即看完整版。
class _StatsDetailPage extends StatelessWidget {
  final List<int> weekCompleted;
  final List<int> weekFocusMin;
  final List<Map<String, dynamic>> history;
  final int streak;
  final int todayCompleted;
  final int todayFocusMin;
  final bool inSheet;
  const _StatsDetailPage({required this.weekCompleted, required this.weekFocusMin, required this.history, required this.streak, required this.todayCompleted, required this.todayFocusMin, this.inSheet = false});
  @override
  Widget build(BuildContext context) {
    final weekTotal = weekCompleted.fold<int>(0, (a, b) => a + b);
    final weekFocus = weekFocusMin.fold<int>(0, (a, b) => a + b);
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final maxDay = weekCompleted.fold<int>(1, (a, b) => a > b ? a : b);
    return CupertinoPageScaffold(
      backgroundColor: inSheet ? CupertinoColors.transparent : null,
      navigationBar: inSheet ? null : const CupertinoNavigationBar(middle: Text('统计详情'), previousPageTitle: '计时'),
      child: SafeArea(top: !inSheet, bottom: !inSheet,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Hero(
                tag: 'stats-card',
                child: _LiquidCard(
                  radius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Expanded(child: _MiniStat(label: '今日专注', value: '$todayFocusMin', unit: '分钟')),
                      Container(width: 1, height: 40, color: _AppTheme.divider),
                      Expanded(child: _MiniStat(label: '今日完成', value: '$todayCompleted', unit: '个番茄')),
                      Container(width: 1, height: 40, color: _AppTheme.divider),
                      Expanded(child: _MiniStat(label: '连续纪录', value: '$streak', unit: '天')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _LiquidCard(
                radius: 24,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('本周: $weekTotal 个番茄 · $weekFocus 分钟', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 110,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: List.generate(7, (i) {
                          final v = weekCompleted[i];
                          final h = 16.0 + (v / maxDay) * 78;
                          return Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Text('$v', style: TextStyle(fontSize: 11, color: _AppTheme.sub, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 4),
                                TweenAnimationBuilder<double>(
                                  tween: Tween(begin: 0, end: h),
                                  duration: Duration(milliseconds: 500 + i * 90),
                                  curve: Curves.easeOutBack,
                                  builder: (context, height, _) => Container(height: height, margin: const EdgeInsets.symmetric(horizontal: 5), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: kTomato.withValues(alpha: i == 6 ? 0.9 : 0.5))),
                                ),
                                const SizedBox(height: 6),
                                Text(weekdays[i], style: TextStyle(fontSize: 11, color: _AppTheme.sub)),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _LiquidCard(
                radius: 24,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('最近番茄记录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _AppTheme.text)),
                    const SizedBox(height: 10),
                    if (history.isEmpty) Text('还没有完成的番茄', style: TextStyle(fontSize: 13, color: _AppTheme.sub)),
                    for (final r in history.reversed.take(20))
                      Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [Expanded(child: Text(r['task'] as String? ?? '专注', style: TextStyle(fontSize: 14, color: _AppTheme.text), overflow: TextOverflow.ellipsis)), Text('${r['date'] ?? ''} · ${r['minutes'] ?? 25} 分钟', style: TextStyle(fontSize: 12, color: _AppTheme.sub))])),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阶段分段(FlClash SegmentedControl 对标):
/// 高 44、内边距 4、容器为 pill 形半透明底;滑块 pill 用 AnimatedAlign
/// 250ms easeOutCubic 滑动,对齐点按 index*2/(count-1)-1 计算,
/// FractionallySizedBox(widthFactor: 1/3);选中段文字 200ms 加粗变色,
/// 已选中段点按为空操作(不重复反馈);切换本身经 _switchPhase 带轻选震动。
/// 阶段分段：旧自写 Container + AnimatedAlign 滑块 pill 已删除，改为
/// 包的 GlassSegmentedControl（jelly 指示器动画来自包，indicatorPinch
/// 等参数都是包的）；indicatorColor 用当前阶段色，选中段不再点按
/// 时 _switchPhase 本来就带轻震，这里只在换段时才回调。
class _PhaseSegment extends StatelessWidget {
  final Phase phase;
  final ValueChanged<Phase> onSelect;
  const _PhaseSegment({required this.phase, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    const phases = Phase.values;
    final index = phases.indexOf(phase);
    return GlassSegmentedControl(
      segments: phases.map((p) => GlassSegment(label: p.nextLabel)).toList(),
      selectedIndex: index,
      onSegmentSelected: (i) {
        if (i != index) onSelect(phases[i]);
      },
      indicatorColor: phase.color,
      selectedTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _AppTheme.text),
      unselectedTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: _AppTheme.sub),
      height: 44,
    );
  }
}

/// 本周专注曲线小折线(FlClash 网速卡小折线对标):
/// 7 个点归一化连线 + 线下淡填充 + 末点圆点,包在 RepaintBoundary 里使用,
/// 不随每秒计时重绘。
class _SparklinePainter extends CustomPainter {
  final List<double> points;
  final Color color;
  const _SparklinePainter({required this.points, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;
    final maxV = points.fold<double>(0, (a, b) => b > a ? b : a);
    final span = points.length == 1 ? 1.0 : (points.length - 1).toDouble();
    Offset pt(int i) {
      final x = span == 0 ? 0.0 : size.width * i / span;
      // 全零一周时 maxV 为 0:必须先把比值置 0,不能让 0*(0/0) 算出 NaN。
      final ratio = maxV <= 0 ? 0.0 : points[i] / maxV;
      final y = size.height - 6 - (size.height - 12) * ratio;
      return Offset(x, y);
    }
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..color = color.withValues(alpha: 0.18)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final last = pt(points.length - 1);
    canvas.drawCircle(last, 5, Paint()..color = CupertinoColors.white);
    canvas.drawCircle(last, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => old.points != points || old.color != color;
}

/// 右上角小菜单卡(FlClash +/菜单对标,简化版):
/// 宽 220、圆角 16(FlClash 卡片 md 档)、每项图标 + 文字 + chevron、
/// 行高 56(FlClash 列表行最小高);点按先按开关给轻选震动,再执行动作。
class _TopMenuCard extends StatelessWidget {
  final bool vibrationEnabled;
  final VoidCallback onAddTask;
  final VoidCallback onNoise;
  final VoidCallback onGoal;
  final VoidCallback onReset;
  const _TopMenuCard({required this.vibrationEnabled, required this.onAddTask, required this.onNoise, required this.onGoal, required this.onReset});
  @override
  Widget build(BuildContext context) {
    final items = [
      (CupertinoIcons.add_circled, '新增任务', onAddTask),
      (CupertinoIcons.music_note, '白噪音', onNoise),
      (CupertinoIcons.flag, '今日目标', onGoal),
      (CupertinoIcons.refresh, '恢复默认', onReset),
    ];
    return _LiquidCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Container(height: 1, margin: const EdgeInsets.only(left: 44, right: 16), color: _AppTheme.divider),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (vibrationEnabled) HapticFeedback.selectionClick();
                  items[i].$3();
                },
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(items[i].$1, color: _AppTheme.text, size: 18),
                      const SizedBox(width: 12),
                      Expanded(child: Text(items[i].$2, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text))),
                      Icon(CupertinoIcons.chevron_right, color: _AppTheme.sub, size: 14),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 白噪音底部弹窗本体(FlClash 底部弹窗对标,近似实现而非 SnapSheetRoute):
/// 顶部圆角 28(FlClash 底部弹窗顶部 xxl 档)、顶部拖动手柄、左上角 X、
/// 标题居中、声音列表(关闭/白噪音/雨声/篝火,选中带对勾,行高 56)、
/// 音量滑块、播放/暂停 pill 键;下滑超过 120 收起,否则弹簧回弹;
/// 点选按开关给轻选震动。
class _NoiseSheet extends StatefulWidget {
  final String noiseName;
  final double volume;
  final bool playing;
  final bool vibrationEnabled;
  final ValueChanged<String> onSelect;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChanged;
  const _NoiseSheet({required this.noiseName, required this.volume, required this.playing, required this.vibrationEnabled, required this.onSelect, required this.onTogglePlay, required this.onVolumeChanged});
  @override
  State<_NoiseSheet> createState() => _NoiseSheetState();
}

class _NoiseSheetState extends State<_NoiseSheet> {
  late String _name;
  late double _volume;
  late bool _playing;

  @override
  void initState() {
    super.initState();
    _name = widget.noiseName;
    _volume = widget.volume;
    _playing = widget.playing;
  }

  @override
  Widget build(BuildContext context) {
    const sounds = [
      ('off', '关闭'),
      ('white', '白噪音'),
      ('rain', '雨声'),
      ('fire', '篝火'),
    ];
    // 浮窗头(拖动条 + X + 标题)由 _openSheet 的 GlassModalSheet 统一提供,这里只剩内容;
    // 下滑关闭、遮罩关闭、来源 morph 也都由 GlassModalSheet 驱动。
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in sounds)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _CardButton(
                  onTap: () {
                    widget.onSelect(s.$1);
                    setState(() {
                      _name = s.$1;
                      _playing = s.$1 != 'off';
                    });
                  },
                  child: _LiquidCard(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    child: Row(
                      children: [
                        Expanded(child: Text(s.$2, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: _AppTheme.text))),
                        if (_name == s.$1) Icon(CupertinoIcons.checkmark, color: _AppTheme.text, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(CupertinoIcons.volume_down, color: _AppTheme.text, size: 18),
                Expanded(
                  child: GlassSlider(
                    value: _volume,
                    min: 0,
                    max: 1,
                    activeColor: kTomato,
                    onChanged: (v) {
                      setState(() => _volume = v);
                      widget.onVolumeChanged(v);
                    },
                  ),
                ),
                Icon(CupertinoIcons.volume_up, color: _AppTheme.text, size: 18),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: GlassButton.custom(
                onTap: () {
                  if (_name == 'off') return;
                  widget.onTogglePlay();
                  setState(() => _playing = !_playing);
                },
                enabled: _name != 'off',
                shape: const LiquidRoundedSuperellipse(borderRadius: 24),
                style: GlassButtonStyle.prominent,
                glowColor: kTomato,
                settings: LiquidGlassSettings(glassColor: kTomato.withValues(alpha: 0.55), thickness: 30),
                child: Text(_playing ? '暂停' : '播放', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: CupertinoColors.white)),
              ),
            ),
            const SizedBox(height: 10),
            Text('本地生成,无需联网 · 下滑可收起', style: TextStyle(fontSize: 12, color: _AppTheme.sub)),
          ],
        ),
      );
  }
}
