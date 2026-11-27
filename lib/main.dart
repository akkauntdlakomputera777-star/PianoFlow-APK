import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:file_picker/file_picker.dart';
import 'midi_file_parser.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'package:flutter_midi_command/flutter_midi_command_messages.dart';
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

void main() => runApp(const PianoFlowApp());

const bg = Color(0xFF090B12);
const panel = Color(0xFF141824);
const purple = Color(0xFF9B7BFF);
const cyan = Color(0xFF50D9E8);
const muted = Color(0xFF8D95A8);

class PianoFlowApp extends StatelessWidget {
  const PianoFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PianoFlow',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(seedColor: purple, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const PianoHomePage(),
    );
  }
}

class PianoNote {
  final int midi;
  final double start;
  final double duration;
  const PianoNote(this.midi, this.start, this.duration);
  String get name {
    const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
    return '${names[midi % 12]}${midi ~/ 12 - 1}';
  }
}

// A short original practice phrase, included so the app works immediately.
const demoNotes = <PianoNote>[
  PianoNote(60, 0.0, .75), PianoNote(64, .8, .75),
  PianoNote(67, 1.6, .75), PianoNote(72, 2.4, 1.0),
  PianoNote(71, 3.5, .5), PianoNote(67, 4.1, .75),
  PianoNote(69, 4.9, .75), PianoNote(72, 5.7, 1.2),
  PianoNote(67, 7.0, .75), PianoNote(64, 7.8, .75),
  PianoNote(60, 8.6, 1.4),
];

class PianoHomePage extends StatefulWidget {
  const PianoHomePage({super.key});
  @override
  State<PianoHomePage> createState() => _PianoHomePageState();
}

