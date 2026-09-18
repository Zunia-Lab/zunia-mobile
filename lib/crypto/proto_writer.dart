/// Minimal protobuf writer for Cosmos TxRaw / message encoding.
library;

import 'dart:convert';
import 'dart:typed_data';

class ProtoWriter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  Uint8List intoBytes() => _buf.toBytes();

  void _writeTag(int tag, int wire) {
    _writeVarint((tag << 3) | wire);
  }

  void _writeVarint(int value) {
    var n = value;
    while (true) {
      final byte = n & 0x7f;
      n >>= 7;
      if (n == 0) {
        _buf.addByte(byte);
        return;
      }
      _buf.addByte(byte | 0x80);
    }
  }

  ProtoWriter uint64(int tag, BigInt value) {
    if (value == BigInt.zero) return this;
    _writeTag(tag, 0);
    _writeVarintBig(value);
    return this;
  }

  void _writeVarintBig(BigInt value) {
    var n = value;
    while (true) {
      final byte = (n & BigInt.from(0x7f)).toInt();
      n >>= 7;
      if (n == BigInt.zero) {
        _buf.addByte(byte);
        return;
      }
      _buf.addByte(byte | 0x80);
    }
  }

  ProtoWriter int32(int tag, int value) {
    if (value == 0) return this;
    _writeTag(tag, 0);
    _writeVarint(value);
    return this;
  }

  ProtoWriter string(int tag, String value) {
    if (value.isEmpty) return this;
    final bytes = utf8.encode(value);
    _writeTag(tag, 2);
    _writeVarint(bytes.length);
    _buf.add(bytes);
    return this;
  }

  ProtoWriter bytes(int tag, Uint8List value) {
    if (value.isEmpty) return this;
    _writeTag(tag, 2);
    _writeVarint(value.length);
    _buf.add(value);
    return this;
  }

  ProtoWriter message(int tag, Uint8List value) => bytes(tag, value);

  ProtoWriter messageAlways(int tag, Uint8List value) {
    _writeTag(tag, 2);
    _writeVarint(value.length);
    _buf.add(value);
    return this;
  }

  ProtoWriter repeatedMessage(int tag, List<Uint8List> values) {
    for (final value in values) {
      _writeTag(tag, 2);
      _writeVarint(value.length);
      _buf.add(value);
    }
    return this;
  }
}
