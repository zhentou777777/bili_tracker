/// 纯 Dart MD5 实现（零第三方依赖）。
///
/// 存在的理由：WBI 签名链路必须能在 CLI 探针里独立跑通验证，
/// 而探针环境不引入任何 pub 依赖，因此这里自带一份标准 MD5。
/// 实现遵循 RFC 1321，常量表由脚本生成，与 Python hashlib 结果一致（见 tools/probe.dart）。
library md5;

import 'dart:convert';
import 'dart:typed_data';

const int _mask32 = 0xFFFFFFFF;

const List<int> _k = <int>[
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
  0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
  0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
  0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
  0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
  0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
  0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
  0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
  0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
];

const List<int> _s = <int>[
  7, 12, 17, 22, 7, 12, 17, 22,
  7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20,
  5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23,
  4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21,
  6, 10, 15, 21, 6, 10, 15, 21,
];

int _rotl(int x, int n) => ((x << n) | ((x & _mask32) >> (32 - n))) & _mask32;

/// 计算 [data] 的 MD5 摘要，返回 16 字节。
Uint8List md5Bytes(List<int> data) {
  final int msgLen = data.length;
  // 填充：0x80 + 若干个 0x00，使长度 ≡ 56 (mod 64)，再补 8 字节位长度
  final int padLen = (56 - (msgLen + 1) % 64 + 64) % 64;
  final int total = msgLen + 1 + padLen + 8;

  final Uint8List buf = Uint8List(total);
  buf.setRange(0, msgLen, data);
  buf[msgLen] = 0x80;

  final ByteData bd = ByteData.sublistView(buf);
  // 原始长度按位计，小端 64 位写入尾部
  final int bitLen = msgLen * 8;
  bd.setUint32(total - 8, bitLen & _mask32, Endian.little);
  bd.setUint32(total - 4, (bitLen >> 32) & _mask32, Endian.little);

  int a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;

  for (int off = 0; off < total; off += 64) {
    final List<int> m = List<int>.generate(
      16,
      (int i) => bd.getUint32(off + i * 4, Endian.little),
      growable: false,
    );

    int a = a0, b = b0, c = c0, d = d0;
    for (int i = 0; i < 64; i++) {
      int f, g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | (~d & _mask32));
        g = (7 * i) % 16;
      }
      f = (f + a + _k[i] + m[g]) & _mask32;
      a = d;
      d = c;
      c = b;
      b = (b + _rotl(f, _s[i])) & _mask32;
    }

    a0 = (a0 + a) & _mask32;
    b0 = (b0 + b) & _mask32;
    c0 = (c0 + c) & _mask32;
    d0 = (d0 + d) & _mask32;
  }

  final Uint8List out = Uint8List(16);
  final ByteData od = ByteData.sublistView(out);
  od.setUint32(0, a0, Endian.little);
  od.setUint32(4, b0, Endian.little);
  od.setUint32(8, c0, Endian.little);
  od.setUint32(12, d0, Endian.little);
  return out;
}

/// 计算 [data] 的 MD5 十六进制（小写 32 位）。
String md5Hex(List<int> data) {
  final StringBuffer sb = StringBuffer();
  for (final int byte in md5Bytes(data)) {
    sb.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 计算字符串 [text]（UTF-8 编码）的 MD5 十六进制。
String md5String(String text) => md5Hex(utf8.encode(text));
