import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const kAccent = Color(0xFF00BFA5);

class CamInfo {
  final String name, ip, key;
  final int port;
  CamInfo(this.name, this.ip, this.port, this.key);
  Map<String, dynamic> toJson() => {'n': name, 'ip': ip, 'p': port, 'k': key};
  factory CamInfo.fromJson(Map j) =>
      CamInfo('${j['n'] ?? 'كاميرا'}', '${j['ip']}', (j['p'] ?? 8080) as int, '${j['k']}');
}

class Det {
  final String label;
  final double conf;
  final Rect box;
  Det(this.label, this.conf, this.box);
}

void main() => runApp(const ReceiverApp());

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'مراقبة المنزل',
        theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: kAccent,
            useMaterial3: true),
        builder: (c, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<CamInfo> _cams = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _load();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final l = p.getStringList('cams') ?? [];
    setState(() => _cams = l.map((e) => CamInfo.fromJson(jsonDecode(e))).toList());
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('cams', _cams.map((e) => jsonEncode(e.toJson())).toList());
  }

  Future<void> _add() async {
    final info = await Navigator.push<CamInfo>(
        context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (info == null) return;
    setState(() {
      _cams.removeWhere((c) => c.ip == info.ip);
      _cams.add(info);
    });
    _save();
  }

  void _remove(CamInfo c) {
    setState(() => _cams.remove(c));
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مراقبة المنزل'),
        actions: [
          IconButton(
              onPressed: _add,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'إضافة كاميرا'),
        ],
      ),
      body: _cams.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.videocam_off_outlined, size: 72, color: Colors.white38),
                const SizedBox(height: 16),
                const Text('لا توجد كاميرات بعد', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 20),
                FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('مسح رمز الكاميرا')),
              ]),
            )
          : GridView.count(
              padding: const EdgeInsets.all(12),
              crossAxisCount: _cams.length == 1 ? 1 : 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: _cams.length == 1 ? 0.72 : 0.62,
              children: [
                for (final c in _cams)
                  CamTile(key: ValueKey('${c.ip}:${c.key}'), info: c, onDelete: () => _remove(c)),
              ],
            ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _ctrl = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _finish(CamInfo i) {
    if (_done) return;
    _done = true;
    Navigator.pop(context, i);
  }

  Future<void> _manual() async {
    final ip = TextEditingController();
    final key = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('إدخال يدوي'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: ip,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'عنوان الكاميرا (IP)')),
          const SizedBox(height: 8),
          TextField(
              controller: key,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'الرمز')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('إضافة')),
        ],
      ),
    );
    if (ok == true && ip.text.trim().isNotEmpty && key.text.trim().isNotEmpty) {
      _finish(CamInfo('كاميرا ${ip.text.trim()}', ip.text.trim(), 8080, key.text.trim()));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('امسح رمز الكاميرا'), actions: [
          IconButton(
              onPressed: () => _ctrl.switchCamera(),
              icon: const Icon(Icons.cameraswitch),
              tooltip: 'تبديل الكاميرا'),
        ]),
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(
            controller: _ctrl,
            errorBuilder: (context, error, child) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'تعذر تشغيل الماسح\nالنوع: ${error.errorCode.name}\nالتفاصيل: ${error.errorDetails?.message ?? '-'}',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                ),
              ),
            ),
            onDetect: (cap) {
              for (final b in cap.barcodes) {
                try {
                  final j = jsonDecode(b.rawValue ?? '');
                  if (j is Map && j['ip'] != null && j['k'] != null) {
                    _finish(CamInfo.fromJson(j));
                    return;
                  }
                } catch (_) {}
              }
            },
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: FilledButton.tonalIcon(
                    onPressed: _manual,
                    icon: const Icon(Icons.keyboard),
                    label: const Text('إدخال يدوي')),
              ),
            ),
          ),
        ]),
      );
}

class CamTile extends StatefulWidget {
  final CamInfo info;
  final VoidCallback onDelete;
  const CamTile({super.key, required this.info, required this.onDelete});
  @override
  State<CamTile> createState() => _CamTileState();
}