class _PianoHomePageState extends State<PianoHomePage> with TickerProviderStateMixin {
  final AudioRecorder _recorder = AudioRecorder();
  final MidiCommand _midi = MidiCommand();
  StreamSubscription<MidiDataReceivedEvent>? _midiSub;
  StreamSubscription<MidiSetupChange>? _midiSetupSub;
  List<MidiDevice> _midiDevices = [];
  MidiDevice? _connectedMidi;
  bool _midiBusy = false;
  StreamSubscription<Uint8List>? _audioSub;
  late final AnimationController _clock;
  bool _listening = false;
  bool _smartFollow = true;
  bool _playing = false;
  String _status = 'Готово к занятию';
  String _detected = '—';
  int _currentIndex = 0;
  int? _lastMidi;
  double _songTime = 0;
  DateTime? _lastTick;
  final Set<int> _pressedKeys = {};
  List<PianoNote> _importedNotes = [];
  String _currentTitle = 'PianoFlow — этюд №1';
  double _importedDuration = 10.5;
  double _tempo = 1.0;
  List<PianoNote> get activeNotes => _importedNotes.isEmpty ? demoNotes : _importedNotes;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(vsync: this, duration: const Duration(seconds: 1))
      ..addListener(_onFrame)
      ..repeat();
    _initializeMidi();
  }

  Future<void> _initializeMidi() async {
    try {
      // BLE transport is enabled so compatible Bluetooth-MIDI keyboards can appear.
      _midi.configureBleTransport(UniversalBleMidiTransport());
      _midiSub = _midi.onMidiDataReceived?.listen(_onMidiData);
      _midiSetupSub = _midi.onMidiSetupChanged?.listen((_) => _refreshMidiDevices());
      await _refreshMidiDevices();
    } catch (_) {
      if (mounted) setState(() => _status = 'MIDI пока недоступен на этом устройстве');
    }
  }

  Future<void> _refreshMidiDevices() async {
    try {
      final found = await _midi.devices ?? <MidiDevice>[];
      if (mounted) setState(() => _midiDevices = found);
    } catch (_) {
      if (mounted) setState(() => _status = 'Не удалось найти MIDI-устройства');
    }
  }

  Future<void> _scanBluetoothMidi() async {
    try {
      await _midi.startBluetooth();
      await _midi.waitUntilBluetoothIsInitialized();
      if (_midi.bluetoothState != BluetoothState.poweredOn) {
        if (mounted) setState(() => _status = 'Включи Bluetooth на телефоне');
        return;
      }
      await _midi.startScanningForBluetoothDevices();
      await _refreshMidiDevices();
      if (mounted) setState(() => _status = 'Ищу Bluetooth-MIDI устройства');
    } catch (_) {
      if (mounted) setState(() => _status = 'Не удалось запустить поиск Bluetooth-MIDI');
    }
  }

  Future<void> _connectMidi(MidiDevice device) async {
    setState(() { _midiBusy = true; _status = 'Подключаю ${device.name}…'; });
    try {
      await _midi.connectToDevice(device);
      if (!mounted) return;
      setState(() {
        _connectedMidi = device;
        _midiBusy = false;
        _status = 'MIDI подключён: ${device.name}';
      });
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() { _midiBusy = false; _status = 'Ошибка MIDI-подключения: проверь кабель или Bluetooth'; });
    }
  }

  void _onMidiData(MidiDataReceivedEvent event) {
    final message = event.message;
    if (message is NoteOnMessage && message.velocity > 0) {
      final midi = message.note;
      if (!mounted) return;
      final expected = _currentIndex < activeNotes.length ? activeNotes[_currentIndex].midi : null;
      setState(() {
        _lastMidi = midi;
        _detected = midiName(midi);
        if (_smartFollow && _playing && expected != null && (midi - expected).abs() <= 1) {
          _currentIndex++;
          _status = 'MIDI: верно! Следующая нота';
          if (_currentIndex >= activeNotes.length) {
            _playing = false;
            _status = 'Отлично! Произведение сыграно';
          }
        } else if (_smartFollow && _playing && expected != null) {
          _status = 'MIDI: нужна ${midiName(expected)}, сыграна ${midiName(midi)}';
        }
      });
    }
  }

  void _onFrame() {
    if (!_playing || _smartFollow) return;
    final now = DateTime.now();
    if (_lastTick != null) {
      _songTime += now.difference(_lastTick!).inMilliseconds / 1000 * _tempo;
    }
    _lastTick = now;
    if (_currentIndex < activeNotes.length &&
        _songTime >= activeNotes[_currentIndex].start + activeNotes[_currentIndex].duration) {
      _currentIndex = (_currentIndex + 1).clamp(0, activeNotes.length);
    }
    if (_songTime > _importedDuration) {
      _playing = false;
      _status = 'Произведение завершено';
    }
    if (mounted) setState(() {});
  }

  void _startSong() {
    setState(() {
      _playing = true;
      _smartFollow = false;
      _currentIndex = 0;
      _songTime = 0;
      _lastTick = DateTime.now();
      _status = 'Воспроизведение';
    });
  }

  void _togglePlayback() {
    setState(() {
      if (_smartFollow) {
        _smartFollow = false;
        _playing = true;
        _status = 'Обычное воспроизведение';
      } else if (_playing) {
        _playing = false;
        _status = 'Пауза';
      } else {
        if (_songTime >= _importedDuration) {
          _songTime = 0;
          _currentIndex = 0;
        }
        _playing = true;
        _lastTick = DateTime.now();
        _status = 'Воспроизведение';
      }
    });
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _audioSub?.cancel();
      _audioSub = null;
      await _recorder.stop();
      if (mounted) setState(() { _listening = false; _status = 'Микрофон выключен'; });
      return;
    }
    try {
      if (!await _recorder.hasPermission()) {
        setState(() => _status = 'Нет разрешения на микрофон');
        return;
      }
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      ));
      _audioSub = stream.listen(_onAudio);
      setState(() { _listening = true; _status = 'Слушаю пианино'; });
    } catch (e) {
      setState(() => _status = 'Не удалось включить микрофон');
    }
  }

  void _onAudio(Uint8List bytes) {
    final midi = PitchDetector.detectMidi(bytes);
    if (midi == null || midi < 36 || midi > 96) return;
    if (!mounted) return;
    final expected = _currentIndex < activeNotes.length ? activeNotes[_currentIndex].midi : null;
    setState(() {
      _lastMidi = midi;
      _detected = midiName(midi);
      if (_smartFollow && _playing && expected != null && (midi - expected).abs() <= 1) {
        _currentIndex++;
        if (_currentIndex >= activeNotes.length) {
          _playing = false;
          _status = 'Отлично! Произведение сыграно';
        } else {
          _status = 'Верно! Следующая нота';
        }
      } else if (_smartFollow && _playing && expected != null) {
        _status = 'Нужна ${midiName(expected)} — сейчас ${midiName(midi)}';
      }
    });
  }

  void _toggleSmart() {
    setState(() {
      _smartFollow = !_smartFollow;
      _playing = true;
      _currentIndex = 0;
      _songTime = 0;
      _status = _smartFollow ? 'Smart Follow: жду правильные ноты' : 'Обычный режим';
    });
  }

  void _tapKey(int midi) {
    setState(() {
      _pressedKeys.add(midi);
      _lastMidi = midi;
      _detected = midiName(midi);
      if (_smartFollow && _playing && _currentIndex < activeNotes.length &&
          (activeNotes[_currentIndex].midi - midi).abs() <= 1) {
        _currentIndex++;
        _status = 'Верно! Следующая нота';
        if (_currentIndex >= activeNotes.length) {
          _playing = false;
          _status = 'Отлично! Произведение сыграно';
        }
      }
    });
    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _pressedKeys.remove(midi));
    });
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _midiSub?.cancel();
    _midiSetupSub?.cancel();
    _midi.dispose();
    _recorder.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final next = _currentIndex < activeNotes.length ? activeNotes[_currentIndex] : null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
              child: Row(children: [
                Container(
                  width: 42, height: 42,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [purple, cyan]),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.piano, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('PianoFlow', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
                  Text('PLAY • LISTEN • LEARN', style: TextStyle(fontSize: 9, letterSpacing: 2, color: muted)),
                ]),
                const Spacer(),
                IconButton(onPressed: () => _showLibrary(context), icon: const Icon(Icons.library_music_outlined)),
                IconButton(onPressed: () => _showAbout(context), icon: const Icon(Icons.help_outline)),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [Color(0xFF25213F), Color(0xFF151A2A)],
                      ),
                      border: Border.all(color: purple.withOpacity(.28)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('СЕЙЧАС ИГРАЕМ', style: TextStyle(color: cyan, fontSize: 10, letterSpacing: 2, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text(_currentTitle, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      const Text('Учебная мелодия • До мажор', style: TextStyle(color: muted, fontSize: 12)),
                      const SizedBox(height: 14),
                      Row(children: [
                        _smallTag(Icons.music_note, '11 нот'),
                        const SizedBox(width: 8),
                        _smallTag(Icons.speed, _smartFollow ? 'Smart Follow' : 'Свободный темп'),
                        const Spacer(),
                        Text('${_currentIndex.clamp(0, activeNotes.length)}/${activeNotes.length}', style: const TextStyle(color: cyan, fontWeight: FontWeight.bold)),
                      ]),
                      const SizedBox(height: 10),
                      ClipRRect(borderRadius: BorderRadius.circular(8), child: LinearProgressIndicator(
                        value: (_currentIndex / activeNotes.length).clamp(0.0, 1.0), minHeight: 5,
                        backgroundColor: Colors.white12, color: cyan,
                      )),
                    ]),
                  ),
                  const SizedBox(height: 16),
                  Row(children: [
                    const Text('Падающие ноты', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(_smartFollow ? 'ОЖИДАНИЕ ИСПОЛНЕНИЯ' : 'АВТОПРОИГРЫВАНИЕ',
                      style: const TextStyle(fontSize: 9, color: muted, letterSpacing: 1)),
                  ]),
                  const SizedBox(height: 10),
                  Container(
                    height: 220,
                    decoration: BoxDecoration(color: const Color(0xFF0D111C), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white10)),
                    clipBehavior: Clip.antiAlias,
                    child: CustomPaint(
                      painter: FallingNotesPainter(
                        notes: activeNotes, currentIndex: _currentIndex,
                        songTime: _songTime, smart: _smartFollow,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    IconButton.filledTonal(
                      onPressed: _togglePlayback,
                      icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      tooltip: _playing ? 'Пауза' : 'Продолжить',
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: () => setState(() {
                        _songTime = 0; _currentIndex = 0; _playing = false;
                        _status = 'Возврат к началу';
                      }),
                      icon: const Icon(Icons.restart_alt),
                      tooltip: 'С начала',
                    ),
                    const Spacer(),
                    Text('${_tempo.toStringAsFixed(2)}×', style: const TextStyle(color: cyan, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 4),
                    const Text('СКОРОСТЬ', style: TextStyle(color: muted, fontSize: 9, letterSpacing: 1)),
                  ]),
                  Row(children: [
                    const Icon(Icons.slow_motion_video, color: muted, size: 16),
                    Expanded(child: Slider(
                      value: _tempo, min: 0.5, max: 1.5, divisions: 20,
                      activeColor: purple,
                      onChanged: (v) => setState(() => _tempo = v),
                    )),
                    const Icon(Icons.speed, color: muted, size: 16),
                  ]),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
                    child: Row(children: [
                      Container(width: 38, height: 38, decoration: BoxDecoration(color: cyan.withOpacity(.12), borderRadius: BorderRadius.circular(12)),
                        child: Icon(_listening ? Icons.graphic_eq : Icons.hearing, color: cyan)),
                      const SizedBox(width: 10),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('Распознавание звука', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text(_status, style: const TextStyle(color: muted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ])),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(_detected, style: const TextStyle(color: cyan, fontWeight: FontWeight.bold, fontSize: 18)),
                        const Text('ПОСЛЕДНЯЯ НОТА', style: TextStyle(color: muted, fontSize: 8, letterSpacing: 1)),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  Row(children: [
                    Expanded(child: _actionButton(
                      icon: _listening ? Icons.mic_off : Icons.mic,
                      label: _listening ? 'Выключить микрофон' : 'Включить микрофон',
                      onTap: _toggleListening, primary: true,
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: _actionButton(
                      icon: _smartFollow ? Icons.pause_circle_outline : Icons.play_arrow,
                      label: _smartFollow ? 'Smart Follow' : 'Обычный режим',
                      onTap: _toggleSmart,
                    )),
                  ]),
                  const SizedBox(height: 10),
                  _actionButton(
                    icon: Icons.usb,
                    label: _connectedMidi == null ? 'Подключить MIDI-клавиатуру' : 'MIDI: ${_connectedMidi!.name}',
                    onTap: _showMidiDevices,
                    primary: _connectedMidi != null,
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _actionButton(icon: Icons.play_arrow_rounded, label: 'Сыграть демо', onTap: _startSong)),
                    const SizedBox(width: 10),
                    Expanded(child: _actionButton(icon: Icons.restart_alt, label: 'С начала', onTap: () => setState(() {
                      _currentIndex = 0; _songTime = 0; _playing = false; _status = 'Готово к занятию';
                    }))),
                  ]),
                  const SizedBox(height: 18),
                  Row(children: [
                    const Text('Виртуальная клавиатура', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text(next == null ? 'ГОТОВО' : 'СЛЕДУЮЩАЯ: ${next.name}', style: const TextStyle(color: cyan, fontSize: 10, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 132,
                    child: PianoKeyboard(onKey: _tapKey, pressed: _pressedKeys, targetMidi: next?.midi),
                  ),
                  const SizedBox(height: 8),
                  const Text('Нажимай клавиши на экране или включи микрофон и играй на настоящем пианино.',
                    style: TextStyle(color: muted, fontSize: 11), textAlign: TextAlign.center),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallTag(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
    decoration: BoxDecoration(color: Colors.white.withOpacity(.07), borderRadius: BorderRadius.circular(20)),
    child: Row(children: [Icon(icon, size: 12, color: cyan), const SizedBox(width: 5), Text(label, style: const TextStyle(fontSize: 10))]),
  );

  Widget _actionButton({required IconData icon, required String label, required VoidCallback onTap, bool primary = false}) =>
    Material(color: primary ? purple.withOpacity(.2) : panel, borderRadius: BorderRadius.circular(14),
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14),
        child: Container(padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: primary ? purple.withOpacity(.5) : Colors.white10)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 17, color: primary ? purple : cyan), const SizedBox(width: 7),
            Flexible(child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );


 Future<void> _importMidiFile() async {
  try {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mid', 'midi'],
    );
    if (result.isEmpty) return;
    final file = result.single;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      setState(() => _status = 'Не удалось прочитать MIDI-файл');
      return;
    }
    final parsed = MidiFileParser.parse(bytes);
    if (parsed.notes.isEmpty) {
        setState(() => _status = 'В MIDI-файле не найдены ноты');
        return;
      }
      setState(() {
        _importedNotes = parsed.notes.map((n) => PianoNote(n.midi, n.startSeconds, n.durationSeconds)).toList();
        _currentTitle = file.name;
        _importedDuration = parsed.durationSeconds;
        _currentIndex = 0;
        _songTime = 0;
        _playing = false;
        _status = 'Загружено ${parsed.notes.length} MIDI-нот';
      });
    } on FormatException catch (e) {
      setState(() => _status = 'Ошибка MIDI: ${e.message}');
    } catch (_) {
      setState(() => _status = 'Не удалось открыть файл');
    }
  }

  Future<void> _selectAudioFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom, allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'flac']);
    if (result.isEmpty) return;
    final file = result.single;
    setState(() => _status = 'Аудио выбрано: ${file.name}. Для извлечения нот нужен сервер транскрипции.');
    if (mounted) {
      showDialog(context: context, builder: (_) => AlertDialog(
        backgroundColor: panel,
        title: const Text('Аудиофайл выбран'),
        content: Text('${file.name}\\n\\nСледующий этап — отправка файла в модуль Audio-to-MIDI. В этой сборке файл выбирается, но точная транскрипция MP3/WAV ещё не подключена.'),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Понятно'))],
      ));
    }
  }

  void _showMidiDevices() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: panel,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: StatefulBuilder(builder: (context, refreshSheet) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Подключение MIDI', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Подключи цифровое пианино по USB или Bluetooth MIDI.', style: TextStyle(color: muted, fontSize: 12)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  onPressed: _midiBusy ? null : () async {
                    await _scanBluetoothMidi();
                    refreshSheet(() {});
                  },
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Искать Bluetooth'),
                )),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _midiBusy ? null : () async {
                    await _refreshMidiDevices();
                    refreshSheet(() {});
                  },
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Обновить список',
                ),
              ]),
              if (_midiBusy) const LinearProgressIndicator(),
              if (_midiDevices.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text('Устройства пока не найдены. Для USB подключи клавиатуру кабелем и нажми обновить; для Bluetooth нажми «Искать Bluetooth».', style: TextStyle(color: muted, fontSize: 12)),
                )
              else
                ..._midiDevices.map((device) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(device.type == MidiDeviceType.ble ? Icons.bluetooth : Icons.piano, color: cyan),
                  title: Text(device.name),
                  subtitle: Text(device.type.name, style: const TextStyle(color: muted, fontSize: 11)),
                  trailing: _connectedMidi?.id == device.id
                      ? const Icon(Icons.check_circle, color: cyan)
                      : const Icon(Icons.link),
                  onTap: _midiBusy ? null : () => _connectMidi(device),
                )),
              const SizedBox(height: 8),
              if (_connectedMidi != null)
                TextButton.icon(
                  onPressed: () async {
                    try {_midi.disconnectDevice(_connectedMidi!); } catch (_) {}
                    if (mounted) setState(() { _connectedMidi = null; _status = 'MIDI отключён'; });
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                  },
                  icon: const Icon(Icons.link_off),
                  label: const Text('Отключить MIDI'),
                ),
            ],
          )),
        ),
      ),
    );
  }

  void _showLibrary(BuildContext context) {
    showModalBottomSheet(context: context, backgroundColor: panel, builder: (_) => SafeArea(
      child: Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Библиотека', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 14),
        _libraryRow('Этюд №1', 'Встроенная учебная мелодия', Icons.music_note),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.piano, color: cyan),
          title: const Text('Загрузить MIDI'),
          subtitle: const Text('Импорт нот, ритма и длительности', style: TextStyle(color: muted, fontSize: 11)),
          onTap: () { Navigator.pop(context); _importMidiFile(); },
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.audio_file, color: cyan),
          title: const Text('Загрузить MP3 / WAV'),
          subtitle: const Text('Выбор аудио для последующей транскрипции', style: TextStyle(color: muted, fontSize: 11)),
          onTap: () { Navigator.pop(context); _selectAudioFile(); },
        ),
        _libraryRow('Моя музыка', 'Импортированные произведения', Icons.folder_open),
      ])),
    ));
  }

  Widget _libraryRow(String title, String subtitle, IconData icon) => ListTile(
    contentPadding: EdgeInsets.zero, leading: Icon(icon, color: cyan),
    title: Text(title), subtitle: Text(subtitle, style: const TextStyle(color: muted, fontSize: 11)),
  );

  void _showAbout(BuildContext context) => showDialog(context: context, builder: (_) => AlertDialog(
    backgroundColor: panel, title: const Text('О PianoFlow'),
    content: const Text('Первая сборка-прототип. Уже есть падающие ноты, экранная клавиатура и базовое распознавание высоты звука через микрофон. MIDI, импорт аудиофайлов и точная транскрипция полифонической музыки — следующие этапы.'),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Понятно'))],
  ));
}


