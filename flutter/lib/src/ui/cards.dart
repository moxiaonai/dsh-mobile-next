/// 统一的卡片语言 —— 会话 / 任务 / 设置三页共用。
///
/// 一套视觉只有一处实现才稳。之前三个页面各写一遍「白卡 + 44 图标瓦片 +
/// 右箭头 + 从标题左沿起的分隔线」，间距和圆角很快就漂了（有的 margin 16
/// 有的 14、有的分隔线 72 有的 76）。这里收拢成四个可复用组件：
///
/// - [RoundIconButton]：标题栏右上角的 44dp 白圆按钮
/// - [IconTile]：行首 44dp 图标瓦片
/// - [GroupHeaderCard]：分组灰头（与下方白卡拼成一张卡）
/// - [CardRow]：一行白卡（图标 + 标题/副标题 + 尾部）
library;

import 'package:flutter/material.dart';

import 'job_widgets.dart' show AppTheme;
import 'tokens.dart';

/// 标题栏右上角的圆形按钮：白底、墨色图标、44dp 命中区。
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final (t, _) = AppTheme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      child: Material(
        color: t.bgCard,
        shape: CircleBorder(side: BorderSide(color: t.borderSubtle)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: Hit.min,
            height: Hit.min,
            child: Icon(icon, size: 22, color: t.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 行首图标瓦片：44dp、浅灰底、圆角 12。
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.size = 44,
    this.iconSize = 22,
  });

  final IconData icon;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final (t, _) = AppTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: t.bgSunken, borderRadius: Radii.rMd),
      child: Icon(icon, size: iconSize, color: t.textSecondary),
    );
  }
}

/// 卡片里的标题样式：正文的骨架 + 半级加粗放大。
///
/// 用 `fontBase` 倍率而不是写死 17：用户在设置页把字号调到 20 时，
/// 卡片标题要跟着长，否则会显得「标题比正文还小」。
TextStyle cardTitleStyle(AppTextStyles txt) => txt.body.copyWith(
  fontWeight: FontWeight.w600,
  fontSize: txt.fontBase * 1.0625,
);

/// 分组灰头：展开态浅灰通栏（只顶部圆角），与下方白卡行拼成一张卡；
/// 收起态换成整张白卡一行（图标 + 组名 + 数量 + 右向箭头）。
class GroupHeaderCard extends StatelessWidget {
  const GroupHeaderCard({
    super.key,
    required this.title,
    this.count,
    this.expanded = true,
    this.onTap,
    this.collapsedIcon = Icons.folder_outlined,
    this.animate = true,
    this.semanticsLabel,
  });

  final String title;
  final int? count;
  final bool expanded;

  /// 为 `null` 时组头不可折叠（任务页的分区就属于这种）。
  final VoidCallback? onTap;

  /// 收起态左侧图标；给 `null` 则收起时也不显示图标。
  final IconData? collapsedIcon;

  /// 是否播放箭头旋转动画（尊重「始终减弱」由上层决定）。
  final bool animate;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final collapsed = onTap != null && !expanded;
    final radius = collapsed
        ? Radii.rLg
        : const BorderRadius.vertical(top: Radius.circular(Radii.lg));

