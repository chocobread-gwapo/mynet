import 'package:flutter/material.dart';

/// A password box with its show / hide eye, used by the change-password screen, the change-email and
/// change-mobile screens, and the delete-account dialog.
Widget passwordField({
  required TextEditingController controller,
  required String label,
  required bool hide,
  required VoidCallback onToggle,
  required String? Function(String?) validator,
  String? helper,
  Iterable<String>? autofillHints,
}) =>
    TextFormField(
      controller: controller,
      autofillHints: autofillHints,
      obscureText: hide,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        suffixIcon: IconButton(
          tooltip: hide ? 'Show password' : 'Hide password',
          icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: onToggle,
        ),
      ),
      validator: validator,
    );
