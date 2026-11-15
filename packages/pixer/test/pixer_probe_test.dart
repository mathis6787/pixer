import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pixer/pixer.dart';
import 'package:test/test.dart';

Uint8List _fixture(String encoded) => base64Decode(encoded);

final _png = _fixture(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAAFUlEQVR4nGP8z8Dwn4GBgYEJRKAwADE7AgRVI0g0AAAAAElFTkSuQmCC',
);
final _jpegHeader = Uint8List.fromList([
  0xff, 0xd8, // SOI
  0xff, 0xe0, 0x00, 0x02, // Empty APP0
  0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x03, 0x00, 0x02, // SOF0
  0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
]);
final _gif = _fixture(
  'R0lGODdhAgADAIEAAP8AAAAAAAAAAAAAACwAAAAAAgADAAAIBgABCBwYEAA7',
);
final _webp = _fixture('UklGRhwAAABXRUJQVlA4TA8AAAAvAYAAAAcQ/Y/+ByKi/wEA');
final _lossyWebp = _fixture(
  'UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoCAAMAAkA4JaACdLoB+AADsAD+8JtD/yC0rlvAH/8SF+JC/Ehf+LmAAAA=',
);
final _extendedWebp = _fixture(
  'UklGRl4AAABXRUJQVlA4WAoAAAAQAAAAAQAAAgAAQUxQSAcAAAAAZGRkZGRkAFZQOCAwAAAA0AEAnQEqAgADAAJAOCWgAnS6AfgAA7AA/vCbQ/8gtK5bwB//EhfiQvxIX/i5gAAA',
);
final _apng = _fixture(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAYAAAC56t6BAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAACAAAAAwAAAAAAAAAAAAEACgAAUa8H6AAAABVJREFUeJxj/M/A8J+BgYGBCUSgMAAxOwIEVSNINAAAABpmY1RMAAAAAQAAAAIAAAADAAAAAAAAAAAAAQAKAADK3O08AAAAGWZkQVQAAAACeJxjZGD4/5+BgYGBCUSgMAAvPQIEBtbc6AAAAABJRU5ErkJggg==',
);
final _animatedGif = _fixture(
  'R0lGODlhAgADAIEAAP8AAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAgADAAAIBgABCBwYEAAh+QQBCgABACwAAAAAAgADAIEAAP8AAAAAAAAAAAAIBgABCBwYEAA7',
);
final _animatedWebp = _fixture(
  'UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAgAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAAEAAAIAAGQAAAJWUDhMDwAAAC8BgAAABxD9j/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAIAAGQAAABWUDhMDwAAAC8BgAAABxDR//4HIqL/AQA=',
);

Uint8List _exif(int orientation, {Endian endian = Endian.little}) {
  final bytes = Uint8List(26);
  bytes.setRange(0, 2, endian == Endian.little ? [0x49, 0x49] : [0x4d, 0x4d]);
  final view = ByteData.sublistView(bytes);
  view.setUint16(2, 42, endian);
  view.setUint32(4, 8, endian);
  view.setUint16(8, 1, endian);
  view.setUint16(10, 0x0112, endian);
  view.setUint16(12, 3, endian);
  view.setUint32(14, 1, endian);
  view.setUint16(18, orientation, endian);
  return bytes;
}

Uint8List _jpegExifSegment(Uint8List exif) {
  final data = <int>[0x45, 0x78, 0x69, 0x66, 0, 0, ...exif];
  final length = data.length + 2;
  return Uint8List.fromList([0xff, 0xe1, length >> 8, length & 0xff, ...data]);
}

Uint8List _jpegWithExif(Uint8List source, List<Uint8List> chunks) =>
    Uint8List.fromList([
      ...source.take(2),
      for (final exif in chunks) ..._jpegExifSegment(exif),
      ...source.skip(2),
    ]);

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0);
    }
  }
  return crc ^ 0xffffffff;
}

