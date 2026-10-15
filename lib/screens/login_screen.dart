import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:mynet/api.dart';
import 'package:mynet/core/config.dart';
import 'package:mynet/core/session.dart';
import 'package:mynet/core/theme.dart';
import 'package:mynet/screens/forgot_password_screen.dart';
import 'package:mynet/screens/register_screen.dart';
import 'package:mynet/screens/shell.dart';
import 'package:mynet/widgets/code_entry.dart';
import 'package:mynet/widgets/common.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false, _hide = true;
  bool _verifying = false; // true once the server asked for an email code; same form, second step
  bool _remember = false; // the "Remember me" box (starts unticked): stay signed in after the app closes
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRememberMe();
    // Only this screen needs Google Sign-In, so it's initialized here rather than in main() — nothing
    // else in the app touches it. A problem here (e.g. a misconfigured client ID) surfaces when the
    // button is actually tapped, via the try/catch in _signInWithGoogle, rather than crashing startup.
    unawaited(GoogleSignIn.instance.initialize(serverClientId: googleServerClientId));
  }

  /// Puts the "Remember me" box back the way it was left. (The email field is never pre-filled: it
  /// always starts empty.)
  Future<void> _loadRememberMe() async {
    final remember = await api.loadRememberMe();
    if (mounted) setState(() => _remember = remember);
  }

  /// Ticks or unticks the box and saves that straight away, so it's still as left even if the app is
  /// closed without signing in.
  void _setRemember(bool value) {
    setState(() => _remember = value);
    unawaited(api.saveRememberMe(value));
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_verifying) {
        final verificationRequired =
            await api.login(_email.text.trim(), _password.text, remember: _remember);
        if (verificationRequired) {
          setState(() => _verifying = true); // show the code field; submitting again now confirms it
          return;
        }
      } else {
        await api.confirmEmailVerification(_email.text.trim(), _code.text.trim(), remember: _remember);
      }
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    if (!GoogleSignIn.instance.supportsAuthenticate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) throw ApiException("Google didn't return a usable sign-in token.");
      await api.loginWithGoogle(idToken, remember: _remember);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Shell()));
    } on GoogleSignInException catch (e) {
      // The user backing out of the Google account picker isn't an error worth showing.
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      if (mounted) setState(() => _error = e.description ?? 'Google sign-in failed (${e.code}).');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        // Pinned to the bottom of the screen; hidden while the keyboard is open so it never crowds the form.
        bottomNavigationBar: (_verifying || MediaQuery.of(context).viewInsets.bottom > 0)
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  // heightFactor: 1 is essential: a plain Center would grow to fill the whole screen here.
                  child: Align(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Center(
                          child: Text("Don't have an account yet?", style: TextStyle(color: Theme.of(context).hintColor)),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          style: bigButton,
                          onPressed: _busy
                              ? null
                              : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RegisterScreen())),
                          child: const Text('Create an account', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  ),
                ),
              ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(child: Form(
                  key: _formKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text(appName, style: TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    const Text('See what you owe and pay your internet bill in one tap.'),
                    const SizedBox(height: 32),
                    if (!_verifying) ...[
                      TextFormField(
                        controller: _email,
                        autofillHints: [AutofillHints.username, AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                        validator: (v) {
                          final value = v?.trim() ?? '';
                          if (value.isEmpty) return 'Enter your email';
                          if (!value.contains('@') || !value.contains('.')) return 'Enter a valid email';
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        autofillHints: [AutofillHints.password],
                        obscureText: _hide,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          suffixIcon: IconButton(
                            tooltip: _hide ? 'Show password' : 'Hide password',
                            icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                            onPressed: () => setState(() => _hide = !_hide),
                          ),
                        ),
                        validator: (v) {
                          final value = v ?? '';
                          if (value.isEmpty) return 'Enter your password';
                          if (value.length < 8) return 'At least 8 characters';
                          return null;
                        },
                      ),
                      Row(children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: _busy ? null : () => _setRemember(!_remember),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Checkbox(
                                  value: _remember,
                                  onChanged: _busy ? null : (v) => _setRemember(v ?? false),
                                ),
                                const Text('Remember me'),
                                const SizedBox(width: 8),
                              ]),
                            ),
                          ),
                        ),
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => ForgotPasswordScreen(initialEmail: _email.text.trim()))),
                            child: const Text('Forgot password?'),
                          ),
                      ]),
                    ] else ...[
                      stepTwoDots(context),
                      CodeEntry(
                        controller: _code,
                        description: 'We sent a code to ${_email.text.trim()}.',
                        busy: _busy,
                        onResend: () =>
                            api.login(_email.text.trim(), _password.text, remember: _remember),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the code you were sent' : null,
                      ),
                      const SizedBox(height: 4),
                      TextButton(
                        onPressed: _busy ? null : () => setState(() => _verifying = false),
                        child: const Text('Use a different email'),
                      ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
                      ),
                    const SizedBox(height: 20),
                    FilledButton(
                      style: bigButton,
                      onPressed: _busy ? null : _submit,
                      child: Text(_busy
                          ? 'Please wait...'
                          : (_verifying ? 'Confirm code' : 'Sign in')),
                    ),
                    if (!_verifying) ...[
                      const SizedBox(height: 20),
                      Row(children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or', style: TextStyle(color: Theme.of(context).hintColor)),
                        ),
                        const Expanded(child: Divider()),
                      ]),
                      const SizedBox(height: 20),
                      // Google's official circular icon button (from their branding asset pack): the dark
                      // version on dark theme, the light one on light theme. It carries its own circle and border.
                      Center(
                        child: Semantics(
                          button: true,
                          label: 'Continue with Google',
                          child: InkResponse(
                            onTap: _busy ? null : _signInWithGoogle,
                            radius: 32,
                            child: Opacity(
                              opacity: _busy ? 0.5 : 1,
                              child: Image.asset(
                                Theme.of(context).brightness == Brightness.dark
                                    ? 'assets/google_g_dark.png'
                                    : 'assets/google_g_light.png',
                                width: 48,
                                height: 48,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, _, _) => const Icon(Icons.login),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ]),
                )),
              ),
            ),
          ),
        ),
      );
}