class FallingNotesPainter extends CustomPainter {
  final List<PianoNote> notes;
  final int currentIndex;
  final double songTime;
  final bool smart;
  FallingNotesPainter({required this.notes, required this.currentIndex, required this.songTime, required this.smart});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..style = PaintingStyle.fill;
    const minMidi = 48;
    const maxMidi = 84;
    final left = 14.0, right = size.width - 14, top = 12.0, bottom = size.height - 14;
    final width = right - left;
    const visibleSeconds = 4.0;
    final pixelsPerSecond = (bottom - top - 12) / visibleSeconds;
    final playY = bottom - 5;

    // Piano-roll grid: semitone lanes and octave guides.
    final laneWidth = width / (maxMidi - minMidi + 1);
    for (int midi = minMidi; midi <= maxMidi; midi++) {
      final x = left + (midi - minMidi) * laneWidth;
      final isBlack = const [1, 3, 6, 8, 10].contains(midi % 12);
      p
        ..color = (midi % 12 == 0 ? Colors.white.withOpacity(.13) :
            (isBlack ? Colors.white.withOpacity(.035) : Colors.white.withOpacity(.012)))
        ..strokeWidth = midi % 12 == 0 ? 1.2 : .6;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), p);
    }
    for (int i = 0; i <= 4; i++) {
      final y = top + i * (bottom - top) / 4;
      p..color = Colors.white.withOpacity(.055)..strokeWidth = 1;
      canvas.drawLine(Offset(left, y), Offset(right, y), p);
    }

    // Draw notes in time order. Low notes are left-hand purple; high notes right-hand cyan.
    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      final lane = n.midi.clamp(minMidi, maxMidi) - minMidi;
      final x = left + lane * laneWidth + 1.5;
      final noteWidth = math.max(2.0, laneWidth - 3);
      double y;
      double h;
      if (smart) {
        final distance = i - currentIndex;
        h = math.max(12.0, n.duration * pixelsPerSecond);
        y = playY - (distance <= 0 ? 0 : distance * 24) - h;
        if (i < currentIndex) continue;
      } else {
        h = math.max(8.0, n.duration * pixelsPerSecond);
        final noteEndY = playY - (n.start + n.duration - songTime) * pixelsPerSecond;
        y = noteEndY - h;
      }
      if (y > bottom || y + h < top || y > playY) continue;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, noteWidth, math.min(h, bottom - y)),
        const Radius.circular(3),
      );
      final isCurrent = i == currentIndex;
      final isLeftHand = n.midi < 60;
      final color = isCurrent ? Colors.white : (isLeftHand ? purple : cyan);
      p.color = color.withOpacity(isCurrent ? .95 : .82);
      canvas.drawRRect(rect, p);
      if (isCurrent) {
        p.color = color.withOpacity(.20);
        canvas.drawRRect(rect.inflate(3), p);
      }
    }

    // Play line and hand labels.
    p..color = cyan.withOpacity(.9)..strokeWidth = 2;
    canvas.drawLine(Offset(left, playY), Offset(right, playY), p);
    final leftLabel = TextPainter(
      text: const TextSpan(text: 'ЛЕВАЯ', style: TextStyle(color: purple, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      textDirection: TextDirection.ltr)..layout();
    leftLabel.paint(canvas, Offset(left + 2, top + 2));
    final rightLabel = TextPainter(
      text: const TextSpan(text: 'ПРАВАЯ', style: TextStyle(color: cyan, fontSize: 8, fontWeight: FontWeight.bold, letterSpacing: 1)),
      textDirection: TextDirection.ltr)..layout();
    rightLabel.paint(canvas, Offset(right - rightLabel.width - 2, top + 2));
  }

  @override
  bool shouldRepaint(covariant FallingNotesPainter old) =>
    old.currentIndex != currentIndex || old.songTime != songTime ||
    old.smart != smart || old.notes != notes;
}

