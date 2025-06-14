import 'package:image/image.dart' as img;

/// Draws the source image onto the destination image at the specified position.
///
/// This function overlays [src] image onto [dst] image starting at the given
/// coordinates. It's optimized for thermal printer use cases.
///
/// Parameters:
/// - [dst]: The destination image to draw onto
/// - [src]: The source image to be drawn
/// - [dstX]: X coordinate on destination image (default: 0)
/// - [dstY]: Y coordinate on destination image (default: 0)
/// - [blend]: Blend mode for compositing (default: BlendMode.over)
///
/// Returns: The modified destination image
img.Image drawImage(
  img.Image dst,
  img.Image src, {
  int dstX = 0,
  int dstY = 0,
  img.BlendMode blend = img.BlendMode.overlay,
}) {
  // Validate input parameters
  if (dstX < 0 || dstY < 0) {
    throw ArgumentError('Destination coordinates cannot be negative');
  }

  // Check if there's anything to draw within bounds
  if (dstX >= dst.width || dstY >= dst.height) {
    return dst; // Nothing to draw within bounds
  }

  // Use the built-in compositeImage function for efficient blending
  return img.compositeImage(dst, src, dstX: dstX, dstY: dstY, blend: blend);
}

/// Convenience function to center an image within another image.
///
/// This function draws the source image centered within the destination image.
/// If the source image is larger than the destination, it will be clipped.
///
/// Parameters:
/// - [dst]: The destination image
/// - [src]: The source image to be centered
/// - [blend]: Blend mode for compositing (default: BlendMode.over)
///
/// Returns: The modified destination image
img.Image drawImageCentered(
  img.Image dst,
  img.Image src, {
  img.BlendMode blend = img.BlendMode.overlay,
}) {
  final centerX = (dst.width - src.width) ~/ 2;
  final centerY = (dst.height - src.height) ~/ 2;

  return drawImage(dst, src, dstX: centerX, dstY: centerY, blend: blend);
}

/// Simple pixel-based drawing for cases where compositeImage doesn't work as expected
///
/// This is a fallback function that manually copies pixels from source to destination.
/// Use this if you encounter issues with the standard drawImage function.
///
/// Parameters:
/// - [dst]: The destination image to draw onto
/// - [src]: The source image to be drawn
/// - [dstX]: X coordinate on destination image (default: 0)
/// - [dstY]: Y coordinate on destination image (default: 0)
///
/// Returns: The modified destination image
img.Image drawImageManual(
  img.Image dst,
  img.Image src, {
  int dstX = 0,
  int dstY = 0,
}) {
  // Validate input parameters
  if (dstX < 0 || dstY < 0) {
    throw ArgumentError('Destination coordinates cannot be negative');
  }

  // Calculate the actual drawing area considering destination bounds
  final drawWidth =
      (dstX + src.width > dst.width) ? dst.width - dstX : src.width;
  final drawHeight =
      (dstY + src.height > dst.height) ? dst.height - dstY : src.height;

  // Check if there's anything to draw within bounds
  if (dstX >= dst.width ||
      dstY >= dst.height ||
      drawWidth <= 0 ||
      drawHeight <= 0) {
    return dst; // Nothing to draw within bounds
  }

  // Perform pixel-by-pixel copying
  for (int y = 0; y < drawHeight; y++) {
    for (int x = 0; x < drawWidth; x++) {
      final srcPixel = src.getPixel(x, y);
      dst.setPixel(dstX + x, dstY + y, srcPixel);
    }
  }

  return dst;
}

/// Creates a composite image by overlaying multiple images.
///
/// This function takes a base image and overlays multiple source images
/// with their respective positions and blend modes.
///
/// Parameters:
/// - [base]: The base image to draw onto
/// - [overlays]: List of overlay configurations
///
/// Returns: The composite image
img.Image createComposite(img.Image base, List<ImageOverlay> overlays) {
  img.Image result = img.Image.from(base);

  for (final overlay in overlays) {
    result = drawImage(
      result,
      overlay.image,
      dstX: overlay.x,
      dstY: overlay.y,
      blend: overlay.blendMode,
    );
  }

  return result;
}

/// Configuration class for image overlays
class ImageOverlay {
  final img.Image image;
  final int x;
  final int y;
  final img.BlendMode blendMode;

  const ImageOverlay({
    required this.image,
    this.x = 0,
    this.y = 0,
    this.blendMode = img.BlendMode.overlay,
  });
}

/// Utility function to create a frame with specified dimensions and background color
///
/// This creates a new image with the specified dimensions and fills it
/// with the given background color.
///
/// Parameters:
/// - [width]: Width of the frame
/// - [height]: Height of the frame
/// - [backgroundColor]: Background color (default: white)
///
/// Returns: The created frame image
img.Image createFrame({
  required int width,
  required int height,
  img.Color? backgroundColor,
}) {
  final bgColor = backgroundColor ?? img.ColorRgb8(255, 255, 255);
  return img.Image(width: width, height: height, backgroundColor: bgColor);
}

/// Utility function to resize an image while maintaining aspect ratio
///
/// This function resizes an image to fit within the specified dimensions
/// while preserving the original aspect ratio.
///
/// Parameters:
/// - [src]: The source image to resize
/// - [maxWidth]: Maximum width (optional)
/// - [maxHeight]: Maximum height (optional)
/// - [maintainAspect]: Whether to maintain aspect ratio (default: true)
///
/// Returns: The resized image
img.Image resizeImageToFit(
  img.Image src, {
  int? maxWidth,
  int? maxHeight,
  bool maintainAspect = true,
}) {
  if (maxWidth == null && maxHeight == null) {
    return src; // No resizing needed
  }

  if (!maintainAspect) {
    return img.copyResize(
      src,
      width: maxWidth ?? src.width,
      height: maxHeight ?? src.height,
    );
  }

  // Calculate the scaling factor to fit within bounds
  double scaleX = maxWidth != null ? maxWidth / src.width : double.infinity;
  double scaleY = maxHeight != null ? maxHeight / src.height : double.infinity;
  double scale = scaleX < scaleY ? scaleX : scaleY;

  if (scale >= 1.0) {
    return src; // No scaling needed
  }

  final newWidth = (src.width * scale).round();
  final newHeight = (src.height * scale).round();

  return img.copyResize(src, width: newWidth, height: newHeight);
}

/// Utility function to create a bordered frame around an image
///
/// This function creates a new image with a border around the source image.
///
/// Parameters:
/// - [src]: The source image
/// - [borderWidth]: Width of the border in pixels
/// - [borderColor]: Color of the border (default: black)
/// - [backgroundColor]: Background color (default: white)
///
/// Returns: The image with border
img.Image addBorder(
  img.Image src, {
  int borderWidth = 1,
  img.Color? borderColor,
  img.Color? backgroundColor,
}) {
  final bColor = borderColor ?? img.ColorRgb8(0, 0, 0);
  final bgColor = backgroundColor ?? img.ColorRgb8(255, 255, 255);

  final newWidth = src.width + (borderWidth * 2);
  final newHeight = src.height + (borderWidth * 2);

  // Create frame with background color
  final frame = createFrame(
    width: newWidth,
    height: newHeight,
    backgroundColor: bgColor,
  );

  // Draw border
  img.drawRect(
    frame,
    x1: 0,
    y1: 0,
    x2: newWidth - 1,
    y2: newHeight - 1,
    color: bColor,
    thickness: borderWidth,
  );

  // Draw the source image in the center
  return drawImage(frame, src, dstX: borderWidth, dstY: borderWidth);
}
