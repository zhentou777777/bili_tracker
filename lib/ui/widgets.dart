/// 共用 UI 组件。
///
/// 抽出来的目的：原来每个页面各写各的 Container + Border.all + TextStyle，
/// 圆角/间距/字号各不相同，整体看着「散」。这里统一成几个组件，
/// 换主题、调密度都只需要改一处。
library widgets;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 卡片：统一圆角、描边与（浅色下的）浅投影。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.margin = EdgeInsets.zero,
    this.accent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;

  /// 左侧竖条强调色（用于「正在直播」这类需要一眼看到的卡片）。
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;
    final Widget body = Padding(padding: padding, child: child);

    return Padding(
      padding: margin,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: c.border),
          boxShadow: <BoxShadow>[
            BoxShadow(color: c.shadow, blurRadius: 16, offset: const Offset(0, 5)),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: accent == null
                ? body
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Container(
                        width: 3.5,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(18),
                          ),
                        ),
                      ),
                      Expanded(child: body),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 分组标题：左侧一小段品牌色竖条 + 标题 + 可选计数/操作。
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.icon,
    this.trailing,
    this.color,
    this.padding = const EdgeInsets.fromLTRB(16, 22, 16, 10),
  });

  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;
    final Color tint = color ?? c.textPrimary;

    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          if (icon != null) ...<Widget>[
            Icon(icon, size: 15, color: tint),
            const SizedBox(width: 6),
          ],
          Text(
            title,
            style: TextStyle(
              color: tint,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 小标签：类型、平台、状态这类信息。
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;
    final Color fg = color ?? c.textSecondary;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 6 : 8,
        vertical: dense ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: c.tint(fg, c.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 10 : 11, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部信息条：抓取结果、提示、警告都用它。
class InfoBar extends StatelessWidget {
  const InfoBar({
    super.key,
    required this.text,
    this.icon = Icons.info_outline,
    this.color,
    this.margin = const EdgeInsets.fromLTRB(16, 12, 16, 0),
    this.trailing,
  });

  final String text;
  final IconData icon;
  final Color? color;
  final EdgeInsetsGeometry margin;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;
    final Color fg = color ?? c.textSecondary;

    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: c.isDark ? c.tint(fg, 0.10) : c.tint(fg, 0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.tint(fg, 0.22)),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: fg, fontSize: 12, height: 1.4),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// 空态：图标 + 一句主文案 + 一句说明 + 可选按钮。
///
/// 比只放一个灰色图标 + 一行字更像「有设计的界面」，
/// 也顺便承担了「下一步该做什么」的引导职责。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
    this.color,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;
    final Color fg = color ?? c.brand;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                color: c.tint(fg, c.isDark ? 0.14 : 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: fg),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (description != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 圆形头像（带占位与直播光圈）。
class AvatarBubble extends StatelessWidget {
  const AvatarBubble({
    super.key,
    required this.url,
    this.size = 42,
    this.live = false,
    this.badge,
  });

  final String url;
  final double size;
  final bool live;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.c;

    final Widget avatar = ClipRRect(
      borderRadius: BorderRadius.circular(size / 2),
      child: url.isEmpty
          ? Container(
              width: size,
              height: size,
              color: c.surfaceAlt,
              child: Icon(Icons.person, size: size * 0.5, color: c.textSecondary),
            )
          : Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: size,
                height: size,
                color: c.surfaceAlt,
                child: Icon(Icons.person,
                    size: size * 0.5, color: c.textSecondary),
              ),
            ),
    );

    if (badge != null) {
      return SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            avatar,
            Positioned(right: -2, bottom: -2, child: badge!),
          ],
        ),
      );
    }

    if (!live) return avatar;

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: c.live, width: 2),
      ),
      child: avatar,
    );
  }
}
