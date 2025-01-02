import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/program_info.dart';
import '../../shared/utils/platform_utils.dart';
import '../providers/output_providers.dart';

class ProcessService extends StateNotifier<Map<String, ProgramInfo>> {
  final Map<String, Process> _processes = {};
  final Ref _ref;
  String _currentOutput = '';
  final Map<String, bool> _stoppingProcesses = {};
  final Map<String, bool> _startingProcesses = {};
  final Map<String, bool> _startRequested = {};
  final Map<String, int> _countdowns = {};

  ProcessService(this._ref) : super({});

  bool isProcessStopping(String name) => _stoppingProcesses[name] ?? false;
  bool isProcessStarting(String name) => _startingProcesses[name] ?? false;
  int getCountdown(String name) => _countdowns[name] ?? 0;

  void updateProgramInfo(String name, ProgramInfo info) {
    final newState = Map<String, ProgramInfo>.from(state);
    newState[name] = info;
    state = newState;
  }

  void _appendOutput(String name, String output) {
    _currentOutput += output;

    // Use the appropriate output provider based on the program name
    if (name == 'go-cyberchain') {
      _ref.read(goCyberchainOutputProvider.notifier).appendOutput(output);
    } else if (name == 'xMiner') {
      _ref.read(xMinerOutputProvider.notifier).appendOutput(output);
    }

    // Update program info with the latest output
    final newState = Map<String, ProgramInfo>.from(state);
    if (newState.containsKey(name)) {
      newState[name] = newState[name]!.copyWith(output: _currentOutput);
      state = newState;
    }
  }

  void _updateProgramState(String name, {required bool isRunning}) {
    final newState = Map<String, ProgramInfo>.from(state);
    if (newState.containsKey(name)) {
      newState[name] = newState[name]!.copyWith(isRunning: isRunning);
      state = newState;
    }
  }

  Future<void> startProgram(String name, List<String> arguments) async {
    _startRequested[name] = true;
    _startingProcesses[name] = true;

    // Clear output when starting
    _currentOutput = '';
    if (name == 'go-cyberchain') {
      _ref.read(goCyberchainOutputProvider.notifier).clear();
    } else if (name == 'xMiner') {
      _ref.read(xMinerOutputProvider.notifier).clear();
    }

    // Get the program path and directory
    final programPath = await PlatformUtils.getProgramPath(name);
    final programDir = Directory(programPath).parent.path;

    // Create or update program info in state if it doesn't exist
    if (!state.containsKey(name)) {
      final newState = Map<String, ProgramInfo>.from(state);
      newState[name] = ProgramInfo(
        name: name,
        version: 'unknown',
        downloadUrl: '',
        localPath: programPath,
        isRunning: false,
        output: '',
      );
      state = newState;
    }

    try {
      // Run the process and capture output
      final process = await Process.start(
        programPath,
        arguments,
        workingDirectory: programDir,
        mode: ProcessStartMode.normal,
        runInShell: true,
        includeParentEnvironment: true,
      );

      _processes[name] = process;

      // Start countdown in a separate future
      Future(() async {
        for (int i = 5; i >= 1; i--) {
          _countdowns[name] = i;
          state = Map<String, ProgramInfo>.from(state); // Force update
          await Future.delayed(const Duration(seconds: 1));
        }
        _countdowns.remove(name);
        _startingProcesses[name] = false;
        _updateProgramState(name, isRunning: true);
        state = Map<String, ProgramInfo>.from(state); // Force update
      });

      // Handle stdout
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          _appendOutput(name, '$line\n');
        },
        onError: (error) {
          _appendOutput(name, '\nError reading output: $error\n');
        },
      );

      // Handle stderr
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          _appendOutput(name, '$line\n');
        },
        onError: (error) {
          _appendOutput(name, '\nError reading error output: $error\n');
        },
      );

      // Handle process exit
      process.exitCode.then((exitCode) => _handleProcessExit(name, exitCode));
    } catch (e) {
      _startingProcesses[name] = false;
      _startRequested[name] = false;
      _updateProgramState(name, isRunning: false);
      _appendOutput(name, '\nError starting program: $e\n');
      rethrow;
    }
  }

  Future<void> stopProgram(String name) async {
    final process = _processes[name];
    if (process == null) {
      return;
    }

    try {
      // Set stopping state first
      _stoppingProcesses[name] = true;
      _startRequested[name] = false;

      // Start countdown in a separate future
      Future(() async {
        for (int i = 5; i >= 1; i--) {
          _countdowns[name] = i;
          state = Map<String, ProgramInfo>.from(state); // Force update
          await Future.delayed(const Duration(seconds: 1));
        }
        _countdowns.remove(name);

        // Only update running state after countdown is complete
        _processes.remove(name);
        _stoppingProcesses[name] = false;
        _startRequested[name] = false;
        _updateProgramState(name, isRunning: false);
        state = Map<String, ProgramInfo>.from(state); // Force update
      });

      // Send stop signal immediately
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/T', '/PID', '${process.pid}']);
      } else {
        await Process.run('pkill', ['-TERM', '-P', '${process.pid}']);
        process.kill(ProcessSignal.sigterm);

        // Wait for the process to exit gracefully
        bool exited = false;
        for (int i = 0; i < 30; i++) {
          await Future.delayed(const Duration(seconds: 1));
          try {
            final result = await Process.run('pgrep', ['-P', '${process.pid}']);
            final mainResult =
                await Process.run('ps', ['-p', '${process.pid}']);

            if (result.exitCode != 0 && mainResult.exitCode != 0) {
              exited = true;
              break;
            }
          } catch (e) {
            // Ignore error
          }
        }

        if (!exited) {
          await Process.run('pkill', ['-KILL', '-P', '${process.pid}']);
          process.kill(ProcessSignal.sigkill);
        }
      }
    } catch (e) {
      // Start error countdown in a separate future
      Future(() async {
        for (int i = 10; i >= 1; i--) {
          _countdowns[name] = i;
          await Future.delayed(const Duration(seconds: 1));
        }
        _countdowns.remove(name);
        _processes.remove(name);
        _stoppingProcesses[name] = false;
        _startRequested[name] = false;
        _updateProgramState(name, isRunning: false);
      });

      rethrow;
    }
  }

  // Handle process exit
  void _handleProcessExit(String name, int exitCode) {
    if (!_countdowns.containsKey(name)) {
      _processes.remove(name);
      _stoppingProcesses[name] = false;
      _startRequested[name] = false;
      _updateProgramState(name, isRunning: false);
    }

    if (exitCode != 0) {
      _appendOutput(name, '\nProgram exited with error code: $exitCode\n');
    }
  }

  @override
  void dispose() {
    for (final process in _processes.values) {
      try {
        process.kill();
      } catch (e) {
        // Ignore error
      }
    }
    _processes.clear();
    _stoppingProcesses.clear();
    _startRequested.clear();
    super.dispose();
  }

  ProgramInfo? getProgramInfo(String name) {
    return state[name];
  }
}