// Arctic YouTube Downloader - Flutter (Android + Windows)
// Only download content you own or have permission to save.
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() => runApp(const DownloaderApp());

class DownloaderApp extends StatelessWidget {
  const DownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Arctic YouTube Downloader',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _url = TextEditingController();
  String _format = 'mp3';
  String _quality = 'standard';
  bool _busy = false;
  double _progress = 0;
  String _status = 'Ready.';
  int _lastStep = -1;

  static const _formats = {
    'mp3': 'MP3, audio',
    'm4a': 'M4A, audio',
    'wav': 'WAV, uncompressed audio',
    'mp4': 'MP4, video',
  };
  static const _qualities = {
    'low': 'Low, smallest file',
    'standard': 'Standard',
    'high': 'High, best quality',
  };
  static const _audioKbps = {'low': 64, 'standard': 128, 'high': 320};
  static const _videoHeight = {'low': 360, 'standard': 720, 'high': 4320};

  void _setStatus(String s) => setState(() => _status = s);

  // Announce progress only every 25 percent so screen readers are not flooded.
  void _setProgress(double p, String label) {
    final step = (p * 4).floor();
    setState(() {
      _progress = p;
      if (step != _lastStep) {
        _lastStep = step;
        _status = '$label ${(p * 100).round()} percent';
      }
    });
  }

  Future<Directory> _outputDir() async {
    Directory dir;
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        dir = Directory('/storage/emulated/0/Download/Arctic Downloads');
      } else {
        dir = (await getExternalStorageDirectory())!;
      }
    } else {
      final d = await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      dir = Directory('${d.path}${Platform.pathSeparator}Arctic Downloads');
    }
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _saveStream(YoutubeExplode yt, StreamInfo info, File file,
      String label, double from, double to) async {
    final total = info.size.totalBytes;
    var got = 0;
    final sink = file.openWrite();
    await for (final chunk in yt.videos.streamsClient.get(info)) {
      got += chunk.length;
      sink.add(chunk);
      _setProgress(from + (to - from) * (got / total), label);
    }
    await sink.flush();
    await sink.close();
  }

  Future<void> _download() async {
    final link = _url.text.trim();
    if (link.isEmpty) {
      _setStatus('Please enter a video web address first.');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _lastStep = -1;
      _status = 'Starting.';
    });

    final yt = YoutubeExplode();
    final temps = <File>[];
    try {
      final video = await yt.videos.get(link);
      final manifest = await yt.videos.streamsClient.getManifest(video.id);
      final dir = await _outputDir();
      final safe = video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final tmp = await getTemporaryDirectory();
      final out = File('${dir.path}${Platform.pathSeparator}$safe.$_format');

      if (_format == 'mp4') {
        final maxH = _videoHeight[_quality]!;
        final videos = manifest.videoOnly
            .where((s) => s.container == StreamContainer.mp4)
            .toList()
          ..sort((a, b) =>
              a.videoResolution.height.compareTo(b.videoResolution.height));
        if (videos.isEmpty) throw Exception('No MP4 video stream found.');
        final fit =
            videos.where((s) => s.videoResolution.height <= maxH).toList();
        final v = fit.isNotEmpty ? fit.last : videos.first;

        final audios = manifest.audioOnly
            .where((s) => s.container == StreamContainer.mp4)
            .toList()
          ..sort((a, b) =>
              a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
        if (audios.isEmpty) throw Exception('No audio stream found.');

        final vf = File('${tmp.path}/v_${video.id}.mp4');
        final af = File('${tmp.path}/a_${video.id}.m4a');
        temps.addAll([vf, af]);
        await _saveStream(yt, v, vf, 'Downloading video', 0, 0.7);
        await _saveStream(yt, audios.last, af, 'Downloading audio', 0.7, 0.9);
        _setStatus('Combining video and audio, please wait.');
        await _ffmpeg(
            ['-y', '-i', vf.path, '-i', af.path, '-c', 'copy', out.path]);
      } else {
        final audios = manifest.audioOnly.toList()
          ..sort((a, b) =>
              a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
        if (audios.isEmpty) throw Exception('No audio stream found.');
        // Low quality uses the smallest source, otherwise the best source.
        final src = _quality == 'low' ? audios.first : audios.last;
        final raw = File('${tmp.path}/raw_${video.id}');
        temps.add(raw);
        await _saveStream(yt, src, raw, 'Downloading', 0, 0.85);
        _setStatus('Converting to $_format, please wait.');
        final kbps = '${_audioKbps[_quality]}k';
        final args = switch (_format) {
          'mp3' => ['-y', '-i', raw.path, '-vn', '-c:a', 'libmp3lame', '-b:a', kbps, out.path],
          'm4a' => ['-y', '-i', raw.path, '-vn', '-c:a', 'aac', '-b:a', kbps, out.path],
          _ => ['-y', '-i', raw.path, '-vn', '-c:a', 'pcm_s16le', out.path],
        };
        await _ffmpeg(args);
      }
      _setProgress(1, 'Done');
      _setStatus('Finished. Saved ${video.title} in ${dir.path}');
    } catch (e) {
      _setStatus('Sorry, the download failed. $e');
    } finally {
      for (final f in temps) {
        if (await f.exists()) await f.delete();
      }
      yt.close();
      setState(() => _busy = false);
    }
  }

  Future<void> _ffmpeg(List<String> args) async {
    final session = await FFmpegKit.executeWithArguments(args);
    final code = await session.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      throw Exception('Conversion failed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final big = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Arctic YouTube Downloader')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Only download content you have permission to save.'),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Video web address',
                hintText: 'Paste the link here',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _format,
              decoration: const InputDecoration(
                  labelText: 'File type', border: OutlineInputBorder()),
              items: _formats.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: _busy ? null : (v) => setState(() => _format = v!),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _quality,
              decoration: const InputDecoration(
                  labelText: 'Quality', border: OutlineInputBorder()),
              items: _qualities.entries
                  .map((e) =>
                      DropdownMenuItem(value: e.key, child: Text(e.value)))
                  .toList(),
              onChanged: _busy ? null : (v) => setState(() => _quality = v!),
            ),
            if (_format == 'wav')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'WAV is always full quality, so the quality setting is ignored.'),
              ),
            const SizedBox(height: 24),
            SizedBox(
              height: 56,
              child: FilledButton(
                onPressed: _busy ? null : _download,
                child: Text('Download', style: big),
              ),
            ),
            const SizedBox(height: 24),
            if (_busy)
              LinearProgressIndicator(
                value: _progress,
                minHeight: 10,
                semanticsLabel: 'Download progress',
                semanticsValue: '${(_progress * 100).round()} percent',
              ),
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outline, width: 2),
                ),
                child: Text(_status, style: big),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