class PianoKeyboard extends StatelessWidget {
  final ValueChanged<int> onKey;
  final Set<int> pressed;
  final int? targetMidi;
  const PianoKeyboard({super.key, required this.onKey, required this.pressed, this.targetMidi});

  @override
  Widget build(BuildContext context) {
    const start = 60;
    const whiteNotes = [0, 2, 4, 5, 7, 9, 11, 12, 14, 16, 17, 19, 21, 23, 24];
    const blackNotes = [1, 3, 6, 8, 10, 13, 15, 18, 20, 22];
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth / whiteNotes.length;
      return Stack(children: [
        Row(children: List.generate(whiteNotes.length, (i) {
          final midi = start + whiteNotes[i];
          final isTarget = midi == targetMidi;
          return Expanded(child: GestureDetector(
            onTap: () => onKey(midi),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              decoration: BoxDecoration(
                color: pressed.contains(midi) ? cyan.withOpacity(.65) : (isTarget ? const Color(0xFFD8F9FC) : const Color(0xFFE9ECF4)),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
                border: Border.all(color: const Color(0xFF9AA2B4)),
              ),
              alignment: Alignment.bottomCenter,
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(midiName(midi), style: const TextStyle(color: Color(0xFF34394A), fontSize: 8)),
            ),
          ));
        })),
        ...blackNotes.map((offset) {
          final midi = start + offset;
          final before = whiteNotes.where((n) => n < offset).length;
          final x = before * w + w * .66;
          final isTarget = midi == targetMidi;
          return Positioned(left: x, top: 0, width: w * .62, height: 78,
            child: GestureDetector(
              onTap: () => onKey(midi),
              child: Container(
                decoration: BoxDecoration(
                  color: pressed.contains(midi) ? cyan : (isTarget ? purple : const Color(0xFF242A3A)),
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(5)),
                  border: Border.all(color: Colors.black54),
                ),
              ),
            ),
          );
        }),
      ]);
    });
  }
}

