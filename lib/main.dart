import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const PureReadApp());

const _pageSize = 1800;
const _catalogKey = 'pure_read_catalog_v1';
const _darkKey = 'pure_read_dark_v1';
const _fontKey = 'pure_read_font_v1';

class Book {
  Book({
    required this.id,
    required this.title,
    required this.format,
    required this.fileName,
    required this.content,
    this.position = 0,
    DateTime? lastRead,
  }) : lastRead = lastRead ?? DateTime.now();

  final String id;
  String title;
  String format;
  String fileName;
  String content;
  int position;
  DateTime lastRead;

  int get progress => content.isEmpty
      ? 0
      : ((position.clamp(0, content.length) / content.length) * 100).round();

  Map<String, Object?> toJson({bool includeContent = false}) => {
        'id': id,
        'title': title,
        'format': format,
        'fileName': fileName,
        'position': position,
        'lastRead': lastRead.toIso8601String(),
        if (includeContent) 'content': content,
      };

  factory Book.fromJson(Map<String, dynamic> json, {String? content}) => Book(
        id: json['id'] as String,
        title: json['title'] as String? ?? '未命名',
        format: json['format'] as String? ?? 'TXT',
        fileName: json['fileName'] as String? ?? '${json['id']}.txt',
        content: content ?? json['content'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        lastRead: DateTime.tryParse(json['lastRead'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class PureReadApp extends StatefulWidget {
  const PureReadApp({super.key});
  @override
  State<PureReadApp> createState() => _PureReadAppState();
}

class _PureReadAppState extends State<PureReadApp> {
  bool _dark = false;
  double _fontSize = 19;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dark = prefs.getBool(_darkKey) ?? false;
      _fontSize = prefs.getDouble(_fontKey) ?? 19;
    });
  }

  Future<void> _toggleTheme() async {
    setState(() => _dark = !_dark);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_darkKey, _dark);
  }

  Future<void> _changeFont(double delta) async {
    setState(() => _fontSize = (_fontSize + delta).clamp(14, 32));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_fontKey, _fontSize);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PureRead',
        debugShowCheckedModeBanner: false,
        themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
        theme: _buildTheme(Brightness.light),
        darkTheme: _buildTheme(Brightness.dark),
        home: LibraryScreen(
          dark: _dark,
          fontSize: _fontSize,
          onToggleTheme: _toggleTheme,
          onFontChange: _changeFont,
        ),
      );

