// The executable. The body moved to `lib/cli.dart` so that a consumer can name
// the entry as `package:cux_buildnumber/cli.dart` instead of reading `rootUri`
// out of `package_config.json` to find this file; that library's header carries
// the reason. This line keeps `dart run cux_buildnumber:git_buildnumber` and
// `dart pub global activate` working, because both look under `bin/`.
export 'package:cux_buildnumber/cli.dart' show main;
