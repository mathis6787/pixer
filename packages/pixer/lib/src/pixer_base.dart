import 'dart:typed_data';

import 'backend_native.dart'
    if (dart.library.js_interop) 'web/backend_web.dart';
import 'enums.dart';
import 'image_metadata.dart';
import 'image_operation.dart';
import 'image_probe.dart';
import 'pixer_encoder.dart';
import 'pixer_exception.dart';

part 'pixer_pipeline.dart';

/// A decoded image, backed by Rust on native and web platforms.
///
/// Operations like [resize], [crop], [blur], and so on start a lazy
/// [PixerPipeline]; chain more operations and finish with
/// [PixerPipeline.encode], [PixerPipeline.saveToFile], or
/// [PixerPipeline.toImage]. The whole chain runs in one native call and the
/// original image is unchanged, so one [Pixer] can feed many pipelines.
///
/// ## Memory management
///
/// Every [Pixer] owns a Rust image: the one you load and every
/// [PixerPipeline.toImage] result. Call [dispose] when you're done with it.
/// Pipelines own no native memory. Native finalizers provide a safety net but
/// are not guaranteed to run (especially across isolates), so explicit
/// disposal is the only reliable strategy.
///
/// Example:
/// ```dart
/// final image = Pixer.fromFile('input.jpg');
/// image.resize(800, 600).grayscale().saveToFile('output.jpg');
/// image.dispose();
/// ```
final class Pixer {
  Pixer._(this._backend);
  final BackendImage _backend;
  bool _isDisposed = false;
  PixerMetadata? _cachedMetadata;

  /// Loads the WASM module on web; native platforms are ready immediately.
  /// Pass [wasmBytes] or [wasmUri], or serve pixer.wasm beside the web page.
  static Future<void> initialize({Uint8List? wasmBytes, Uri? wasmUri}) =>
      BackendImage.initialize(wasmBytes: wasmBytes, wasmUri: wasmUri);

  /// Whether the native resources have been disposed.
  bool get isDisposed => _isDisposed;