  ThemeData _buildTheme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff79684f),
      brightness: brightness,
      surface: dark ? const Color(0xff191817) : const Color(0xfff8f6f1),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xff191817) : const Color(0xfff8f6f1),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xff191817) : const Color(0xfff8f6f1),
        foregroundColor: dark ? const Color(0xffefede7) : const Color(0xff292722),
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xff242220) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.dark,
    required this.fontSize,
    required this.onToggleTheme,
    required this.onFontChange,
  });
  final bool dark;
  final double fontSize;
  final VoidCallback onToggleTheme;
  final ValueChanged<double> onFontChange;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Book> _books = [];
  bool _loading = true;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<Directory> get _bookDirectory async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory('${root.path}/pure_read_books');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _loadLibrary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_catalogKey);
      final dir = await _bookDirectory;
      final loaded = <Book>[];
      if (raw != null) {
        for (final item in (jsonDecode(raw) as List).cast<Map<String, dynamic>>()) {
          final book = Book.fromJson(item);
          final file = File('${dir.path}/${book.fileName}');
          if (await file.exists()) book.content = await file.readAsString();
          if (book.content.isNotEmpty) {
            book.position = book.position.clamp(0, book.content.length);
            loaded.add(book);
          }
        }
      }
      loaded.sort((a, b) => b.lastRead.compareTo(a.lastRead));
      if (mounted) setState(() => _books = loaded);
    } catch (e) {
      _message('读取书架失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _catalogKey,
      jsonEncode(_books.map((book) => book.toJson()).toList()),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _importBooks() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['txt', 'epub', 'mobi', 'md'],
        withData: true,
      );
      if (result == null) return;
      setState(() => _working = true);
      final directory = await _bookDirectory;
      var added = 0;
      for (final picked in result.files) {
        final bytes = picked.bytes ??
            (picked.path == null ? null : await File(picked.path!).readAsBytes());
        if (bytes == null || bytes.isEmpty) continue;
        final ext = picked.extension?.toLowerCase() ?? '';
        final content = _extractText(bytes, ext);
        if (content.trim().isEmpty) continue;
        final id = '${DateTime.now().microsecondsSinceEpoch}_${added++}';
        final storedName = '$id.txt';
        await File('${directory.path}/$storedName').writeAsString(content);
        final title = picked.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        _books.insert(
          0,
          Book(
            id: id,
            title: title.isEmpty ? '未命名' : title,
            format: ext.toUpperCase(),
            fileName: storedName,
            content: content,
          ),
        );
      }
      await _saveLibrary();
      if (mounted) setState(() {});
      _message(added == 0 ? '没有导入可读取的文件' : '已导入 $added 本书');
    } catch (e) {
      _message('导入失败：$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _extractText(Uint8List bytes, String ext) {
    if (ext == 'txt' || ext == 'md') return _decodeText(bytes);
    if (ext == 'epub') return _extractEpub(bytes);
    if (ext == 'mobi') return _extractMobi(bytes);
    throw FormatException('不支持的格式：$ext');
  }

  String _decodeText(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true).replaceFirst('\uFEFF', '');
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  String _extractEpub(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, String>{};
    for (final file in archive.files.where((f) => f.isFile)) {
      final name = file.name.replaceAll('\\', '/');
      files[name] = _decodeText(file.content as List<int>);
    }
    final container = files['META-INF/container.xml'];
    if (container == null) throw const FormatException('EPUB 缺少 container.xml');
    final rootPath = RegExp(r'<rootfile[^>]*full-path=["\']([^"\']+)')
            .firstMatch(container)
            ?.group(1) ??
        '';
    final opf = files[rootPath];
    if (opf == null) throw const FormatException('EPUB 目录文件无效');
    final base = rootPath.contains('/') ? rootPath.substring(0, rootPath.lastIndexOf('/') + 1) : '';
    final manifest = <String, String>{};
    for (final match in RegExp(r'<item\b([^>]*)/?>', caseSensitive: false).allMatches(opf)) {
      final attrs = match.group(1)!;
      final id = RegExp(r'\bid=["\']([^"\']+)').firstMatch(attrs)?.group(1);
      final href = RegExp(r'\bhref=["\']([^"\']+)').firstMatch(attrs)?.group(1);
      final media = RegExp(r'\bmedia-type=["\']([^"\']+)').firstMatch(attrs)?.group(1) ?? '';
      if (id != null && href != null && (media.contains('html') || href.endsWith('.xhtml') || href.endsWith('.html'))) {
        manifest[id] = _normalizeArchivePath('$base${Uri.decodeComponent(href)}');
      }
    }
    final chapters = <String>[];
    for (final match in RegExp(r'<itemref\b[^>]*\bidref=["\']([^"\']+)', caseSensitive: false).allMatches(opf)) {
      final path = manifest[match.group(1)];
      if (path != null && files[path] != null) chapters.add(_htmlToText(files[path]!));
    }
    if (chapters.isEmpty) {
      for (final entry in files.entries.where((e) => e.key.endsWith('.xhtml') || e.key.endsWith('.html'))) {
        chapters.add(_htmlToText(entry.value));
      }
    }
    return chapters.join('\n\n');
  }

  String _normalizeArchivePath(String path) {
    final parts = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  String _htmlToText(String html) {
    final body = html
        .replaceAll(RegExp(r'(?is)<(script|style)[^>]*>.*?</\1>'), '')
        .replaceAll(RegExp(r'(?i)<br\s*/?>|</(p|div|h[1-6]|li|tr|section|article)>'), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    return _decodeEntities(body).replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n').trim();
  }

  String _decodeEntities(String text) => text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAllMapped(RegExp(r'&#(x[0-9a-fA-F]+|[0-9]+);'), (m) {
        final value = m.group(1)!;
        final code = value.startsWith('x') || value.startsWith('X')
            ? int.tryParse(value.substring(1), radix: 16)
            : int.tryParse(value);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      });

  String _extractMobi(Uint8List bytes) {
    if (bytes.length < 86) throw const FormatException('MOBI 文件过短');
    final data = ByteData.sublistView(bytes);
    final records = data.getUint16(76, Endian.big);
    if (records == 0 || bytes.length < 78 + records * 8) throw const FormatException('MOBI 数据库无效');
    final offsets = <int>[];
    for (var i = 0; i < records; i++) {
      offsets.add(data.getUint32(78 + i * 8, Endian.big));
    }
    final first = offsets.first;
    if (first + 16 > bytes.length) throw const FormatException('MOBI 头部无效');
    final compression = data.getUint16(first, Endian.big);
    final textLength = data.getUint32(first + 4, Endian.big);
    final textRecordCount = data.getUint16(first + 8, Endian.big);
    final recordSize = data.getUint16(first + 10, Endian.big);
    if (textRecordCount == 0 || recordSize == 0 || offsets.length < textRecordCount + 1) {
      throw const FormatException('MOBI 文本记录无效');
    }
    final output = BytesBuilder(copy: false);
    for (var i = 1; i <= textRecordCount; i++) {
      final start = offsets[i];
      final end = i + 1 < offsets.length ? offsets[i + 1] : bytes.length;
      if (start < 0 || end > bytes.length || end <= start) continue;
      final record = bytes.sublist(start, end);
      if (compression == 1) {
        output.add(record);
      } else if (compression == 2) {
        output.add(_decompressPalmDoc(record));
      } else {
        throw FormatException('暂不支持 MOBI 压缩方式：$compression');
      }
    }
    final raw = output.takeBytes();
    final length = textLength == 0 || textLength > raw.length ? raw.length : textLength;
    return _htmlToText(_decodeText(raw.sublist(0, length)));
  }

  Uint8List _decompressPalmDoc(List<int> input) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < input.length) {
      final c = input[i++];
      if (c == 0) {
        out.addByte(0);
      } else if (c <= 8) {
        for (var j = 0; j < c && i < input.length; j++) out.addByte(input[i++]);
      } else if (c <= 0x7f) {
        out.addByte(c);
      } else if (c <= 0xbf) {
        if (i >= input.length) break;
        final pair = (c << 8) | input[i++];
        final distance = (pair & 0x3fff) >> 3;
        final count = (pair & 7) + 3;
        final decoded = out.takeBytes().toList();
        final start = decoded.length - distance;
        for (var j = 0; j < count; j++) decoded.add(decoded[start + j]);
        out.add(decoded);
      } else {
        out.add([0x20, c ^ 0x80]);
      }
    }
    return out.takeBytes();
  }

  Future<void> _removeBook(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移出书架？'),
        content: Text('“${book.title}”及其本地缓存将被移除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移出')),
        ],
      ),
    );
    if (confirmed != true) return;
    final dir = await _bookDirectory;
    final file = File('${dir.path}/${book.fileName}');
    if (await file.exists()) await file.delete();
    setState(() => _books.removeWhere((item) => item.id == book.id));
    await _saveLibrary();
  }

  Future<void> _openBook(Book book) async {
    book.lastRead = DateTime.now();
    setState(() {
      _books.sort((a, b) => b.lastRead.compareTo(a.lastRead));
    });
    await _saveLibrary();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(
        book: book,
        dark: widget.dark,
        fontSize: widget.fontSize,
        onToggleTheme: widget.onToggleTheme,
        onFontChange: widget.onFontChange,
        onPositionChanged: (position) async {
          book.position = position;
          book.lastRead = DateTime.now();
          await _saveLibrary();
          if (mounted) setState(() => _books.sort((a, b) => b.lastRead.compareTo(a.lastRead)));
        },
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _exportBackup() async {
    try {
      setState(() => _working = true);
      final bytes = utf8.encode(jsonEncode({
        'format': 'PureRead backup',
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        'books': _books.map((book) => book.toJson(includeContent: true)).toList(),
      }));
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '导出 PureRead 备份',
        fileName: 'pureread_backup.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path != null) _message('备份已导出');
    } catch (e) {
      _message('导出失败：$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _importBackup() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      setState(() => _working = true);
      final picked = result.files.first;
      final bytes = picked.bytes ?? (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) throw const FormatException('无法读取备份文件');
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final entries = (json['books'] as List).cast<Map<String, dynamic>>();
      final directory = await _bookDirectory;
      for (final entry in entries) {
        final content = entry['content'] as String? ?? '';
        if (content.isEmpty) continue;
        final id = '${DateTime.now().microsecondsSinceEpoch}_${_books.length}';
        final fileName = '$id.txt';
        await File('${directory.path}/$fileName').writeAsString(content);
        final restored = Book.fromJson(
          {...entry, 'id': id, 'fileName': fileName},
          content: content,
        );
        restored.position = restored.position.clamp(0, content.length);
        _books.removeWhere((book) => book.title == restored.title);
        _books.add(restored);
      }
      _books.sort((a, b) => b.lastRead.compareTo(a.lastRead));
      await _saveLibrary();
      if (mounted) setState(() {});
      _message('已导入备份');
    } catch (e) {
      _message('备份无效或导入失败：$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('PureRead', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -.5)),
          Text('只读本地，不连接网络', style: TextStyle(fontSize: 11, fontWeight: FontWeight.normal)),
        ]),
        actions: [
          IconButton(tooltip: '导入备份', onPressed: _working ? null : _importBackup, icon: const Icon(Icons.file_upload_outlined)),
          IconButton(tooltip: '导出备份', onPressed: _working ? null : _exportBackup, icon: const Icon(Icons.file_download_outlined)),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
              ? _emptyState(colors)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 110),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(children: [
                        Text('我的书架', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('${_books.length} 本', style: TextStyle(color: colors.onSurfaceVariant)),
                      ]),
                    ),
                    for (final book in _books) _bookCard(book),
                  ],
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _working ? null : _importBooks,
        icon: _working ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add),
        label: Text(_working ? '处理中' : '导入书籍'),
      ),
    );
  }

  Widget _emptyState(ColorScheme colors) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_rounded, size: 58, color: colors.primary.withValues(alpha: .7)),
            const SizedBox(height: 18),
            const Text('书架还空着', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('从设备中选择 TXT、EPUB、MOBI 或 Markdown 文件开始阅读。', textAlign: TextAlign.center, style: TextStyle(color: colors.onSurfaceVariant, height: 1.6)),
          ]),
        ),
      );

  Widget _bookCard(Book book) {
    final colors = Theme.of(context).colorScheme;
    final date = book.lastRead.millisecondsSinceEpoch == 0 ? '尚未阅读' : _formatDate(book.lastRead);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _openBook(book),
        onLongPress: () => _removeBook(book),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 52,
              height: 68,
              decoration: BoxDecoration(color: colors.primaryContainer, borderRadius: BorderRadius.circular(10)),
              child: Icon(Icons.menu_book_rounded, color: colors.onPrimaryContainer, size: 27),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(height: 5),
              Text('${book.format}  ·  $date', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
              const SizedBox(height: 13),
              Row(children: [
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: book.progress / 100, minHeight: 4, backgroundColor: colors.surfaceContainerHighest))),
                const SizedBox(width: 10),
                Text('${book.progress}%', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
              ]),
            ])),
            const SizedBox(width: 5),
            Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final local = date.toLocal();
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '今天 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  }
}

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.book,
    required this.dark,
    required this.fontSize,
    required this.onToggleTheme,
    required this.onFontChange,
    required this.onPositionChanged,
  });
  final Book book;
  final bool dark;
  final double fontSize;
  final VoidCallback onToggleTheme;
  final ValueChanged<double> onFontChange;
  final ValueChanged<int> onPositionChanged;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  late final PageController _controller;
  late int _page;
  late int _pageCount;
  int _lastSavedPage = -1;

  @override
  void initState() {
    super.initState();
    _pageCount = (widget.book.content.length / _pageSize).ceil().clamp(1, 1 << 30);
    _page = (widget.book.position ~/ _pageSize).clamp(0, _pageCount - 1);
    _lastSavedPage = _page;
    _controller = PageController(initialPage: _page);
    WidgetsBinding.instance.addPostFrameCallback((_) => _setSystemUi());
  }

  void _setSystemUi() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: widget.dark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: Theme.of(context).scaffoldBackgroundColor,
      systemNavigationBarIconBrightness: widget.dark ? Brightness.light : Brightness.dark,
    ));
  }

  String _pageText(int page) {
    final start = page * _pageSize;
    var end = (start + _pageSize).clamp(0, widget.book.content.length);
    if (end < widget.book.content.length) {
      final boundary = widget.book.content.lastIndexOf('\n', end);
      if (boundary > start + _pageSize ~/ 2) end = boundary + 1;
    }
    return widget.book.content.substring(start, end);
  }

  void _go(int page) {
    final next = page.clamp(0, _pageCount - 1);
    if (next == _page) return;
    _controller.jumpToPage(next);
    setState(() => _page = next);
    _savePosition();
  }

  void _savePosition() {
    if (_lastSavedPage == _page) return;
    _lastSavedPage = _page;
    final position = (_page * _pageSize).clamp(0, widget.book.content.length);
    widget.onPositionChanged(position);
  }

  @override
  void dispose() {
    _savePosition();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    _setSystemUi();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
        actions: [
          IconButton(tooltip: '减小字号', onPressed: () => widget.onFontChange(-1), icon: const Icon(Icons.text_decrease)),
          IconButton(tooltip: '增大字号', onPressed: () => widget.onFontChange(1), icon: const Icon(Icons.text_increase)),
          IconButton(tooltip: widget.dark ? '切换日间模式' : '切换夜间模式', onPressed: widget.onToggleTheme, icon: Icon(widget.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined)),
        ],
      ),
      body: Column(children: [
        Expanded(
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) < -100) _go(_page + 1);
              if ((details.primaryVelocity ?? 0) > 100) _go(_page - 1);
            },
            child: PageView.builder(
              controller: _controller,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _pageCount,
              itemBuilder: (context, index) => SingleChildScrollView(
                key: ValueKey('${widget.book.id}-$index-${widget.fontSize}'),
                padding: const EdgeInsets.fromLTRB(26, 22, 26, 34),
                child: SelectableText(
                  _pageText(index),
                  style: TextStyle(fontSize: widget.fontSize, height: 1.9, letterSpacing: .2, color: colors.onSurface),
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
            child: Row(children: [
              IconButton(onPressed: _page > 0 ? () => _go(_page - 1) : null, icon: const Icon(Icons.chevron_left)),
              Expanded(child: Column(children: [
                ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: (_page + 1) / _pageCount, minHeight: 3)),
                const SizedBox(height: 6),
                Text('${((_page + 1) / _pageCount * 100).floor()}%  ·  ${_page + 1} / $_pageCount', style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant)),
              ])),
              IconButton(onPressed: _page < _pageCount - 1 ? () => _go(_page + 1) : null, icon: const Icon(Icons.chevron_right)),
            ]),
          ),
        ),
      ]),
    );
  }
}