class PitchDetector {
  // Lightweight autocorrelation pitch estimate for monophonic input.
  // Works best with a clean piano tone and limited background noise.
  static int? detectMidi(Uint8List bytes) {
    if (bytes.length < 4096) return null;
    final count = math.min(bytes.length ~/ 2, 4096);
    final samples = List<double>.generate(count, (i) {
      final v = (bytes[i * 2] | (bytes[i * 2 + 1] << 8));
      final signed = v > 32767 ? v - 65536 : v;
      return signed / 32768.0;
    });
    double mean = samples.reduce((a, b) => a + b) / count;
    for (int i = 0; i < count; i++) {
      samples[i] -= mean;
    }
    double energy = 0;
    for (final s in samples) { energy += s * s; }
    if (energy / count < 0.00002) return null;

    const sampleRate = 44100.0;
    final minLag = (sampleRate / 1000).floor();
    final maxLag = (sampleRate / 65).floor();
    double best = 0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag; lag++) {
      double corr = 0;
      for (int i = 0; i < count - lag; i += 2) {
        corr += samples[i] * samples[i + lag];
      }
      if (corr > best) { best = corr; bestLag = lag; }
    }
    if (bestLag == 0) return null;
    final frequency = sampleRate / bestLag;
    if (frequency < 65 || frequency > 1000) return null;
    return (69 + 12 * (math.log(frequency / 440) / math.ln2)).round();
  }
}

String midiName(int midi) {
  const names = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}
