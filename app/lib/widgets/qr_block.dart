import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/services.dart';
import '../theme/tokens.dart';
import 'common.dart';

const _qrEye = QrEyeStyle(eyeShape: QrEyeShape.square, color: C.ink);
const _qrData = QrDataModuleStyle(
  dataModuleShape: QrDataModuleShape.square,
  color: C.ink,
);

/// QR code for a check link, with copy and download.
class QrBlock extends StatelessWidget {
  const QrBlock({super.key, required this.url, required this.fileStem});

  final String url;
  final String fileStem;

  Future<void> _download(BuildContext context) async {
    final browser = Services.of(context).browser;
    const size = 720.0;
    const pad = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, size + pad * 2, size + pad * 2),
        Paint()..color = Colors.white,
      )
      ..translate(pad, pad);
    QrPainter(
      data: url,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      gapless: true,
      eyeStyle: _qrEye,
      dataModuleStyle: _qrData,
    ).paint(canvas, const Size(size, size));
    final image = await recorder.endRecording().toImage(
      (size + pad * 2).toInt(),
      (size + pad * 2).toInt(),
    );
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    browser.download(
      data.buffer.asUint8List(),
      '$fileStem-qr.png',
      'image/png',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(S.x2),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: C.rule),
                borderRadius: BorderRadius.circular(R.control),
              ),
              child: QrImageView(
                data: url,
                size: 132,
                padding: EdgeInsets.zero,
                gapless: true,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                eyeStyle: _qrEye,
                dataModuleStyle: _qrData,
                semanticsLabel: 'QR code that opens this check page',
              ),
            ),
            const SizedBox(width: S.x4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Print it on the certificate or show it on screen. '
                    'Scanning it opens this page.',
                    style: T.small,
                  ),
                  const SizedBox(height: S.x2),
                  TextButton.icon(
                    onPressed: () => _download(context),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('Download QR code'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: S.x4),
        LinkField(label: 'Check link', url: url),
      ],
    );
  }
}
