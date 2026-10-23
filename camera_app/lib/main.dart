import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const kPort = 8080;
const kAccent = Color(0xFF00BFA5);
const kNames = {
  'Fashion good': 'ملابس / أزياء',
  'Home good': 'أغراض منزلية',
  'Food': 'طعام',
  'Place': 'مكان',
  'Plant': 'نبات',
};

class Det {
  final String label;
  final double conf;
  final Rect box; // normalized ltrb
  Det(this.label, this.conf, this.box);
}

class _Raw {
  final Uint8List bytes;
  final int w, h, stride;
  _Raw(this.bytes, this.w, this.h, this.stride);
}

// NV21 -> JPEG at half resolution (runs in an isolate)
Uint8List _toJpeg(_Raw r) {
  final ow = r.w ~/ 2, oh = r.h ~/ 2;
  final out = img.Image(width: ow, height: oh);
  final ySize = r.stride * r.h;
  for (var y = 0; y < oh; y++) {
    for (var x = 0; x < ow; x++) {
      final sx = x * 2, sy = y * 2;
      final yy = r.bytes[sy * r.stride + sx];
      final uv = ySize + (sy >> 1) * r.stride + (sx & ~1);
      final v = r.bytes[uv] - 128;
      final u = r.bytes[uv + 1] - 128;
      out.setPixelRgb(
        x,
        y,
        (yy + 1.402 * v).round().clamp(0, 255).toInt(),
        (yy - 0.344 * u - 0.714 * v).round().clamp(0, 255).toInt(),
        (yy + 1.772 * u).round().clamp(0, 255).toInt(),
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: 60));
}

Future<String> findIp() async {
  final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
  for (final i in list) {
    if (i.name.startsWith('wlan') || i.name.startsWith('ap')) {
      return i.addresses.first.address;
    }
  }
  for (final i in list) {
    if (!i.addresses.first.isLoopback) return i.addresses.first.address;
  }
  return 'غير متصل';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CamApp());
}