Uint8List _pngExifChunk(Uint8List exif) {
  final bytes = Uint8List(exif.length + 12);
  final view = ByteData.sublistView(bytes);
  view.setUint32(0, exif.length);
  bytes.setRange(4, 8, ascii.encode('eXIf'));
  bytes.setRange(8, 8 + exif.length, exif);
  view.setUint32(8 + exif.length, _crc32(bytes.sublist(4, 8 + exif.length)));
  return bytes;
}

Uint8List _pngWithExif(
  Uint8List source,
  List<Uint8List> chunks, {
  bool afterImageData = false,
}) {
  // Insert before IDAT for ordinary metadata; the late variant is before IEND.
  final offset = afterImageData ? source.length - 12 : 33;
  return Uint8List.fromList([
    ...source.take(offset),
    for (final exif in chunks) ..._pngExifChunk(exif),
    ...source.skip(offset),
  ]);
}

Uint8List _webpChunk(String type, Uint8List data) {
  final bytes = Uint8List(8 + data.length + (data.length & 1));
  bytes.setRange(0, 4, ascii.encode(type));
  ByteData.sublistView(bytes).setUint32(4, data.length, Endian.little);
  bytes.setRange(8, 8 + data.length, data);
  return bytes;
}

Uint8List _webpWithExif(Uint8List source, List<Uint8List> chunks) {
  // The base fixture is a 2x3 lossless WebP without an extended header.
  final header = Uint8List.fromList([0x08, 0, 0, 0, 1, 0, 0, 2, 0, 0]);
  final body = <int>[
    ...ascii.encode('WEBP'),
    ..._webpChunk('VP8X', header),
    ...source.skip(12),
    for (final exif in chunks) ..._webpChunk('EXIF', exif),
  ];
  final bytes = Uint8List(8 + body.length);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  ByteData.sublistView(bytes).setUint32(4, body.length, Endian.little);
  bytes.setRange(8, bytes.length, body);
  return bytes;
}

Uint8List _withExif(ImageFormatEnum format, List<Uint8List> chunks) =>
    switch (format) {
      ImageFormatEnum.Jpeg => _jpegWithExif(_jpegHeader, chunks),
      ImageFormatEnum.Png => _pngWithExif(_png, chunks),
      ImageFormatEnum.WebP => _webpWithExif(_webp, chunks),
      _ => throw ArgumentError.value(format),
    };

void _expectOrientation(
  Uint8List bytes,
  int orientation, {
  int width = 2,
  int height = 3,
}) {
  final header = Pixer.probe(bytes);
  expect(header.orientation, orientation);
  expect(header.needsOrientationTransform, orientation != 1);
  expect((
    header.width,
    header.height,
  ), orientation >= 5 ? (height, width) : (width, height));
  expect(header.frameCount, 1);
}

