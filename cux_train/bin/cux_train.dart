// The executable. The body lives in `lib/cli.dart` so that a consumer can name
// the entry as `package:cux_train/cli.dart` instead of reading `rootUri` out of
// `package_config.json` to find this file; that library's header carries the
// reason. This line keeps `dart run cux_train` and `dart pub global activate`
// working, because both look under `bin/`.
export 'package:cux_train/cli.dart' show main;
