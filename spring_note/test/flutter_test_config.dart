import 'dart:async';

import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LeakTesting.enable();
  LeakTesting.settings = LeakTesting.settings
      .withTrackedAll()
      // ImageStreamCompleterHandle/_LiveImage are the global image cache's
      // bookkeeping for images still decoding when a test ends; widget tests
      // never finish real codec work under fake async, so they always look
      // alive at teardown.
      .withIgnored(classes: ['ImageStreamCompleterHandle', '_LiveImage'])
      .withCreationStackTrace();
  await testMain();
}