void main() {
  group('Pixer.guessFormat', () {
    for (final (format, bytes) in [
      (ImageFormatEnum.Png, _png),
      (ImageFormatEnum.Jpeg, _jpegHeader),
      (ImageFormatEnum.Gif, _gif),
      (ImageFormatEnum.WebP, _webp),
      (ImageFormatEnum.Bmp, Uint8List.fromList([0x42, 0x4d])),
      (ImageFormatEnum.Ico, Uint8List.fromList([0, 0, 1, 0])),
      (ImageFormatEnum.Tiff, Uint8List.fromList([0x49, 0x49, 0x2a, 0])),
      (ImageFormatEnum.Tiff, Uint8List.fromList([0x4d, 0x4d, 0, 0x2a])),
    ]) {
      test('recognizes ${format.name} signatures without decoding', () {
        expect(Pixer.guessFormat(bytes), format);
      });
    }

    test('does not treat a recognized signature as image validation', () {
      expect(
        Pixer.guessFormat(Uint8List.sublistView(_png, 0, 8)),
        ImageFormatEnum.Png,
      );
    });

    test('rejects empty, unknown and incomplete signatures', () {
      for (final bytes in [
        Uint8List(0),
        utf8.encode('<svg/>'),
        _png.sublist(0, 4),
      ]) {
        expect(
          () => Pixer.guessFormat(Uint8List.fromList(bytes)),
          throwsA(isA<UnsupportedFormatException>()),
        );
      }
    });
  });

  group('Pixer.probe', () {
    for (final (format, bytes) in [
      (ImageFormatEnum.Png, _png),
      (ImageFormatEnum.Jpeg, _jpegHeader),
      (ImageFormatEnum.Gif, _gif),
      (ImageFormatEnum.WebP, _webp),
    ]) {
      test('reads a still ' + format.name + ' without decoding', () {
        final header = Pixer.probe(bytes);
        expect(header.format, format);
        expect((header.width, header.height, header.frameCount), (2, 3, 1));
      });
    }

    test('reads lossy and extended still WebP containers', () {
      for (final bytes in [_lossyWebp, _extendedWebp]) {
        final header = Pixer.probe(bytes);
        expect(header.format, ImageFormatEnum.WebP);
        expect((header.width, header.height, header.frameCount), (2, 3, 1));
      }
    });

    for (final (format, bytes) in [
      (ImageFormatEnum.Png, _apng),
      (ImageFormatEnum.Gif, _animatedGif),
      (ImageFormatEnum.WebP, _animatedWebp),
    ]) {
      test('counts frames in animated ' + format.name, () {
        final header = Pixer.probe(bytes);
        expect(header.format, format);
        expect((header.width, header.height, header.frameCount), (2, 3, 2));
      });
    }

    test('reports large dimensions for callers to enforce their own limit', () {
      final oversized = Uint8List.fromList(_png);
      ByteData.sublistView(oversized).setUint32(16, 8193);
      expect(Pixer.probe(oversized).width, 8193);
    });

    test('rejects zero dimensions', () {
      final zeroWidth = Uint8List.fromList(_png);
      ByteData.sublistView(zeroWidth).setUint32(16, 0);
      expect(
        () => Pixer.probe(zeroWidth),
        throwsA(isA<InvalidDimensionsException>()),
      );
    });

    test('rejects unsupported formats', () {
      expect(
        () => Pixer.probe(Uint8List.fromList([0x42, 0x4d, 0, 0])),
        throwsA(isA<UnsupportedFormatException>()),
      );
    });

    test('rejects an empty buffer', () {
      expect(
        () => Pixer.probe(Uint8List(0)),
        throwsA(isA<DecodingException>()),
      );
    });

    test('rejects truncated headers and containers', () {
      for (final bytes in [
        _png.sublist(0, _png.length - 5),
        _jpegHeader.sublist(0, 12),
        _gif.sublist(0, _gif.length - 1),
        _webp.sublist(0, _webp.length - 1),
      ]) {
        expect(() => Pixer.probe(bytes), throwsA(isA<DecodingException>()));
      }
    });

    test('rejects a PNG animation with a false frame count', () {
      final wrongCount = Uint8List.fromList(_apng);
      ByteData.sublistView(wrongCount).setUint32(37, 3);
      expect(() => Pixer.probe(wrongCount), throwsA(isA<DecodingException>()));
    });

    test('does not decode compressed pixel data', () {
      final corruptPixels = Uint8List.fromList(_png);
      corruptPixels[44] = 0xff;
      expect(Pixer.probe(corruptPixels).format, ImageFormatEnum.Png);
    });
  });

  group('Pixer.probe EXIF orientation', () {
    for (final format in [
      ImageFormatEnum.Jpeg,
      ImageFormatEnum.Png,
      ImageFormatEnum.WebP,
    ]) {
      for (var orientation = 1; orientation <= 8; orientation++) {
        test(
          'reads ${format.name} orientation $orientation in either byte order',
          () {
            for (final endian in [Endian.little, Endian.big]) {
              _expectOrientation(
                _withExif(format, [_exif(orientation, endian: endian)]),
                orientation,
              );
            }
          },
        );
      }

      test(
        'ignores malformed ${format.name} EXIF without rejecting its container',
        () {
          final invalid = <Uint8List>[
            Uint8List(0),
            Uint8List.fromList([0, 1, 2, 3]),
            _exif(6).sublist(0, 8),
            _exif(6).sublist(0, 19),
            _exif(0),
            _exif(9),
            _exif(65535),
            _exif(6)..[2] = 43,
            _exif(6)..[10] = 0x13,
            _exif(6)..[12] = 4,
            _exif(6)..[14] = 2,
            _exif(6)..setRange(4, 8, [0xff, 0xff, 0xff, 0xff]),
          ];
          for (final exif in invalid) {
            _expectOrientation(_withExif(format, [exif]), 1);
          }
        },
      );
    }

    test('defaults to unchanged orientation when EXIF is absent', () {
      for (final bytes in [_png, _jpegHeader, _gif, _webp]) {
        _expectOrientation(bytes, 1);
      }
    });

    test('reads JPEG EXIF after the frame header and before the scan', () {
      final bytes = Uint8List.fromList([
        ..._jpegHeader,
        ..._jpegExifSegment(_exif(6)),
        0xff,
        0xda,
      ]);
      _expectOrientation(bytes, 6);
    });

    test(
      'uses the last JPEG EXIF segment, including an invalid last value',
      () {
        _expectOrientation(
          _withExif(ImageFormatEnum.Jpeg, [_exif(6), _exif(2)]),
          2,
        );
        _expectOrientation(
          _withExif(ImageFormatEnum.Jpeg, [_exif(6), _exif(9)]),
          1,
        );
      },
    );

    test('uses the first WebP EXIF chunk rather than a later one', () {
      _expectOrientation(
        _withExif(ImageFormatEnum.WebP, [_exif(6), _exif(2)]),
        6,
      );
      _expectOrientation(
        _withExif(ImageFormatEnum.WebP, [_exif(9), _exif(6)]),
        1,
      );
    });

    test(
      'does not interpret a JPEG EXIF prefix as raw PNG or WebP TIFF metadata',
      () {
        final prefixed = Uint8List.fromList([
          ...ascii.encode('Exif'),
          0,
          0,
          ..._exif(6),
        ]);
        for (final format in [ImageFormatEnum.Png, ImageFormatEnum.WebP]) {
          _expectOrientation(_withExif(format, [prefixed]), 1);
        }
      },
    );

    test(
      'ignores PNG orientation metadata after image data like the native probe',
      () {
        _expectOrientation(
          _pngWithExif(_png, [_exif(6)], afterImageData: true),
          1,
        );
      },
    );

    test('uses the first CRC-valid PNG EXIF chunk', () {
      _expectOrientation(_pngWithExif(_png, [_exif(6), _exif(2)]), 6);
      _expectOrientation(_pngWithExif(_png, [_exif(9), _exif(6)]), 1);
    });

    test('ignores an invalid PNG EXIF CRC and can use a later valid chunk', () {
      final invalidOnly = _pngWithExif(_png, [_exif(6)]);
      invalidOnly[33 + _pngExifChunk(_exif(6)).length - 1] ^= 1;
      _expectOrientation(invalidOnly, 1);
      final laterValid = _pngWithExif(_png, [_exif(6), _exif(2)]);
      laterValid[33 + _pngExifChunk(_exif(6)).length - 1] ^= 1;
      _expectOrientation(laterValid, 2);
    });

    test(
      'ignores EXIF appended to a simple WebP without an extended header',
      () {
        final bytes = Uint8List.fromList([
          ..._webp,
          ..._webpChunk('EXIF', _exif(6)),
        ]);
        ByteData.sublistView(
          bytes,
        ).setUint32(4, bytes.length - 8, Endian.little);
        _expectOrientation(bytes, 1);
      },
    );

    test('uses the first matching TIFF orientation entry', () {
      for (final format in [
        ImageFormatEnum.Jpeg,
        ImageFormatEnum.Png,
        ImageFormatEnum.WebP,
      ]) {
        for (final first in [6, 9]) {
          final exif = Uint8List.fromList([
            ..._exif(first).take(22),
            ..._exif(2).skip(10).take(12),
            0,
            0,
            0,
            0,
          ]);
          ByteData.sublistView(exif).setUint16(8, 2, Endian.little);
          _expectOrientation(_withExif(format, [exif]), first == 6 ? 6 : 1);
        }
      }
    });

    test(
      'reads a valid entry even if a later declared TIFF entry is truncated',
      () {
        final exif = _exif(6)..[8] = 2;
        for (final format in [
          ImageFormatEnum.Jpeg,
          ImageFormatEnum.Png,
          ImageFormatEnum.WebP,
        ]) {
          _expectOrientation(_withExif(format, [exif]), 6);
        }
      },
    );

    test(
      'keeps animation frame counts when applying EXIF canvas orientation',
      () {
        final header = Pixer.probe(_pngWithExif(_apng, [_exif(6)]));
        expect((header.width, header.height, header.frameCount), (3, 2, 2));
        expect(header.orientation, 6);
      },
    );
  });

  group('Pixer.probe and decoded EXIF dimensions', () {
    setUpAll(() => Pixer.initialize(wasmUri: Uri.parse('pixer.wasm')));

    for (var orientation = 1; orientation <= 8; orientation++) {
      test('matches native dimensions for orientation $orientation', () {
        final jpeg = img.encodeJpg(img.Image(width: 2, height: 3));
        for (final bytes in [
          _jpegWithExif(jpeg, [_exif(orientation)]),
          _pngWithExif(_png, [_exif(orientation)]),
          _webpWithExif(_webp, [_exif(orientation)]),
        ]) {
          final header = Pixer.probe(bytes);
          final decoded = Pixer.fromMemory(bytes);
          try {
            expect(
              (header.width, header.height),
              (decoded.width, decoded.height),
            );
          } finally {
            decoded.dispose();
          }
        }
      });
    }

    test('matches native handling of metadata edge cases', () {
      final invalidCrc = _pngWithExif(_png, [_exif(6)]);
      invalidCrc[33 + _pngExifChunk(_exif(6)).length - 1] ^= 1;
      final laterValidCrc = _pngWithExif(_png, [_exif(6), _exif(2)]);
      laterValidCrc[33 + _pngExifChunk(_exif(6)).length - 1] ^= 1;
      final simpleWebp = Uint8List.fromList([
        ..._webp,
        ..._webpChunk('EXIF', _exif(6)),
      ]);
      ByteData.sublistView(
        simpleWebp,
      ).setUint32(4, simpleWebp.length - 8, Endian.little);
      final jpeg = img.encodeJpg(img.Image(width: 2, height: 3));
      for (final bytes in [
        invalidCrc,
        laterValidCrc,
        simpleWebp,
        _pngWithExif(_png, [_exif(6), _exif(2)]),
        _pngWithExif(_png, [_exif(9), _exif(6)]),
        _webpWithExif(_webp, [_exif(6), _exif(2)]),
        _webpWithExif(_webp, [_exif(9), _exif(6)]),
        _jpegWithExif(jpeg, [_exif(6), _exif(2)]),
        _jpegWithExif(jpeg, [_exif(6), _exif(9)]),
        _pngWithExif(_png, [_exif(6)], afterImageData: true),
        _webpWithExif(_webp, [
          Uint8List.fromList([...ascii.encode('Exif'), 0, 0, ..._exif(6)]),
        ]),
      ]) {
        final header = Pixer.probe(bytes);
        final decoded = Pixer.fromMemory(bytes);
        try {
          expect(
            (header.width, header.height),
            (decoded.width, decoded.height),
          );
        } finally {
          decoded.dispose();
        }
      }
    });
  });
}