class _CamTileState extends State<CamTile> {
  WebSocket? _ws;
  Timer? _retry;
  bool _online = false, _disposed = false;
  Uint8List? _frame;
  double _asp = 2 / 3;
  int _rot = 90;
  List<Det> _dets = [];
  IOSink? _rec;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final i = widget.info;
    try {
      final ws = await WebSocket.connect('ws://${i.ip}:${i.port}/ws?k=${i.key}')
          .timeout(const Duration(seconds: 4));
      if (_disposed) {
        ws.close();
        return;
      }
      _ws = ws;
      setState(() => _online = true);
      ws.listen(_onMsg, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
    } catch (_) {
      _lost();
    }
  }

  void _lost() {
    _ws = null;
    if (_disposed) return;
    if (mounted) setState(() => _online = false);
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), _connect);
  }

  void _onMsg(dynamic m) {
    if (m is! String) return;
    final j = jsonDecode(m);
    final bytes = base64Decode(j['img']);
    _rec?.add(bytes);
    final rot = j['rot'] as int;
    final w = (j['w'] as num).toDouble(), h = (j['h'] as num).toDouble();
    final dets = (j['obj'] as List)
        .map((o) => Det('${o['l']}', (o['c'] as num).toDouble(),
            Rect.fromLTWH((o['x'] as num).toDouble(), (o['y'] as num).toDouble(), (o['w'] as num).toDouble(), (o['h'] as num).toDouble())))
        .toList();
    if (!mounted) return;
    setState(() {
      _frame = bytes;
      _rot = rot;
      _asp = (rot == 90 || rot == 270) ? h / w : w / h;
      _dets = dets;
    });
  }

  Future<void> _toggleRec() async {
    if (_rec != null) {
      await _rec!.flush();
      await _rec!.close();
      setState(() => _rec = null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم حفظ التسجيل')));
      }
      return;
    }
    final base = await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/recordings');
    await dir.create(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final f = File('${dir.path}/${widget.info.ip}_$ts.mjpeg');
    setState(() => _rec = f.openWrite());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('بدأ التسجيل: ${f.path}')));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    _rec?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Container(
        color: Colors.black,
        child: Stack(fit: StackFit.expand, children: [
          if (_frame == null)
            Center(
                child: _online
                    ? const CircularProgressIndicator()
                    : const Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.wifi_off, color: Colors.white38, size: 40),
                        SizedBox(height: 8),
                        Text('جاري الاتصال...', style: TextStyle(color: Colors.white54)),
                      ]))
          else
            Center(
              child: AspectRatio(
                aspectRatio: _asp,
                child: Stack(fit: StackFit.expand, children: [
                  RotatedBox(
                      quarterTurns: _rot ~/ 90,
                      child: Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill)),
                  CustomPaint(painter: BoxPainter(_dets)),
                ]),
              ),
            ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.black87, Colors.transparent], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: Row(children: [
                Icon(Icons.circle, size: 10, color: _online ? Colors.greenAccent : Colors.redAccent),
                const SizedBox(width: 6),
                Expanded(child: Text(widget.info.name, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                if (_rec != null) const Icon(Icons.fiber_manual_record, size: 14, color: Colors.red),
              ]),
            ),
          ),
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              decoration: const BoxDecoration(
                  gradient: LinearGradient(colors: [Colors.transparent, Colors.black87], begin: Alignment.topCenter, end: Alignment.bottomCenter)),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                IconButton(
                    onPressed: _frame == null ? null : _toggleRec,
                    icon: Icon(_rec != null ? Icons.stop_circle : Icons.fiber_manual_record, color: _rec != null ? Colors.red : Colors.white)),
                IconButton(onPressed: widget.onDelete, icon: const Icon(Icons.delete_outline)),
              ]),
            ),
          ),
        ]),
      ),
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
      ..strokeWidth = 2
      ..color = kAccent;
    for (final d in dets) {
      final r = Rect.fromLTRB(d.box.left * s.width, d.box.top * s.height, d.box.right * s.width, d.box.bottom * s.height);
      c.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), p);
      final tp = TextPainter(
        text: TextSpan(
            text: ' ${d.label} ${(d.conf * 100).round()}% ',
            style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold, backgroundColor: kAccent)),
        textDirection: TextDirection.rtl,
      )..layout();
      tp.paint(c, Offset(r.left, max(0, r.top - tp.height)));
    }
  }

  @override
  bool shouldRepaint(BoxPainter o) => true;
}
