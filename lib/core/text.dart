/// 文本处理的小工具。
///
/// 抽出来的理由：截断逻辑原本在 `platform/bilibili.dart`（阈值 600）与
/// `service/notify_service.dart`（阈值 60）里各写了一份。两处独立演化很容易
/// 出现「解析层放开了长度、通知层还按旧长度截」这种不一致，所以统一到一处。
library text_util;

/// 超过 [max] 个字符就截断并补一个省略号。
///
/// 用 `max` 而不是写死，是因为「存进数据库的正文」和「塞进通知栏的一行字」
/// 对长度的要求本来就不同 —— 但那应该是**调用方传参**的差别，不是两份实现。
String clipText(String text, {int max = 600}) {
  if (text.length <= max) return text;
  return '${text.substring(0, max)}…';
}