  /// Guesses the image format from its file signature without decoding it.
  ///
  /// Supports PNG, JPEG, GIF, WebP, BMP, ICO, and TIFF on native and web.
  /// Throws [UnsupportedFormatException] if the signature is not recognized.
  static ImageFormatEnum guessFormat(Uint8List data) {
    bool matches(List<int> signature, [int offset = 0]) {
      if (data.length < offset + signature.length) return false;
      for (var index = 0; index < signature.length; index++) {
        if (data[offset + index] != signature[index]) return false;
      }
      return true;
    }

    if (matches([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return ImageFormatEnum.Png;
    }
    if (matches([0xff, 0xd8, 0xff])) return ImageFormatEnum.Jpeg;
    if (matches([0x47, 0x49, 0x46, 0x38]) &&
        (matches([0x37, 0x61], 4) || matches([0x39, 0x61], 4))) {
      return ImageFormatEnum.Gif;
    }
    if (matches([0x52, 0x49, 0x46, 0x46]) &&
        matches([0x57, 0x45, 0x42, 0x50], 8)) {
      return ImageFormatEnum.WebP;
    }
    if (matches([0x42, 0x4d])) return ImageFormatEnum.Bmp;
    if (matches([0x00, 0x00, 0x01, 0x00])) return ImageFormatEnum.Ico;
    if (matches([0x49, 0x49, 0x2a, 0x00]) ||
        matches([0x4d, 0x4d, 0x00, 0x2a])) {
      return ImageFormatEnum.Tiff;
    }
    throw UnsupportedFormatException('input: memory');
  }

  /// Reads an encoded image's format, dimensions, and frame count without
  /// decoding its pixels or loading the native/WASM engine.
  ///
  /// Supports PNG, JPEG, GIF, and WebP. This validates container structure,
  /// not compressed pixel data; [Pixer.fromMemory] performs full decoding.
  /// Dimensions are the encoded canvas dimensions; unlike [Pixer.fromMemory],
  /// this helper does not apply EXIF orientation.
  /// Throws [UnsupportedFormatException] for other formats,
  /// [DecodingException] for malformed headers, or
  /// [InvalidDimensionsException] for zero dimensions.
  static PixerImageHeader probe(Uint8List bytes) => probeImageHeader(bytes);

  /// Loads an image from a file path
  ///
  /// Throws [InvalidPathException] if the path is empty or invalid.
  /// Throws [IoException] if the file cannot be read.
  /// Throws [DecodingException] if the image format cannot be decoded.
  /// Throws [UnsupportedFormatException] if the format is not supported.
  /// Throws [UnsupportedError] on web; use [Pixer.fromMemory] instead.
  factory Pixer.fromFile(String path) {
    if (path.trim().isEmpty) throw InvalidPathException('path is empty');
    return Pixer._(BackendImage.fromFile(path));
  }

  /// Loads an image from a byte buffer
  ///
  /// The format is detected from the bytes unless [format] is given.
  /// Throws [DecodingException] if the buffer is empty or cannot be decoded.
  /// Throws [UnsupportedFormatException] if the format is not supported.
  factory Pixer.fromMemory(Uint8List data, {ImageFormatEnum? format}) {
    if (data.isEmpty) throw DecodingException('input buffer is empty');
    return Pixer._(BackendImage.fromMemory(data, format));
  }

  /// Checks if the image has been disposed
  void _checkDisposed() {
    if (_isDisposed) {
      throw InvalidPointerException('image has been disposed');
    }
  }

  PixerPipeline get _pipeline {
    _checkDisposed();
    return PixerPipeline._(this, const []);
  }

  /// Gets the image metadata (width, height, color type).
  ///
  /// The result is cached; subsequent calls return the cached value
  /// without calling the platform backend again.
  PixerMetadata getMetadata() {
    _checkDisposed();
    return _cachedMetadata ??= _backend.getMetadata();
  }

  /// Gets the image width
  int get width => getMetadata().width;

  /// Gets the image height
  int get height => getMetadata().height;

  /// Gets the image color type
  ColorType get colorType => getMetadata().colorType;

  /// Saves the image to a file
  ///
  /// The format is determined by the file extension.
  /// Throws [InvalidPathException] if the path is empty.
  /// Throws [UnsupportedError] on web; use [encode] instead.
  void saveToFile(String path) => _pipeline.saveToFile(path);

  /// Encodes the image to a byte buffer with [encoder].
  ///
  /// Pass `const PixerPngEncoder()` (or any other [PixerEncoder]) for default
  /// settings, or e.g. `PixerJpegEncoder(quality: 90)` to tune output.
  Uint8List encode(PixerEncoder encoder) => _pipeline.encode(encoder);

  /// Starts a pipeline that resizes to fit within [width] x [height],
  /// preserving aspect ratio. See [PixerPipeline.resize].
  PixerPipeline resize(
    int width,
    int height, {
    FilterTypeEnum filter = FilterTypeEnum.Lanczos3,
  }) => _pipeline.resize(width, height, filter: filter);

  /// Starts a pipeline that resizes to exactly [width] x [height]. See
  /// [PixerPipeline.resizeExact].
  PixerPipeline resizeExact(
    int width,
    int height, {
    FilterTypeEnum filter = FilterTypeEnum.Lanczos3,
  }) => _pipeline.resizeExact(width, height, filter: filter);

  /// Starts a pipeline that crops to a rectangle. See [PixerPipeline.crop].
  PixerPipeline crop(int x, int y, int width, int height) =>
      _pipeline.crop(x, y, width, height);

  /// Starts a pipeline that rotates 90 degrees clockwise.
  PixerPipeline rotate90() => _pipeline.rotate90();

  /// Starts a pipeline that rotates 180 degrees.
  PixerPipeline rotate180() => _pipeline.rotate180();

  /// Starts a pipeline that rotates 270 degrees clockwise.
  PixerPipeline rotate270() => _pipeline.rotate270();

  /// Starts a pipeline that flips horizontally.
  PixerPipeline flipHorizontal() => _pipeline.flipHorizontal();

  /// Starts a pipeline that flips vertically.
  PixerPipeline flipVertical() => _pipeline.flipVertical();

  /// Starts a pipeline that applies a Gaussian blur. See
  /// [PixerPipeline.blur].
  PixerPipeline blur(double sigma) => _pipeline.blur(sigma);

  /// Starts a pipeline that adjusts brightness. See
  /// [PixerPipeline.brightness].
  PixerPipeline brightness(int value) => _pipeline.brightness(value);

  /// Starts a pipeline that adjusts contrast. See [PixerPipeline.contrast].
  PixerPipeline contrast(double contrast) => _pipeline.contrast(contrast);

  /// Starts a pipeline that converts to grayscale.
  PixerPipeline grayscale() => _pipeline.grayscale();

  /// Starts a pipeline that inverts the colors.
  PixerPipeline invert() => _pipeline.invert();

  /// Disposes the native resources
  ///
  /// Call this when the image is no longer needed to prevent memory leaks.
  /// Native finalizers provide a fallback. Web requires explicit disposal.
  void dispose() {
    if (_isDisposed) return;
    _backend.dispose();
    _isDisposed = true;
  }
}
