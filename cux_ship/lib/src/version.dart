// SPDX-License-Identifier: Apache-2.0
//
// This package's own version, as a constant the code can read.
//
// Hand-maintained, and drift is caught by a test that reads `pubspec.yaml` and
// compares. The alternatives are worse: `Platform.script` does not point at a
// pubspec once the binary is globally activated or AOT-compiled, and generating
// a `.g.dart` for one string would put a codegen step between a version bump
// and a working build.
//
// It matters because a manifest records which producer wrote it. "cux_ship
// 3.4.0" is the difference between reading a five-month-old manifest and
// knowing what it means, and guessing.
const cuxShipVersion = '3.4.0-dev.1';
