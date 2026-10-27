import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../../core/data/record_store.dart';
import '../../core/data/tool_record.dart';
import '../../core/storage/data_mutation_gate.dart';
import '../../core/storage/owned_file_store.dart';
import '../archive/archive_service.dart';

class ImageOptions {
  const ImageOptions({
    this.format = 'png',
    this.width = 0,
    this.height = 0,
    this.quality = 85,
    this.cropX = 0,
    this.cropY = 0,
    this.cropWidth = 0,
    this.cropHeight = 0,
    this.stripExif = true,
    this.whiteBackground = false,
    this.watermark,
    this.rotation = 0,
    this.flipHorizontal = false,
    this.flipVertical = false,
    this.scalePercent = 100,
    this.maintainAspect = false,
    this.noUpscale = false,
    this.watermarkOpacity = 1,
    this.watermarkPercent = 0,
    this.watermarkPosition = 'bottomRight',
    this.watermarkMargin = 0,
    this.textWatermark = '',
    this.textColor = 0xffeeeeee,
    this.textSize = 24,
  });
  final String format;
  final int width, height, quality, cropX, cropY, cropWidth, cropHeight;
  final bool stripExif, whiteBackground;
  final Uint8List? watermark;
  final int rotation,
      scalePercent,
      watermarkPercent,
      watermarkMargin,
      textColor,
      textSize;
  final bool flipHorizontal, flipVertical, maintainAspect, noUpscale;
  final double watermarkOpacity;
  final String watermarkPosition, textWatermark;
  void validate() {
    if (!{'png', 'jpg', 'webp'}.contains(format) ||
        quality < 1 ||
        quality > 100 ||
        width < 0 ||
        height < 0 ||
        width > 4096 ||
        height > 4096 ||
        cropX < 0 ||
        cropY < 0 ||
        cropWidth < 0 ||
        cropHeight < 0) {
      throw const ToolFailure('图片参数无效：输出PNG/JPG/WebP，尺寸最多4096，质量1–100。');
    }
    if (!{0, 90, 180, 270}.contains(rotation) ||
        scalePercent < 1 ||
        scalePercent > 400 ||
        watermarkOpacity < 0 ||
        watermarkOpacity > 1 ||
        !watermarkOpacity.isFinite ||
        watermarkPercent < 0 ||
        watermarkPercent > 100 ||
        watermarkMargin < 0 ||
        watermarkMargin > 500 ||
        !{
          'topLeft',
          'topRight',
          'bottomLeft',
          'bottomRight',
          'center',
        }.contains(watermarkPosition) ||
        textSize < 8 ||
        textSize > 128 ||
        textWatermark.length > 200) {
      throw const ToolFailure('旋转、缩放或水印参数无效。');
    }
    if ((cropWidth == 0) != (cropHeight == 0)) {
      throw const ToolFailure('裁剪宽高必须同时填写。');
    }
  }
}

class ImageOutput {
  const ImageOutput(this.bytes, this.width, this.height, this.exif);
  final Uint8List bytes;
  final int width, height;
  final String exif;
}

img.Image _decode(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 25 * 1024 * 1024) {
    throw const ToolFailure('单张图片最多25MB。');
  }
  final decoder = img.findDecoderForData(bytes),
      info = img.findDecoderForData(bytes)?.startDecode(bytes);
  if (decoder == null ||
      info == null ||
      info.width * info.height > 24 * 1024 * 1024) {
    throw const ToolFailure('无法识别图片，或超过2400万像素。');
  }
  if (info.numFrames > 1) throw const ToolFailure('当前批处理只处理静态图片，避免静默丢弃动画帧。');
  final image = decoder.decode(bytes);
  if (image == null) throw const ToolFailure('图片解码失败。');
  return image;
}

