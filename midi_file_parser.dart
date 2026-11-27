import 'dart:typed_data';

class MidiFileNote {
  final int midi;
  final double startSeconds;
  final double durationSeconds;
  final int velocity;
  final int channel;
  const MidiFileNote({
    required this.midi,
    required this.startSeconds,
    required this.durationSeconds,
    required this.velocity,
    required this.channel,
  });
}

class ParsedMidi {
  final int ticksPerQuarter;
  final List<MidiFileNote> notes;
  final double durationSeconds;
  const ParsedMidi(this.ticksPerQuarter, this.notes, this.durationSeconds);
}

/// Minimal Standard MIDI File parser for note-on, note-off and tempo events.
/// Supports PPQN timing (not SMPTE timing), formats 0 and 1.
class MidiFileParser {
  static ParsedMidi parse(Uint8List bytes) {
    final r = _MidiReader(bytes);
    if (r.readAscii(4) != 'MThd') throw const FormatException('Not a Standard MIDI File');
    final headerLength = r.readU32();
    final format = r.readU16();
    final tracks = r.readU16();
    final division = r.readU16();
    if (headerLength > 6) r.skip(headerLength - 6);
    if (format > 1) throw const FormatException('Only MIDI format 0 and 1 are supported');
    if ((division & 0x8000) != 0) throw const FormatException('SMPTE MIDI timing is not supported');
    if (division == 0) throw const FormatException('Invalid MIDI ticks per quarter note');

    final events = <_Event>[];
    var order = 0;
    for (var t = 0; t < tracks; t++) {
      if (r.readAscii(4) != 'MTrk') throw const FormatException('Missing MIDI track');
      final end = r.position + r.readU32();
      var tick = 0;
      var runningStatus = 0;
      while (r.position < end) {
        tick += r.readVarInt();
        var status = r.peekU8();
        if (status < 0x80) {
          if (runningStatus == 0) throw const FormatException('Invalid MIDI running status');
          status = runningStatus;
        } else {
          r.readU8();
          if (status < 0xF0) runningStatus = status;
        }
        if (status == 0xFF) {
          final type = r.readU8();
          final len = r.readVarInt();
          if (type == 0x51 && len == 3) {
            final us = (r.readU8() << 16) | (r.readU8() << 8) | r.readU8();
            events.add(_Event(tick, order++, tempo: us));
          } else {
            r.skip(len);
          }
        } else if (status == 0xF0 || status == 0xF7) {
          final len = r.readVarInt();
          r.skip(len);
        } else {
          final command = status & 0xF0;
          final channel = status & 0x0F;
          final d1 = status < 0x80 ? r.readU8() : r.readU8();
          final d2 = (command == 0xC0 || command == 0xD0) ? 0 : r.readU8();
          if (command == 0x90 && d2 > 0) {
            events.add(_Event(tick, order++, midi: d1, velocity: d2, channel: channel, on: true));
          } else if (command == 0x80 || (command == 0x90 && d2 == 0)) {
            events.add(_Event(tick, order++, midi: d1, velocity: d2, channel: channel, on: false));
          }
        }
      }
      if (r.position > end) throw const FormatException('MIDI track length overrun');
      r.position = end;
    }

    events.sort((a, b) {
      final byTick = a.tick.compareTo(b.tick);
      return byTick != 0 ? byTick : a.order.compareTo(b.order);
    });
    var tempo = 500000;
    var lastTick = 0;
    var seconds = 0.0;
    final open = <String, List<_OpenNote>>{};
    final notes = <MidiFileNote>[];
    for (final e in events) {
      seconds += (e.tick - lastTick) * tempo / division / 1000000.0;
      lastTick = e.tick;
      if (e.tempo != null) {
        tempo = e.tempo!;
      } else if (e.midi != null) {
        final key = '${e.channel}:${e.midi}';
        if (e.on) {
          (open[key] ??= []).add(_OpenNote(seconds, e.velocity!, e.channel!, e.midi!));
        } else {
          final queue = open[key];
          if (queue != null && queue.isNotEmpty) {
            final started = queue.removeAt(0);
            notes.add(MidiFileNote(
              midi: started.midi,
              startSeconds: started.start,
              durationSeconds: (seconds - started.start).clamp(0.04, 120.0),
              velocity: started.velocity,
              channel: started.channel,
            ));
          }
        }
      }
    }
    for (final queue in open.values) {
      for (final n in queue) {
        notes.add(MidiFileNote(midi: n.midi, startSeconds: n.start,
          durationSeconds: (seconds - n.start).clamp(0.1, 120.0),
          velocity: n.velocity, channel: n.channel));
      }
    }
    notes.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    return ParsedMidi(division, notes, seconds);
  }
}

class _OpenNote {
  final double start;
  final int velocity, channel, midi;
  _OpenNote(this.start, this.velocity, this.channel, this.midi);
}
class _Event {
  final int tick, order;
  final int? midi, velocity, channel, tempo;
  final bool on;
  _Event(this.tick, this.order, {this.midi, this.velocity, this.channel, this.tempo, this.on = false});
}
class _MidiReader {
  final Uint8List data;
  int position = 0;
  _MidiReader(this.data);
  int readU8() { if (position >= data.length) throw const FormatException('Unexpected end of MIDI'); return data[position++]; }
  int peekU8() { if (position >= data.length) throw const FormatException('Unexpected end of MIDI'); return data[position]; }
  int readU16() => (readU8() << 8) | readU8();
  int readU32() => (readU8() << 24) | (readU8() << 16) | (readU8() << 8) | readU8();
  String readAscii(int n) => String.fromCharCodes(List.generate(n, (_) => readU8()));
  void skip(int n) { position += n; if (position > data.length) throw const FormatException('Unexpected end of MIDI'); }
  int readVarInt() {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final b = readU8();
      value = (value << 7) | (b & 0x7F);
      if ((b & 0x80) == 0) return value;
    }
    throw const FormatException('Invalid MIDI variable-length integer');
  }
}
