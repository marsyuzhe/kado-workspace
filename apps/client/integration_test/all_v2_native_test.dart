import 'all_native_test.dart' as baseline;
import 'studio_acceptance_test.dart' as studio;
import 'utilities_acceptance_test.dart' as utilities;
import 'codex_probe_acceptance_test.dart' as codex;
import 'utilities_v22b_acceptance_test.dart' as utilities_b;
import 'utilities_v22c_acceptance_test.dart' as utilities_c;
import 'utilities_v22d_acceptance_test.dart' as utilities_d;

void main() {
  baseline.main();
  studio.main();
  utilities.main();
  codex.main();
  utilities_b.main();
  utilities_c.main();
  utilities_d.main();
}
