String? emailValidator(String? v) {
  final value = v?.trim() ?? '';
  if (value.isEmpty) return 'Enter the new email address';
  if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
  return null;
}

/// The rule for a new password, matching the server's. Null when it's fine.
String? newPasswordProblem(String value) {
  if (value.length < 8 || !value.contains(RegExp('[A-Z]')) || !value.contains(RegExp('[0-9]'))) {
    return '8+ characters, an uppercase letter and a number';
  }
  return null;
}

String? mobileValidator(String? v) {
  final value = (v ?? '').replaceAll(RegExp(r'[\s-]'), '');
  if (value.isEmpty) return 'Enter a mobile number';
  if (!RegExp(r'^\+?\d{10,13}$').hasMatch(value)) return 'Enter a valid mobile number';
  return null;
}
