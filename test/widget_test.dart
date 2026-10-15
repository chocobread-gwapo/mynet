import 'package:flutter_test/flutter_test.dart';
import 'package:mynet/core/format.dart';
import 'package:mynet/core/validators.dart';

// The default counter-app test that `flutter create` writes doesn't apply to NetPulse, so these small
// tests of the plain-Dart helpers replace it. Run them with `flutter test`.
void main() {
  test('peso formats centavos with thousands separators', () {
    expect(peso(99900), '₱999.00');
    expect(peso(123456789), '₱1,234,567.89');
    expect(peso(-5050), '-₱50.50');
  });

  test('fmtDate shows a readable date', () {
    expect(fmtDate('2026-10-16'), 'Oct 16, 2026');
  });

  test('new passwords need 8+ characters, an uppercase letter and a number', () {
    expect(newPasswordProblem('Password1'), isNull);
    expect(newPasswordProblem('password1'), isNotNull);
    expect(newPasswordProblem('Password'), isNotNull);
    expect(newPasswordProblem('Pass1'), isNotNull);
  });

  test('mobile numbers accept local and +63 forms with spaces or dashes', () {
    expect(mobileValidator('0917-123-4567'), isNull);
    expect(mobileValidator('+63 917 123 4567'), isNull);
    expect(mobileValidator('abc'), isNotNull);
    expect(mobileValidator(''), isNotNull);
  });
}