    return Semantics(
      button: onTap != null,
      // ⚠ 只给 expanded，不同时给 onExpand —— Flutter 会抛
      // "An expanded node cannot have an expand action"
      expanded: onTap == null ? null : expanded,
      label: semanticsLabel,
      child: Material(
        color: collapsed ? t.bgCard : t.bgSunken,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(horizontal: Space.s5),
            child: Row(
              children: [
                // ⚠ 不能写 `Flexible(标题) … Spacer() 箭头`：Flexible 也是
                // flex 子项，会和 Spacer 平分自由空间，标题只占自身宽度但
                // 份额已经分出去了 → 箭头被顶离右边缘约 70dp。
                // 正确做法：左侧整组用 Expanded 吃掉剩余空间，箭头直接收尾。
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (collapsed && collapsedIcon != null) ...[
                        Icon(
                          collapsedIcon,
                          size: 22,
                          color: t.textSecondary,
                        ),
                        const SizedBox(width: Space.s6),
                      ],
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: cardTitleStyle(txt),
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: Space.s4),
                        Text(
                          '$count',
                          style: txt.body.copyWith(
                            fontSize: 15,
                            color: t.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null)
                  AnimatedRotation(
                    turns: collapsed ? -0.25 : 0,
                    duration: animate
                        ? const Duration(milliseconds: 150)
                        : Duration.zero,
                    curve: Curves.easeOut,
                    child: Icon(
                      Icons.expand_more,
                      size: 22,
                      color: t.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行白卡：可选图标瓦片 + 标题/副标题 + 尾部（默认右箭头）。
///
/// [last] 为真时带底部圆角，和上面的 [GroupHeaderCard] 凑成一张完整的卡；
/// 否则在标题左沿补一条分隔线（iOS 列表的常规做法）。
class CardRow extends StatelessWidget {
  const CardRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leadingIcon,
    this.leading,
    this.trailing,
    this.onTap,
    this.first = false,
    this.last = false,
    this.showChevron = true,
    this.dotColor,
    this.titleStyle,
    this.margin = const EdgeInsets.symmetric(horizontal: Space.s8),
    this.dividerInset = 76,
    this.minHeight = 64,
  });

  final String title;

  /// 副标题：给 Widget 而不是 String，任务页要在里面塞状态 chip。
  final Widget? subtitle;

  /// 行首图标瓦片（与 [leading] 二选一）。
  final IconData? leadingIcon;

  /// 自定义行首组件（优先于 [leadingIcon]）。
  final Widget? leading;

  final Widget? trailing;

  final VoidCallback? onTap;

  /// 是否本组第一行：只有它带上部圆角（独立卡片则与 [last] 一起为真）。
  final bool first;

  final bool last;
  final bool showChevron;

  /// 标题前的状态点（如「运行中」用绿点）。
  final Color? dotColor;

  final TextStyle? titleStyle;
  final EdgeInsets margin;
  final double dividerInset;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final (t, txt) = AppTheme.of(context);
    final radius = switch ((first, last)) {
      (true, true) => Radii.rLg,
      (true, false) => const BorderRadius.vertical(
        top: Radius.circular(Radii.lg),
      ),
      (false, true) => const BorderRadius.vertical(
        bottom: Radius.circular(Radii.lg),
      ),
      (false, false) => BorderRadius.zero,
    };
    final lead = leading ??
        (leadingIcon == null ? null : IconTile(icon: leadingIcon!));

    return Container(
      margin: margin,
      decoration: BoxDecoration(color: t.bgCard, borderRadius: radius),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Column(
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.s4,
                    Space.s5,
                    Space.s4,
                    Space.s5,
                  ),
                  child: Row(
                    children: [
                      if (lead != null) ...[
                        lead,
                        const SizedBox(width: Space.s6),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                if (dotColor != null) ...[
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      color: dotColor,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: Space.s3),
                                ],
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        titleStyle ?? cardTitleStyle(txt),
                                  ),
                                ),
                              ],
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: Space.s1),
                              subtitle!,
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: Space.s4),
                      if (trailing != null)
                        trailing!
                      else if (showChevron)
                        Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: t.textTertiary,
                        ),
                    ],
                  ),
                ),
              ),
              if (!last)
                Container(
                  height: 1,
                  margin: EdgeInsets.only(left: dividerInset),
                  color: t.borderSubtle,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 独立的白色卡片（设置页的每个分组用它）：四周圆角、浅阴影都不加，
/// 只靠画布灰与卡白拉出层次。
class CardSurface extends StatelessWidget {
  const CardSurface({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: Space.s8),
    this.padding = const EdgeInsets.all(Space.s4),
  });

  final Widget child;
  final EdgeInsets margin;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final (t, _) = AppTheme.of(context);
    return Container(
      margin: margin,
      decoration: BoxDecoration(color: t.bgCard, borderRadius: Radii.rLg),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 副标题的统一样式（灰、13 级、单行）。
Widget cardSubtitle(String text, AppTextStyles txt, Tokens t) => Text(
  text,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: txt.caption.copyWith(color: t.textTertiary),
);
