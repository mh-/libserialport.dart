/*
 * Based on libserialport (https://sigrok.org/wiki/Libserialport).
 *
 * Copyright (C) 2010-2012 Bert Vermeulen <bert@biot.com>
 * Copyright (C) 2010-2015 Uwe Hermann <uwe@hermann-uwe.de>
 * Copyright (C) 2013-2015 Martin Ling <martin-libserialport@earth.li>
 * Copyright (C) 2013 Matthias Heidbrink <m-sigrok@heidbrink.biz>
 * Copyright (C) 2014 Aurelien Jacobs <aurel@gnuage.org>
 * Copyright (C) 2020 J-P Nurmi <jpnurmi@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:libserialport/src/android.dart';
import 'package:libserialport/src/bindings.dart';
import 'package:libserialport/src/dylib.dart';
import 'package:libserialport/src/error.dart';
import 'package:libserialport/src/port.dart';
import 'package:usb_serial/usb_serial.dart';

const int _kReadEvents = sp_event.SP_EVENT_RX_READY | sp_event.SP_EVENT_ERROR;

/// Asynchronous serial port reader.
///
/// Provides a [stream] that can be listened to asynchronously to receive data
/// whenever available.
///
/// The [stream] will attempt to open a given [port] for reading. If the stream
/// fails to open the port, it will emit [SerialPortError]. If the port is
/// successfully opened, the stream will begin emitting [Uint8List] data events.
///
/// **Note:** The reader must be closed using [close()] when done with reading.
abstract class SerialPortReader {
  /// Creates a reader for the port. Optional [timeout] parameter can be
  /// provided to specify a time im milliseconds between attempts to read after
  /// a failure to open the [port] for reading. If not given, [timeout] defaults
  /// to 500ms.
  factory SerialPortReader(SerialPort port, {int? timeout}) {
    if (Platform.isAndroid) {
      return _SerialPortReaderAndroidImpl(port, timeout: timeout);
    }

    return _SerialPortReaderDesktopImpl(port, timeout: timeout);
  }

  /// Gets the port the reader operates on.
  SerialPort get port;

  /// Gets a stream of data.
  Stream<Uint8List> get stream;

  /// Closes the stream.
  void close();
}

class _SerialPortReaderArgs {
  final int address;
  final int timeout;
  final SendPort sendPort;
  _SerialPortReaderArgs({
    required this.address,
    required this.timeout,
    required this.sendPort,
  });
}

class _SerialPortReaderDesktopImpl implements SerialPortReader {
  final SerialPort _port;
  final int _timeout;
  Isolate? _isolate;
  ReceivePort? _receiver;
  StreamController<Uint8List>? __controller;
  static const MAX_LEN = 33;

  _SerialPortReaderDesktopImpl(SerialPort port, {int? timeout})
      : _port = port,
        _timeout = timeout ?? 500;

  @override
  SerialPort get port => _port;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  void close() {
    __controller?.close();
    __controller = null;
  }

  StreamController<Uint8List> get _controller {
    return __controller ??= StreamController<Uint8List>(
      onListen: _startRead,
      onCancel: _cancelRead,
      onPause: _cancelRead,
      onResume: _startRead,
    );
  }

  void _startRead() {
    _receiver = ReceivePort();
    _receiver!.listen((data) {
      if (data is SerialPortError) {
        _controller.addError(data);
      } else if (data is Uint8List) {
        _controller.add(data);
      }
    });
    final args = _SerialPortReaderArgs(
      address: _port.address,
      timeout: _timeout,
      sendPort: _receiver!.sendPort,
    );
    Isolate.spawn(
      _waitRead,
      args,
      debugName: toString(),
    ).then((value) => _isolate = value);
  }

  void _cancelRead() {
    _receiver?.close();
    _receiver = null;
    _isolate?.kill();
    _isolate = null;
  }

  static void _waitRead(_SerialPortReaderArgs args) {
    final port = ffi.Pointer<sp_port>.fromAddress(args.address);
    final events = _createEvents(port, _kReadEvents);
    var bytes = 0;
    Uint8List data = Uint8List(0);

    while (bytes >= 0) {
      ffi.using((arena) {
        final ptr = arena<ffi.Uint8>(MAX_LEN);
        bytes = dylib.sp_blocking_read(port, ptr.cast(), MAX_LEN, args.timeout);

        if(bytes < 0) {
          throw bytes;
        }
        
        data = Uint8List.fromList(ptr.asTypedList(bytes));
      });

      if (bytes > 0) {
        args.sendPort.send(data);
      } else if (bytes < 0) {
        args.sendPort.send(SerialPort.lastError);
      }
    }
    _releaseEvents(events);
  }

  static ffi.Pointer<ffi.Pointer<sp_event_set>> _createEvents(
    ffi.Pointer<sp_port> port,
    int mask,
  ) {
    final events = ffi.calloc<ffi.Pointer<sp_event_set>>();
    dylib.sp_new_event_set(events);
    dylib.sp_add_port_events(events.value, port, mask);
    return events;
  }

  static int _waitEvents(
    ffi.Pointer<sp_port> port,
    ffi.Pointer<ffi.Pointer<sp_event_set>> events,
    int timeout,
  ) {
    dylib.sp_wait(events.value, timeout);
    return dylib.sp_input_waiting(port);
  }

  static void _releaseEvents(ffi.Pointer<ffi.Pointer<sp_event_set>> events) {
    dylib.sp_free_event_set(events.value);
  }
}

class _SerialPortReaderAndroidImpl implements SerialPortReader {
  final SerialPortAndroid _port;
  final int? _timeout;
  StreamController<Uint8List>? __controller;
  StreamSubscription<Uint8List>? _receiver;
  StreamSubscription<UsbEvent>? _usbEvents;

  @override
  SerialPortAndroid get port => _port;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  _SerialPortReaderAndroidImpl(SerialPort port, {int? timeout})
      : _port = port as SerialPortAndroid,
        _timeout = timeout;

  StreamController<Uint8List> get _controller {
    return __controller ??= StreamController<Uint8List>(
      onListen: _startRead,
      onCancel: _cancelRead,
      onPause: _cancelRead,
      onResume: _startRead,
    );
  }

  @override
  void close() {
    _receiver?.cancel();
    _receiver = null;
    _usbEvents?.cancel();
    _usbEvents = null;
    __controller?.close();
    __controller = null;
  }

  void _startRead() {
    // If no timeout is set, the default 500ms that _SerialPortReaderDesktopImpl uses make stream end earlier, not maintaining the same behavior
    // Stream will have timeout only if timeout is set
    Stream<Uint8List> _stream = _timeout == null
        ? _port.port!.inputStream!
        : _port.port!.inputStream!.timeout(
      Duration(milliseconds: _timeout!),
      onTimeout: (sink) {
        sink.addError(SerialPortError('Timeout'));
      },
    );

    _receiver = _stream!.listen((data) {
      if (data is SerialPortError) {
        _controller.addError(data);
      } else {
        _controller.add(data);
      }
    }, onError: (e) {
      _controller.addError(SerialPortError(e.toString()));
    });

    _usbEvents = UsbSerial.usbEventStream?.listen((usbEvent) {
      if (usbEvent.device == null) return;

      if (usbEvent.device!.deviceId != port.address) return;

      if (usbEvent.event == UsbEvent.ACTION_USB_DETACHED) {
        _controller.addError(SerialPortError('Device disconnected'));
      }
    });
  }

  void _cancelRead() {
    _receiver?.cancel();
    _receiver = null;
    _usbEvents?.cancel();
    _usbEvents = null;
  }
}