ImageOutput _transform(Uint8List bytes, ImageOptions options) {
  options.validate();
  var image = _decode(bytes);
  final exif = image.exif.toString();
  image = img.bakeOrientation(image);
  if (options.rotation != 0) {
    image = img.copyRotate(image, angle: options.rotation);
  }
  if (options.flipHorizontal) image = img.flipHorizontal(image);
  if (options.flipVertical) image = img.flipVertical(image);
  if (options.cropWidth > 0) {
    if (options.cropX + options.cropWidth > image.width ||
        options.cropY + options.cropHeight > image.height) {
      throw const ToolFailure('裁剪区域超出图片边界。');
    }
    image = img.copyCrop(
      image,
      x: options.cropX,
      y: options.cropY,
      width: options.cropWidth,
      height: options.cropHeight,
    );
  }
  if (options.width > 0 || options.height > 0 || options.scalePercent != 100) {
    int? width = options.width > 0 ? options.width : null,
        height = options.height > 0 ? options.height : null;
    if (width == null && height == null) {
      width = (image.width * options.scalePercent / 100).round().clamp(
        1,
        16384,
      );
      if (width > 4096 || image.height * options.scalePercent / 100 > 4096) {
        throw const ToolFailure('百分比缩放结果超过4096，请降低比例。');
      }
    }
    if (options.maintainAspect && width != null && height != null) {
      final ratio = (width / image.width) < (height / image.height)
          ? width / image.width
          : height / image.height;
      width = (image.width * ratio).round().clamp(1, 4096);
      height = null;
    }
    if (options.noUpscale &&
        (width != null && width > image.width ||
            height != null && height > image.height)) {
      width = image.width;
      height = null;
    }
    image = img.copyResize(
      image,
      width: width,
      height: height,
      interpolation: img.Interpolation.average,
    );
  }
  if (image.width * image.height > 16 * 1024 * 1024 ||
      image.width > 4096 ||
      image.height > 4096) {
    throw const ToolFailure('输出图片过大。');
  }
  if (options.whiteBackground || options.format == 'jpg') {
    final white = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    )..clear(img.ColorRgb8(255, 255, 255));
    img.compositeImage(white, image);
    white.exif = image.exif.clone();
    image = white;
  }
  if (options.watermark != null) {
    var mark = _decode(options.watermark!);
    if (options.watermarkPercent > 0) {
      mark = img.copyResize(
        mark,
        width: (image.width * options.watermarkPercent / 100).round().clamp(
          1,
          4096,
        ),
      );
    }
    if (mark.width > image.width || mark.height > image.height) {
      mark = img.copyResize(
        mark,
        width: (image.width ~/ 3).clamp(1, 4096),
        maintainAspect: true,
      );
    }
    if (mark.height > image.height) throw const ToolFailure('水印比例不适合当前图片。');
    mark = mark.convert(numChannels: 4);
    for (final pixel in mark) {
      pixel.a = (pixel.a * options.watermarkOpacity).round();
    }
    final location = _watermarkLocation(
      image.width,
      image.height,
      mark.width,
      mark.height,
      options,
    );
    img.compositeImage(image, mark, dstX: location.$1, dstY: location.$2);
  }
  if (options.textWatermark.isNotEmpty) {
    // The bundled bitmap font is deliberately ASCII only. Chinese is rendered
    // by the UI into a transparent PNG and uses the same image watermark path.
    if (options.textWatermark.runes.any((r) => r > 126 || r < 32)) {
      throw const ToolFailure('此离线字体仅支持ASCII，请使用UI生成中文文字水印。');
    }
    var mark = img.Image(
      width: (options.textWatermark.length * 15).clamp(1, 4096),
      height: 32,
      numChannels: 4,
    );
    img.drawString(
      mark,
      options.textWatermark,
      font: img.arial24,
      color: img.ColorRgba8(
        (options.textColor >> 16) & 255,
        (options.textColor >> 8) & 255,
        options.textColor & 255,
        (255 * options.watermarkOpacity).round(),
      ),
    );
    mark = img.copyResize(mark, height: options.textSize);
    if (mark.width > image.width || mark.height > image.height) {
      throw const ToolFailure('文字水印超出图片范围，请减小字号。');
    }
    final at = _watermarkLocation(
      image.width,
      image.height,
      mark.width,
      mark.height,
      options,
    );
    img.compositeImage(image, mark, dstX: at.$1, dstY: at.$2);
  }
  if (options.stripExif) image.exif = img.ExifData();
  final out = switch (options.format) {
    'jpg' => img.encodeJpg(image, quality: options.quality),
    'webp' => img.encodeWebP(image, lossless: false, quality: options.quality),
    _ => img.encodePng(image),
  };
  return ImageOutput(out, image.width, image.height, exif);
}

(int, int) _watermarkLocation(
  int width,
  int height,
  int markWidth,
  int markHeight,
  ImageOptions options,
) {
  final margin = options.watermarkMargin;
  if (markWidth + margin > width || markHeight + margin > height) {
    throw const ToolFailure('水印边距或尺寸超出图片。');
  }
  return switch (options.watermarkPosition) {
    'topLeft' => (margin, margin),
    'topRight' => (width - markWidth - margin, margin),
    'bottomLeft' => (margin, height - markHeight - margin),
    'center' => ((width - markWidth) ~/ 2, (height - markHeight) ~/ 2),
    _ => (width - markWidth - margin, height - markHeight - margin),
  };
}

Future<ImageOutput> transformImageAsync(
  Uint8List bytes,
  ImageOptions options,
) => Isolate.run(() => _transform(bytes, options));

class ImageToolService {
  ImageToolService(this.store, this.files);
  final RecordStore store;
  final Future<OwnedFileStore> Function() files;
  Future<ImageOutput> preview(Uint8List bytes, ImageOptions options) =>
      transformImageAsync(bytes, options);
  Future<ToolRecord> process(
    String name,
    Uint8List bytes,
    ImageOptions options,
    TaskCancellation cancel, {
    required bool confirmed,
    String jobId = '',
  }) async {
    if (!confirmed) throw const ToolFailure('图片处理需要确认输出格式与范围。');
    cancel.check();
    final output = await preview(bytes, options);
    cancel.check();
    return DataMutationGate.shared.run(() async {
      cancel.check();
      final owned = await files(),
          relative = await (await files()).write(
            'utilities',
            output.bytes,
            extension: options.format,
          );
      try {
        return await store.create(
          'utility_output',
          name,
          data: {
            'payloadVersion': 1,
            'attachment': relative,
            'format': options.format,
            'width': output.width,
            'height': output.height,
            'size': output.bytes.length,
            'checksum': sha256.convert(output.bytes).toString(),
            'source': 'imageTool',
            'jobId': jobId,
            'exifRemoved': options.stripExif,
            'syncAllowed': false,
          },
        );
      } catch (_) {
        await owned.remove(relative);
        rethrow;
      }
    });
  }
}