class CamApp extends StatelessWidget {
  const CamApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'كاميرا المراقبة',
        theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: kAccent,
            useMaterial3: true),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const CameraPage(),
      );
}

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
  CameraController? _cam;
  HttpServer? _server;
  final _clients = <WebSocket>[];
  final _detector = ObjectDetector(
      options: ObjectDetectorOptions(
          mode: DetectionMode.stream,
          classifyObjects: true,
          multipleObjects: true));
  List<Det> _dets = [];
  String _ip = '...', _key = '', _error = '';
  bool _busy = false;
  int _last = 0, _rot = 90;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _key = prefs.getString('key') ??
          (100000 + Random().nextInt(900000)).toString();
      await prefs.setString('key', _key);
      _ip = await findIp();
      final cams = await availableCameras();
      final back = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final ctrl = CameraController(back, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
      await ctrl.initialize();
      await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
      _rot = back.sensorOrientation;
      await _startServer();
      await ctrl.startImageStream(_onFrame);
      await WakelockPlus.enable();
      if (mounted) setState(() => _cam = ctrl);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _startServer() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
    _server!.listen((req) async {
      if (req.uri.path == '/ws' &&
          req.uri.queryParameters['k'] == _key &&
          WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        _clients.add(ws);
        if (mounted) setState(() {});
        ws.listen((_) {}, onDone: () {
          _clients.remove(ws);
          if (mounted) setState(() {});
        }, onError: (_) => _clients.remove(ws));
      } else {
        req.response.statusCode = 403;
        await req.response.close();
      }
    });
  }

  void _onFrame(CameraImage im) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_busy || now - _last < 120) return;
    _busy = true;
    _last = now;
    _process(im).whenComplete(() => _busy = false);
  }

  Future<void> _process(CameraImage im) async {
    if (im.planes.length != 1) return;
    final p = im.planes.first;
    final rot = InputImageRotationValue.fromRawValue(_rot) ??
        InputImageRotation.rotation90deg;
    final input = InputImage.fromBytes(
      bytes: p.bytes,
      metadata: InputImageMetadata(
        size: Size(im.width.toDouble(), im.height.toDouble()),
        rotation: rot,
        format: InputImageFormat.nv21,
        bytesPerRow: p.bytesPerRow,
      ),
    );
    final objs = await _detector.processImage(input);
    final swap = _rot == 90 || _rot == 270;
    final rw = (swap ? im.height : im.width).toDouble();
    final rh = (swap ? im.width : im.height).toDouble();
    final dets = objs.map((o) {
      final b = o.boundingBox;
      Label? best;
      for (final l in o.labels) {
        if (best == null || l.confidence > best.confidence) best = l;
      }
      final name = best == null ? 'جسم' : (kNames[best.text] ?? best.text);
      return Det(name, best?.confidence ?? 0,
          Rect.fromLTRB(b.left / rw, b.top / rh, b.right / rw, b.bottom / rh));
    }).toList();
    if (mounted) setState(() => _dets = dets);
    if (_clients.isEmpty) return;
    final jpg = await compute(_toJpeg, _Raw(p.bytes, im.width, im.height, p.bytesPerRow));
    final msg = jsonEncode({
      'img': base64Encode(jpg),
      'w': im.width ~/ 2,
      'h': im.height ~/ 2,
      'rot': _rot,
      'obj': dets
          .map((d) => {
                'l': d.label,
                'c': d.conf,
                'x': d.box.left,
                'y': d.box.top,
                'w': d.box.width,
                'h': d.box.height
              })
          .toList(),
    });
    for (final c in List.of(_clients)) {
      try {
        c.add(msg);
      } catch (_) {}
    }
  }

  void _showQr() {
    final name = 'كاميرا ${_ip.split('.').last}';
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF16201F),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('امسح الرمز من تطبيق الاستقبال',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(16)),
            child: QrImageView(
                data: jsonEncode({'n': name, 'ip': _ip, 'p': kPort, 'k': _key}),
                size: 230),
          ),
          const SizedBox(height: 12),
          Text('$_ip : $kPort', style: const TextStyle(color: Colors.white70)),
          Text('الرمز: $_key', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    for (final c in _clients) {
      c.close();
    }
    _server?.close(force: true);
    _cam?.dispose();
    _detector.close();
    super.dispose();
  }

  Widget _chip(IconData i, String t, {Color? c}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 16, color: c ?? kAccent),
          const SizedBox(width: 6),
          Text(t, style: const TextStyle(fontSize: 13)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('تعذر تشغيل الكاميرا\n$_error', textAlign: TextAlign.center))));
    }
    final cam = _cam;
    if (cam == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        Center(
          child: AspectRatio(
            aspectRatio: 1 / cam.value.aspectRatio,
            child: Stack(fit: StackFit.expand, children: [
              CameraPreview(cam),
              CustomPaint(painter: BoxPainter(_dets)),
            ]),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              _chip(Icons.circle, 'مباشر', c: Colors.redAccent),
              _chip(Icons.visibility, 'المشاهدون: ${_clients.length}'),
              _chip(Icons.category, 'أجسام: ${_dets.length}'),
            ]),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FilledButton.icon(
                onPressed: _showQr,
                icon: const Icon(Icons.qr_code_2),
                label: const Text('رمز الربط'),
                style: FilledButton.styleFrom(
                    minimumSize: const Size(220, 54),
                    textStyle: const TextStyle(fontSize: 17)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class BoxPainter extends CustomPainter {
  final List<Det> dets;
  BoxPainter(this.dets);
  @override
  void paint(Canvas c, Size s) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = kAccent;
    for (final d in dets) {
      final r = Rect.fromLTRB(d.box.left * s.width, d.box.top * s.height,
          d.box.right * s.width, d.box.bottom * s.height);
      c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), p);
      final tp = TextPainter(
        text: TextSpan(
            text: ' ${d.label} ${(d.conf * 100).round()}% ',
            style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                backgroundColor: kAccent)),
        textDirection: TextDirection.rtl,
      )..layout();
      tp.paint(c, Offset(r.left, max(0, r.top - tp.height)));
    }
  }

  @override
  bool shouldRepaint(BoxPainter o) => true;
}
