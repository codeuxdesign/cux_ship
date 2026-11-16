/// The command tree, for a caller that wants to run a verb without a process.
///
/// **Published for the same reason `cux_ship` publishes its own**: a consumer
/// that writes its own entry point should not have to reproduce the command
/// list, and a test should not have to spawn a VM to find out what a verb
/// does. `cli.dart` is the executable; this is what it runs.
library;

export 'src/runner.dart' show buildRunner;
